# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "set"
require "tempfile"
require_relative "../../scripts/artifact_log"
require_relative "../../scripts/content_scan"
require_relative "../../scripts/coordinator_runtime"
require_relative "../../scripts/event_log"
require_relative "../../scripts/failure_log"
require_relative "../../scripts/temper_cli"
require_relative "shapes"

module PrGraph
  # Stores a run in a Temper context as it happens, so another machine can resume it (docs/harness.md).
  #
  # A run is one research resource. Each write the harness makes is a data artifact on it, under a kind
  # whose enforcing shape is the log's contract (shapes.rb):
  #
  #   giraffe-run-event-log, -artifact-log, -failure-log   one transition: {transition_id, events}
  #   giraffe-run-<family>                                 an artifact's evidence: {record, content}
  #   giraffe-run-manifest                                 a coordinator lease or result: {name, text}
  #
  # The stored logs below write through the store before they append locally, so a write the store
  # refuses never lands locally. There is no offline mode: a write the store does not take after its
  # retries raises. A write carrying a secret or over 1 MB raises before any Temper call.
  class Store
    class Error < StandardError; end

    TAG = "pr-graph-run"
    UUID = Shapes::PATTERNS.fetch("uuid").delete_prefix("^").delete_suffix("$")
    ARTIFACT_ID = /\A#{UUID}\z/
    MANIFEST_NAME = /\A(?<attempt>#{UUID})\.[a-z_]+\.json\z/i
    EVENT_LOG = Shapes::EVENT_LOG
    ARTIFACT_LOG = Shapes::ARTIFACT_LOG
    FAILURE_LOG = Shapes::FAILURE_LOG
    MANIFEST = Shapes::MANIFEST

    attr_reader :context, :run_id

    def initialize(context:, run_id:, ticket:, cli: TemperCli.new, backoff: [1, 5, 25])
      @context = context
      @run_id = run_id
      @ticket = ticket
      @cli = cli
      @backoff = backoff
      @in_step = Set.new
    end

    # Finds or creates the run's resource and makes every kind enforcing under the shape the contracts
    # build now, declaring a kind again when Temper holds a different one. Idempotent.
    def open!
      @resource = find_resource || create_resource
      declared = temper("data-artifact", "schema", "list", "--context", context).to_h { |shape| [shape["kind"], shape] }
      shapes.each do |kind, schema|
        next if declared_current?(declared[kind], schema)

        with_file(JSON.generate(schema)) do |path|
          temper("data-artifact", "schema", "declare", context, "--kind", kind, "--enforcement", "enforcing", "--content", "@#{path}")
        end
      end
      self
    end

    # Writes one data artifact and returns its ID. Raises Error before any Temper call when the content
    # carries a secret or is over 1 MB, and after the last retry when the store will not take it.
    def commit(kind:, content:, precedence:, correlation:)
      json = JSON.generate(content)
      if (reason = ContentScan.violation(content, json))
        raise Error, "#{kind} was not stored: #{reason}"
      end

      with_file(json) do |path|
        temper("data-artifact", "commit", resource, "--kind", kind, "--intent", "member", "--precedence", precedence.to_s,
               "--content", "@#{path}", "--correlation", correlation).fetch("artifact_id")
      end
    end

    # One append to the log at `path`: a check that every artifact its findings and links name has evidence
    # in Temper, the evidence its own artifact events name, then the events as one transition, then the
    # local append the block makes. A process checks the first time it appends to a log, and again after
    # a local append failed, that Temper holds nothing at or past the log's next sequence number. A crash
    # between Temper taking a transition and the local log taking it leaves the local log behind, and
    # appending would give that sequence number to a different transition.
    def append(kind, path, events, evidence: {})
      key = [kind, path]
      ensure_not_behind!(kind, path, events.first.fetch("seq")) unless @in_step.delete?(key)
      ensure_held!(named_artifacts(events))
      evidence.each { |record, bytes| commit_evidence(record, bytes) }
      commit_transition(kind, events)
      yield
      @in_step << key
    end

    # An artifact's content, which must be UTF-8 text, written before the record that names it.
    def commit_evidence(record, bytes)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      raise Error, "artifact #{record['artifact_id']} content is not UTF-8 text, which the store holds" unless text.valid_encoding?

      commit(kind: Shapes.family_kind(record.fetch("family")), content: {"record" => record, "content" => text},
             precedence: record.fetch("seq"), correlation: record.fetch("attempt_id"))
    end

    def commit_manifest(name, text)
      commit(kind: MANIFEST, content: {"name" => name, "text" => text}, precedence: 0, correlation: name[MANIFEST_NAME, :attempt] || run_id)
    end

    def event_log
      @event_log ||= StoredEventLog.new(self)
    end

    def artifact_log
      @artifact_log ||= StoredArtifactLog.new(self, execution_log: event_log)
    end

    def failure_log
      @failure_log ||= StoredFailureLog.new(self, execution_log: event_log)
    end

    def coordinator(execution_path:, session:)
      StoredCoordinator.new(self, execution_path: execution_path, run_id: run_id, session: session,
                            event_log: event_log, artifact_log: artifact_log, failure_log: failure_log)
    end

    # Rebuilds the run from the store at `path`, a file named as the run's event log was when it was
    # written (an artifact record names its content by that name). Nothing is written unless the whole
    # run reads back and validates: a transition stored twice reads once, and a gap or two different
    # transitions under one ID raise. Evidence and manifests nothing names, left by a write that did not
    # finish, are skipped.
    def hydrate(path)
      path = File.expand_path(path)
      raise Error, "#{path} must end in .jsonl" unless path.end_with?(".jsonl")

      dir = File.dirname(path)
      base = File.basename(path, ".jsonl")
      targets = [path, "#{File.join(dir, base)}.artifacts.jsonl", "#{File.join(dir, base)}.failures.jsonl",
                 "#{File.join(dir, base)}.artifacts", "#{File.join(dir, base)}.coordinator"]
      raise Error, "#{targets.find { |target| File.exist?(target) }} already exists" if targets.any? { |target| File.exist?(target) }

      resource || raise(Error, "#{context} holds no run #{run_id}")
      events = transitions(EVENT_LOG)
      raise Error, "#{context} holds no #{EVENT_LOG} for run #{run_id}" if events.empty?

      artifact_events = transitions(ARTIFACT_LOG)
      failures = transitions(FAILURE_LOG)
      blobs = blobs_for(artifact_events, base)
      manifests = manifests_for(events)

      FileUtils.mkdir_p(dir, mode: 0o700)
      stage = File.join(dir, ".#{base}.hydrate-#{SecureRandom.hex(4)}")
      begin
        FileUtils.mkdir(stage, mode: 0o700)
        staged = File.join(stage, base)
        write_rows("#{staged}.jsonl", events)
        write_rows("#{staged}.artifacts.jsonl", artifact_events) if artifact_events.any?
        write_rows("#{staged}.failures.jsonl", failures) if failures.any?
        blobs.each do |ref, bytes|
          target = File.expand_path(File.join(stage, ref))
          raise Error, "artifact path #{ref} leaves the staging directory" unless target.start_with?("#{File.expand_path(stage)}/")

          write_file(target, bytes)
        end
        manifests.each { |name, text| write_file("#{staged}.coordinator/#{name}", text) }
        validate_staged!("#{staged}.jsonl")
        move_into(stage, dir, base, [".artifacts", ".coordinator", ".artifacts.jsonl", ".failures.jsonl", ".jsonl"])
      ensure
        FileUtils.rm_rf(stage)
      end
      {"events" => events.length, "artifacts" => artifact_events.length, "failures" => failures.length,
       "blobs" => blobs.length, "manifests" => manifests.length}
    end

    private

    def resource
      @resource ||= find_resource
    end

    def shapes
      @shapes ||= Shapes.build
    end

    # One transition of a log: every event one append added, written as one unit.
    def commit_transition(kind, events)
      commit(kind: kind, content: {"transition_id" => SecureRandom.uuid, "events" => events}, precedence: events.first.fetch("seq"),
             correlation: attempt_of(events) || run_id)
    end

    # The artifacts findings and links name, other than those the same append adds.
    def named_artifacts(events)
      added = events.select { |event| event["e"] == "artifact" }.map { |event| event["artifact_id"] }
      named = events.flat_map do |event|
        case event["e"]
        when "finding" then event["artifact_ids"]
        when "link" then event.values_at("from_artifact_id", "to_artifact_id")
        end
      end
      named.compact.uniq - added
    end

    def ensure_held!(ids)
      return if ids.empty?

      missing = ids - evidence.keys
      raise Error, "the store holds no content for artifact #{missing.join(', ')}, which a transition names" if missing.any?
    end

    # Each stored artifact's content by its ID.
    def evidence
      Shapes.family_kinds.each_with_object({}) do |kind, held|
        contents(kind).each { |content| held[content.dig("record", "artifact_id")] = content.fetch("content") }
      end
    end

    def ensure_not_behind!(kind, path, next_seq)
      held = contents(kind).flat_map { |content| content.fetch("events") }.map { |event| event.fetch("seq") }.max
      return if held.nil? || held < next_seq

      raise Error, "#{path} is behind Temper: #{kind} holds sequence #{held} and the next local sequence is #{next_seq}. " \
                   "Hydrate the run from Temper into a new path instead of appending here"
    end

    def declared_current?(shape, schema)
      shape && shape["enforcement"] == "enforcing" &&
        temper("data-artifact", "schema", "show", shape.fetch("shape_id")).dig("schema", "title") == schema["title"]
    end

    def find_resource
      rows = temper("resource", "list", "--context", context, "--type", "research", "--title-contains", run_id,
                    "--all", "--with", "open-meta").fetch("rows")
      rows.find { |row| row.dig("open_meta", "pr_graph_run") == run_id }&.fetch("id")
    end

    def create_resource
      meta = JSON.generate("tags" => [TAG], "pr_graph_run" => run_id, "ticket" => @ticket)
      body = "# pr-graph run #{@ticket} #{run_id}\n\nThis run is in progress. Its event, artifact, and failure logs, its " \
             "coordinator manifests, and its artifacts are stored here as data artifacts as the harness writes them.\n"
      with_file(body) do |path|
        temper("resource", "create", "--type", "research", "--context", context, "--title", "pr-graph run #{@ticket} #{run_id}",
               "--open-meta", meta, "--body", "@#{path}").fetch("id")
      end
    end

    # The first attempt an event belongs to, which every write of that attempt is correlated under.
    def attempt_of(events)
      events.each do |event|
        id = event.values_at("attempt_id", "from_attempt_id", "source_attempt_id").find { |value| value.is_a?(String) }
        return id if id
      end
      nil
    end

    def temper(*args)
      attempts = 1
      begin
        @cli.call(*args)
      rescue TemperCli::Error => e
        delay = @backoff[attempts - 1]
        raise Error, "temper #{args.first(2).join(' ')} failed after #{attempts} attempts: #{e.message}" unless delay

        attempts += 1
        sleep(delay)
        retry
      end
    end

    # The bytes sit in one file for every retry of a write.
    def with_file(text)
      Tempfile.create("pr-graph-store") do |handle|
        handle.write(text)
        handle.flush
        yield handle.path
      end
    end

    def contents(kind)
      temper("data-artifact", "list", resource, "--kind", kind).map { |row| row.fetch("content") }
    end

    # The events of a log in order, each transition once. Two different transitions under one ID raise; a gap
    # or a repeated sequence number fails the log's validator in hydrate.
    def transitions(kind)
      held = {}
      contents(kind).each do |content|
        id = content.fetch("transition_id")
        raise Error, "#{kind} holds two different transitions with ID #{id}" if held.key?(id) && canonical(held[id]) != canonical(content)

        held[id] = content
      end
      held.values.flat_map { |content| content.fetch("events") }.sort_by { |event| event.fetch("seq") }
    end

    def canonical(value)
      case value
      when Hash then value.sort_by { |key, _| key }.to_h { |key, inner| [key, canonical(inner)] }
      when Array then value.map { |inner| canonical(inner) }
      else value
      end
    end

    # Each artifact row's content by its path under the run's directory. The artifact log's validator checks it
    # against the row's SHA-256.
    def blobs_for(artifact_events, base)
      held = evidence
      artifact_events.select { |event| event["e"] == "artifact" }.to_h do |event|
        id = event.fetch("artifact_id")
        raise Error, "artifact #{id.inspect} is not a UUID, so it cannot name a file" unless id.to_s.match?(ARTIFACT_ID)

        ref = "#{base}.artifacts/#{id}.blob"
        raise Error, "artifact #{id} was stored as #{event['content_ref']}; hydrate to a file named #{base}.jsonl" unless event["content_ref"] == ref

        bytes = held[id] or raise Error, "artifact #{id} has no stored content"

        [ref, bytes]
      end
    end

    # Manifests named by a node event, each by name. A manifest whose attempt no event names was written by a
    # step that did not finish.
    def manifests_for(events)
      attempts = events.select { |event| event["e"] == "node" }.to_set { |event| event["attempt_id"] }
      held = {}
      contents(MANIFEST).each do |content|
        name = content.fetch("name")
        match = MANIFEST_NAME.match(name) or raise Error, "#{MANIFEST} holds a manifest with an unusable name"
        next unless attempts.include?(match[:attempt])
        raise Error, "#{MANIFEST} holds two different manifests named #{name}" if held.key?(name) && held[name] != content["text"]

        held[name] = content.fetch("text")
      end
      held
    end

    def write_rows(path, events)
      write_file(path, events.map { |event| "#{JSON.generate(event)}\n" }.join)
    end

    def write_file(path, text)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(text)
        file.flush
        file.fsync
      end
    end

    def validate_staged!(execution_path)
      artifact_path = execution_path.sub(/\.jsonl\z/, ".artifacts.jsonl")
      failure_path = execution_path.sub(/\.jsonl\z/, ".failures.jsonl")
      execution_events = event_log.validate_file!(execution_path)
      artifact_log.validate_file!(artifact_path, execution_path: execution_path)
      failure_log.validate_file!(failure_path, execution_events: execution_events)
    rescue ContractError => e
      raise Error, "the stored run is not a valid run: #{e.message}"
    end

    # Moves what the stage holds into place, the event log last so a partial move never looks like a run.
    def move_into(stage, dir, base, suffixes)
      moved = []
      suffixes.each do |suffix|
        from = File.join(stage, "#{base}#{suffix}")
        next unless File.exist?(from)

        to = File.join(dir, "#{base}#{suffix}")
        File.rename(from, to)
        moved << to
      end
    rescue SystemCallError => e
      moved.each { |to| FileUtils.rm_rf(to) }
      raise Error, "could not place the hydrated run: #{e.message}"
    end
  end

  # An event log whose appends are stored first.
  class StoredEventLog < EventLog
    def initialize(store, contract_path: nil)
      @store = store
      super(contract_path: contract_path)
    end

    private

    def append!(path, additions)
      @store.append(Store::EVENT_LOG, path, additions) { super }
    end
  end

  # An artifact log whose appends are stored first, each artifact's content before the transition naming it.
  class StoredArtifactLog < ArtifactLog
    def initialize(store, contract_path: nil, execution_log: EventLog.new)
      @store = store
      super(contract_path: contract_path, execution_log: execution_log)
    end

    private

    def append!(path, additions)
      evidence = additions.select { |event| event["e"] == "artifact" }.to_h do |event|
        [event, File.binread(File.join(File.dirname(path), event.fetch("content_ref")))]
      end
      @store.append(Store::ARTIFACT_LOG, path, additions, evidence: evidence) { super }
    end
  end

  # A failure log whose appends are stored first.
  class StoredFailureLog < FailureLog
    def initialize(store, contract_path: nil, execution_log: EventLog.new)
      @store = store
      super(contract_path: contract_path, execution_log: execution_log)
    end

    private

    def append_events!(path, events)
      @store.append(Store::FAILURE_LOG, path, events) { super }
    end
  end

  # A coordinator whose lease and result manifests are stored before they are written locally.
  class StoredCoordinator < Coordinator
    def initialize(store, **options)
      @store = store
      super(**options)
    end

    private

    def write_manifest!(path, manifest)
      @store.commit_manifest(File.basename(path), "#{JSON.pretty_generate(manifest)}\n") unless File.exist?(path)
      super
    end
  end
end

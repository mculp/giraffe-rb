# frozen_string_literal: true

require "digest"
require_relative "errors"
require_relative "store"

module Giraffe
  # Local journals are authoritative on the execution host. The journals themselves are the outbox:
  # rebuilding a sync batch never depends on a separate queue entry surviving a crash.
  class LocalStore
    attr_reader :path, :run_id

    # A run's file beside its event log, named by `suffix` in place of the log's extension.
    def self.sibling(path, suffix) = path.sub(/\.jsonl\z/, suffix)

    def self.read_states(path)
      File.open(sibling(path, ".state.jsonl")) do |file|
        file.flock(File::LOCK_SH)
        file.each_line.map { |line| JSON.parse(line) }
      end
    rescue JSON::ParserError
      raise Error, "local state journal is damaged; recover from the last mirrored checkpoint"
    end

    # Mirrors to `backend` as it goes. Without one the run stays local.
    def initialize(path:, run_id:, backend: nil)
      @path, @run_id, @backend = path, run_id, backend
    end

    def event_log = @event_log ||= PrGraph::StoredEventLog.new(self)
    def artifact_log = @artifact_log ||= PrGraph::StoredArtifactLog.new(self, execution_log: event_log)
    def failure_log = @failure_log ||= PrGraph::StoredFailureLog.new(self, execution_log: event_log)
    def coordinator(session:)
      LiveCoordinator.new(self, execution_path: path, run_id: run_id, session: session,
                              event_log: event_log, artifact_log: artifact_log, failure_log: failure_log)
    end

    def read_states = self.class.read_states(path)

    def append_state(content)
      json = JSON.generate(content)
      reason = PrGraph::ContentScan.violation(content, json)
      raise UnstorableContent, "state was not stored: #{reason}" if reason
      File.open(sibling(".state.jsonl"), File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
        file.flock(File::LOCK_EX)
        file.write(json + "\n")
        file.flush
        file.fsync
      end
      live do
        remote.commit(kind: PrGraph::Shapes::HARNESS_LIVE, content: content.slice(*PrGraph::Shapes::HARNESS_LIVE_FIELDS),
                      precedence: content.fetch("revision"), correlation: run_id)
      end
    end

    def sync_status
      target = sibling(".sync.json")
      File.exist?(target) ? JSON.parse(File.read(target)) : {"mode" => mirrored? ? "mirrored" : "local", "synced" => false}
    end

    def sync(state)
      return {"mode" => "local", "synced" => false} unless mirrored?
      logs = {
        PrGraph::Shapes::EVENT_LOG => event_log.validate_file!(path),
        PrGraph::Shapes::ARTIFACT_LOG => artifact_log.read(sibling(".artifacts.jsonl"), allow_empty: true),
        PrGraph::Shapes::FAILURE_LOG => failure_log.read(sibling(".failures.jsonl"), allow_empty: true)
      }
      coordinator(session: state.fetch("session")).snapshot
      # Evidence before the log rows referring to it. The remote copy may be ahead of the last fully
      # synced checkpoint if an earlier sync was interrupted; matching writes are safe to repeat.
      logs.fetch(PrGraph::Shapes::ARTIFACT_LOG).select { |row| row["e"] == "artifact" }.group_by { |row| row["family"] }.each do |family, rows|
        kind = PrGraph::Shapes.family_kind(family)
        held = remote.read_records(kind)
        rows.each do |row|
          bytes = File.read(File.join(File.dirname(path), row.fetch("content_ref")))
          content = {"record" => row, "content" => bytes}
          next if held.include?(content)
          remote.commit_evidence(row, bytes)
        end
      end
      manifests = Dir.glob(sibling(".coordinator/*.json")).sort.to_h { |file| [File.basename(file), File.read(file)] }
      held = remote.read_records(PrGraph::Shapes::MANIFEST)
      manifests.each do |name, text|
        next if held.include?({"name" => name, "text" => text})
        raise Error, "#{@backend} has a different coordinator manifest #{name}" if held.any? { |row| row["name"] == name }
        remote.commit_manifest(name, text)
      end
      logs.each do |kind, rows|
        held_rows = remote.read_records(kind).flat_map { |row| row.fetch("events") }.uniq
        raise Error, "#{@backend} history diverges from this local run" unless held_rows.all? { |row| rows.include?(row) }
        rows.each { |row| commit_row(kind, row) unless held_rows.include?(row) }
      end
      checkpoint = {"logs" => logs.transform_values(&:length), "manifests" => manifests.transform_values { |text| Digest::SHA256.hexdigest(text) }}
      remote_state = state.merge("runtime" => state.fetch("runtime").merge("sync_checkpoint" => checkpoint))
      unless remote.read_records(PrGraph::Shapes::HARNESS).include?(remote_state)
        remote.commit(kind: PrGraph::Shapes::HARNESS, content: remote_state, precedence: state.fetch("revision"), correlation: run_id)
      end
      write_sync_status({"mode" => "mirrored", "synced" => true, "revision" => state["revision"], "event_seq" => logs[PrGraph::Shapes::EVENT_LOG].length})
    rescue StandardError => error
      write_sync_status({"mode" => "mirrored", "synced" => false, "error" => error.message})
    end

    # What the Stored logs call to append: the journal takes the rows first, then the backend, and a row the
    # backend misses waits for the next sync.
    def append(kind, _path, events, evidence: {})
      yield
      live do
        evidence.each { |record, bytes| remote.commit_evidence(record, bytes) }
        events.each { |row| commit_row(kind, row) }
      end
    end

    def live_manifest(file)
      live { remote.commit_manifest(File.basename(file), File.read(file)) }
    end

    private

    def sibling(suffix) = self.class.sibling(path, suffix)
    def mirrored? = !@backend.nil?

    def remote
      @remote ||= PrGraph::Store.new(backend: @backend, run_id: run_id).open!
    end

    # A row's transition ID derives from its content, so a retry after a lost acknowledgement cannot add it twice.
    def commit_row(kind, row)
      digest = Digest::SHA256.hexdigest(JSON.generate(row.sort.to_h))
      uuid = [digest[0, 8], digest[8, 4], digest[12, 4], digest[16, 4], digest[20, 12]].join("-")
      remote.commit(kind: kind, content: {"transition_id" => uuid, "events" => [row]}, precedence: row.fetch("seq"), correlation: run_id)
    end

    def live
      return unless mirrored?
      write_sync_status({"mode" => "mirrored", "synced" => false, "pending_checkpoint" => true})
      yield
    rescue StandardError => error
      write_sync_status({"mode" => "mirrored", "synced" => false, "error" => error.message})
    end

    def write_sync_status(status)
      target = sibling(".sync.json")
      temporary = "#{target}.tmp"
      File.open(temporary, "w", 0o600) { |file| file.write(JSON.generate(status)); file.flush; file.fsync }
      File.rename(temporary, target)
      status
    end
  end

  class LiveCoordinator < PrGraph::Coordinator
    def initialize(store, **options) = (@store = store; super(**options))
    private
    def write_manifest!(path, manifest)
      super
      @store.live_manifest(path)
    end
  end
end

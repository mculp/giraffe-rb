# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require "time"
require_relative "backends"
require_relative "store"
require_relative "local_store"
require_relative "config"

module Giraffe
  class Run
    attr_reader :path, :store, :state

    def self.start(config, ticket)
      id = SecureRandom.uuid
      path = File.join(config["runs_dir"], id, "run.jsonl")
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      state = {"version" => 1, "run_id" => id, "session" => "giraffe-#{id}", "revision" => 0,
               "config" => config.data, "ticket" => ticket, "status" => "running", "questions" => [],
               "answers" => {}, "runtime" => {}, "created_at" => Time.now.utc.iso8601(6), "error" => nil}
      run = new(path, store_for(path, state), state)
      run.save!
      run.store.event_log.emit(path, run_id: id, session: state["session"], payload: {"e" => "run_start", "entry" => "ticket", "ticket" => ticket.fetch("id")})
      run
    end

    def self.load(path)
      path = File.expand_path(path)
      raise Error, "run path must end in .jsonl" unless path.end_with?(".jsonl")
      latest = LocalStore.read_states(path).last
      raise Error, "local state journal is empty" unless latest
      new(path, store_for(path, latest)).reload!
    rescue KeyError => e
      raise Error, "invalid run locator: #{e.message}"
    end

    # Installs a run's last fully synced checkpoint under `destination`. Returns its path and state.
    def self.restore(id, ticket:, destination:, context: nil, database: nil)
      raise Error, "restore takes either --context REF or --database PATH, not both" if context && database
      raise Error, "restore needs --context REF or --database PATH" unless context || database
      raise Error, "invalid run ID" unless id.match?(PrGraph::EventLog::UUID)
      destination = File.expand_path(destination)
      raise Error, "restore destination must be empty" if File.exist?(destination) && Dir.children(destination).any?
      settings = context ? {"backend" => "temper", "context" => context} : {"backend" => "sqlite", "database" => File.expand_path(database)}
      remote = PrGraph::Store.new(backend: Backends.reader(settings, run_id: id, ticket: ticket), run_id: id)
      state = remote.latest_checkpoint || raise(Error, "no fully synced checkpoint")
      raise Error, "checkpoint identity mismatch" unless state["run_id"] == id && same_home?(state["config"], settings)
      FileUtils.mkdir_p(destination, mode: 0o700)
      path = File.join(destination, "run.jsonl")
      remote.hydrate(path)
      # The state came from the backend, so there is nothing to mirror back.
      LocalStore.new(path: path, run_id: id).append_state(state)
      [path, state]
    end

    # A checkpoint belongs to the backend and the context or database it froze at start.
    def self.same_home?(frozen, settings)
      frozen ||= {}
      return false unless (frozen["backend"] || Backends::DEFAULT) == settings["backend"]
      key = settings["backend"] == "sqlite" ? "database" : "context"
      frozen[key] == settings[key]
    end
    private_class_method :same_home?

    def self.store_for(path, state)
      run_id = state.fetch("run_id")
      backend = Backends.mirror(state["config"], run_id: run_id, ticket: state.dig("ticket", "id")) if state.dig("config", "store") == "mirrored"
      LocalStore.new(path: path, run_id: run_id, backend: backend)
    end
    private_class_method :store_for

    def initialize(path, store, state = nil)
      @path, @store, @state = File.expand_path(path), store, state
    end

    def reload!
      records = store.read_states
      raise Error, "local journal holds no harness state for #{store.run_id}" if records.empty?
      revisions = records.group_by { |row| row.fetch("revision") }
      raise Error, "conflicting harness state revisions" unless revisions.each_value.all? { |rows| rows.uniq.one? }
      @state = revisions.max_by { |revision, _| revision }.last.first
      raise Error, "harness state identity mismatch" unless state["version"] == 1 && state["run_id"] == store.run_id
      @config = Config.new(state.fetch("config"), resolved: true)
      self
    end

    def sync = store.sync(state)

    def config = @config ||= Config.new(state.fetch("config"), resolved: true)
    def id = state.fetch("run_id")
    def directory = File.dirname(path)
    def coordinator = @coordinator ||= store.coordinator(session: state.fetch("session"))
    def events = store.event_log.read(path)

    def save!(proposed = state)
      next_state = proposed.merge("revision" => state.fetch("revision") + 1)
      store.append_state(next_state)
      @state = next_state
    end

    def update(**fields)
      save!(state.merge(fields.transform_keys(&:to_s)))
    end

    def checkpoint(key, value) = update(runtime: state.fetch("runtime").merge(key => value))
    def checkpoint_entry(section, key, value) = checkpoint(section, state.fetch("runtime").fetch(section, {}).merge(key => value))

    def lock
      File.open(File.join(directory, "harness.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        raise RunLocked, "this run already has an active harness" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        reload!
        yield
      end
    end

    def answer(question_id, text)
      lock do
        question = state.fetch("questions").find { |row| row["id"] == question_id }
        raise Error, "no open question #{question_id}" unless question
        raise Error, "an answer cannot be empty" if text.to_s.strip.empty?
        update(answers: state["answers"].merge(question_id => {"question" => question["text"], "answer" => text}),
               questions: state["questions"].reject { |row| row["id"] == question_id }, status: "paused")
      end
    end

    def cancel_requested? = File.exist?(cancel_path)

    # An active harness sees the request and stops itself; an idle run is marked here.
    def cancel
      File.write(cancel_path, "cancel\n", mode: "w", perm: 0o600)
      lock { update(status: "cancelled", error: "Cancellation requested by the operator") }
    rescue RunLocked
      nil
    end

    private

    def cancel_path = File.join(directory, "cancel.request")
  end
end

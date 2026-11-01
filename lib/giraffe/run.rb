# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require "time"
require_relative "../../scripts/temper_cli"
require_relative "store"
require_relative "local_store"
require_relative "config"

module Giraffe
  class Run
    KIND = "giraffe-harness-state"
    attr_reader :path, :store, :state

    def self.start(config, ticket, cli: PrGraph::TemperCli.new)
      id = SecureRandom.uuid
      path = File.join(config["runs_dir"], id, "run.jsonl")
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      store = LocalStore.new(path: path, context: config["context"], run_id: id, ticket: ticket.fetch("id"), mirror: config["store"] == "mirrored", cli: cli)
      run = new(path, store)
      run.instance_variable_set(:@state, {"version" => 1, "run_id" => id, "session" => "giraffe-#{id}", "revision" => 0,
                                         "config" => config.data, "ticket" => ticket, "status" => "running", "questions" => [],
                                         "answers" => {}, "runtime" => {}, "created_at" => Time.now.utc.iso8601(6), "error" => nil})
      run.save!
      store.event_log.emit(path, run_id: id, session: run.state["session"], payload: {"e" => "run_start", "entry" => "ticket", "ticket" => ticket.fetch("id")})
      run
    end

    def self.load(path, cli: PrGraph::TemperCli.new)
      path = File.expand_path(path)
      raise Error, "run path must end in .jsonl" unless path.end_with?(".jsonl")
      cached = File.open(path.sub(/\.jsonl\z/, ".state.jsonl")) do |file|
        file.flock(File::LOCK_SH)
        file.each_line.map { |line| JSON.parse(line) }.last
      end
      raise Error, "local state journal is empty" unless cached
      store = LocalStore.new(path: path, context: cached.dig("config", "context"), run_id: cached.fetch("run_id"), ticket: cached.dig("ticket", "id"), mirror: cached.dig("config", "store") == "mirrored", cli: cli)
      run = new(path, store)
      run.reload!
      run
    rescue JSON::ParserError, KeyError => e
      raise Error, "invalid run locator: #{e.message}"
    end

    def initialize(path, store)
      @path, @store = File.expand_path(path), store
    end

    def reload!
      records = store.read_records(KIND)
      raise Error, "local journal holds no harness state for #{store.run_id}" if records.empty?
      revisions = records.group_by { |row| row.fetch("revision") }
      revisions.each_value do |rows|
        raise Error, "conflicting harness state revisions" unless rows.map { |row| canonical(row) }.uniq.length == 1
      end
      @state = revisions.max_by { |revision, _| revision }.last.first
      raise Error, "harness state identity mismatch" unless state["version"] == 1 && state["run_id"] == store.run_id
      Config.new(state.fetch("config"), resolved: true)
      cache!
      self
    end

    def sync = store.sync(state)

    def config = Config.new(state.fetch("config"), resolved: true)
    def id = state.fetch("run_id")
    def directory = File.dirname(path)
    def coordinator = @coordinator ||= store.coordinator(execution_path: path, session: state.fetch("session"))
    def events = store.event_log.read(path)

    def save!(proposed = state)
      next_state = proposed.merge("revision" => state.fetch("revision") + 1)
      store.commit(kind: KIND, content: next_state, precedence: next_state["revision"], correlation: id)
      @state = next_state
      cache!
    end

    def update(**fields)
      save!(state.merge(fields.transform_keys(&:to_s)))
    end

    def lock
      File.open(File.join(directory, "harness.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        raise Error, "this run already has an active harness" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
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

    private

    def cache!
      target = path.sub(/\.jsonl\z/, ".harness.json")
      temporary = "#{target}.#{SecureRandom.hex(4)}.tmp"
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.pretty_generate(state)); file.flush; file.fsync }
      File.rename(temporary, target)
    ensure
      File.unlink(temporary) if temporary && File.file?(temporary)
    end

    def canonical(value)
      case value
      when Hash then value.sort.to_h.transform_values { |inner| canonical(inner) }
      when Array then value.map { |inner| canonical(inner) }
      else value
      end
    end
  end
end

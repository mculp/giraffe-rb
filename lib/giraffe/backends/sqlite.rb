# frozen_string_literal: true

require "json"
require_relative "kind_map"
require_relative "../store"

module Giraffe
  module Backends
    # Keeps a run in a SQLite file that many runs may share: one row per run, and one append-only row per record.
    # SQLite declares no shapes, so a run is pinned to this release's kinds once, on its row, not on each record.
    class Sqlite
      # The one class callers rescue, whichever backend a run is on.
      Error = PrGraph::Store::Error
      BUSY_TIMEOUT_MS = 10_000
      SCHEMA = [
        "CREATE TABLE IF NOT EXISTS runs (run_id TEXT PRIMARY KEY, ticket TEXT, kind_map TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS records (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL, " \
        "kind TEXT NOT NULL, content TEXT NOT NULL, precedence, correlation)",
        # Every append reads a kind's records for its run back, and one file holds many runs, so without this each read scans
        # every run's records. `id` comes last so the same index also returns them in the order they were committed.
        "CREATE INDEX IF NOT EXISTS records_by_run_kind ON records (run_id, kind, id)"
      ].freeze
      INSERT_RUN = "INSERT OR IGNORE INTO runs (run_id, ticket, kind_map) VALUES (?, ?, ?)"
      INSERT_RECORD = "INSERT INTO records (run_id, kind, content, precedence, correlation) VALUES (?, ?, ?, ?, ?)"

      # A running run's mirror. It creates the file and the run's row when they are missing.
      def self.mirror(settings, run_id:, ticket:)
        new(path: settings.fetch("database"), run_id: run_id, ticket: ticket, creating: true)
      end

      # A restore's one read of a run. It creates nothing: a mistyped path must fail, not become an empty database.
      def self.reader(settings, run_id:, ticket:)
        new(path: settings.fetch("database"), run_id: run_id, ticket: ticket, creating: false)
      end

      # The driver loads when the backend is built, not at its first call: live writes swallow errors into the sync status,
      # so a missing gem must fail here, where the run is built.
      def initialize(path:, run_id:, ticket:, creating:)
        load_driver
        @path = path
        @run_id = run_id
        @ticket = ticket
        @creating = creating
      end

      # Ensures the schema and the run's row. Idempotent: a run has exactly one row.
      def open!
        create if @creating
        guard { check_pin }
        self
      end

      # Appends one record and returns its ID.
      def commit(kind:, content:, precedence:, correlation:)
        write do
          db.execute(INSERT_RECORD, [run_id, kind, JSON.generate(content), precedence, correlation])
          db.last_insert_row_id.to_s
        end
      end

      def contents(kind)
        guard do
          next [] unless tables?

          db.execute("SELECT content FROM records WHERE run_id = ? AND kind = ? ORDER BY id", [run_id, kind])
            .map { |(text)| JSON.parse(text) }
        end
      end

      def holds_run?
        guard do
          next false unless tables? && !stored_map.nil?

          check_pin
          true
        end
      end

      def to_s
        path
      end

      private

      attr_reader :path, :run_id

      # The gem is optional, so only a run that chose this backend needs it.
      def load_driver
        require "sqlite3"
      rescue LoadError
        raise Error, "the sqlite backend needs the sqlite3 gem: gem install sqlite3"
      end

      def db
        @db ||= connect
      end

      def connect
        raise Error, "#{path} does not exist" unless @creating || File.exist?(path)

        SQLite3::Database.new(path, readonly: !@creating).tap { |database| database.busy_timeout = BUSY_TIMEOUT_MS }
      end

      # The schema and the run's row in one transaction, so a run is never half made.
      def create
        write do
          SCHEMA.each { |sql| db.execute(sql) }
          db.execute(INSERT_RUN, [run_id, @ticket, JSON.generate(KindMap.current)])
        end
      end

      # Immediate, so a writer takes the lock where it begins and waits on the busy timeout there, instead of failing
      # partway when a deferred transaction tries to upgrade.
      def write(&block) = guard { db.transaction(:immediate, &block) }

      # Whatever SQLite refuses reaches callers as the Error every backend raises, naming the file.
      def guard
        yield
      rescue SQLite3::Exception => e
        raise Error, "#{path}: #{e.message}"
      end

      def tables?
        return false if @creating && !File.exist?(path) # asking must not create the file

        db.get_first_value("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name IN ('runs', 'records')") == 2
      end

      def stored_map
        db.get_first_value("SELECT kind_map FROM runs WHERE run_id = ?", [run_id])
      end

      def check_pin
        stored = stored_map
        raise Error, KindMap::MISMATCH if stored && JSON.parse(stored) != KindMap.current
      end
    end
  end
end

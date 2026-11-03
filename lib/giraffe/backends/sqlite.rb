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
        "kind TEXT NOT NULL, content TEXT NOT NULL, precedence, correlation)"
      ].freeze

      # A running run's mirror. It creates the file and the run's row when they are missing.
      def self.mirror(settings, run_id:, ticket:)
        new(path: settings.fetch("database"), run_id: run_id, ticket: ticket, creating: true)
      end

      # A restore's one read of a run. It creates nothing: a mistyped path must fail, not become an empty database.
      def self.reader(settings, run_id:, ticket:)
        new(path: settings.fetch("database"), run_id: run_id, ticket: ticket, creating: false)
      end

      def initialize(path:, run_id:, ticket:, creating:)
        @path = path
        @run_id = run_id
        @ticket = ticket
        @creating = creating
      end

      # Ensures the schema and the run's row. Idempotent: a run has exactly one row.
      def open!
        guard do
          if @creating
            db.transaction(:immediate) do
              SCHEMA.each { |sql| db.execute(sql) }
              db.execute("INSERT OR IGNORE INTO runs (run_id, ticket, kind_map) VALUES (?, ?, ?)",
                         [run_id, @ticket, JSON.generate(KindMap.current)])
            end
          end
          check_pin
        end
        self
      end

      # Appends one record and returns its ID.
      def commit(kind:, content:, precedence:, correlation:)
        guard do
          db.transaction(:immediate) do
            db.execute("INSERT INTO records (run_id, kind, content, precedence, correlation) VALUES (?, ?, ?, ?, ?)",
                       [run_id, kind, JSON.generate(content), precedence, correlation])
            db.last_insert_row_id.to_s
          end
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

      def db
        @db ||= connect
      end

      def connect
        raise Error, "#{path} does not exist" unless @creating || File.exist?(path)

        SQLite3::Database.new(path, readonly: !@creating).tap { |database| database.busy_timeout = BUSY_TIMEOUT_MS }
      end

      # The gem is optional, so only a run that chose this backend needs it.
      def load_driver
        require "sqlite3"
      rescue LoadError
        raise Error, "the sqlite backend needs the sqlite3 gem: gem install sqlite3"
      end

      def guard
        load_driver
        begin
          yield
        rescue SQLite3::Exception => e
          raise Error, "#{path}: #{e.message}"
        end
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

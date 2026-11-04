# frozen_string_literal: true

require_relative "../errors"

module Giraffe
  module Backends
    # Where a restore reads a run from: a backend, and the one setting that says where in it, a Temper context or a SQLite
    # database file. The restore's two flags name it, and exactly one of them must.
    class Home
      def self.from(context: nil, database: nil)
        raise Error, "restore takes either --context REF or --database PATH, not both" if context && database
        raise Error, "restore needs --context REF or --database PATH" unless context || database

        context ? new("temper", "context", context) : new("sqlite", "database", File.expand_path(database))
      end
      private_class_method :new

      def initialize(backend, key, place)
        @backend = backend
        @key = key
        @place = place
      end

      # What Backends.reader builds a backend from.
      def settings = {"backend" => @backend, @key => @place}

      # A checkpoint belongs to the backend and the context or database it froze at start. A configuration from before
      # `backend` existed names none, and means the default.
      def named_by?(frozen)
        frozen ||= {}
        (frozen["backend"] || Backends::DEFAULT) == @backend && frozen[@key] == @place
      end
    end
  end
end

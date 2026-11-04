# frozen_string_literal: true

require "digest"
require "json"
require "tempfile"
require_relative "../../../scripts/temper_cli"
require_relative "../shapes"
require_relative "../store"

module Giraffe
  module Backends
    # Keeps a run in a Temper context: the run is one research resource, and each record a data artifact on it,
    # under a kind Temper enforces the shape of. A call Temper still refuses after its retries raises Error.
    class Temper
      # The one class callers rescue, whichever backend a run is on.
      Error = PrGraph::Store::Error
      TAG = "giraffe-live-run"

      # A running run's mirror. The journal is the retry queue, so it never waits on a retry, and it pins the
      # run's kinds to this release's contracts.
      def self.mirror(settings, run_id:, ticket:)
        new(context: settings["context"], run_id: run_id, ticket: ticket, backoff: [], versioned: true)
      end

      # A restore's one read of a run. No running harness waits on it, so it keeps the usual retries, and it
      # creates nothing, so the run's own record decides which kinds it reads.
      def self.reader(settings, run_id:, ticket:)
        new(context: settings["context"], run_id: run_id, ticket: ticket)
      end

      def initialize(context:, run_id:, ticket:, cli: PrGraph::TemperCli.new, backoff: [1, 5, 25], versioned: false)
        @context = context
        @run_id = run_id
        @ticket = ticket
        @cli = cli
        @backoff = backoff
        @versioned = versioned
      end

      # Finds or creates the run's resource and makes every kind enforcing under the shape the contracts
      # build now, declaring a kind again when Temper holds a different one. Idempotent.
      def open!
        @resource = find_resource || create_resource
        declared = temper("data-artifact", "schema", "list", "--context", context).to_h { |shape| [shape["kind"], shape] }
        shapes.each do |kind, schema|
          physical = physical_kind(kind)
          next if declared_current?(declared[physical], schema)

          with_file(JSON.generate(schema)) do |path|
            temper("data-artifact", "schema", "declare", context, "--kind", physical, "--enforcement", "enforcing", "--content", "@#{path}")
          end
        end
        self
      end

      # Writes one data artifact and returns its ID.
      def commit(kind:, content:, precedence:, correlation:)
        with_file(JSON.generate(content)) do |path|
          temper("data-artifact", "commit", resource, "--kind", physical_kind(kind), "--intent", "member", "--precedence", precedence.to_s,
                 "--content", "@#{path}", "--correlation", correlation).fetch("artifact_id")
        end
      end

      def contents(kind)
        temper("data-artifact", "list", resource, "--kind", physical_kind(kind)).map { |row| row.fetch("content") }
      end

      def holds_run?
        !resource.nil?
      end

      def to_s
        context
      end

      private

      attr_reader :context, :run_id

      def resource
        @resource ||= find_resource
      end

      def shapes
        @shapes ||= PrGraph::Shapes.build
      end

      def versioned_kinds
        shapes.to_h { |kind, schema| [kind, "#{kind}-#{Digest::SHA256.hexdigest(JSON.generate(schema))[0, 16]}"] }
      end

      # Finding the resource is what loads the run's kind map, so it comes first.
      def physical_kind(kind)
        resource
        @kind_map ? @kind_map.fetch(kind) : kind
      end

      # A versioned kind's name already carries its schema's digest, so only an unversioned one needs reading back.
      def declared_current?(shape, schema)
        return false unless shape && shape["enforcement"] == "enforcing"

        @kind_map || temper("data-artifact", "schema", "show", shape.fetch("shape_id")).dig("schema", "title") == schema["title"]
      end

      def find_resource
        rows = temper("resource", "list", "--context", context, "--type", "research", "--title-contains", run_id,
                      "--all", "--with", "open-meta").fetch("rows")
        matches = rows.select { |row| row.dig("open_meta", "giraffe_run_id") == run_id }
        raise Error, "multiple live resources claim run #{run_id}; reconcile them before writing" if matches.length > 1
        return nil if matches.empty?
        @kind_map = matches.first.dig("open_meta", "giraffe_kind_map")
        if @kind_map && @kind_map != versioned_kinds
          raise Error, "run uses different contracts; resume it with its pinned Giraffe release"
        end
        matches.first.fetch("id")
      end

      def create_resource
        @kind_map = versioned_kinds if @versioned
        meta = JSON.generate({"tags" => [TAG], "giraffe_run_id" => run_id, "ticket" => @ticket, "giraffe_kind_map" => @kind_map}.compact)
        body = "# giraffe live run #{@ticket} #{run_id}\n\nThis run is in progress. Its event, artifact, and failure logs, its " \
               "coordinator manifests, and its artifacts are stored here as data artifacts as the harness writes them.\n"
        with_file(body) do |path|
          @cli.call("resource", "create", "--type", "research", "--context", context, "--title", "giraffe live run #{@ticket} #{run_id}",
                 "--open-meta", meta, "--body", "@#{path}").fetch("id")
        end
      rescue PrGraph::TemperCli::Error => error
        find_resource || raise(Error, "resource creation was not confirmed: #{error.message}; retry sync to reconcile")
      end

      def temper(*args)
        attempts = 1
        begin
          @cli.call(*args)
        rescue PrGraph::TemperCli::Error => e
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
    end
  end
end

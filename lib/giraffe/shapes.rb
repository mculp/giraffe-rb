# frozen_string_literal: true

require "digest"
require "json"

module PrGraph
  # The JSON Schemas (draft 2020-12) Temper enforces on each data artifact kind a run is stored under,
  # built from the v1 contracts at runtime so the store refuses what the logs would refuse. Each schema's
  # title carries a digest of the schema, so a store can tell whether Temper holds the current one.
  #
  # One kind per log (`giraffe-run-event-log`, `-artifact-log`, `-failure-log`), one for coordinator
  # manifests, and one per artifact family (`giraffe-run-<family>`, with `_` as `-`). The `giraffe-run-`
  # prefix keeps them apart from the kinds the finished-run record commits (`scripts/run_record.rb`).
  module Shapes
    ROOT = File.expand_path("../..", __dir__)
    EVENT_LOG = "giraffe-run-event-log"
    ARTIFACT_LOG = "giraffe-run-artifact-log"
    FAILURE_LOG = "giraffe-run-failure-log"
    MANIFEST = "giraffe-run-manifest"
    HARNESS = "giraffe-harness-state"
    DIALECT = "https://json-schema.org/draft/2020-12/schema"
    # JSON Schema keeps these as patterns. They stay inside the dialect Temper and Ruby share: no \d, no
    # inline flags, and a case-insensitive class spelled out.
    PATTERNS = {
      "uuid" => "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
      "session" => "^[A-Za-z0-9_-]{1,128}$",
      "git_sha" => "^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$",
      "sha256" => "^[0-9a-fA-F]{64}$",
      "artifact_ref" => "^[A-Za-z0-9_.-]+\\.artifacts/[0-9a-fA-F-]{36}\\.blob$",
      "outcome_id" => "^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$",
      "utc_timestamp" => "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$"
    }.freeze

    module_function

    # The kind an artifact family's evidence is stored under.
    def family_kind(family)
      "giraffe-run-#{family.tr('_', '-')}"
    end

    def family_kinds
      contract("artifact").fetch("families").keys.map { |family| family_kind(family) }
    end

    # Every governed kind and its schema.
    def build
      execution = contract("execution")
      artifact = contract("artifact")
      failure = contract("failure")
      nodes = execution.dig("graph", "nodes")
      families = artifact.fetch("families").keys
      lookup = {"node" => nodes, "node_or_orchestrator" => nodes + ["ORCHESTRATOR"], "artifact_family" => families}

      record = branch("artifact", artifact.dig("events", "artifact"), artifact.fetch("envelope"), lookup)
      kinds = {
        EVENT_LOG => transition(execution.fetch("events").map do |name, spec|
          branch(name, spec, execution.fetch("envelope"), lookup, extra: execution.fetch("common_properties"))
        end),
        ARTIFACT_LOG => transition(artifact.fetch("events").map do |name, spec|
          branch(name, spec, artifact.fetch("envelope"), lookup)
        end),
        FAILURE_LOG => transition(failure.fetch("events").map do |name, spec|
          branch(name, {"required" => spec.fetch("required"), "properties" => {}}, {"required" => failure.dig("envelope", "required"),
                 "properties" => execution.dig("envelope", "properties")}, lookup)
        end),
        MANIFEST => object({"name" => {"type" => "string", "minLength" => 1}, "text" => {"type" => "string"}}),
        HARNESS => object({"version" => {"const" => 1}, "run_id" => {"type" => "string", "pattern" => PATTERNS.fetch("uuid")},
                           "revision" => {"type" => "integer", "minimum" => 1}, "session" => {"type" => "string"},
                           "config" => {"type" => "object"}, "ticket" => {"type" => "object"},
                           "status" => {"type" => "string"}, "questions" => {"type" => "array"},
                           "answers" => {"type" => "object"}, "created_at" => {"type" => "string"},
                           "error" => {"type" => ["string", "null"]}, "runtime" => {"type" => "object"}})
      }
      families.each do |family|
        family_record = Marshal.load(Marshal.dump(record))
        family_record["properties"]["family"] = {"const" => family}
        kinds[family_kind(family)] = object({"record" => family_record, "content" => {"type" => "string"}})
      end
      kinds["giraffe-harness-live"] = kinds.fetch(HARNESS)
      kinds.transform_values do |schema|
        {"$schema" => DIALECT, "title" => "giraffe run store #{Digest::SHA256.hexdigest(JSON.generate(schema))[0, 16]}"}.merge(schema)
      end
    end

    def contract(name)
      JSON.parse(File.read(File.join(ROOT, "references", "#{name}-contract-v1.json")))
    end

    # A transition: one write, a transition ID and the events it holds, each one of the log's event types.
    def transition(branches)
      object("transition_id" => {"type" => "string", "pattern" => PATTERNS.fetch("uuid")},
             "events" => {"type" => "array", "minItems" => 1, "items" => {"oneOf" => branches}})
    end

    # An object that requires every key it names and allows no other.
    def object(properties)
      {"type" => "object", "required" => properties.keys, "properties" => properties, "additionalProperties" => false}
    end

    # One event type: the envelope, its own properties, and `e` pinned to its name.
    def branch(name, spec, envelope, lookup, extra: {})
      properties = envelope.fetch("properties").merge(extra).merge(spec.fetch("properties"))
      required = envelope.fetch("required") + spec.fetch("required")
      properties = required.to_h { |key| [key, {}] }.merge(properties)
      translated = properties.transform_values { |rules| rule(rules, lookup) }
      translated["e"] = {"type" => "string", "const" => name}
      {"type" => "object", "required" => required, "properties" => translated, "additionalProperties" => false}
    end

    # One contract rule as JSON Schema keywords. A rule the contract uses that is not listed here raises, so
    # a new rule cannot reach the contract without a shape.
    def rule(rules, lookup)
      rules.each_with_object({}) do |(key, value), schema|
        case key
        when "type", "const", "enum", "minimum" then schema[key] = value
        when "min_length" then schema["minLength"] = value
        when "items" then schema["items"] = rule(value, lookup)
        when "format" then schema.merge!(format(value, lookup))
        else raise ArgumentError, "the contracts use a rule with no shape: #{key}"
        end
      end
    end

    def format(name, lookup)
      return {"pattern" => PATTERNS.fetch(name)} if PATTERNS.key?(name)
      return {"enum" => lookup.fetch(name)} if lookup.key?(name)

      raise ArgumentError, "the contracts use a format with no shape: #{name}"
    end
  end
end

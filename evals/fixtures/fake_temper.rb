#!/usr/bin/env ruby
# frozen_string_literal: true

# A stand-in for the `temper` CLI, for tests and eval fixtures. It serves one context from
# FAKE_TEMPER_CONTEXT (a JSON file of {"context", "rows", "contents", "artifacts", "shapes"}) and saves
# writes back to the file. It answers:
#
#   resource list, show, create, update
#   data-artifact commit     stores kind, intent, precedence, correlation, supersedes, and the content with
#                            its object keys sorted, as Temper returns them. An enforcing shape for the kind
#                            refuses non-conforming content, naming the failing JSON path, and stores nothing.
#   data-artifact list       the resource's artifacts in commit order, without superseded ones unless
#                            --include-folded, with Temper's row keys
#   data-artifact schema declare, list, show
#                            shapes by kind (show adds the schema); a schema using a keyword outside the
#                            subset checked here is refused
#
# It appends every invocation to FAKE_TEMPER_LOG. Any other context, and any invocation containing
# FAKE_TEMPER_FAIL, answers with the CLI's API error. The first data-artifact commit containing
# FAKE_TEMPER_LOSE_ONCE stores its write and then answers with that error, as a write that landed but
# reported failure; the loss is recorded under "lost" in the context file.

require "json"

File.open(ENV.fetch("FAKE_TEMPER_LOG"), "a") { |log| log.puts(ARGV.join(" ")) }
path = ENV.fetch("FAKE_TEMPER_CONTEXT")
project = JSON.parse(File.read(path))
refuse = lambda do |message = "forbidden"|
  puts JSON.generate("code" => "api", "message" => "API error: #{message}")
  exit 1
end
fail_on = ENV["FAKE_TEMPER_FAIL"].to_s
refuse.call("unavailable") if !fail_on.empty? && ARGV.join(" ").include?(fail_on)
option = ->(name) { (index = ARGV.index(name)) && ARGV[index + 1] }
file = ->(name) { File.read(option.call(name).delete_prefix("@")) }
save = lambda do |output|
  File.write(path, JSON.generate(project))
  puts JSON.generate(output)
end

SCHEMA_KEYWORDS = %w[type const enum minimum minLength pattern required properties additionalProperties items minItems oneOf $schema title].freeze

# The first keyword in a schema that conform does not check, so a shape cannot rely on a rule the fake skips.
unchecked = lambda do |schema|
  return nil unless schema.is_a?(Hash)

  extra = (schema.keys - SCHEMA_KEYWORDS).first
  return extra if extra

  children = schema.fetch("properties", {}).values + [schema["items"]].compact + schema.fetch("oneOf", [])
  children << schema["additionalProperties"] if schema["additionalProperties"].is_a?(Hash)
  children.each do |child|
    found = unchecked.call(child)
    return found if found
  end
  nil
end

# The ways a value fails a schema, each naming its JSON path; empty when it conforms.
conform = lambda do |schema, value, path|
  types = Array(schema["type"])
  type_ok = lambda do |type|
    case type
    when "object" then value.is_a?(Hash)
    when "array" then value.is_a?(Array)
    when "string" then value.is_a?(String)
    when "integer" then value.is_a?(Integer)
    when "number" then value.is_a?(Numeric)
    when "boolean" then [true, false].include?(value)
    when "null" then value.nil?
    end
  end
  return ["#{path}: must have type #{types.join(' or ')}"] if types.any? && types.none?(&type_ok)

  errors = []
  errors << "#{path}: must equal #{schema['const'].inspect}" if schema.key?("const") && value != schema["const"]
  errors << "#{path}: must be one of #{schema['enum'].join(', ')}" if schema["enum"] && !schema["enum"].include?(value)
  errors << "#{path}: must be at least #{schema['minimum']}" if schema["minimum"] && value.is_a?(Numeric) && value < schema["minimum"]
  if value.is_a?(String)
    errors << "#{path}: must have at least #{schema['minLength']} characters" if schema["minLength"] && value.length < schema["minLength"]
    if schema["pattern"]
      pattern = Regexp.new(schema["pattern"].sub(/\A\^/, "\\A").sub(/\$\z/, "\\z"))
      errors << "#{path}: must match #{schema['pattern']}" unless value.match?(pattern)
    end
  end
  if value.is_a?(Hash)
    (schema["required"] || []).each { |key| errors << "#{path}: missing required property #{key}" unless value.key?(key) }
    properties = schema["properties"] || {}
    value.each do |key, inner|
      if properties.key?(key) then errors.concat(conform.call(properties[key], inner, "#{path}.#{key}"))
      elsif schema["additionalProperties"] == false then errors << "#{path}: unexpected property #{key}"
      elsif schema["additionalProperties"].is_a?(Hash) then errors.concat(conform.call(schema["additionalProperties"], inner, "#{path}.#{key}"))
      end
    end
  end
  if value.is_a?(Array)
    errors << "#{path}: must have at least #{schema['minItems']} items" if schema["minItems"] && value.length < schema["minItems"]
    value.each_with_index { |inner, index| errors.concat(conform.call(schema["items"], inner, "#{path}[#{index}]")) } if schema["items"]
  end
  if schema["oneOf"]
    results = schema["oneOf"].map { |branch| conform.call(branch, value, path) }
    matched = results.count(&:empty?)
    if matched.zero? then errors.concat(results.min_by(&:length))
    elsif matched > 1 then errors << "#{path}: matches more than one oneOf branch"
    end
  end
  errors
end

sorted = lambda do |value|
  case value
  when Hash then value.sort_by { |key, _| key }.to_h { |key, inner| [key, sorted.call(inner)] }
  when Array then value.map { |inner| sorted.call(inner) }
  else value
  end
end

shape_state = lambda do |artifact|
  shape = project.fetch("shapes", {})[artifact["kind"]]
  if shape.nil? then "never_declared"
  elsif conform.call(shape["schema"], artifact["content"], "$").empty? then "conforming"
  else "non_conforming"
  end
end

case ARGV.first(2)
when %w[resource list]
  refuse.call unless option.call("--context") == project.fetch("context")
  rows = project.fetch("rows")
  rows = rows.select { |row| row["title"].include?(option.call("--title-contains")) } if option.call("--title-contains")
  puts JSON.generate("rows" => rows, "total" => rows.length, "returned" => rows.length, "truncated" => false)
when %w[resource show]
  content = project.fetch("contents", {})[ARGV[2]] or refuse.call
  puts JSON.generate("id" => ARGV[2], "content" => content)
when %w[resource create]
  refuse.call unless option.call("--context") == project.fetch("context")
  id = format("01a00000-0000-7000-8000-%012d", project["rows"].length + 100)
  project["rows"] << {"id" => id, "doc_type_name" => option.call("--type"), "title" => option.call("--title"),
                      "open_meta" => JSON.parse(option.call("--open-meta"))}
  (project["contents"] ||= {})[id] = file.call("--body")
  save.call("id" => id)
when %w[resource update]
  row = project["rows"].find { |candidate| candidate["id"] == ARGV[2] } or refuse.call
  row["open_meta"] = JSON.parse(option.call("--open-meta")) if option.call("--open-meta")
  project["contents"][ARGV[2]] = file.call("--body") if option.call("--body")
  save.call("id" => ARGV[2])
when %w[data-artifact commit]
  refuse.call unless project["rows"].any? { |row| row["id"] == ARGV[2] }
  artifacts = (project["artifacts"] ||= [])
  id = format("02a00000-0000-7000-8000-%012d", artifacts.length + 1)
  supersedes = ARGV.each_index.select { |i| ARGV[i] == "--supersedes" }.map { |i| ARGV[i + 1] }
  artifact = {"id" => id, "resource" => ARGV[2], "kind" => option.call("--kind"), "intent" => option.call("--intent"),
              "precedence" => Float(option.call("--precedence") || 0), "correlation" => option.call("--correlation"),
              "supersedes" => supersedes, "content" => sorted.call(JSON.parse(file.call("--content")))}
  shape = project.fetch("shapes", {})[artifact["kind"]]
  if shape && shape["enforcement"] == "enforcing" && (errors = conform.call(shape["schema"], artifact["content"], "$")).any?
    refuse.call("content does not conform to the #{artifact['kind']} shape: #{errors.first}")
  end
  artifacts << artifact
  lose_on = ENV["FAKE_TEMPER_LOSE_ONCE"].to_s
  if !lose_on.empty? && ARGV.join(" ").include?(lose_on) && !project.fetch("lost", []).include?(lose_on)
    project["lost"] = project.fetch("lost", []) + [lose_on]
    File.write(path, JSON.generate(project))
    refuse.call("unavailable")
  end
  save.call("artifact_id" => id)
when %w[data-artifact list]
  refuse.call unless project["rows"].any? { |row| row["id"] == ARGV[2] }
  artifacts = project.fetch("artifacts", []).select { |artifact| artifact["resource"] == ARGV[2] }
  folded = artifacts.flat_map { |artifact| artifact["supersedes"] }
  artifacts = artifacts.select { |artifact| artifact["kind"] == option.call("--kind") } if option.call("--kind")
  artifacts = artifacts.select { |artifact| artifact["intent"] == option.call("--intent") } if option.call("--intent")
  artifacts = artifacts.reject { |artifact| folded.include?(artifact["id"]) } unless ARGV.include?("--include-folded")
  puts JSON.generate(artifacts.map do |artifact|
    {"artifact_id" => artifact["id"], "artifact_kind" => artifact["kind"], "intent" => artifact["intent"],
     "precedence" => artifact["precedence"], "is_folded" => folded.include?(artifact["id"]), "resource_id" => artifact["resource"],
     "shape_state" => shape_state.call(artifact), "content" => artifact["content"]}
  end)
when %w[data-artifact schema]
  case ARGV[2]
  when "declare"
    refuse.call unless ARGV[3] == project.fetch("context")
    schema = JSON.parse(file.call("--content"))
    if (keyword = unchecked.call(schema))
      refuse.call("the fake Temper does not check the #{keyword} keyword, so a shape may not use it")
    end
    shapes = (project["shapes"] ||= {})
    kind = option.call("--kind")
    version = shapes.key?(kind) ? shapes[kind]["version"] + 1 : 1
    shapes[kind] = {"shape_id" => format("03a00000-0000-7000-8000-%012d", shapes.length + 1), "kind" => kind,
                    "enforcement" => option.call("--enforcement") || "advisory", "version" => version, "schema" => schema}
    save.call(shapes[kind].slice("shape_id", "kind", "enforcement", "version"))
  when "show"
    shape = project.fetch("shapes", {}).values.find { |candidate| candidate["shape_id"] == ARGV[3] } or refuse.call("shape not found")
    puts JSON.generate(shape.slice("shape_id", "kind", "enforcement", "version", "schema"))
  when "list"
    refuse.call unless option.call("--context") == project.fetch("context")
    puts JSON.generate(project.fetch("shapes", {}).values.map { |shape| shape.slice("shape_id", "kind", "enforcement", "version") })
  else
    warn "fake temper: unsupported command #{ARGV.join(' ')}"
    exit 2
  end
else
  warn "fake temper: unsupported command #{ARGV.join(' ')}"
  exit 2
end

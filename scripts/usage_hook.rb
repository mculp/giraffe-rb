#!/usr/bin/env ruby
# frozen_string_literal: true

# Claude/Cursor hook. Append usage events only when the hook conversation has
# a matching active pr-graph run. Fail open so telemetry can never block work.

require "json"
require "digest"
require "fileutils"
require_relative "event_log"

def state_root
  override = ENV["PR_GRAPH_STATE_ROOT"]
  return File.expand_path(override) unless override.to_s.empty?

  installed_root = File.expand_path("../.cursor-state-root", __dir__)
  return File.read(installed_root).chomp if File.file?(installed_root)

  script = File.expand_path(__FILE__)
  product = script.include?("/.cursor/") ? ".cursor" : ".claude"
  File.expand_path("~/#{product}/pr-graph")
end

def hook_product(payload)
  return "cursor" if payload.key?("conversation_id") || File.file?(File.expand_path("../.cursor-state-root", __dir__))

  File.expand_path(__FILE__).include?("/.cursor/") ? "cursor" : "claude"
end

def valid_session?(session)
  session.to_s.match?(/\A[A-Za-z0-9_-]{1,128}\z/)
end

def read_state(path)
  File.readlines(path, chomp: true).each_with_object({}) do |line, state|
    key, value = line.split("=", 2)
    state[key] = value if key && value
  end
end

def transcript_checkpoint(session, path)
  digest = Digest::SHA256.hexdigest(File.expand_path(path))
  File.join(state_root, "checkpoints", session, digest)
end

def write_checkpoint(path, offset)
  FileUtils.mkdir_p(File.dirname(path))
  tmp = "#{path}.#{Process.pid}.tmp"
  File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
    file.write(offset.to_s)
    file.flush
    file.fsync
  end
  File.rename(tmp, path)
end

def transcript_messages(path, session)
  checkpoint = transcript_checkpoint(session, path)
  offset = if File.file?(checkpoint)
             Integer(File.read(checkpoint), exception: false) || 0
           else
             0
           end
  size = File.size(path)
  offset = 0 if offset.negative? || offset > size

  data = File.open(path, "rb") do |file|
    file.seek(offset)
    file.read
  end
  last_newline = data.rindex("\n")
  return [{}, offset, checkpoint] unless last_newline

  messages = {}
  data.byteslice(0, last_newline + 1).each_line do |line|
    record = JSON.parse(line)
    message = record["message"]
    next unless record["type"] == "assistant" && message.is_a?(Hash)
    next unless message["usage"].is_a?(Hash) && message["id"]

    messages[message["id"]] = message
  rescue JSON::ParserError
    next
  end
  [messages, offset + last_newline + 1, checkpoint]
end

def transcript_usage(event_log, path, events_path, current, payload, source)
  return 0 unless File.file?(path.to_s)

  # Claude transcripts repeat a message id as content blocks arrive. Keep the
  # last copy so cumulative usage is counted exactly once.
  messages, offset, checkpoint = transcript_messages(path, current["session"])
  events = messages.map do |message_id, message|
    usage = message["usage"]
    cache_creation = usage["cache_creation"].is_a?(Hash) ? usage["cache_creation"] : {}
    cache_w5 = cache_creation["ephemeral_5m_input_tokens"]
    cache_w1 = cache_creation["ephemeral_1h_input_tokens"]
    if cache_w5.nil? && cache_w1.nil?
      cache_w5 = usage["cache_creation_input_tokens"]
      cache_w1 = 0 if cache_w5
    end

    {
      "e" => "usage",
      "node" => current["node"] || "ORCHESTRATOR",
      "label" => payload["subagent_type"] || payload["agent_type"] || current["label"] || "assistant",
      "model" => message["model"],
      "generation_id" => message_id,
      "subagent_id" => payload["subagent_id"] || payload["agent_id"],
      "source" => source,
      "input" => usage.fetch("input_tokens", 0).to_i,
      "cache_w5" => cache_w5.to_i,
      "cache_w1" => cache_w1.to_i,
      "cache_read" => usage.fetch("cache_read_input_tokens", 0).to_i,
      "output" => usage.fetch("output_tokens", 0).to_i,
      "calls" => 1,
      "duration_ms" => payload["duration_ms"],
      "note" => "usage harvested from Claude transcript; repeated message ids deduplicated"
    }
  end
  if events.empty?
    write_checkpoint(checkpoint, offset)
    return 0
  end

  additions = event_log.emit_many(
    events_path,
    run_id: current.fetch("run_id"),
    session: current.fetch("session"),
    payloads: events,
    unique_by: "generation_id"
  )
  write_checkpoint(checkpoint, offset)
  additions.length
end

begin
  raw = $stdin.read
  exit 0 if raw.to_s.strip.empty?
  payload = JSON.parse(raw)

  session = payload["conversation_id"] || payload["session_id"]
  exit 0 unless valid_session?(session)

  current_path = File.join(state_root, "active", session)
  exit 0 unless File.file?(current_path)

  current = read_state(current_path)
  exit 0 unless current["session"] == session

  events_path = current["events"]
  exit 0 if events_path.to_s.empty?
  FileUtils.mkdir_p(File.dirname(events_path))

  event_name = (payload["hook_event_name"] || payload["event"] || "").to_s
  event_name = event_name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase.tr("-", "_")

  event_log = PrGraph::EventLog.new
  node = current["node"] || "ORCHESTRATOR"
  model = payload["model"] || payload["model_id"]

  case event_name
  when "stop", "after_agent_response"
    raw_input = payload["input_tokens"]
    unless raw_input
      transcript_usage(
        event_log, payload["transcript_path"], events_path, current, payload,
        "#{hook_product(payload)}-transcript-#{event_name}"
      )
      exit 0
    end

    generation = payload["generation_id"] || payload.dig("message", "id") || payload["prompt_id"]
    generation ||= "payload-#{Digest::SHA256.hexdigest(raw)}"

    cache_read = payload["cache_read_tokens"]
    cache_write = payload["cache_write_tokens"]
    output = payload["output_tokens"]

    event = {
      "e" => "usage",
      "node" => node,
      "label" => current["label"] || "stop",
      "model" => model,
      "generation_id" => generation,
      "source" => "#{hook_product(payload)}-hook-#{event_name}",
      "calls" => 1,
      "note" => "parent turn only; subagent tokens are not in this payload"
    }
    if raw_input
      read_tokens = cache_read.to_i
      write_tokens = cache_write.to_i
      event["input"] = [raw_input.to_i - read_tokens - write_tokens, 0].max
    end
    event["cache_w5"] = cache_write.to_i if cache_write
    event["cache_w1"] = 0 if cache_write || cache_read
    event["cache_read"] = cache_read.to_i if cache_read
    event["output"] = output.to_i if output
    event_log.emit_many(
      events_path,
      run_id: current.fetch("run_id"),
      session: session,
      payloads: [event],
      unique_by: "generation_id"
    )

  when "subagent_stop"
    agent_id = payload["subagent_id"] || payload["agent_id"]
    transcript_path = payload["agent_transcript_path"].to_s
    agent_id ||= File.basename(transcript_path, ".jsonl") unless transcript_path.empty?
    agent_id ||= "payload-#{Digest::SHA256.hexdigest(raw)}"

    harvested = transcript_usage(
      event_log, payload["agent_transcript_path"], events_path, current, payload,
      "#{hook_product(payload)}-transcript-subagentStop"
    )
    exit 0 if harvested.positive?

    event_log.emit_many(events_path, run_id: current.fetch("run_id"), session: session, payloads: [{
      "e" => "usage",
      "node" => node,
      "label" => payload["subagent_type"] || payload["agent_type"] || current["label"] || "subagent",
      "model" => model,
      "subagent_id" => agent_id,
      "source" => "#{hook_product(payload)}-hook-subagentStop",
      "input" => 0,
      "cache_w5" => 0,
      "cache_w1" => 0,
      "cache_read" => 0,
      "output" => 0,
      "calls" => 0,
      "duration_ms" => payload["duration_ms"],
      "note" => "subagentStop has no token fields; model and duration only"
    }], unique_by: "subagent_id")
  end
rescue StandardError
  # Fail open. A hook crash must never block the agent.
end

exit 0

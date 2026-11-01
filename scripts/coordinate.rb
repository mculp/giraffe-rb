#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "fileutils"
require "securerandom"
require_relative "coordinator_runtime"

def usage!
  warn <<~USAGE
    Usage:
      coordinate.rb start <session> <NODE> [--worktree PATH] [--refresh]
      coordinate.rb partial <session> <NODE> <attempt-id> --note TEXT
      coordinate.rb wake <session> <NODE> <attempt-id> <kind> <state> [--wake-id UUID]
      coordinate.rb finish <session> <NODE> <attempt-id> [--findings N] [--pr N --candidate-sha SHA] [--disposition FILE]
      coordinate.rb complete ... (alias for finish; same arguments)
      coordinate.rb fail <session> <NODE> <attempt-id> --reason TEXT --failure-id ID --revision REV [--findings N]
        finish and fail accept --cancel-live-wakes to cancel the attempt's registered or armed wakes as it closes
      coordinate.rb reap-wakes <session> --reason TEXT
      coordinate.rb supersede <session> <NODE> <attempt-id> <stale-artifact-id> <replacement-artifact-id> --reason TEXT
      coordinate.rb resume|check <session> [--worktree PATH] [--offline]
      coordinate.rb resume-run|check-run <events.jsonl> [--worktree PATH] [--offline]
  USAGE
  exit 1
end

def state_root
  override = ENV["PR_GRAPH_STATE_ROOT"]
  return File.expand_path(override) unless override.to_s.empty?

  installed_root = File.expand_path("../.cursor-state-root", __dir__)
  return File.read(installed_root).chomp if File.file?(installed_root)

  product = File.expand_path(__FILE__).include?("/.cursor/") ? ".cursor" : ".claude"
  File.expand_path("~/#{product}/pr-graph")
end

def read_state(session)
  unless session.match?(PrGraph::EventLog::SESSION)
    raise PrGraph::Coordinator::CoordinatorError, "missing or malformed conversation identity"
  end

  path = File.join(state_root, "active", session)
  unless File.file?(path)
    raise PrGraph::Coordinator::CoordinatorError, "no active run for conversation #{session}"
  end
  state = File.readlines(path, chomp: true).each_with_object({}) do |line, values|
    key, value = line.split("=", 2)
    values[key] = value if key && value
  end
  unless state["session"] == session && state["events"] && state["run_id"]
    raise PrGraph::Coordinator::CoordinatorError, "active coordinator state is incomplete or mismatched"
  end
  state
end

def activate_run(execution_path, events)
  root = state_root
  raise PrGraph::Coordinator::CoordinatorError, "unsafe state root" if root.empty? || root == "/"
  if execution_path.match?(/[\r\n]/)
    raise PrGraph::Coordinator::CoordinatorError, "execution path must fit on one line"
  end
  session = events.first.fetch("session")
  open_attempts = {}
  events.each do |event|
    next unless event["e"] == "node"

    if event["phase"] == "start"
      open_attempts[event["attempt_id"]] = event
    elsif event["phase"] == "done"
      open_attempts.delete(event["attempt_id"])
    end
  end
  active = open_attempts.values.max_by { |event| event.fetch("seq") }
  node = active ? active.fetch("node") : "ORCHESTRATOR"
  label = active ? active.fetch("label", "pg-#{node}") : "main"
  ticket = events.first.fetch("ticket").to_s.gsub(/[\r\n]/, " ")
  directory = File.join(root, "active")
  FileUtils.mkdir_p(directory, mode: 0o700)
  destination = File.join(directory, session)
  temporary = File.join(directory, ".state.#{$$}.#{SecureRandom.uuid}")
  content = [
    "events=#{execution_path}",
    "run_id=#{events.first.fetch('run_id')}",
    "ticket=#{ticket}",
    "session=#{session}",
    "node=#{node}",
    "label=#{label}"
  ].join("\n") + "\n"
  File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.write(content)
    file.flush
    file.fsync
  end
  File.rename(temporary, destination)
  destination
ensure
  File.unlink(temporary) if defined?(temporary) && temporary && File.file?(temporary)
end

def parser_for(options, *definitions)
  OptionParser.new do |parser|
    definitions.each do |definition|
      flag, description, key, type = definition
      if type
        parser.on(flag, type, description) { |value| options[key] = value }
      else
        parser.on(flag, description) { |value| options[key] = value }
      end
    end
  end
end

def read_json_file(path, label)
  return nil unless path

  JSON.parse(File.read(path))
rescue JSON::ParserError => e
  raise PrGraph::Coordinator::CoordinatorError, "invalid #{label} JSON: #{e.message}"
end

begin
  command = ARGV.shift || usage!
  command = "complete" if command == "finish"
  session = ARGV.shift || usage!
  options = {}

  case command
  when "start"
    node = ARGV.shift || usage!
    parser_for(
      options,
      ["--worktree PATH", "Exact git worktree path", :worktree, String],
      ["--refresh", "Re-arm current BOT-FEEDBACK evidence", :refresh, nil]
    ).parse!(ARGV)
    usage! if ARGV.any?
  when "partial"
    node = ARGV.shift || usage!
    attempt_id = ARGV.shift || usage!
    parser_for(options, ["--note TEXT", "Partial result summary", :note, String]).parse!(ARGV)
    usage! if ARGV.any? || options[:note].to_s.empty?
  when "wake"
    node = ARGV.shift || usage!
    attempt_id = ARGV.shift || usage!
    kind = ARGV.shift || usage!
    wake_state = ARGV.shift || usage!
    parser_for(options, ["--wake-id UUID", "Existing wake identity", :wake_id, String]).parse!(ARGV)
    usage! if ARGV.any?
  when "complete"
    node = ARGV.shift || usage!
    attempt_id = ARGV.shift || usage!
    parser_for(
      options,
      ["--findings N", "Non-blocking finding count", :findings, Integer],
      ["--pr N", "Published PR number", :pr, Integer],
      ["--candidate-sha SHA", "Published candidate SHA", :candidate_sha, String],
      ["--disposition FILE", "DONE outcome disposition JSON", :disposition_path, String],
      ["--cancel-live-wakes", "Cancel this attempt's live wakes as it closes", :cancel_live_wakes, nil]
    ).parse!(ARGV)
    usage! if ARGV.any?
  when "fail"
    node = ARGV.shift || usage!
    attempt_id = ARGV.shift || usage!
    parser_for(
      options,
      ["--reason TEXT", "Red-edge reason", :reason, String],
      ["--findings N", "Blocking finding count", :findings, Integer],
      ["--failure-id ID", "Stable failure identity", :failure_id, String],
      ["--revision REV", "Immutable source revision", :revision, String],
      ["--cancel-live-wakes", "Cancel this attempt's live wakes as it closes", :cancel_live_wakes, nil]
    ).parse!(ARGV)
    usage! if ARGV.any? || options[:reason].to_s.empty? || options[:failure_id].to_s.empty? || options[:revision].to_s.empty?
  when "supersede"
    node = ARGV.shift || usage!
    attempt_id = ARGV.shift || usage!
    stale = ARGV.shift || usage!
    replacement = ARGV.shift || usage!
    parser_for(options, ["--reason TEXT", "Why the duplicate is superseded", :reason, String]).parse!(ARGV)
    usage! if ARGV.any? || options[:reason].to_s.empty?
  when "reap-wakes"
    parser_for(options, ["--reason TEXT", "Why the stranded wakes are being cancelled", :reason, String]).parse!(ARGV)
    usage! if ARGV.any? || options[:reason].to_s.empty?
  when "resume", "check", "resume-run", "check-run"
    parser_for(
      options,
      ["--worktree PATH", "Exact git worktree path", :worktree, String],
      ["--offline", "Skip optional external refresh", :offline, nil]
    ).parse!(ARGV)
    usage! if ARGV.any?
  else
    usage!
  end

  if %w[resume-run check-run].include?(command)
    execution_path = File.expand_path(session)
    events = PrGraph::EventLog.new.validate_file!(execution_path)
    state = {
      "events" => execution_path,
      "run_id" => events.first.fetch("run_id"),
      "session" => events.first.fetch("session")
    }
    session = state.fetch("session")
  else
    state = read_state(session)
  end
  coordinator = PrGraph::Coordinator.new(
    execution_path: state.fetch("events"),
    run_id: state.fetch("run_id"),
    session: session
  )
  result = case command
           when "start"
             coordinator.start(node, worktree: options[:worktree], refresh: options.fetch(:refresh, false))
           when "partial"
             coordinator.partial(node, attempt_id, note: options.fetch(:note))
           when "wake"
             coordinator.wake(node, attempt_id, kind: kind, state: wake_state, wake_id: options[:wake_id])
           when "complete"
             coordinator.complete(
               node,
               attempt_id,
               findings: options.fetch(:findings, 0),
               pr: options[:pr],
               candidate_sha: options[:candidate_sha],
               disposition: read_json_file(options[:disposition_path], "outcome disposition"),
               cancel_live_wakes: options.fetch(:cancel_live_wakes, false)
             )
           when "fail"
             coordinator.fail(
               node,
              attempt_id,
              reason: options.fetch(:reason),
              findings: options.fetch(:findings, 1),
              failure_id: options.fetch(:failure_id),
              revision: options.fetch(:revision),
              cancel_live_wakes: options.fetch(:cancel_live_wakes, false)
            )
           when "reap-wakes"
             coordinator.reap_wakes(reason: options.fetch(:reason))
           when "supersede"
             coordinator.supersede_duplicate(node, attempt_id, stale: stale, replacement: replacement, reason: options.fetch(:reason))
           when "resume", "resume-run"
             coordinator.resume(worktree: options[:worktree], offline: options.fetch(:offline, false))
           when "check", "check-run"
             coordinator.check(worktree: options[:worktree], offline: options.fetch(:offline, false))
           end
  result["active_state"] = activate_run(state.fetch("events"), events) if command == "resume-run"
  puts JSON.pretty_generate(result)
rescue OptionParser::ParseError, PrGraph::ContractError, KeyError,
       Errno::ENOENT, Errno::EACCES, Errno::EEXIST, Errno::ENOTDIR => e
  warn "ERROR: #{e.message}"
  exit 1
end

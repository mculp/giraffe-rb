#!/usr/bin/env ruby
# frozen_string_literal: true

# pr-graph run metrics: per-node iterations and wall time,
# red edges, quality proxies, background-shell tasks, and usage events.
# Usage rows come from scripts/usage_hook.rb. Claude parent and subagent tokens
# are harvested from transcripts. Cursor parent tokens come from hook payloads;
# Cursor subagent rows have model and duration only. Grok/Composer are unpriced
# unless a usage event carries charged_cents.

# Usage:
#   metrics.rb <events.jsonl> [--json]

require "json"
require "time"
require_relative "event_log"

NODES = %w[
  TRIAGE INVESTIGATE WORKTREE REPRODUCE PLAN BUILD VERIFY PUBLISH
  CI-WATCH BOT-FEEDBACK SELF-REVIEW VALIDATE REVIEW-APP DESC-SYNC DONE TEST
].freeze

PRICING = [
  [/fable-5|mythos/,                    { in: 10.0, out: 50.0 }],
  [/opus-5|opus-4-8|opus-4-7|opus-4-6/, { in: 5.0,  out: 25.0 }],
  [/opus/,                              { in: 15.0, out: 75.0 }],
  [/sonnet-5/,                          { in: 2.0,  out: 10.0 }],
  [/sonnet/,                            { in: 3.0,  out: 15.0 }],
  [/haiku-4-5/,                         { in: 1.0,  out: 5.0 }],
  [/haiku/,                             { in: 0.8,  out: 4.0 }],
].freeze

def fmt_duration(sec)
  sec = sec.to_i
  return "#{sec}s" if sec < 60
  return format("%dm%02ds", sec / 60, sec % 60) if sec < 3600

  format("%dh%02dm", sec / 3600, (sec % 3600) / 60)
end

def fmt_tokens(n)
  n >= 1_000_000 ? format("%.1fM", n / 1_000_000.0) : format("%.1fk", n / 1000.0)
end

def node_order(node)
  NODES.index(node) || NODES.size
end

def ts(event)
  Time.parse(event["ts"]) if event["ts"]
rescue ArgumentError, TypeError
  nil
end

def union_duration(intervals)
  intervals.sort_by(&:first).reduce([]) do |merged, (start_at, end_at)|
    if merged.empty? || start_at > merged.last.last
      merged << [start_at, end_at]
    else
      merged.last[1] = [merged.last.last, end_at].max
      merged
    end
  end.sum { |start_at, end_at| end_at - start_at }
end

def attempt_timeline(events)
  snapshot_at = events.map { |event| ts(event) }.compact.max
  attempts = {}
  wakes = {}

  events.each do |event|
    case event["e"]
    when "node"
      attempt = attempts[event["attempt_id"]] ||= {
        attempt_id: event["attempt_id"], node: event["node"],
        iteration: event["iteration"] || event["iter"] || 1,
        start_at: nil, end_at: nil
      }
      attempt[:start_at] = ts(event) if event["phase"] == "start"
      attempt[:end_at] = ts(event) if event["phase"] == "done"
    when "wake"
      wake = wakes[event["wake_id"]] ||= {
        attempt_id: event["attempt_id"], armed_at: nil, end_at: nil
      }
      wake[:armed_at] = ts(event) if event["state"] == "armed"
      wake[:end_at] = ts(event) if %w[fired cancelled expired].include?(event["state"])
    end
  end

  attempts.each_value.map do |attempt|
    end_at = attempt[:end_at] || snapshot_at
    elapsed = if attempt[:start_at] && end_at
                [end_at - attempt[:start_at], 0].max
              else
                0
              end
    wait_intervals = wakes.values.each_with_object([]) do |wake, intervals|
      next unless wake[:attempt_id] == attempt[:attempt_id] && wake[:armed_at]

      wait_end = wake[:end_at] || end_at
      next unless wait_end && attempt[:start_at]

      start_at = [wake[:armed_at], attempt[:start_at]].max
      stop_at = [wait_end, end_at].min
      intervals << [start_at, stop_at] if stop_at > start_at
    end
    wait = [union_duration(wait_intervals), elapsed].min
    attempt.merge(
      elapsed: elapsed,
      wait: wait,
      active: elapsed - wait,
      open: attempt[:end_at].nil?
    )
  end
end

def node_timeline(events)
  attempt_timeline(events).group_by { |attempt| attempt[:node] }.map do |node, attempts|
    {
      node: node,
      iterations: attempts.map { |attempt| attempt[:iteration] }.max,
      attempts: attempts.size,
      open: attempts.count { |attempt| attempt[:open] },
      elapsed: attempts.sum { |attempt| attempt[:elapsed] },
      active: attempts.sum { |attempt| attempt[:active] },
      wait: attempts.sum { |attempt| attempt[:wait] }
    }
  end
end

def usage_tokens(event)
  {
    input: event.fetch("input", 0).to_i,
    cache_w5: event.fetch("cache_w5", 0).to_i,
    cache_w1: event.fetch("cache_w1", 0).to_i,
    cache_read: event.fetch("cache_read", 0).to_i,
    output: event.fetch("output", 0).to_i,
    calls: event.fetch("calls", 0).to_i
  }
end

def usage_tokens?(event)
  t = usage_tokens(event)
  t[:input] + t[:cache_w5] + t[:cache_w1] + t[:cache_read] + t[:output] > 0
end

def cost_usd(model, t, charged_cents: nil)
  return charged_cents.to_f / 100.0 unless charged_cents.nil?
  rate = PRICING.find { |re, _| model.to_s.match?(re) }&.last
  return nil unless rate

  (t[:input] * rate[:in] +
   t[:cache_w5] * rate[:in] * 1.25 +
   t[:cache_w1] * rate[:in] * 2.0 +
   t[:cache_read] * rate[:in] * 0.1 +
   t[:output] * rate[:out]) / 1_000_000.0
end

def usage_by_node(events)
  events.select { |e| e["e"] == "usage" && usage_tokens?(e) }.group_by { |e| e["node"] || "UNATTRIBUTED" }.map do |node, group|
    tokens = Hash.new(0)
    models = Hash.new(0)
    cost = 0.0
    unpriced = []
    group.each do |e|
      model = e["model"] || "unknown"
      t = usage_tokens(e)
      models[model] += t[:calls]
      t.each { |k, v| tokens[k] += v unless k == :calls }
      priced = cost_usd(model, t, charged_cents: e["charged_cents"])
      if priced
        cost += priced
      else
        unpriced << model
      end
    end
    { node: node, agents: group.size, cost: cost, tokens: tokens, models: models, unpriced: unpriced.uniq }
  end
end

def print_usage_table(events)
  rows = usage_by_node(events)
  return if rows.empty?

  puts "\n## Token usage (from usage events)"
  header = format("%-14s %6s %9s %9s %9s %9s %9s  %s",
                  "NODE", "AGENTS", "COST", "FRESH-IN", "CACHE-W", "CACHE-R", "OUT", "MODELS")
  puts header
  puts "=" * header.length
  total = Hash.new(0)
  rows.sort_by { |r| node_order(r[:node]) }.each do |r|
    t = r[:tokens]
    cache_w = t[:cache_w5] + t[:cache_w1]
    puts format("%-14s %6d %9s %9s %9s %9s %9s  %s",
                r[:node], r[:agents], format("$%.2f", r[:cost]),
                fmt_tokens(t[:input]), fmt_tokens(cache_w),
                fmt_tokens(t[:cache_read]), fmt_tokens(t[:output]),
                r[:models].keys.join(","))
    total[:cost] += r[:cost]
    total[:input] += t[:input]
    total[:cache_w] += cache_w
    total[:cache_read] += t[:cache_read]
    total[:output] += t[:output]
  end
  puts "=" * header.length
  puts format("%-14s %6s %9s %9s %9s %9s %9s",
              "TOTAL", "", format("$%.2f", total[:cost]), fmt_tokens(total[:input]),
              fmt_tokens(total[:cache_w]), fmt_tokens(total[:cache_read]),
              fmt_tokens(total[:output]))

  unpriced = rows.flat_map { |r| r[:unpriced] }.uniq
  puts "warning: no pricing for model(s) #{unpriced.join(", ")}, cost understated" if unpriced.any?
end

def print_models_without_tokens(events)
  only = events.select { |e| e["e"] == "usage" && !usage_tokens?(e) }
  return if only.empty?

  puts "\n## Models without token counts"
  only.each do |e|
    label = e["label"] ? " [#{e["label"]}]" : ""
    note = e["note"] ? " (#{e["note"]})" : ""
    puts "  #{e["node"]}: #{e["model"]}#{label}#{note}"
  end
end

def print_report(path, events)
  ticket = nil
  pr = nil
  events.each do |e|
    ticket ||= e["ticket"] if e["e"] == "run_start"
    pr ||= e["pr"] if e["e"] == "publish"
  end

  puts "# pr-graph run report: #{File.basename(path, ".jsonl")}"
  info = []
  info << "Ticket: #{ticket}" if ticket
  info << "PR: ##{pr}" if pr
  puts info.join("  ") if info.any?

  stamps = events.map { |e| ts(e) }.compact
  if stamps.size >= 2
    puts "Run wall: #{fmt_duration(stamps.max - stamps.min)} across #{events.size} events"
  end
  puts

  timeline = node_timeline(events)
  if timeline.any?
    total_active = timeline.sum { |row| row[:active] }
    total_wait = timeline.sum { |row| row[:wait] }
    total_elapsed = timeline.sum { |row| row[:elapsed] }
    puts "Attempt time: #{fmt_duration(total_active)} active + #{fmt_duration(total_wait)} wait = #{fmt_duration(total_elapsed)} elapsed"
    puts "Attempt totals sum parallel work and may exceed run wall. Wait is the union of armed wake intervals within each attempt."
    puts

    header = format("%-14s %6s %8s %9s %9s %9s  %s",
                    "NODE", "ITERS", "ATTEMPTS", "ACTIVE", "WAIT", "ELAPSED", "STATE")
    puts header
    puts "-" * header.length
    timeline.sort_by { |r| [node_order(r[:node]), r[:node]] }.each do |r|
      state = r[:open].positive? ? "#{r[:open]} open" : "closed"
      puts format("%-14s %6d %8d %9s %9s %9s  %s",
                  r[:node], r[:iterations], r[:attempts],
                  fmt_duration(r[:active]), fmt_duration(r[:wait]),
                  fmt_duration(r[:elapsed]), state)
    end
  end

  print_usage_table(events)
  print_models_without_tokens(events)

  edges = events.select { |e| e["e"] == "edge" }
  if edges.any?
    puts "\n## Red edges"
    edges.group_by { |e| "#{e["from"]} => #{e["to"]}" }.each do |route, group|
      puts "  #{route} x#{group.size}"
      group.each { |e| puts "    * #{e["reason"]}" if e["reason"] }
    end
  end

  outcomes = events.select { |e| e["e"] == "outcome" }
  if outcomes.any?
    puts "\n## Quality proxies"
    outcomes.group_by { |e| e["kind"] }.each do |kind, group|
      first = group.first
      passes = group.count { |e| e["pass"] }
      first_pass = first["pass"] ? "first-pass PASS" : "first-pass FAIL"
      findings = group.sum { |e| e["n"] || 0 }
      extra = findings > 0 ? ", #{findings} finding(s)" : ""
      puts "  #{kind}: #{first_pass}, #{passes}/#{group.size} attempts green#{extra}"
    end
  end

  tasks = events.select { |e| e["e"] == "task" }
  if tasks.any?
    puts "\n## Background shells"
    tasks.each { |e| puts "  #{e["node"]}: shell #{e["task_id"]} (#{e["desc"]})" }
  end
end

json_mode = !ARGV.delete("--json").nil?
path = ARGV.first
abort "usage: metrics.rb <events.jsonl> [--json]" unless path && File.exist?(path)

begin
  events = PrGraph::EventLog.new.validate_file!(path)
rescue PrGraph::ContractError, JSON::ParserError => e
  abort "invalid event stream: #{e.message}"
end

if json_mode
  puts JSON.pretty_generate(
    run: File.basename(path, ".jsonl"),
    nodes: node_timeline(events).map do |row|
      row.merge(
        active: row[:active].round,
        wait: row[:wait].round,
        elapsed: row[:elapsed].round
      )
    end,
    usage: usage_by_node(events),
    events: events
  )
else
  print_report(path, events)
end

#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "optparse"
require "securerandom"
require "tempfile"
require_relative "content_scan"
require_relative "temper_cli"

module PrGraph
  # Records a finished run in the Temper context the user opted into (docs/run-records.md): one
  # research resource summarizing the run, with its event log, failure log, and artifacts as data
  # artifacts.
  #
  # Only the orchestrator runs this, after DONE or an early stop. The coordinator never calls it, and a
  # skip or failure never reopens DONE. A state file beside the event log lets a rerun resume, and a
  # run recorded again after it grew gets a new summary and logs that supersede the old ones.
  class RunRecord
    TAG = "pr-graph-run"
    REASON_CHARS = 300
    SECRET = ContentScan::SECRET

    def initialize(cli: TemperCli.new)
      @cli = cli
    end

    def record(events_path, context:)
      return {"skipped" => "run recording is off"} if context.to_s.empty? || context == "none"
      unless context.match?(TemperCli::CONTEXT_REF)
        return {"skipped" => "#{context} is not a context ref (@owner/slug, +team/slug, or a UUID)"}
      end

      base = events_path.sub(/\.jsonl\z/, "")
      events = File.readlines(events_path).map { |row| JSON.parse(row) }
      start = events.find { |event| event["e"] == "run_start" } or return {"skipped" => "#{events_path} has no run_start event"}
      failures = jsonl("#{base}.failures.jsonl")
      items = logs(events_path, base) + artifacts(base, jsonl("#{base}.artifacts.jsonl"))
      state_path = "#{base}.temper-record.json"
      state = File.file?(state_path) ? JSON.parse(File.read(state_path)) : {"context" => context, "logs" => {}, "artifacts" => {}}
      return {"skipped" => "this run is recorded in #{state['context']}"} unless state["context"] == context

      save = -> { File.write(state_path, JSON.pretty_generate(state)) }
      correlation = ["--correlation", SecureRandom.uuid]
      body = summary(start, events, failures, items).gsub(SECRET, "[withheld]")
      meta = JSON.generate({"tags" => [TAG], "pr_graph_run" => start["run_id"], "ticket" => start["ticket"],
                            "status" => events.any? { |event| event["e"] == "done" } ? "done" : "stopped",
                            "pr" => events.reverse.find { |event| event["e"] == "publish" }&.dig("pr")}.compact)
      if state["resource"]
        unless state["body_sha"] == digest(body)
          file(body) { |path| temper("resource", "update", state["resource"], "--body", "@#{path}", "--open-meta", meta, *correlation) }
        end
      else
        rows = temper("resource", "list", "--context", context, "--type", "research", "--title-contains", start["run_id"],
                      "--all", "--with", "open-meta").fetch("rows")
        if (existing = rows.find { |row| row.dig("open_meta", "pr_graph_run") == start["run_id"] })
          return {"skipped" => "#{context} already holds a record of this run (#{existing['id']}) with no local record state"}
        end

        state["resource"] = file(body) do |path|
          temper("resource", "create", "--type", "research", "--context", context, "--title", "pr-graph run #{start['ticket']} #{start['run_id']}",
                 "--open-meta", meta, "--body", "@#{path}", *correlation)
        end.fetch("id")
      end
      state["body_sha"] = digest(body)
      save.call

      committed = 0
      items.each do |item|
        next if item[:withheld]

        held = item[:log] ? state["logs"][item[:key]] : state["artifacts"][item[:key]]
        next if held && (!item[:log] || held["sha"] == item[:sha])

        supersedes = item[:log] && held ? ["--supersedes", held["id"]] : []
        id = file(JSON.generate(item[:content])) do |path|
          temper("data-artifact", "commit", state["resource"], "--kind", item[:kind], "--intent", item[:log] ? "current" : "member",
                 "--precedence", item[:precedence].to_s, "--content", "@#{path}", *supersedes, *correlation)
        end.fetch("artifact_id")
        (item[:log] ? state["logs"] : state["artifacts"])[item[:key]] = {"sha" => item[:sha], "id" => id}
        save.call
        committed += 1
      end

      withheld = items.select { |item| item[:withheld] }.map { |item| {"record" => item[:label], "key" => item[:key], "reason" => item[:withheld]} }
      attached = state["logs"].length + state["artifacts"].length
      {"context" => context, "resource" => state["resource"], "committed" => committed, "attached" => attached, "withheld" => withheld,
       "summary" => "Run record: #{state['resource']} in #{context}, #{attached} data artifacts" \
                    "#{withheld.empty? ? '' : ", #{withheld.length} withheld (#{withheld.map { |w| w['record'] }.join(', ')})"}."}
    rescue TemperCli::Error => e
      {"failed" => e.message, "context" => context, "resource" => state&.dig("resource"),
       "summary" => "Run record failed: #{e.message}.#{' Rerunning resumes it.' if state&.dig('resource')}"}
    end

    private

    def logs(events_path, base)
      {"event-log" => events_path, "failure-log" => "#{base}.failures.jsonl"}.filter_map do |key, path|
        next unless File.file?(path)

        item(key, key.tr("-", " "), "pr-graph-#{key}", 0, {"events" => jsonl(path)}).merge(log: true)
      end
    end

    # Reads a blob only at the path artifact_log writes for the row, and only when its checksum matches.
    def artifacts(base, rows)
      rows.select { |row| row["e"] == "artifact" }.map do |row|
        id = row.fetch("artifact_id").to_s
        ref = "#{File.basename(base)}.artifacts/#{id}.blob"
        blob = File.join(File.dirname(base), ref)
        raw = File.binread(blob) if id.match?(/\A[\w-]+\z/) && row["content_ref"] == ref && File.file?(blob)
        raw = raw && digest(raw) == row["content_sha256"] ? raw.force_encoding(Encoding::UTF_8) : nil
        content = if raw.nil? then nil
                  elsif !raw.valid_encoding? then nil
                  elsif row["content_type"].to_s.include?("json") then parse(raw)
                  else {"text" => raw}
                  end
        meta = row.reject { |key, _| %w[v run_id session e content_ref].include?(key) }
        found = item(row.fetch("artifact_id"), row.fetch("family"), "pr-graph-#{row.fetch('family').tr('_', '-')}", row.fetch("seq"),
                     {"record" => meta, "content" => content})
        if raw.nil? then found.merge(withheld: "its content file is missing or does not match its record")
        elsif content.nil? then found.merge(withheld: "its content is not text")
        else found
        end
      end
    end

    def item(key, label, kind, precedence, content)
      json = JSON.generate(content)
      {key: key, label: label, kind: kind, precedence: precedence, content: content, sha: digest(json),
       withheld: ContentScan.violation(content, json)}
    end

    def summary(start, events, failures, items)
      nodes = events.select { |event| event["e"] == "node" }.group_by { |event| event["attempt_id"] }.values.group_by { |rows| rows.first["node"] }
      publish = events.reverse.find { |event| event["e"] == "publish" }
      times = events.filter_map { |event| event["ts"] }
      done = events.any? { |event| event["e"] == "done" }
      lines = ["# pr-graph run #{start['ticket']} #{start['run_id']}", "",
               "#{start['ticket']}, entered from #{start['entry'] == 'adopt' ? 'an existing branch or PR' : 'a ticket'}, ran from " \
               "#{times.first} to #{times.last} and #{done ? 'reached DONE' : 'stopped before DONE'}." \
               "#{publish ? " PR #{publish['pr']} at `#{publish['candidate_sha']}`." : ''}",
               "", "## Nodes", "", "| Node | Attempts | Last attempt |", "| --- | --- | --- |"]
      nodes.each do |node, attempts|
        lines << "| #{node} | #{attempts.length} | #{attempts.last.any? { |event| event['phase'] == 'done' } ? 'done' : 'open'} |"
      end
      edges = events.select { |event| event["e"] == "edge" }
      lines.push("", "## Red edges", "")
      lines.concat(edges.empty? ? ["None."] : edges.map { |edge| "- #{edge['from']} to #{edge['to']}: #{line(edge['reason'])}" })
      lines.push("", "## Failures", "")
      found = failures.select { |event| event["e"] == "finding" }.map { |f| "- `#{f['failure_id']}` from #{f['source_node']}: #{line(f['reason'])}" }
      found += failures.select { |event| event["e"] == "stop" }.map do |stop|
        "- Stopped on `#{stop['failure_id']}` after #{stop['processed_cycles']} cycles: #{line(stop['reason'])}"
      end
      lines.concat(found.empty? ? ["None."] : found)
      attached = items.reject { |item| item[:withheld] }.map { |item| item[:label] }.tally.map { |label, n| n > 1 ? "#{label} (#{n})" : label }
      lines.push("", "## Records", "", "Data artifacts: #{attached.empty? ? 'none' : attached.join(', ')}.")
      items.select { |item| item[:withheld] }.each { |item| lines << "- Withheld #{item[:label]} `#{item[:key]}`: #{item[:withheld]}." }
      "#{lines.join("\n")}\n"
    end

    def temper(*args)
      @cli.call(*args)
    rescue TemperCli::Failed => e
      raise TemperCli::Error, "temper #{args.first(2).join(' ')} failed: #{e.message}"
    end

    def file(text)
      Tempfile.create("pr-graph-record") do |handle|
        handle.write(text)
        handle.flush
        yield handle.path
      end
    end

    def jsonl(path)
      File.file?(path) ? File.readlines(path).map { |row| JSON.parse(row) } : []
    end

    def parse(raw)
      JSON.parse(raw)
    rescue JSON::ParserError
      {"text" => raw}
    end

    # Withholds a reason carrying a secret whole, so truncation never leaves part of one behind.
    def line(text)
      flat = text.to_s.gsub(/[[:cntrl:][:space:]]+/, " ").strip
      return "[withheld]" if flat.match?(SECRET)

      flat.length > REASON_CHARS ? "#{flat[0, REASON_CHARS]}..." : flat
    end

    def digest(text)
      Digest::SHA256.hexdigest(text)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  OptionParser.new do |parser|
    parser.on("--events PATH") { |value| options["events"] = value }
    parser.on("--context REF") { |value| options["context"] = value }
  end.parse!(ARGV)
  abort("Usage: run_record.rb --events <run>.jsonl [--context REF|none]") unless options["events"]
  begin
    context = options.fetch("context") { ENV.fetch("PR_GRAPH_RECORD_CONTEXT", "") }
    puts JSON.pretty_generate(PrGraph::RunRecord.new.record(options["events"], context: context))
  rescue JSON::ParserError, Errno::ENOENT => e
    warn "ERROR: #{e.message}"
    exit 1
  end
end

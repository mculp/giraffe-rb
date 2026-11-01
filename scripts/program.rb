#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "securerandom"
require "shellwords"
require "time"
require_relative "event_log"

module PrGraph
  # Schedules a set of tickets as child pr-graph runs.
  #
  # The plan is written once by the program's TRIAGE. After that, every decision is a pure function of
  # the plan, the launches this program recorded, each child's own run stream, and its PR: which
  # tickets start, on which base, which finished children need a rebase, and which are parked. No
  # model reports progress to the scheduler; it reads the streams the child coordinators wrote.
  class Program
    class ProgramError < ContractError; end

    PLAN_FIELDS = %w[program_id repo github_repo base max_building max_open env_offset context launch tickets].freeze
    TICKET_FIELDS = %w[id branch blocked_by status reason].freeze
    LAUNCH_GRACE = 20 * 60
    STALL_AFTER = 3 * 60 * 60
    OPEN = %w[launching building published stalled].freeze
    WATCHED = %w[state launch question answer supervisor].freeze

    attr_reader :plan

    def self.validate_plan!(plan)
      raise ProgramError, "plan must be a JSON object" unless plan.is_a?(Hash)
      missing = PLAN_FIELDS - plan.keys
      raise ProgramError, "plan is missing field(s): #{missing.join(', ')}" if missing.any?
      %w[max_building max_open].each do |field|
        raise ProgramError, "#{field} must be a positive integer" unless plan[field].is_a?(Integer) && plan[field].positive?
      end
      raise ProgramError, "launch must contain {prompt_file}" unless plan["launch"].to_s.include?("{prompt_file}")
      if plan.key?("model") != plan["launch"].include?("{model}")
        raise ProgramError, "model and {model} in launch go together: set both, so every child runs the plan's model, or neither"
      end

      tickets = plan["tickets"]
      raise ProgramError, "tickets must be a non-empty array" unless tickets.is_a?(Array) && tickets.any?
      ids = tickets.map do |ticket|
        missing = TICKET_FIELDS - ticket.keys
        raise ProgramError, "ticket is missing field(s): #{missing.join(', ')}" if missing.any?
        unless %w[ready excluded].include?(ticket["status"])
          raise ProgramError, "#{ticket['id']} status must be ready or excluded"
        end
        ticket["id"]
      end
      duplicates = ids.tally.select { |_, count| count > 1 }.keys
      raise ProgramError, "duplicate ticket(s): #{duplicates.join(', ')}" if duplicates.any?
      tickets.each do |ticket|
        unknown = ticket["blocked_by"] - ids
        next if unknown.empty?

        raise ProgramError, "#{ticket['id']} is blocked by ticket(s) outside the plan: #{unknown.join(', ')}"
      end
      check_acyclic!(tickets)
      plan
    end

    def self.check_acyclic!(tickets)
      edges = tickets.to_h { |ticket| [ticket["id"], ticket["blocked_by"]] }
      state = {}
      visit = lambda do |id, path|
        raise ProgramError, "dependency cycle: #{(path + [id]).join(' -> ')}" if state[id] == :visiting
        return if state[id] == :done

        state[id] = :visiting
        edges.fetch(id).each { |parent| visit.call(parent, path + [id]) }
        state[id] = :done
      end
      edges.each_key { |id| visit.call(id, []) }
    end

    def initialize(dir:, runs_dir:, pr_adapter: nil, now: -> { Time.now.utc })
      @dir = dir
      @runs_dir = runs_dir
      @now = now
      @plan = self.class.validate_plan!(JSON.parse(File.read(File.join(dir, "plan.json"))))
      @pr_adapter = pr_adapter || method(:gh_pr)
    end

    def self.init(dir, plan)
      validate_plan!(plan)
      path = File.join(dir, "plan.json")
      raise ProgramError, "program already initialized at #{dir}" if File.exist?(path)

      FileUtils.mkdir_p(dir)
      File.write(path, JSON.pretty_generate(plan))
    end

    def tickets
      plan.fetch("tickets")
    end

    # Every ticket's derived state, in plan order.
    def states
      @states ||= begin
        derived = {}
        tickets.each { |ticket| derived[ticket["id"]] = derive(ticket, derived) }
        derived
      end
    end

    def actions
      building = states.values.count { |state| %w[launching building].include?(state["state"]) }
      open = states.values.count { |state| OPEN.include?(state["state"]) }
      planned = []
      tickets.each do |ticket|
        state = states.fetch(ticket["id"])
        action = case state["state"]
                 when "ready" then start_action(ticket, state)
                 when "lost" then state["relaunches"].zero? && state["last_kind"] != "reopen" ? start_action(ticket, state, kind: "relaunch") : nil
                 when "done" then rebase_action(ticket, state)
                 end
        next unless action

        next if building >= plan["max_building"] || open >= plan["max_open"]

        building += 1
        open += 1
        planned << action
      end
      planned
    end

    # Record every ticket whose state changed since the last tick, then launch every action and record
    # it. `runner` receives the shell command.
    def tick(runner: ->(command) { system(command) || raise(ProgramError, "launch failed: #{command}") })
      record_state_changes
      planned = actions
      planned.each { |action| launch(action, runner) }
      planned
    end

    # The session answering this program's questions: the latest `supervise`, else the plan's.
    def supervisor
      events.reverse.find { |event| event["e"] == "supervisor" }&.fetch("session") || plan["supervisor"]
    end

    def supervise(session)
      raise ProgramError, "a supervisor needs a session name" if session.to_s.strip.empty?

      record("e" => "supervisor", "session" => session)
    end

    # A child records what it needs decided instead of asking in its own chat, where no one watches.
    def ask(id, text)
      raise ProgramError, "#{id} is not in the plan" unless ticket_by_id(id)
      raise ProgramError, "a question needs text" if text.to_s.strip.empty?

      question_id = SecureRandom.uuid
      record("e" => "question", "question_id" => question_id, "ticket" => id, "text" => text)
      {"question_id" => question_id, "supervisor" => supervisor}
    end

    def answer(question_id, text)
      question = open_questions.find { |event| event["question_id"] == question_id }
      raise ProgramError, "no open question #{question_id}" unless question
      raise ProgramError, "an answer needs text" if text.to_s.strip.empty?

      record("e" => "answer", "question_id" => question_id, "ticket" => question["ticket"], "text" => text)
    end

    # The answer event for a question, or nil while it is open.
    def answer_for(question_id)
      unless events.any? { |event| event["e"] == "question" && event["question_id"] == question_id }
        raise ProgramError, "no question #{question_id}"
      end

      events.find { |event| event["e"] == "answer" && event["question_id"] == question_id }
    end

    def open_questions
      answered = events.select { |event| event["e"] == "answer" }.map { |event| event["question_id"] }
      events.select { |event| event["e"] == "question" && !answered.include?(event["question_id"]) }
    end

    # One line for each event a supervisor acts on, or nil for the rest.
    def self.describe(event)
      case event["e"]
      when "state"
        pr = event["pr"] ? " (PR ##{event['pr']})" : ""
        detail = event["detail"].to_s.empty? ? "" : ": #{event['detail']}"
        "#{event['ticket']} is #{event['state']}#{pr}#{detail}"
      when "launch"
        "#{event['ticket']} launched (#{event['kind']}) on #{event['base_ref']}"
      when "question"
        "#{event['ticket']} asks #{event['question_id']}: #{event['text']}"
      when "answer"
        "#{event['ticket']} answered #{event['question_id']}"
      when "supervisor"
        "supervisor is now #{event['session']}"
      end
    end

    # Events recorded after line `offset` of program.jsonl, and the new offset.
    def events_after(offset)
      [events.drop(offset).select { |event| WATCHED.include?(event["e"]) }, events.length]
    end

    # Reopen a child in adopt mode for work a human asked for: review findings a published or finished
    # run dropped, or the user's decision on a parked run's durable stop. A parked run cannot take
    # another step, so the reopen is a fresh run on the same branch. The reason goes into the prompt
    # and the launch record.
    def reopen(id, reason:, runner: ->(command) { system(command) || raise(ProgramError, "launch failed: #{command}") })
      ticket = ticket_by_id(id) || raise(ProgramError, "#{id} is not in the plan")
      state = states.fetch(id)
      reopenable = state["state"] == "parked" || (%w[published done].include?(state["state"]) && state["pr"])
      unless reopenable
        raise ProgramError, "#{id} is #{state['state']}; only a parked child, or a published or done child with a PR, can be reopened"
      end
      raise ProgramError, "#{id} was launched in the last #{LAUNCH_GRACE / 60} minutes" if launched_recently?(id)
      raise ProgramError, "a reopen needs a reason" if reason.to_s.strip.empty?

      target = state["pr"] ? "#{ticket['branch']} (PR ##{state['pr']})" : ticket["branch"]
      prompt = <<~PROMPT
        /pr-graph adopt #{target}

        Program child of `#{plan['program_id']}`, reopened: #{reason}
        Fix what this names in BUILD, re-run VERIFY, push, and run to the DONE GATE autonomously.
        Use TEST_ENV_NUMBER=#{env_number(ticket)}.
      PROMPT
      action = {"ticket" => id, "kind" => "reopen", "base_ref" => state["base_ref"], "base_sha" => state["base_sha"],
                "reason" => reason, "prompt" => prompt + question_note(ticket)}
      launch(action, runner)
      action
    end

    def status
      tickets.map do |ticket|
        state = states.fetch(ticket["id"])
        [ticket["id"], state["state"], state["pr"], state["base_ref"], state["detail"]].map(&:to_s)
      end
    end

    private

    def derive(ticket, derived)
      id = ticket["id"]
      return {"state" => "excluded", "detail" => ticket["reason"]} if ticket["status"] == "excluded"

      launches = launches_for(id)
      last = launches.last
      run = last && latest_run(id, since: Time.parse(last["at"]) - 60)
      result = {"relaunches" => launches.count { |item| item["kind"] == "relaunch" }}
      result["base_ref"] = last && last["base_ref"]
      result["base_sha"] = last && last["base_sha"]
      result["last_kind"] = last && last["kind"]
      prior = launches.reverse.lazy.map { |item| latest_run(id, since: Time.parse(item["at"]) - 60) }.find(&:itself)
      pr = (run || prior)&.dig("pr")
      result["pr"] = pr
      if pr
        live = @pr_adapter.call(plan["github_repo"], pr)
        return result.merge("state" => "merged", "sha" => live["headRefOid"]) if live["state"] == "MERGED"

        result["live"] = live
      end

      unless last
        blocker = blocked(ticket, derived)
        return result.merge("state" => blocker ? "blocked" : parents_ready(ticket, derived) ? "ready" : "waiting",
                            "detail" => blocker)
      end

      unless run
        age = @now.call - Time.parse(last["at"])
        return result.merge("state" => age < LAUNCH_GRACE ? "launching" : (result["relaunches"].zero? ? "lost" : "parked"),
                            "detail" => age < LAUNCH_GRACE ? nil : "no run started after launch")
      end

      result["sha"] = run["sha"]
      return result.merge("state" => "parked", "detail" => run["stop"]) if run["stop"]
      return result.merge("state" => "done") if run["done"]

      state = run["pr"] ? "published" : "building"
      question = open_questions.reverse.find { |event| event["ticket"] == id && Time.parse(event["at"]) >= Time.parse(last["at"]) }
      return result.merge("state" => state, "detail" => "waiting on #{question['question_id']}") if question

      state = "stalled" if @now.call - run["last_ts"] > STALL_AFTER
      result.merge("state" => state)
    end

    def record_state_changes
      recorded = events.select { |event| event["e"] == "state" }.to_h { |event| [event["ticket"], event.slice("state", "pr", "detail")] }
      states.each do |id, state|
        current = {"state" => state["state"], "pr" => state["pr"], "detail" => state["detail"]}
        record("e" => "state", "ticket" => id, **current.transform_keys(&:to_sym)) unless recorded[id] == current
      end
    end

    def blocked(ticket, derived)
      ticket["blocked_by"].each do |parent|
        state = derived.fetch(parent)["state"]
        return "#{parent} is #{state}" if %w[excluded parked blocked lost].include?(state)
      end
      nil
    end

    # A child may start once each parent has published a candidate; it stacks on the one parent not
    # yet merged. Two unmerged parents cannot both be a base, so the child waits for a merge.
    def parents_ready(ticket, derived)
      parents = ticket["blocked_by"].map { |parent| derived.fetch(parent) }
      return false unless parents.all? { |state| %w[published done merged].include?(state["state"]) }

      parents.count { |state| state["state"] != "merged" } <= 1
    end

    def start_action(ticket, state, kind: "start")
      parent = ticket["blocked_by"].map { |id| [id, states.fetch(id)] }.find { |_, item| item["state"] != "merged" }
      base_ref, base_sha = if parent
                             ["origin/#{ticket_by_id(parent.first)['branch']}", parent.last["sha"]]
                           else
                             ["origin/#{plan['base']}", nil]
                           end
      action = {"ticket" => ticket["id"], "kind" => kind, "base_ref" => base_ref, "base_sha" => base_sha}
      action.merge("prompt" => child_prompt(ticket, action, parent&.first))
    end

    # A finished child is re-opened in adopt mode when its base moved: the stacked parent pushed a new
    # candidate, the parent merged, or the PR no longer merges cleanly.
    def rebase_action(ticket, state)
      return if launched_recently?(ticket["id"])

      parent_id = ticket["blocked_by"].find { |id| state["base_ref"] == "origin/#{ticket_by_id(id)['branch']}" }
      parent = parent_id && states.fetch(parent_id)
      reason, onto, onto_sha = if parent && parent["state"] == "merged"
                                 ["#{parent_id} merged", "origin/#{plan['base']}", nil]
                               elsif parent && parent["sha"] && parent["sha"] != state["base_sha"]
                                 ["#{parent_id} pushed #{parent['sha'][0, 12]}", state["base_ref"], parent["sha"]]
                               elsif state.dig("live", "mergeable") == "CONFLICTING"
                                 ["the PR conflicts with #{state['base_ref']}", state["base_ref"], state["base_sha"]]
                               end
      return unless reason

      action = {"ticket" => ticket["id"], "kind" => "rebase", "base_ref" => onto, "base_sha" => onto_sha}
      action.merge("prompt" => rebase_prompt(ticket, state, reason, onto))
    end

    def launched_recently?(id)
      last = launches_for(id).last
      last && @now.call - Time.parse(last["at"]) < LAUNCH_GRACE
    end

    def child_prompt(ticket, action, parent)
      topology = if parent
                   "stacked on #{parent}'s branch `#{action['base_ref']}` at #{action['base_sha']}; " \
                     "open the PR against `#{action['base_ref'].delete_prefix('origin/')}`"
                 else
                   "new, off `#{action['base_ref']}`"
                 end
      <<~PROMPT
        /pr-graph #{ticket['id']}

        Program child of `#{plan['program_id']}`. Run autonomously to the DONE GATE; do not stop to ask questions.
        - Branch `#{ticket['branch']}`, topology #{topology}.
        - Use TEST_ENV_NUMBER=#{env_number(ticket)} for every spec run in this worktree.
        - Project context: read `#{plan['context']}` before INVESTIGATE. The codebase and prior-art lanes
          start from it and search only what it does not answer.
      PROMPT
        .then { |prompt| prompt + question_note(ticket) }
    end

    def rebase_prompt(ticket, state, reason, onto)
      old_base = state["base_sha"] || state["base_ref"]
      retarget = onto == "origin/#{plan['base']}" && old_base != onto ? " and change the PR base to `#{plan['base']}`" : ""
      <<~PROMPT
        /pr-graph adopt #{ticket['branch']} (PR ##{state['pr']})

        Program child of `#{plan['program_id']}`: #{reason}. Rebase before anything else with
        `git rebase --onto #{onto} #{old_base}`#{retarget}, resolve conflicts in BUILD, then run to the
        DONE GATE autonomously. Use TEST_ENV_NUMBER=#{env_number(ticket)}.
      PROMPT
        .then { |prompt| prompt + question_note(ticket) }
    end

    # The channel comes from the launch the user approved, so a child takes recorded answers as that
    # user's decisions. Questions and answers live in program.jsonl, so neither side has to be running
    # when the other writes.
    def question_note(ticket)
      program = Shellwords.escape(plan["program_id"])
      <<~NOTE
        - Never ask a question in this chat; no one reads it. When you need a question, decision, blocker, or
          permission answered, record it with the options and your recommendation:
          `ruby "$PR_GRAPH_SCRIPTS/program.rb" ask #{program} #{ticket['id']} "<question>"`
          Then run `ruby "$PR_GRAPH_SCRIPTS/program.rb" await #{program} <question-id>` as a background shell
          and keep moving any work that does not depend on the answer. When it exits 0, its output is the
          answer, recorded by the program's supervisor or the user who launched this program, and it carries
          that user's authority for this run. When it exits 3, or the shell is killed, the question is still
          open: run the same await again. Never idle without an await running for an open question.
      NOTE
    end

    def env_number(ticket)
      plan["env_offset"] + tickets.index(ticket) + 1
    end

    def launch_command(action, prompt_file)
      plan["launch"]
        .gsub("{ticket}", Shellwords.escape(action["ticket"]))
        .gsub("{repo}", Shellwords.escape(plan["repo"]))
        .gsub("{prompt_file}", Shellwords.escape(prompt_file))
        .then { |command| plan.key?("model") ? command.gsub("{model}", Shellwords.escape(plan["model"])) : command }
    end

    def launch(action, runner)
      prompt_file = File.join(@dir, "prompts", "#{action['ticket']}-#{@now.call.to_i}.md")
      FileUtils.mkdir_p(File.dirname(prompt_file))
      File.write(prompt_file, action.fetch("prompt"))
      runner.call(launch_command(action, prompt_file))
      record("e" => "launch", **action.slice("ticket", "kind", "base_ref", "base_sha", "reason").transform_keys(&:to_sym))
    end

    def ticket_by_id(id)
      tickets.find { |ticket| ticket["id"] == id }
    end

    def launches_for(id)
      events.select { |event| event["e"] == "launch" && event["ticket"] == id }
    end

    def events
      @events ||= begin
        path = File.join(@dir, "program.jsonl")
        File.exist?(path) ? File.readlines(path).map { |line| JSON.parse(line) } : []
      end
    end

    # Children, the driver, and the supervisor all append here, so each write holds the lock.
    def record(event)
      line = JSON.generate(event.transform_keys(&:to_s).merge("at" => @now.call.iso8601))
      File.open(File.join(@dir, "program.jsonl"), "a") do |file|
        file.flock(File::LOCK_EX)
        file.puts(line)
      end
      @events = nil
    end

    # The newest run for a ticket started after `since`, summarized from its own streams.
    def latest_run(id, since:)
      Dir.glob(File.join(@runs_dir, "#{id}-*.jsonl"))
         .reject { |path| path.end_with?(".artifacts.jsonl", ".failures.jsonl") }
         .filter_map { |path| summarize(path) }
         .select { |run| run["started"] >= since }
         .max_by { |run| run["started"] }
    end

    def summarize(path)
      lines = File.readlines(path).map { |line| JSON.parse(line) }
      start = lines.first
      return unless start && start["e"] == "run_start"

      publish = lines.reverse.find { |event| event["e"] == "publish" }
      done = lines.reverse.find { |event| event["e"] == "done" }
      failures = path.sub(/\.jsonl\z/, ".failures.jsonl")
      stop = File.exist?(failures) && File.readlines(failures).map { |line| JSON.parse(line) }.find { |e| e["e"] == "stop" }
      {
        "started" => Time.parse(start["ts"]), "last_ts" => Time.parse(lines.last["ts"]),
        "pr" => publish&.dig("pr") || start["pr"],
        "sha" => (done || publish)&.dig("candidate_sha"),
        "done" => !done.nil?, "stop" => stop && stop["reason"]
      }
    end

    def gh_pr(repo, number)
      output, error, status = Open3.capture3("gh", "pr", "view", number.to_s, "--repo", repo,
                                             "--json", "state,mergeable,headRefOid,baseRefName")
      raise ProgramError, "gh pr view #{number} failed: #{error}" unless status.success?

      JSON.parse(output)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  def state_root
    ENV["PR_GRAPH_STATE_ROOT"] || File.join(Dir.home, ".claude", "pr-graph")
  end

  def program_for(id)
    PrGraph::Program.new(dir: File.join(state_root, "programs", id), runs_dir: File.join(state_root, "runs"))
  end

  command, id, plan_path = ARGV
  begin
    case command
    when "init"
      plan = JSON.parse(File.read(plan_path || abort("Usage: program.rb init <program-id> <plan.json>")))
      abort "plan program_id #{plan['program_id']} does not match #{id}" unless plan["program_id"] == id
      PrGraph::Program.init(File.join(state_root, "programs", id), plan)
      puts "initialized #{id}"
    when "plan"
      puts JSON.pretty_generate(program_for(id).actions.map { |action| action.except("prompt") })
    when "tick"
      launched = program_for(id).tick
      puts JSON.generate(launched.map { |action| action.except("prompt") })
    when "status"
      rows = [%w[ticket state pr base detail]] + program_for(id).status
      widths = rows.transpose.map { |column| column.map(&:length).max }
      rows.each { |row| puts row.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join("  ").rstrip }
    when "reopen"
      ticket, reason = ARGV[2], ARGV[3]
      abort "Usage: program.rb reopen <program-id> <ticket> <reason>" unless ticket && reason
      puts JSON.generate(program_for(id).reopen(ticket, reason: reason).except("prompt"))
    when "supervise"
      session = ARGV[2] || abort("Usage: program.rb supervise <program-id> <session-name>")
      program_for(id).supervise(session)
      puts "supervisor of #{id} is #{session}"
    when "ask"
      ticket, text = ARGV[2], ARGV[3]
      abort "Usage: program.rb ask <program-id> <ticket> <question|->" unless ticket && text
      puts JSON.generate(program_for(id).ask(ticket, text == "-" ? $stdin.read : text))
    when "answer"
      question_id, text = ARGV[2], ARGV[3]
      abort "Usage: program.rb answer <program-id> <question-id> <answer|->" unless question_id && text
      program_for(id).answer(question_id, text == "-" ? $stdin.read : text)
      puts "answered #{question_id}"
    when "questions"
      program_for(id).open_questions.each { |event| puts PrGraph::Program.describe(event) }
    when "await"
      question_id = ARGV[2] || abort("Usage: program.rb await <program-id> <question-id> [--timeout seconds]")
      # Background shells are capped at two hours, so give up first and say so; the child re-arms.
      timeout = ARGV[3] == "--timeout" ? Integer(ARGV[4]) : 100 * 60
      deadline = Time.now + timeout
      $stdout.sync = true
      loop do
        answer = program_for(id).answer_for(question_id)
        break puts(answer["text"]) if answer

        if Time.now >= deadline
          puts "question #{question_id} is still open; run await again"
          exit 3
        end
        sleep 15
      end
    when "watch"
      $stdout.sync = true
      offset = ARGV[2] == "--all" ? 0 : program_for(id).events_after(0).last
      loop do
        found, offset = program_for(id).events_after(offset)
        found.each { |event| puts PrGraph::Program.describe(event) }
        sleep 15
      end
    else
      abort "Usage: program.rb init|plan|tick|status|reopen|supervise|ask|answer|questions|await|watch <program-id> ..."
    end
  rescue PrGraph::ContractError, JSON::ParserError, Errno::ENOENT => e
    warn "ERROR: #{e.message}"
    exit 1
  end
end

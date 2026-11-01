#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ruby -I "${SCRIPT_DIR}/../scripts" <<'RUBY'
require "tmpdir"
require "program"

TESTS = []

def assert(value, message)
  raise message unless value
end

def rejected(message)
  yield
  raise "expected rejection containing #{message.inspect}"
rescue PrGraph::ContractError => e
  raise "expected #{message.inspect}, got #{e.message.inspect}" unless e.message.include?(message)
end

def ticket(id, blocked_by = [], status: "ready")
  {"id" => id, "branch" => "feature/#{id.downcase}", "blocked_by" => blocked_by, "status" => status,
   "reason" => status == "ready" ? "" : "decision ticket"}
end

def plan(tickets, **overrides)
  {"program_id" => "mcp", "repo" => "/repo", "github_repo" => "acme/app", "base" => "main",
   "max_building" => 2, "max_open" => 4, "env_offset" => 10, "context" => "/ctx.md",
   "launch" => "launch {ticket} {repo} {prompt_file}", "tickets" => tickets}.merge(overrides)
end

# A program over fake child runs, PRs, and a movable clock.
class World
  attr_reader :launched, :prs

  def initialize(root, tickets, **options)
    @root = root
    @runs = File.join(root, "runs")
    FileUtils.mkdir_p(@runs)
    @dir = File.join(root, "programs", "mcp")
    PrGraph::Program.init(@dir, plan(tickets, **options))
    @clock = Time.utc(2026, 10, 1, 9)
    @prs = {}
    @launched = []
    @seq = 0
  end

  def program
    PrGraph::Program.new(dir: @dir, runs_dir: @runs, now: -> { @clock },
                         pr_adapter: ->(_repo, number) { @prs.fetch(number, {"state" => "OPEN", "mergeable" => "MERGEABLE"}) })
  end

  def advance(minutes)
    @clock += minutes * 60
  end

  def tick
    program.tick(runner: ->(command) { @launched << command })
  end

  def states
    program.states.transform_values { |state| state["state"] }
  end

  # Write a child run stream the way a child coordinator would.
  def run(id, pr: nil, sha: nil, done: false, stop: nil)
    @seq += 1
    path = File.join(@runs, "#{id}-20261001-#{@seq}.jsonl")
    started = @clock.iso8601
    lines = [{"e" => "run_start", "ticket" => id, "entry" => "ticket", "ts" => started}]
    lines << {"e" => "publish", "pr" => pr, "candidate_sha" => sha, "ts" => started} if pr
    lines << {"e" => "done", "candidate_sha" => sha, "ts" => started} if done
    File.write(path, lines.map { |line| JSON.generate(line) }.join("\n") + "\n")
    return unless stop

    File.write(path.sub(/\.jsonl\z/, ".failures.jsonl"), JSON.generate({"e" => "stop", "reason" => stop}) + "\n")
  end
end

rejected("dependency cycle: A -> B -> A") { PrGraph::Program.validate_plan!(plan([ticket("A", ["B"]), ticket("B", ["A"])])) }
rejected("outside the plan: Z") { PrGraph::Program.validate_plan!(plan([ticket("A", ["Z"])])) }
rejected("duplicate ticket(s): A") { PrGraph::Program.validate_plan!(plan([ticket("A"), ticket("A")])) }
rejected("launch must contain {prompt_file}") { PrGraph::Program.validate_plan!(plan([ticket("A")], "launch" => "claude")) }
TESTS << "a plan must be acyclic, closed over its tickets, and launchable"

Dir.mktmpdir do |root|
  world = World.new(root, [ticket("A"), ticket("B"), ticket("C"), ticket("D", status: "excluded")])
  started = world.tick
  assert(started.map { |action| action["ticket"] } == %w[A B], "only max_building tickets start, in plan order")
  assert(world.launched.first.start_with?("launch A /repo "), "the launch template was not filled")
  prompt = started.first["prompt"]
  assert(prompt.include?("/pr-graph A") && prompt.include?("TEST_ENV_NUMBER=11") && prompt.include?("/ctx.md"),
         "the child prompt lacks its ticket, test database, or project context")
  assert(world.tick.empty?, "a second tick relaunched children still starting")
  assert(world.states.values_at("C", "D") == %w[ready excluded], "C should wait for capacity and D stays excluded")
end
TESTS << "independent tickets start in plan order up to the build cap, each with its own test database"

Dir.mktmpdir do |root|
  world = World.new(root, [ticket("A"), ticket("B"), ticket("C")])
  world.tick
  world.run("A", pr: 101, sha: "a1" * 20)
  world.run("B")
  started = world.tick
  assert(started.map { |action| action["ticket"] } == ["C"], "a published child should free its build slot")
  assert(world.states.values_at("A", "B", "C") == %w[published building launching], "states were not derived from streams")
end
TESTS << "a child waiting on CI after PUBLISH does not hold a build slot"

Dir.mktmpdir do |root|
  world = World.new(root, [ticket("A"), ticket("B", ["A"])])
  world.tick
  assert(world.states["B"] == "waiting", "B must wait for its parent")
  world.run("A", pr: 101, sha: "a1" * 20)
  action = world.tick.first
  assert(action["ticket"] == "B" && action["base_ref"] == "origin/feature/a" && action["base_sha"] == "a1" * 20,
         "B should stack on A's published candidate")
  assert(action["prompt"].include?("open the PR against `feature/a`"), "the stacked PR must target the parent branch")
end
TESTS << "a dependent ticket starts once its parent publishes, stacked on the parent's candidate"

Dir.mktmpdir do |root|
  world = World.new(root, [ticket("A"), ticket("B", ["A"]), ticket("C", ["B"]), ticket("D")])
  world.tick
  world.run("A", stop: "failure recurred after 3 consecutive BUILD cycles")
  world.run("D", pr: 104, sha: "d4" * 20, done: true)
  assert(world.states.values_at("A", "B", "C", "D") == %w[parked blocked blocked done], "a stop must park its dependents")
  assert(world.tick.empty?, "nothing downstream of a parked ticket may start")
end
TESTS << "a stopped child parks its dependents while other lanes finish"

Dir.mktmpdir do |root|
  world = World.new(root, [ticket("A"), ticket("B"), ticket("C", %w[A B])])
  world.tick
  world.run("A", pr: 101, sha: "a1" * 20, done: true)
  world.run("B", pr: 102, sha: "b2" * 20, done: true)
  assert(world.tick.empty? && world.states["C"] == "waiting", "two unmerged parents cannot both be a base")
  world.prs[101] = {"state" => "MERGED", "headRefOid" => "a1" * 20}
  action = world.tick.first
  assert(action["ticket"] == "C" && action["base_ref"] == "origin/feature/b", "C should stack on the unmerged parent")
end
TESTS << "a ticket with two parents waits until one merges, then stacks on the other"

Dir.mktmpdir do |root|
  world = World.new(root, [ticket("A"), ticket("B", ["A"])])
  world.tick
  world.run("A", pr: 101, sha: "a1" * 20)
  world.tick
  world.advance(30)
  world.run("B", pr: 102, sha: "b1" * 20, done: true)
  world.run("A", pr: 101, sha: "a2" * 20)
  action = world.tick.first
  assert(action["kind"] == "rebase" && action["base_sha"] == "a2" * 20, "a parent push should rebase the finished child")
  assert(action["prompt"].include?("git rebase --onto origin/feature/a #{'a1' * 20}"), "the rebase must replay only the child")
  assert(world.tick.empty?, "a rebase in flight must not be launched twice")

  world.advance(30)
  world.run("B", pr: 102, sha: "b2" * 20, done: true)
  world.prs[101] = {"state" => "MERGED", "headRefOid" => "a2" * 20}
  action = world.tick.first
  assert(action["base_ref"] == "origin/main" && action["prompt"].include?("change the PR base to `main`"),
         "a merged parent should retarget the child onto main")

  world.advance(30)
  world.run("B", pr: 102, sha: "b3" * 20, done: true)
  world.prs[102] = {"state" => "OPEN", "mergeable" => "CONFLICTING"}
  action = world.tick.first
  assert(action["kind"] == "rebase" && action["prompt"].include?("conflicts with origin/main"), "a conflicting PR should rebase")
end
TESTS << "a finished child rebases when its parent pushes, retargets when the parent merges, and rebases on conflict"

Dir.mktmpdir do |root|
  world = World.new(root, [ticket("A")])
  world.tick
  world.advance(25)
  assert(world.states["A"] == "lost", "a launch with no run after the grace period is lost")
  assert(world.tick.first["kind"] == "relaunch", "a lost child is relaunched once")
  world.advance(25)
  assert(world.states["A"] == "parked" && world.tick.empty?, "a second lost launch parks the ticket")
end
TESTS << "a launch that never starts a run is retried once, then parked"

Dir.mktmpdir do |root|
  world = World.new(root, [ticket("A")])
  world.tick
  world.run("A")
  world.advance(200)
  assert(world.states["A"] == "stalled", "a child silent for hours should be reported stalled")
  assert(world.tick.empty?, "a stalled child is reported, not relaunched")
end
TESTS << "a child silent for hours is reported stalled and left alone"

Dir.mktmpdir do |root|
  world = World.new(root, [ticket("A"), ticket("B", ["A"])])
  prompt = world.tick.first["prompt"]
  assert(prompt.include?("program.rb\" ask mcp A") && prompt.include?("program.rb\" await mcp"),
         "every child must be told to record questions and await the answer")
  world.run("A", pr: 101, sha: "a1" * 20, done: true)
  world.tick
  world.advance(30)
  world.run("B", pr: 102, sha: "b1" * 20, done: true)
  world.run("A", pr: 101, sha: "a2" * 20, done: true)
  rebase = world.tick.first
  assert(rebase["kind"] == "rebase" && rebase["prompt"].include?("program.rb\" ask mcp B"), "rebase children need the channel too")
end
TESTS << "every child prompt, including rebases, carries the question channel"

Dir.mktmpdir do |root|
  world = World.new(root, [ticket("A")], "supervisor" => "app-16")
  assert(world.program.supervisor == "app-16", "the plan names the first supervisor")
  world.program.supervise("app-42")
  asked = world.program.ask("A", "Option 1 or 2? I recommend 1")
  assert(asked["supervisor"] == "app-42", "a question goes to the latest supervisor, not the one the plan named")
  rejected("is not in the plan") { world.program.ask("Z", "x") }
  rejected("needs text") { world.program.ask("A", " ") }
  rejected("no question") { world.program.answer_for("nope") }
  assert(world.program.answer_for(asked["question_id"]).nil?, "an open question has no answer")
  assert(world.program.open_questions.map { |event| event["question_id"] } == [asked["question_id"]], "the question is open")
  world.program.answer(asked["question_id"], "Take option 1")
  assert(world.program.answer_for(asked["question_id"])["text"] == "Take option 1", "await reads the recorded answer")
  assert(world.program.open_questions.empty?, "an answered question is closed")
  rejected("no open question") { world.program.answer(asked["question_id"], "again") }
end
TESTS << "a child's question is recorded, routed to the current supervisor, and answered once"

Dir.mktmpdir do |root|
  world = World.new(root, [ticket("A")])
  world.tick
  world.run("A")
  question = world.program.ask("A", "May I widen the scope?")
  world.advance(200)
  state = world.program.states["A"]
  assert(state["state"] == "building" && state["detail"] == "waiting on #{question['question_id']}",
         "a child waiting on an answer is not stalled")
  world.program.answer(question["question_id"], "No")
  assert(world.states["A"] == "stalled", "once answered, silence counts again")
end
TESTS << "a child waiting on an answer is shown waiting, not stalled"

Dir.mktmpdir do |root|
  world = World.new(root, [ticket("A"), ticket("B", status: "excluded")])
  _, offset = world.program.events_after(0)
  world.tick
  found, offset = world.program.events_after(offset)
  lines = found.map { |event| PrGraph::Program.describe(event) }
  assert(lines.include?("A is ready") && lines.include?("B is excluded: decision ticket") &&
         lines.include?("A launched (start) on origin/main"), "the first tick reports every state and the launch: #{lines.inspect}")
  world.tick
  found, offset = world.program.events_after(offset)
  assert(found.map { |event| PrGraph::Program.describe(event) } == ["A is launching"], "the next tick sees the launch")
  world.tick
  assert(world.program.events_after(offset).first.empty?, "an unchanged tick records nothing")
  world.run("A", pr: 101, sha: "a1" * 20)
  world.tick
  found, = world.program.events_after(offset)
  assert(found.map { |event| PrGraph::Program.describe(event) } == ["A is published (PR #101)"], "a change is reported once")
end
TESTS << "the driver records each state change once, and watch describes it"

Dir.mktmpdir do |root|
  world = World.new(root, [ticket("A"), ticket("B")])
  world.tick
  world.run("A", pr: 101, sha: "a1" * 20, done: true)
  rejected("B is launching") { world.program.reopen("B", reason: "x", runner: ->(_) {}) }
  rejected("launched in the last 20 minutes") { world.program.reopen("A", reason: "x", runner: ->(_) {}) }
  world.advance(30)
  rejected("needs a reason") { world.program.reopen("A", reason: " ", runner: ->(_) {}) }
  action = world.program.reopen("A", reason: "fix Review Bot's open findings on PR #101", runner: ->(command) { world.launched << command })
  assert(action["prompt"].include?("/pr-graph adopt feature/a (PR #101)") && action["prompt"].include?("Review Bot's open findings"),
         "a reopen must adopt the PR and carry the reason")
  assert(action["prompt"].include?("program.rb\" ask mcp A"), "a reopened child needs the question channel")
  assert(world.states["A"] == "launching", "a reopened child is tracked like any launch")
  assert(world.tick.none? { |item| item["ticket"] == "A" }, "the scheduler must not relaunch a reopen in flight")
  world.advance(25)
  assert(world.states["A"] == "lost" && world.tick.empty?, "a reopen that never starts is reported, not relaunched as a fresh start")
end
TESTS << "a published or finished child can be reopened with a reason, and the scheduler tracks it"

Dir.mktmpdir do |root|
  world = World.new(root, [ticket("A"), ticket("B", ["A"])])
  world.tick
  world.run("A", stop: "failure recurred after 3 consecutive BUILD cycles")
  world.advance(30)
  assert(world.states == {"A" => "parked", "B" => "blocked"}, "a stopped child parks its dependents")
  action = world.program.reopen("A", reason: "the user chose option 1", runner: ->(command) { world.launched << command })
  assert(action["prompt"].start_with?("/pr-graph adopt feature/a\n") && action["prompt"].include?("option 1"),
         "a parked child with no PR is reopened on its branch: #{action['prompt'].lines.first.inspect}")
  world.advance(5)
  world.run("A")
  assert(world.states == {"A" => "building", "B" => "waiting"}, "the fresh run un-parks the child and its dependents")
end
TESTS << "a parked child can be reopened after the user decides, and its dependents follow"

rejected("model and {model} in launch go together") { PrGraph::Program.validate_plan!(plan([ticket("A")], "model" => "claude-opus-5-5")) }
rejected("model and {model} in launch go together") { PrGraph::Program.validate_plan!(plan([ticket("A")], "launch" => "claude --model {model} {prompt_file}")) }
Dir.mktmpdir do |root|
  world = World.new(root, [ticket("A")], "model" => "claude-opus-5-5", "launch" => "launch --model {model} {prompt_file}")
  world.tick
  assert(world.launched.first.start_with?("launch --model claude-opus-5-5 "), "the plan's model must reach every child")
end
TESTS << "a plan that names a model passes it to every child launch"
TESTS.each_with_index { |name, index| puts "ok #{index + 1}: #{name}" }
puts "#{TESTS.length} program tests passed"
RUBY

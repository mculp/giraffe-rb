#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/../scripts"

ruby - "${SCRIPTS_DIR}" <<'RUBY'
scripts_dir = ARGV.fetch(0)
$LOAD_PATH.unshift(scripts_dir)
require "github_feedback"
require "coordinator_runtime"
require "rbconfig"

SHA_A = "a" * 40
SHA_B = "d" * 40
WAKE = "11111111-1111-4111-8111-111111111111"
WAKE_2 = "22222222-2222-4222-8222-222222222222"
BASELINE = "2026-09-08T12:00:00Z"

def assert(condition, message)
  raise message unless condition
end

def assert_error(fragment)
  yield
  raise "expected error containing #{fragment.inspect}"
rescue PrGraph::ContractError => error
  raise "expected #{fragment.inspect}, got #{error.message.inspect}" unless error.message.include?(fragment)
end

def user(id, login, type)
  {"node_id" => id, "login" => login, "type" => type}
end

class FakeRunner
  attr_accessor :issue_pages, :review_pages, :review_comment_pages, :thread_pages, :failure
  attr_reader :calls

  def initialize
    @calls = []
    @failure = nil
    @repository = {"node_id" => "repo-node-1", "full_name" => "acme/app"}
    @pull_request = {
      "node_id" => "pr-node-17", "number" => 17,
      "head" => {"sha" => SHA_A}, "draft" => true, "state" => "open"
    }
    @issue_pages = [[]]
    @review_pages = [[]]
    @review_comment_pages = [[]]
    @thread_pages = [thread_page([])]
  end

  def thread_page(nodes)
    {
      "data" => {"repository" => {"pullRequest" => {"reviewThreads" => {"nodes" => nodes}}}}
    }
  end

  def head_sha=(sha)
    @pull_request["head"]["sha"] = sha
  end

  def capture(*command)
    @calls << command
    raise PrGraph::CommandRunner::CommandError, failure if failure
    return JSON.generate(@thread_pages) if command[0, 3] == ["gh", "api", "graphql"]

    endpoint = command.last
    value = case endpoint
            when "repos/acme/app" then @repository
            when "repos/acme/app/pulls/17" then @pull_request
            when %r{/issues/17/comments\?} then @issue_pages
            when %r{/pulls/17/reviews\?} then @review_pages
            when %r{/pulls/17/comments\?} then @review_comment_pages
            else raise "unexpected command: #{command.inspect}"
            end
    JSON.generate(value)
  end
end

def thread(id: "THREAD_1", resolved: false, outdated: false, comment_id: "PRRC_AUTO", body: "Fix the unsafe branch")
  {
    "id" => id, "isResolved" => resolved, "isOutdated" => outdated,
    "path" => "app/example.rb", "line" => 12,
    "comments" => {
      "totalCount" => 1,
      "nodes" => [{
        "id" => comment_id, "databaseId" => 301, "body" => body,
        "updatedAt" => "2026-09-08T12:10:00Z", "commit" => {"oid" => SHA_A},
        "originalCommit" => {"oid" => SHA_A}, "replyTo" => nil,
        "author" => {"id" => "BOT_REVIEW_BOT_1", "login" => "review-bot[bot]", "__typename" => "Bot"}
      }]
    }
  }
end

clock = -> { Time.iso8601("2026-09-08T12:30:00Z") }
runner = FakeRunner.new
adapter = PrGraph::GitHubFeedback.new(runner: runner, clock: clock)
runner.issue_pages = [[
  {
    "node_id" => "IC_CLAUDE", "id" => 101, "body" => "Early automated summary",
    "user" => user("BOT_kgDODIGtWg", "claude[bot]", "Bot"),
    "created_at" => "2026-09-08T11:00:00Z", "updated_at" => "2026-09-08T11:01:00Z"
  },
  {
    "node_id" => "IC_HUMAN", "id" => 102, "body" => "Human note",
    "user" => user("U_HUMAN", "human-dev", "User"),
    "created_at" => "2026-09-08T12:02:00Z", "updated_at" => "2026-09-08T12:03:00Z"
  }
]]
runner.review_pages = [[{
  "node_id" => "PRR_EMPTY", "id" => 201, "body" => "",
  "user" => user("BOT_kgDOC98s_g", "chatgpt-codex-connector[bot]", "Bot"),
  "commit_id" => SHA_A, "submitted_at" => "2026-09-08T12:04:00Z", "state" => "COMMENTED"
}]]
runner.review_comment_pages = [[{
  "node_id" => "PRRC_AUTO", "id" => 301, "body" => "Fix the unsafe branch",
  "user" => user("BOT_REVIEW_BOT_1", "review-bot[bot]", "Bot"),
  "commit_id" => SHA_A, "original_commit_id" => SHA_A, "updated_at" => "2026-09-08T12:10:00Z"
}]]
runner.thread_pages = [runner.thread_page([thread])]

pending = adapter.reconcile(
  repo: "acme/app", pr_number: 17, candidate_sha: SHA_A, wake_id: WAKE, baseline_at: BASELINE
)
assert(pending["overall"] == "pending", "unprocessed automated feedback did not remain pending")
early = pending["feedback"].find { |item| item["feedback_id"] == "issue_comment:IC_CLAUDE" }
human = pending["feedback"].find { |item| item["feedback_id"] == "issue_comment:IC_HUMAN" }
empty = pending["feedback"].find { |item| item["feedback_id"] == "review:PRR_EMPTY" }
assert(early, "pre-baseline automated feedback was filtered out")
assert(human.dig("author", "classification") == "human", "human author was not classified explicitly")
human_ledger = pending["ledger"].find { |entry| entry["feedback_id"] == human["feedback_id"] }
empty_ledger = pending["ledger"].find { |entry| entry["feedback_id"] == empty["feedback_id"] }
assert(human_ledger["decision"] == "ignored_human", "human feedback entered the automated gate")
assert(empty_ledger["decision"] == "no_content", "empty automated review was not terminal")
assert(runner.calls.count { |call| call.include?("--paginate") } == 4, "all feedback surfaces were not paginated")
puts "ok 1 - reconciles every surface and includes unresolved pre-baseline feedback"

review_bot = pending["feedback"].find { |item| item["feedback_id"] == "review_comment:PRRC_AUTO" }
decisions = {
  "decisions" => [
    {"feedback_id" => early["feedback_id"], "revision" => early["revision"], "decision" => "clean", "reason" => "reviewed with no actionable finding"},
    {"feedback_id" => review_bot["feedback_id"], "revision" => review_bot["revision"], "decision" => "fixed", "reason" => "guarded the branch", "candidate_sha" => SHA_A}
  ]
}
clean = adapter.reconcile(
  repo: "acme/app", pr_number: 17, candidate_sha: SHA_A, wake_id: WAKE,
  baseline_at: BASELINE, previous: pending, decisions: decisions
)
assert(clean["overall"] == "clean", "processed feedback did not become clean")
clean_again = adapter.reconcile(
  repo: "acme/app", pr_number: 17, candidate_sha: SHA_A, wake_id: WAKE,
  baseline_at: BASELINE, previous: clean
)
assert(clean_again["ledger"] == clean["ledger"], "unchanged revisions were processed more than once")
runner.head_sha = SHA_B
next_candidate = adapter.reconcile(
  repo: "acme/app", pr_number: 17, candidate_sha: SHA_B, wake_id: WAKE_2,
  baseline_at: BASELINE, previous: clean
)
assert(next_candidate["overall"] == "clean", "a new candidate reprocessed unchanged feedback")
assert(next_candidate["ledger"] == clean["ledger"], "a new wake discarded or duplicated the processing ledger")
runner.head_sha = SHA_A
puts "ok 2 - processes each immutable identity and revision exactly once"

runner.issue_pages.first.first["body"] = "Edited automated summary"
runner.issue_pages.first.first["updated_at"] = "2026-09-08T12:40:00Z"
edited = adapter.reconcile(
  repo: "acme/app", pr_number: 17, candidate_sha: SHA_A, wake_id: WAKE,
  baseline_at: BASELINE, previous: clean
)
edited_item = edited["feedback"].find { |item| item["feedback_id"] == early["feedback_id"] }
assert(edited["overall"] == "pending", "edited feedback inherited an old decision")
assert(edited_item["previous_revision"] == early["revision"], "edit lineage was not recorded")
finding_decisions = {"decisions" => [{
  "feedback_id" => edited_item["feedback_id"], "revision" => edited_item["revision"],
  "decision" => "finding", "reason" => "new revision identifies a regression"
}]}
finding = adapter.reconcile(
  repo: "acme/app", pr_number: 17, candidate_sha: SHA_A, wake_id: WAKE,
  baseline_at: BASELINE, previous: edited, decisions: finding_decisions
)
assert(finding["overall"] == "findings", "processed finding did not close with findings")
assert(finding["ledger"].any? { |entry| entry["feedback_id"] == early["feedback_id"] && entry["revision"] == early["revision"] },
       "edited feedback discarded its processed revision history")
assert_error("requires a processed finding") { PrGraph::FeedbackContract.new.validate!(clean, expected_pass: false) }
puts "ok 3 - reopens edits as new revisions and preserves finding polarity"

runner.thread_pages = [runner.thread_page([thread(resolved: true)])]
resolved = adapter.reconcile(
  repo: "acme/app", pr_number: 17, candidate_sha: SHA_A, wake_id: WAKE,
  baseline_at: BASELINE, previous: finding
)
resolved_review_bot = resolved["feedback"].find { |item| item["feedback_id"] == review_bot["feedback_id"] }
resolved_entry = resolved["ledger"].find do |entry|
  entry["feedback_id"] == review_bot["feedback_id"] && entry["revision"] == resolved_review_bot["revision"]
end
assert(resolved_review_bot["resolution_state"] == "resolved", "thread resolution was not projected")
assert(resolved_entry["decision"] == "resolved", "resolved thread did not become terminal")
puts "ok 4 - records review-thread resolution as a new terminal revision"

runner.issue_pages = [[runner.issue_pages.first.last]]
deleted = adapter.reconcile(
  repo: "acme/app", pr_number: 17, candidate_sha: SHA_A, wake_id: WAKE,
  baseline_at: BASELINE, previous: resolved
)
deleted_item = deleted["feedback"].find { |item| item["feedback_id"] == early["feedback_id"] }
deleted_entry = deleted["ledger"].find do |entry|
  entry["feedback_id"] == early["feedback_id"] && entry["revision"] == deleted_item["revision"]
end
assert(deleted_item["remote_state"] == "deleted", "deleted feedback disappeared from the ledger")
assert(deleted_entry["decision"] == "deleted", "deleted automated feedback stayed blocking")
puts "ok 5 - records deletion and lets deleted automated feedback unblock"

runner.issue_pages.first << {
  "node_id" => "IC_ANY_BOT", "id" => 103, "body" => "Snyk found a vulnerable dependency",
  "user" => user("BOT_ANY", "snyk-io[bot]", "Bot"),
  "created_at" => "2026-09-08T12:50:00Z", "updated_at" => "2026-09-08T12:50:00Z"
}
any_bot = adapter.reconcile(
  repo: "acme/app", pr_number: 17, candidate_sha: SHA_A, wake_id: WAKE,
  baseline_at: BASELINE, previous: deleted
)
any_bot_item = any_bot["feedback"].find { |item| item["feedback_id"] == "issue_comment:IC_ANY_BOT" }
assert(any_bot_item.dig("author", "classification") == "automated", "a GitHub App bot outside the list was not automated")
assert(any_bot["overall"] != "blocked", "a GitHub App bot outside the list blocked the gate")

runner.issue_pages.first << {
  "node_id" => "IC_UNKNOWN", "id" => 104, "body" => "Unknown automation",
  "user" => user("O_UNKNOWN", "acme-org", "Organization"),
  "created_at" => "2026-09-08T12:51:00Z", "updated_at" => "2026-09-08T12:51:00Z"
}
blocked = adapter.reconcile(
  repo: "acme/app", pr_number: 17, candidate_sha: SHA_A, wake_id: WAKE,
  baseline_at: BASELINE, previous: any_bot
)
unknown = blocked["feedback"].find { |item| item["feedback_id"] == "issue_comment:IC_UNKNOWN" }
assert(blocked["overall"] == "blocked", "an organization author did not fail closed")
assert(unknown.dig("author", "classification") == "unknown", "unknown author was misclassified")
assert_error("requires ledger decision blocked_unknown_author") do
  malformed = Marshal.load(Marshal.dump(blocked))
  malformed["ledger"].find { |entry| entry["feedback_id"] == unknown["feedback_id"] }["decision"] = "ignored_human"
  PrGraph::FeedbackContract.new.validate!(malformed)
end
puts "ok 6 - treats any GitHub App bot as automated, excludes humans, and fails closed on unknown authors"

runner.issue_pages = [[runner.issue_pages.first.first], [runner.issue_pages.first.first]]
assert_error("duplicate remote feedback identity") do
  adapter.reconcile(
    repo: "acme/app", pr_number: 17, candidate_sha: SHA_A, wake_id: WAKE,
    baseline_at: BASELINE
  )
end
runner.issue_pages = [[{
  "node_id" => nil, "id" => 104, "body" => "Missing identity",
  "user" => user("BOT_kgDODIGtWg", "claude[bot]", "Bot"),
  "created_at" => "2026-09-08T12:55:00Z", "updated_at" => "2026-09-08T12:55:00Z"
}]]
assert_error("issue_comment identity is missing") do
  adapter.reconcile(
    repo: "acme/app", pr_number: 17, candidate_sha: SHA_A, wake_id: WAKE,
    baseline_at: BASELINE
  )
end
runner.issue_pages = {}
assert_error("paginated GitHub feedback response must contain array pages") do
  adapter.reconcile(
    repo: "acme/app", pr_number: 17, candidate_sha: SHA_A, wake_id: WAKE,
    baseline_at: BASELINE
  )
end
puts "ok 7 - rejects pagination duplicates and missing stable identities"

runner.failure = "GitHub denied the feedback request"
assert_error("GitHub denied the feedback request") do
  adapter.reconcile(
    repo: "acme/app", pr_number: 17, candidate_sha: SHA_A, wake_id: WAKE,
    baseline_at: BASELINE
  )
end
assert_error("timed out") do
  PrGraph::CommandRunner.new(timeout_seconds: 0.05).capture(RbConfig.ruby, "-e", "sleep 5")
end
puts "ok 8 - surfaces API denial and bounds every GitHub command"

def decide(manifest, id, decision, reason, candidate_sha: nil)
  item = manifest["feedback"].find { |candidate| candidate["feedback_id"] == id }
  entry = {"feedback_id" => id, "revision" => item["revision"], "decision" => decision, "reason" => reason}
  entry["candidate_sha"] = candidate_sha if candidate_sha
  entry
end

def reconcile_with(adapter, previous: nil, decisions: nil)
  adapter.reconcile(
    repo: "acme/app", pr_number: 17, candidate_sha: SHA_A, wake_id: WAKE,
    baseline_at: BASELINE, previous: previous, decisions: decisions && {"decisions" => decisions}
  )
end

runner = FakeRunner.new
adapter = PrGraph::GitHubFeedback.new(runner: runner, clock: clock)
runner.review_pages = [[{
  "node_id" => "PRR_REVIEW_BOT", "id" => 202, "body" => "Two findings inline",
  "user" => user("BOT_REVIEW_BOT_1", "review-bot[bot]", "Bot"),
  "commit_id" => SHA_A, "submitted_at" => "2026-09-08T12:05:00Z", "state" => "COMMENTED"
}]]
runner.review_comment_pages = [[
  {
    "node_id" => "PRRC_AUTO", "id" => 301, "body" => "Fix the unsafe branch",
    "user" => user("BOT_REVIEW_BOT_1", "review-bot[bot]", "Bot"),
    "commit_id" => SHA_A, "original_commit_id" => SHA_A, "updated_at" => "2026-09-08T12:10:00Z"
  },
  {
    "node_id" => "PRRC_HUMAN", "id" => 302, "body" => "Human inline note",
    "user" => user("U_HUMAN", "human-dev", "User"),
    "commit_id" => SHA_A, "original_commit_id" => SHA_A, "updated_at" => "2026-09-08T12:11:00Z"
  }
]]
runner.thread_pages = [runner.thread_page([thread, thread(id: "THREAD_2", comment_id: "PRRC_HUMAN")])]
observed = reconcile_with(adapter)
assert(observed["overall"] == "pending", "undecided automated findings did not stay pending")
assert(observed["ledger"].find { |entry| entry["feedback_id"] == "review_comment:PRRC_HUMAN" }["decision"] == "ignored_human",
       "human inline comment required a decision")
summary = decide(observed, "review:PRR_REVIEW_BOT", "not_actionable", "summary of the inline findings")
assert_error("is an automated finding; decide fixed, declined, or not_actionable") do
  reconcile_with(adapter, previous: observed, decisions: [summary, decide(observed, "review_comment:PRRC_AUTO", "clean", "looks fine")])
end
assert_error("feedback decision fields are invalid") do
  reconcile_with(adapter, previous: observed, decisions: [summary, decide(observed, "review_comment:PRRC_AUTO", "fixed", "guarded")])
end
assert_error("feedback decision reason is missing") do
  reconcile_with(adapter, previous: observed, decisions: [summary, decide(observed, "review_comment:PRRC_AUTO", "declined", "")])
end
forged = Marshal.load(Marshal.dump(reconcile_with(adapter, previous: observed, decisions: [
  summary, decide(observed, "review_comment:PRRC_AUTO", "declined", "the branch is unreachable")
])))
forged["ledger"].find { |entry| entry["feedback_id"] == "review_comment:PRRC_AUTO" }["decision"] = "clean"
assert_error("overall clean requires a fixed, declined, or not_actionable decision on review_comment:PRRC_AUTO") do
  PrGraph::FeedbackContract.new.validate!(forged, expected_pass: true)
end
puts "ok 9 - refuses clean while an automated Review Bot inline finding is undecided"

%w[fixed declined not_actionable].each do |decision|
  sha = decision == "fixed" ? SHA_B : nil
  result = reconcile_with(adapter, previous: observed, decisions: [
    summary, decide(observed, "review_comment:PRRC_AUTO", decision, "judged #{decision}", candidate_sha: sha)
  ])
  assert(result["overall"] == "clean", "#{decision} did not settle the finding")
  PrGraph::FeedbackContract.new.validate!(result, expected_pass: true)
end
routed = reconcile_with(adapter, previous: observed, decisions: [
  summary, decide(observed, "review_comment:PRRC_AUTO", "finding", "requires BUILD")
])
assert(routed["overall"] == "findings", "an open finding did not route")
settled = reconcile_with(adapter, previous: routed, decisions: [
  decide(routed, "review_comment:PRRC_AUTO", "fixed", "guarded the branch", candidate_sha: SHA_B)
])
settled_entries = settled["ledger"].select { |entry| entry["feedback_id"] == "review_comment:PRRC_AUTO" }
assert(settled["overall"] == "clean" && settled_entries.map { |entry| entry["decision"] } == ["fixed"],
       "a routed finding was not settled in place by its fix")
assert(settled_entries.first["candidate_sha"] == SHA_B, "fixed decision lost its candidate SHA")
legacy = Marshal.load(Marshal.dump(routed))
legacy["ledger"].find { |entry| entry["feedback_id"] == "review:PRR_REVIEW_BOT" }["decision"] = "clean"
PrGraph::FeedbackContract.new.validate!(legacy, expected_pass: false)
puts "ok 10 - accepts fixed, declined, and not_actionable decisions and settles routed findings"

class FakeFeedbackAdapter
  attr_accessor :live, :threads

  def reconcile(**)
    live
  end

  def review_threads(repo:, pr_number:)
    raise "unexpected thread query" unless repo == "acme/app" && pr_number == 17

    threads
  end
end

def done_check(live, threads)
  fake = FakeFeedbackAdapter.new
  fake.live = live
  fake.threads = threads
  coordinator = PrGraph::Coordinator.allocate
  coordinator.instance_variable_set(:@feedback_contract, PrGraph::FeedbackContract.new)
  coordinator.instance_variable_set(:@feedback_adapter, fake)
  publish = {"repository" => {"name_with_owner" => "acme/app"}, "pull_request" => {"number" => 17}}
  artifacts = {
    "publish_manifest" => {"family" => "publish_manifest"},
    "bot_feedback" => {"family" => "bot_feedback", "candidate_sha" => SHA_A, "input_sha" => SHA_A, "wake_id" => WAKE}
  }
  coordinator.define_singleton_method(:current_artifacts) { |_state, family, **| [artifacts.fetch(family)] }
  coordinator.define_singleton_method(:read_structured_artifact!) do |artifact|
    artifact["family"] == "publish_manifest" ? publish : live
  end
  coordinator.send(:verify_live_feedback!, {}, SHA_A)
end

runner.thread_pages = [runner.thread_page([
  thread, thread(id: "THREAD_2", comment_id: "PRRC_HUMAN").tap do |node|
    node["comments"]["nodes"][0]["author"] = {"id" => "U_HUMAN", "login" => "human-dev", "__typename" => "User"}
  end
])]
live_threads = adapter.review_threads(repo: "acme/app", pr_number: 17)
assert(live_threads.map { |item| [item["comment_id"], item.dig("author", "classification")] } ==
       [%w[PRRC_AUTO automated], %w[PRRC_HUMAN human]], "review threads lost first-comment authorship")
assert(runner.calls.last.include?("--paginate"), "review threads were not paginated")
fixed = reconcile_with(adapter, previous: observed, decisions: [
  summary, decide(observed, "review_comment:PRRC_AUTO", "fixed", "guarded the branch", candidate_sha: SHA_B)
])
assert_error("unresolved automated review thread(s): app/example.rb (comment PRRC_AUTO)") do
  done_check(fixed, live_threads)
end
done_check(fixed, live_threads.map { |item| item.merge("is_outdated" => item["comment_id"] == "PRRC_AUTO") })
done_check(fixed, live_threads.map { |item| item.merge("is_resolved" => item["comment_id"] == "PRRC_AUTO") })
done_check(fixed, live_threads.select { |item| item["comment_id"] == "PRRC_HUMAN" })
puts "ok 11 - DONE refuses unresolved automated threads and ignores outdated, resolved, and human ones"

declined = reconcile_with(adapter, previous: observed, decisions: [
  summary, decide(observed, "review_comment:PRRC_AUTO", "declined", "the branch is unreachable")
])
done_check(declined, live_threads)
puts "ok 12 - DONE passes a declined finding for the human to read"

puts "1..12"
RUBY

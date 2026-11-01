#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/../scripts"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "${TEST_ROOT}/worktree"
printf 'Pull request body\n' > "${TEST_ROOT}/body.md"

ruby - "${SCRIPTS_DIR}" "${TEST_ROOT}" <<'RUBY'
scripts_dir, test_root = ARGV
$LOAD_PATH.unshift(scripts_dir)
require "github_pr_ci"
require "rbconfig"

SHA_A = "a" * 40
SHA_B = "b" * 40
WAKE = "11111111-1111-4111-8111-111111111111"

def assert(condition, message)
  raise message unless condition
end

def assert_error(fragment)
  yield
  raise "expected error containing #{fragment.inspect}"
rescue PrGraph::ContractError => error
  raise "expected #{fragment.inspect}, got #{error.message.inspect}" unless error.message.include?(fragment)
end

class FakeRunner
  attr_accessor :pulls, :pull_request, :check_pages, :status_pages, :failure
  attr_reader :calls, :create_count

  def initialize
    @calls = []
    @create_count = 0
    @pulls = []
    @failure = nil
    @repository = {"node_id" => "repo-node-1", "full_name" => "acme/app"}
    @pull_request = {
      "node_id" => "pr-node-17",
      "number" => 17,
      "html_url" => "https://github.com/acme/app/pull/17",
      "base" => {"ref" => "main"},
      "head" => {"ref" => "feature/demo-769", "sha" => SHA_A},
      "draft" => true,
      "state" => "open",
      "updated_at" => "2026-09-08T12:00:00Z"
    }
    @check_pages = [{"check_runs" => []}]
    @status_pages = [[]]
  end

  def capture(*command)
    @calls << command
    raise PrGraph::CommandRunner::CommandError, failure if failure
    return "#{SHA_A}\n" if command.first == "git"
    if command[0, 3] == ["gh", "pr", "create"]
      @create_count += 1
      return "https://github.com/acme/app/pull/17\n"
    end

    endpoint = command.last
    value = case endpoint
            when "repos/acme/app" then @repository
            when %r{\Arepos/acme/app/pulls\?} then @pulls
            when "repos/acme/app/pulls/17" then @pull_request
            when %r{/check-runs\?} then @check_pages
            when %r{/statuses\?} then @status_pages
            else raise "unexpected command: #{command.inspect}"
            end
    JSON.generate(value)
  end
end

clock = -> { Time.iso8601("2026-09-08T12:30:00Z") }
runner = FakeRunner.new
adapter = PrGraph::GitHubPrCi.new(runner: runner, clock: clock)

created = adapter.publish(
  repo: "acme/app",
  worktree: File.join(test_root, "worktree"),
  base: "main",
  head: "feature/demo-769",
  title: "Reconcile CI",
  body_file: File.join(test_root, "body.md")
)
assert(created["action"] == "created", "new branch did not create a PR")
assert(created.dig("pull_request", "id") == "pr-node-17", "stable PR identity was not persisted")
assert(created.dig("pull_request", "head_sha") == SHA_A, "candidate SHA was not persisted")
assert(runner.create_count == 1, "draft PR was not created exactly once")
create_call = runner.calls.find { |call| call[0, 3] == ["gh", "pr", "create"] }
assert(create_call&.include?("--draft"), "PR creation omitted the draft boundary")

runner.pulls = [{"number" => 17}]
adopted = adapter.publish(
  repo: "acme/app",
  worktree: File.join(test_root, "worktree"),
  base: "main",
  head: "feature/demo-769",
  title: "Reconcile CI",
  body_file: File.join(test_root, "body.md")
)
assert(adopted["action"] == "adopted", "existing PR was not adopted")
assert(runner.create_count == 1, "retry created a duplicate PR")
puts "ok 1 - creates or adopts exactly one draft PR by stable identity"

runner.pulls = [{"number" => 17}, {"number" => 18}]
assert_error("ambiguous open pull requests") do
  adapter.publish(
    repo: "acme/app", worktree: File.join(test_root, "worktree"), base: "main",
    head: "feature/demo-769", title: "Reconcile CI", body_file: File.join(test_root, "body.md")
  )
end
assert_error("repository must be owner/name") do
  adapter.publish(
    repo: "acme/app?state=all", worktree: File.join(test_root, "worktree"), base: "main",
    head: "feature/demo-769", title: "Reconcile CI", body_file: File.join(test_root, "body.md")
  )
end
runner.pulls = []
runner.pull_request["draft"] = false
ready = adapter.publish(
  repo: "acme/app", worktree: File.join(test_root, "worktree"), base: "main",
  head: "feature/demo-769", title: "Reconcile CI", body_file: File.join(test_root, "body.md"), pr_number: 17
)
assert(ready.dig("pull_request", "is_draft") == false, "a PR marked ready was not adopted as is")
runner.pull_request["draft"] = true
puts "ok 2 - blocks ambiguous PR identity and adopts a PR a person marked ready"

runner.check_pages = [
  {"check_runs" => [{
    "id" => 100, "name" => "build", "head_sha" => SHA_A, "status" => "completed",
    "conclusion" => "failure", "started_at" => "2026-09-08T12:01:00Z",
    "completed_at" => "2026-09-08T12:05:00Z", "details_url" => "https://buildkite.test/1",
    "app" => {"node_id" => "buildkite-app"}
  }]},
  {"check_runs" => [{
    "id" => 101, "name" => "build", "head_sha" => SHA_A, "status" => "completed",
    "conclusion" => "success", "started_at" => "2026-09-08T12:06:00Z",
    "completed_at" => "2026-09-08T12:10:00Z", "details_url" => "https://buildkite.test/2",
    "app" => {"node_id" => "buildkite-app"}
  }]}
]
runner.status_pages = [[{
  "id" => 200, "context" => "security", "sha" => SHA_A, "state" => "success",
  "created_at" => "2026-09-08T12:02:00Z", "updated_at" => "2026-09-08T12:08:00Z",
  "target_url" => "https://checks.test/200", "creator" => {"node_id" => "security-app"}
}]]
ci = adapter.reconcile_ci(repo: "acme/app", pr_number: 17, candidate_sha: SHA_A, wake_id: WAKE)
builds = ci["checks"].select { |check| check["logical_id"].include?("build") }
assert(ci["overall"] == "passed", "authoritative CI result did not pass")
assert(builds.map { |check| check["attempt"] } == [1, 2], "rerun attempts were not ordered")
assert(builds.last["supersedes_run_id"] == builds.first["run_id"], "rerun lineage was not recorded")
assert(ci["authoritative_run_ids"].include?("check-run:101"), "new rerun was not authoritative")
assert(!ci["authoritative_run_ids"].include?("check-run:100"), "superseded failure remained authoritative")
assert(runner.calls.any? { |call| call.include?("--paginate") && call.last.include?("check-runs") },
       "check pagination was not requested")
assert(runner.calls.any? { |call| call.include?("--paginate") && call.last.include?("statuses") },
       "status pagination was not requested")
puts "ok 3 - reconciles paginated check and status reruns by immutable identity"

original_statuses = runner.status_pages
runner.status_pages = [[
  {
    "id" => 300, "context" => "security/snyk (acme)", "sha" => SHA_A, "state" => "pending",
    "created_at" => "2026-09-08T12:03:00Z", "updated_at" => "2026-09-08T12:03:00Z",
    "target_url" => "https://snyk.test/300", "creator" => {"node_id" => "snyk-user-one"}
  },
  {
    "id" => 301, "context" => "security/snyk (acme)", "sha" => SHA_A, "state" => "success",
    "created_at" => "2026-09-08T12:04:00Z", "updated_at" => "2026-09-08T12:04:00Z",
    "target_url" => "https://snyk.test/301", "creator" => {"node_id" => "snyk-user-two"}
  }
]]
split = adapter.reconcile_ci(repo: "acme/app", pr_number: 17, candidate_sha: SHA_A, wake_id: WAKE)
snyk = split["checks"].select { |check| check["logical_id"] == "status:security/snyk (acme)" }
assert(snyk.length == 2, "statuses for one context were split into separate lanes")
assert(snyk.map { |check| check["attempt"] } == [1, 2], "status attempts were not ordered by creation time")
assert(snyk.last["supersedes_run_id"] == "status:300", "the later status did not supersede the pending one")
assert(snyk.map { |check| check["provider_identity"] } == %w[snyk-user-one snyk-user-two],
       "creator identity was not retained on each status row")
assert(split["overall"] == "passed", "a superseded pending status kept CI pending")
assert(split["authoritative_run_ids"] == ["check-run:101", "status:301"], "authoritative runs did not collapse to one per lane")
runner.status_pages = original_statuses
puts "ok 4 - lanes commit statuses by context so a pending posted under another creator is superseded"

runner.check_pages.first.fetch("check_runs").first["head_sha"] = SHA_B
assert_error("stale check run") do
  adapter.reconcile_ci(repo: "acme/app", pr_number: 17, candidate_sha: SHA_A, wake_id: WAKE)
end
runner.check_pages.first.fetch("check_runs").first["head_sha"] = SHA_A
runner.status_pages.first.first["sha"] = SHA_B
assert_error("stale commit status") do
  adapter.reconcile_ci(repo: "acme/app", pr_number: 17, candidate_sha: SHA_A, wake_id: WAKE)
end
runner.status_pages.first.first["sha"] = SHA_A
runner.pull_request.dig("head")["sha"] = SHA_B
assert_error("pull request head moved") do
  adapter.reconcile_ci(repo: "acme/app", pr_number: 17, candidate_sha: SHA_A, wake_id: WAKE)
end
runner.pull_request.dig("head")["sha"] = SHA_A
puts "ok 5 - rejects stale PR, check, and status SHA observations"

runner.check_pages = [{"check_runs" => []}]
runner.status_pages = [[]]
pending = adapter.reconcile_ci(repo: "acme/app", pr_number: 17, candidate_sha: SHA_A, wake_id: WAKE)
assert(pending["overall"] == "pending", "empty CI was treated as green")
assert_error("cannot complete before checks pass") do
  PrGraph::PrCiContract.new.validate_ci!(pending, expected_pass: true)
end
puts "ok 6 - preserves empty CI as pending"

failed = Marshal.load(Marshal.dump(ci))
failed_check = failed["checks"].find { |check| check["run_id"] == "check-run:101" }
failed_check["state"] = "failed"
failed["overall"] = "failed"
PrGraph::PrCiContract.new.validate_ci!(failed, expected_pass: false)
stale = Marshal.load(Marshal.dump(ci))
stale["checks"].first["head_sha"] = SHA_B
assert_error("stale CI status") { PrGraph::PrCiContract.new.validate_ci!(stale) }
wrong_artifact = {"candidate_sha" => SHA_A, "input_sha" => SHA_A, "wake_id" => "22222222-2222-4222-8222-222222222222"}
assert_error("artifact wake") { PrGraph::PrCiContract.new.validate_ci!(ci, artifact: wrong_artifact) }
puts "ok 7 - validates terminal polarity, candidate lineage, and wake binding"

runner.failure = "GitHub denied the request"
assert_error("GitHub denied the request") do
  adapter.reconcile_ci(repo: "acme/app", pr_number: 17, candidate_sha: SHA_A, wake_id: WAKE)
end
puts "ok 8 - surfaces API denial as a retryable adapter failure"

assert_error("timed out") do
  PrGraph::CommandRunner.new(timeout_seconds: 0.05).capture(RbConfig.ruby, "-e", "sleep 5")
end
puts "ok 9 - bounds external commands with a hard timeout"

puts "1..9"
RUBY

#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCRIPTS="${SCRIPT_DIR}/../scripts" ruby -I "${SCRIPT_DIR}/../scripts" <<'RUBY'
require "fileutils"
require "spec_audit_contract"

TESTS = []

def rejected(message)
  yield
  raise "expected rejection containing #{message.inspect}"
rescue PrGraph::ContractError => e
  raise "expected #{message.inspect}, got #{e.message.inspect}" unless e.message.include?(message)
end

CANDIDATE = "c" * 40
BASE = "b" * 40
PATHS = %w[spec/models/vendor_spec.rb].freeze

def spec(**overrides)
  {"ref" => "spec/models/vendor_spec.rb:12", "behavior" => "an unknown status is rejected", "classes" => [],
   "mutation" => {"change" => "remove the status guard", "result" => "fail"}}.merge(overrides)
end

def audit(specs = [spec], overrides = {})
  {"spec_audit" => {"candidate_sha" => CANDIDATE, "base_sha" => BASE, "specs" => specs}.merge(overrides)}
end

contract = PrGraph::SpecAuditContract.new
check = ->(verification, paths = PATHS) { contract.validate!(verification, candidate_sha: CANDIDATE, base_sha: BASE, spec_paths: paths) }

check.call(audit)
check.call(audit([]), [])
check.call(audit([spec, spec("ref" => "spec/models/vendor_spec.rb:30")]))
TESTS << "accepts clean specs that a mutation turns red, and an empty audit when no spec changed"

PrGraph::SpecAuditContract::CLASSES.each do |name|
  rejected("spec/models/vendor_spec.rb:12 (#{name})") { check.call(audit([spec("classes" => [name])])) }
end
rejected("(passes_without_change)") { check.call(audit([spec("mutation" => {"change" => "flip the guard", "result" => "pass"})])) }
rejected("(restates_literal, passes_without_change)") do
  check.call(audit([spec("classes" => ["restates_literal"], "mutation" => {"change" => "edit the list", "result" => "pass"})]))
end
TESTS << "each of the five classes, and a spec that survives its mutation, blocks VERIFY"

rejected("must record a spec_audit") { check.call({"failures" => 0}) }
rejected("must audit the current candidate") { check.call(audit([spec], "candidate_sha" => "d" * 40)) }
rejected("must diff against the run's base #{BASE}") { check.call(audit([spec], "base_sha" => CANDIDATE)) }
rejected("base_sha must be a full 40-character Git SHA") { check.call(audit([spec], "base_sha" => "main")) }
TESTS << "the audit covers the current candidate against the run's own base"

rejected("no entry for changed spec file(s): spec/models/status_spec.rb") { check.call(audit, PATHS + ["spec/models/status_spec.rb"]) }
rejected("did not add or change: spec/other_spec.rb") { check.call(audit([spec, spec("ref" => "spec/other_spec.rb:1")])) }
rejected("lists spec/models/vendor_spec.rb:12 more than once") { check.call(audit([spec, spec])) }
TESTS << "every changed spec file is audited, and nothing outside the change is"

rejected("ref must be path:line") { check.call(audit([spec("ref" => "spec/models/vendor_spec.rb")])) }
rejected("unknown class(es) nitpick") { check.call(audit([spec("classes" => ["nitpick"])])) }
rejected("repeats a class") { check.call(audit([spec("classes" => %w[mocks_subject mocks_subject])])) }
rejected("mutation result must be one of fail, pass") { check.call(audit([spec("mutation" => {"change" => "x", "result" => "skipped"})])) }
rejected("mutation change must be non-empty text") { check.call(audit([spec("mutation" => {"change" => " ", "result" => "fail"})])) }
rejected("behavior must be non-empty text") { check.call(audit([spec("behavior" => "")])) }
TESTS << "a malformed entry is refused"

contract.validate_shape!(audit([spec("classes" => ["mocks_subject"])]), candidate_sha: CANDIDATE)
TESTS << "a red audit still passes the shape check so a red VERIFY can be saved"

%w[spec/models/vendor_spec.rb test/vendor_list_test.rb app/javascript/foo.test.tsx web/bar.spec.js].each do |path|
  raise "#{path} should be a spec path" unless PrGraph::SpecAuditContract.spec_path?(path)
end
%w[spec/factories/vendors.rb spec/support/helpers.rb app/models/vendor.rb].each do |path|
  raise "#{path} should not be a spec path" if PrGraph::SpecAuditContract.spec_path?(path)
end
TESTS << "spec paths are spec and test files, not factories or support"

require "open3"
require "tmpdir"
Dir.mktmpdir do |repo|
  git = ->(*args) { Open3.capture2e("git", "-C", repo, *args).tap { |out, st| raise out unless st.success? }.first.strip }
  commit = lambda do |path, body|
    FileUtils.mkdir_p(File.dirname(File.join(repo, path)))
    File.write(File.join(repo, path), body)
    git.call("add", path)
    git.call("-c", "user.name=t", "-c", "user.email=t@t", "-c", "core.hooksPath=/dev/null", "commit", "-qm", path)
    git.call("rev-parse", "HEAD")
  end
  git.call("init", "-q")
  base = commit.call("lib/vendor.rb", "class Vendor; end\n")
  commit.call("spec/factories/vendors.rb", "# factory\n")
  candidate = commit.call("spec/models/vendor_spec.rb", "# spec\n")
  cli = File.join(ENV.fetch("SCRIPTS"), "spec_audit.rb")
  run = ->(*args) { Open3.capture3("ruby", cli, *args) }

  out, _, status = run.call("paths", repo, base, candidate)
  raise "paths: #{out}" unless status.success? && JSON.parse(out) == PATHS

  file = File.join(repo, "..", "#{File.basename(repo)}-audit.json")
  File.write(file, JSON.generate(audit.fetch("spec_audit").merge("candidate_sha" => candidate, "base_sha" => base)))
  out, err, status = run.call("check", repo, base, candidate, file)
  raise "clean check: #{out}#{err}" unless status.success? && JSON.parse(out) == {"specs" => 1, "spec_files" => 1}

  File.write(file, JSON.generate(audit([spec("classes" => ["restates_literal"])]).fetch("spec_audit")
                                   .merge("candidate_sha" => candidate, "base_sha" => base)))
  _, err, status = run.call("check", repo, base, candidate, file)
  raise "flagged check passed: #{err}" if status.success? || !err.include?("(restates_literal)")

  _, err, status = run.call("paths", repo, candidate, base)
  raise "reversed range passed: #{err}" if status.success? || !err.include?("is not an ancestor")
  File.delete(file)
end
TESTS << "the CLI lists changed spec files and checks an audit outside any run"

TESTS.each_with_index { |name, index| puts "ok #{index + 1}: #{name}" }
puts "#{TESTS.size} spec audit tests passed"
RUBY

#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECORD="${SCRIPT_DIR}/../scripts/run_record.rb"
FAKE="${SCRIPT_DIR}/../evals/fixtures/fake_temper.rb"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

tests=0

ok() {
  tests=$((tests + 1))
  echo "ok ${tests} - $1"
}

fail() {
  echo "not ok $((tests + 1)) - $1" >&2
  exit 1
}

# Assert with a Ruby expression over the parsed JSON on stdin, bound to `doc`.
check() {
  ruby -r json -e "doc = JSON.parse(\$stdin.read); exit((${1}) ? 0 : 1)" || fail "$2"
}

calls() {
  [ -f "$TEST_ROOT/calls.log" ] && wc -l < "$TEST_ROOT/calls.log" | tr -d ' ' || echo 0
}

printf '#!/usr/bin/env bash\nexec ruby %q "$@"\n' "$FAKE" > "$TEST_ROOT/temper"
chmod +x "$TEST_ROOT/temper"
export PR_GRAPH_TEMPER_BIN="$TEST_ROOT/temper" FAKE_TEMPER_LOG="$TEST_ROOT/calls.log" FAKE_TEMPER_CONTEXT="$TEST_ROOT/context.json"
unset PR_GRAPH_RECORD_CONTEXT FAKE_TEMPER_FAIL
CONTEXT=@me/pr-graph-runs
printf '{"context":"%s","rows":[],"contents":{}}' "$CONTEXT" > "$TEST_ROOT/context.json"

# A run that stopped after one red VERIFY: four artifacts the record attaches, one carrying a token after a
# newline that it must withhold, and one failure finding.
write_run() {
  ruby -r json -r fileutils -r digest -e '
    base, run_id = ARGV
    event = ->(seq, e, fields = {}) { JSON.generate({"v" => 1, "run_id" => run_id, "seq" => seq, "ts" => "2026-10-29T10:%02d:00Z" % seq,
                                                     "session" => "s1", "e" => e}.merge(fields)) }
    node = ->(seq, name, attempt, phase, iteration = 1) { event.call(seq, "node", "node" => name, "phase" => phase, "attempt_id" => attempt, "iteration" => iteration) }
    File.write("#{base}.jsonl", [
      event.call(1, "run_start", "ticket" => "ACME-201", "entry" => "ticket"),
      node.call(2, "TRIAGE", "a1", "start"), node.call(3, "TRIAGE", "a1", "done"),
      node.call(4, "BUILD", "a2", "start"), node.call(5, "BUILD", "a2", "done"),
      node.call(6, "VERIFY", "a3", "start"),
      event.call(7, "edge", "from" => "VERIFY", "to" => "BUILD", "from_attempt_id" => "a3", "reason" => "spec failed:\nexpected 2 got 3"),
      node.call(8, "BUILD", "a4", "start", 2), node.call(9, "BUILD", "a4", "done", 2),
      event.call(10, "publish", "pr" => 7, "candidate_sha" => "c" * 40)
    ].join("\n") + "\n")
    File.write("#{base}.failures.jsonl", JSON.generate({"e" => "finding", "failure_id" => "spec:totals", "source_node" => "VERIFY",
                                                        "reason" => "totals spec red"}) + "\n")
    dir = "#{base}.artifacts"
    FileUtils.mkdir_p(dir)
    blobs = [
      ["triage_brief", "TRIAGE", "application/json", JSON.generate("gaps" => ["currency"])],
      ["implementation_plan", "PLAN", "text/markdown", "# Plan\n\n1. Quote with the standard library."],
      ["self_review", "BUILD", "application/json", JSON.generate("findings" => [])],
      ["self_review", "BUILD", "application/json", JSON.generate("findings" => ["n+1 in export"])],
      ["verification", "VERIFY", "application/json", JSON.generate("log" => "GITHUB_TOKEN:\nghp_#{"a" * 36}")]
    ]
    rows = blobs.each_with_index.map do |(family, node_name, type, content), index|
      id = "art-#{index + 1}"
      File.write(File.join(dir, "#{id}.blob"), content)
      JSON.generate("e" => "artifact", "family" => family, "node" => node_name, "artifact_id" => id, "content_type" => type,
                    "content_ref" => "#{File.basename(dir)}/#{id}.blob", "content_sha256" => Digest::SHA256.hexdigest(content),
                    "content_bytes" => content.bytesize, "seq" => index + 1, "v" => 1, "run_id" => run_id, "session" => "s1")
    end
    File.write("#{base}.artifacts.jsonl", rows.join("\n") + "\n")
  ' "$1" "$2"
}

RUN_ID=01a20000-0000-7000-8000-000000000001
RUN="$TEST_ROOT/runs/ACME-201-$RUN_ID"
mkdir -p "$TEST_ROOT/runs"
write_run "$RUN" "$RUN_ID"

ruby "$RECORD" --events "$RUN.jsonl" | check 'doc == {"skipped" => "run recording is off"}' "no context should skip"
ruby "$RECORD" --events "$RUN.jsonl" --context none | check 'doc == {"skipped" => "run recording is off"}' "none should skip"
ruby "$RECORD" --events "$RUN.jsonl" --context pr-graph | check 'doc["skipped"].start_with?("pr-graph is not a context ref")' "a bare name should skip"
[ "$(calls)" = 0 ] || fail "a skipped record called Temper"
[ ! -e "$RUN.temper-record.json" ] || fail "a skipped record wrote state"
ok "skips without calling Temper when recording is off or the context is not a ref"

PR_GRAPH_RECORD_CONTEXT=$CONTEXT ruby "$RECORD" --events "$RUN.jsonl" > "$TEST_ROOT/first.json"
check 'doc["attached"] == 6 && doc["committed"] == 6 && doc["withheld"].map { |w| [w["record"], w["reason"]] } == [["verification", "it matches a secret pattern"]] &&
       doc["summary"].end_with?("6 data artifacts, 1 withheld (verification).")' \
  "the first record should attach both logs and four artifacts, and withhold the token" < "$TEST_ROOT/first.json"
check 'rows = doc["rows"]; rows.length == 1 && rows[0]["doc_type_name"] == "research" && rows[0]["title"] == "pr-graph run ACME-201 01a20000-0000-7000-8000-000000000001" &&
       rows[0]["open_meta"] == {"tags" => ["pr-graph-run"], "pr_graph_run" => "01a20000-0000-7000-8000-000000000001", "ticket" => "ACME-201", "status" => "stopped", "pr" => 7}' \
  "the run should be one research resource tagged with its run, ticket, status, and PR" < "$TEST_ROOT/context.json"
check 'body = doc["contents"].values.first; body.include?("| BUILD | 2 | done |") && body.include?("| VERIFY | 1 | open |") &&
       body.include?("- VERIFY to BUILD: spec failed: expected 2 got 3") && body.include?("- `spec:totals` from VERIFY: totals spec red") &&
       body.include?("stopped before DONE. PR 7") && body.include?("Data artifacts: event log, failure log, triage_brief, implementation_plan, self_review (2).") &&
       body.include?("- Withheld verification `art-5`: it matches a secret pattern.")' \
  "the summary should list nodes, red edges, failures, and what it attached and withheld" < "$TEST_ROOT/context.json"
check 'arts = doc["artifacts"]; arts.map { |a| [a["kind"], a["intent"]] } == [["pr-graph-event-log", "current"], ["pr-graph-failure-log", "current"],
       ["pr-graph-triage-brief", "member"], ["pr-graph-implementation-plan", "member"], ["pr-graph-self-review", "member"], ["pr-graph-self-review", "member"]] &&
       arts[3]["content"]["content"] == {"text" => "# Plan\n\n1. Quote with the standard library."} && arts[2]["content"]["record"]["family"] == "triage_brief" &&
       !JSON.generate(doc).include?("ghp_")' \
  "each record should be a data artifact of its family, and the token should never reach Temper" < "$TEST_ROOT/context.json"
ok "records a run as one resource with its logs and artifacts as data artifacts, withholding a secret"

before=$(calls)
PR_GRAPH_RECORD_CONTEXT=$CONTEXT ruby "$RECORD" --events "$RUN.jsonl" | check 'doc["committed"] == 0 && doc["attached"] == 6' "an unchanged rerun should commit nothing"
[ "$(calls)" = "$before" ] || fail "an unchanged rerun called Temper"
ok "makes no Temper call when nothing changed since the last record"

ruby -r json -e 'puts JSON.generate("v" => 1, "run_id" => ARGV[0], "seq" => 11, "ts" => "2026-10-29T10:11:00Z", "session" => "s1", "e" => "done", "candidate_sha" => "c" * 40)' \
  "$RUN_ID" >> "$RUN.jsonl"
before=$(calls)
PR_GRAPH_RECORD_CONTEXT=$CONTEXT ruby "$RECORD" --events "$RUN.jsonl" | check 'doc["committed"] == 1 && doc["attached"] == 6' "a grown log should commit only the new event log"
[ "$(($(calls) - before))" = 2 ] || fail "a grown log should make one update and one commit"
check 'rows = doc["rows"]; arts = doc["artifacts"]; rows.length == 1 && rows[0]["open_meta"]["status"] == "done" &&
       doc["contents"].values.first.include?("reached DONE") && arts.length == 7 && arts.last["kind"] == "pr-graph-event-log" &&
       arts.last["supersedes"] == [arts.first["id"]] && arts.last["content"]["events"].last["e"] == "done"' \
  "the record should update its summary and status, and the new event log should supersede the old" < "$TEST_ROOT/context.json"
ok "updates the summary and supersedes the event log when a recorded run finishes later"

RUN2_ID=01a20000-0000-7000-8000-000000000002
RUN2="$TEST_ROOT/runs/ACME-202-$RUN2_ID"
write_run "$RUN2" "$RUN2_ID"
FAKE_TEMPER_FAIL=pr-graph-self-review PR_GRAPH_RECORD_CONTEXT=$CONTEXT ruby "$RECORD" --events "$RUN2.jsonl" > "$TEST_ROOT/failed.json"
check 'doc["failed"] == "temper data-artifact commit failed: API error: unavailable" && doc["resource"] &&
       doc["summary"] == "Run record failed: temper data-artifact commit failed: API error: unavailable. Rerunning resumes it."' \
  "a failed write should report the CLI reason and the resource it reached" < "$TEST_ROOT/failed.json"
PR_GRAPH_RECORD_CONTEXT=$CONTEXT ruby "$RECORD" --events "$RUN2.jsonl" | check 'doc["committed"] == 2 && doc["attached"] == 6' "the rerun should commit only what failed"
check 'rid = doc["rows"].find { |r| r["open_meta"]["pr_graph_run"] == "01a20000-0000-7000-8000-000000000002" }["id"];
       doc["rows"].count { |r| r["open_meta"]["pr_graph_run"] == "01a20000-0000-7000-8000-000000000002" } == 1 &&
       doc["artifacts"].count { |a| a["resource"] == rid } == 6' \
  "a resumed record should hold one resource and no duplicate artifacts" < "$TEST_ROOT/context.json"
ok "resumes a record after a failed write without duplicating the resource or its artifacts"

rm "$RUN2.temper-record.json"
before=$(calls)
PR_GRAPH_RECORD_CONTEXT=$CONTEXT ruby "$RECORD" --events "$RUN2.jsonl" \
  | check 'doc["skipped"].start_with?("@me/pr-graph-runs already holds a record of this run (01a00000-")' "a record with no local state should skip"
[ "$(($(calls) - before))" = 1 ] || fail "a record with no local state should only look"
ok "refuses to record a run twice when the local record state is gone"

RUN3_ID=01a20000-0000-7000-8000-000000000003
RUN3="$TEST_ROOT/runs/ACME-203-$RUN3_ID"
write_run "$RUN3" "$RUN3_ID"
PR_GRAPH_RECORD_CONTEXT=@someone/else ruby "$RECORD" --events "$RUN3.jsonl" \
  | check 'doc["failed"] == "temper resource list failed: API error: forbidden" && doc["resource"].nil?' "an unwritable context should fail before any write"
! grep -q "resource create.*ACME-203" "$TEST_ROOT/calls.log" || fail "an unwritable context reached create"
ok "fails with the CLI's reason and writes nothing when the context is not readable"

# Reasons carrying a token cut by the length limit and a private key, one artifact row pointing outside
# the run, and one blob that fails its checksum.
RUN4_ID=01a20000-0000-7000-8000-000000000004
RUN4="$TEST_ROOT/runs/ACME-204-$RUN4_ID"
write_run "$RUN4" "$RUN4_ID"
ruby -r json -r digest -e '
  base = ARGV[0]
  key = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA#{"k" * 40}\n-----END RSA PRIVATE KEY-----"
  File.write("#{base}.failures.jsonl", [
    {"e" => "finding", "failure_id" => "ci:leak", "source_node" => "CI-WATCH", "reason" => "#{"x" * 290} ghp_#{"b" * 36}"},
    {"e" => "finding", "failure_id" => "verify:token", "source_node" => "VERIFY", "reason" => "GET /graphql?key%3Dlin_api_#{"c" * 40}"},
    {"e" => "finding", "failure_id" => "verify:aws", "source_node" => "VERIFY", "reason" => "export aws_AKIA#{"Q" * 16}"},
    {"e" => "stop", "failure_id" => "ci:leak", "processed_cycles" => 3, "reason" => key}
  ].map { |row| JSON.generate(row) }.join("\n") + "\n")
  File.write(File.join(File.dirname(base), "..", "outside.blob"), "outside the run")
  File.write("#{base}.artifacts/art-2.blob", "tampered plan")
  rows = File.readlines("#{base}.artifacts.jsonl").map { |row| JSON.parse(row) }
  rows[0].merge!("content_ref" => "../outside.blob", "content_sha256" => Digest::SHA256.hexdigest("outside the run"))
  File.write("#{base}.artifacts.jsonl", rows.map { |row| JSON.generate(row) }.join("\n") + "\n")
' "$RUN4"
PR_GRAPH_RECORD_CONTEXT=$CONTEXT ruby "$RECORD" --events "$RUN4.jsonl" \
  | check 'doc["attached"] == 3 && doc["withheld"].map { |w| [w["record"], w["reason"]] } == [["failure log", "it matches a secret pattern"],
           ["triage_brief", "its content file is missing or does not match its record"],
           ["implementation_plan", "its content file is missing or does not match its record"], ["verification", "it matches a secret pattern"]]' \
  "secrets, a row pointing outside the run, and a failed checksum should each be withheld"
check 'body = doc["rows"].find { |r| r["open_meta"]["pr_graph_run"] == "01a20000-0000-7000-8000-000000000004" }.then { |r| doc["contents"][r["id"]] };
       body.include?("- `ci:leak` from CI-WATCH: [withheld]") && body.include?("- `verify:token` from VERIFY: [withheld]") &&
       body.include?("- `verify:aws` from VERIFY: [withheld]") && body.include?("- Stopped on `ci:leak` after 3 cycles: [withheld]") &&
       !%w[ghp_ lin_api_ AKIA MIIE PRIVATE].any? { |s| JSON.generate(doc).include?(s) } && !JSON.generate(doc).include?("outside the run") && !JSON.generate(doc).include?("tampered")' \
  "no part of a secret, and no content outside the run or failing its checksum, should reach Temper" < "$TEST_ROOT/context.json"
ok "withholds secret reasons whole and artifacts whose rows do not match their blobs"

RUN5_ID=01a20000-0000-7000-8000-000000000005
RUN5="$TEST_ROOT/runs/ACME-205-$RUN5_ID"
write_run "$RUN5" "$RUN5_ID"
PR_GRAPH_TEMPER_BIN="$TEST_ROOT/missing-temper" PR_GRAPH_RECORD_CONTEXT=$CONTEXT ruby "$RECORD" --events "$RUN5.jsonl" \
  | check 'doc["failed"] == "Temper is not installed" && doc["resource"].nil? && doc["summary"] == "Run record failed: Temper is not installed."' \
  "a missing CLI should fail without saying a rerun resumes"
ok "says a rerun resumes only when a partial record exists"

echo "1..${tests}"

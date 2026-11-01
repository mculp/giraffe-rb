#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GIRAFFE_ROOT="${SCRIPT_DIR}/.."
FAKE="${GIRAFFE_ROOT}/evals/fixtures/fake_temper.rb"
COORDINATE="${GIRAFFE_ROOT}/scripts/coordinate.rb"
RECORD="${GIRAFFE_ROOT}/scripts/run_record.rb"
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

printf '#!/usr/bin/env bash\nexec ruby %q "$@"\n' "$FAKE" > "$TEST_ROOT/temper"
chmod +x "$TEST_ROOT/temper"
export PR_GRAPH_TEMPER_BIN="$TEST_ROOT/temper" FAKE_TEMPER_LOG="$TEST_ROOT/calls.log" FAKE_TEMPER_CONTEXT="$TEST_ROOT/context.json"
unset FAKE_TEMPER_FAIL FAKE_TEMPER_LOSE_ONCE PR_GRAPH_RECORD_CONTEXT
export CONTEXT=@me/pr-graph-runs
OUT="$TEST_ROOT/out.json"
WRITER="$TEST_ROOT/writer"
READER="$TEST_ROOT/reader"
PRELUDE="$TEST_ROOT/prelude.rb"

# The helpers every driver shares: a store on the fake Temper, a fixture run, and views of what the fake
# and a run's files hold.
cat > "$PRELUDE" <<'RUBY'
require "digest"
require "fileutils"
require "json"
require "securerandom"
require File.join(ENV.fetch("GIRAFFE_ROOT"), "lib/giraffe/store")

module Fixture
  CONTEXT_FILE = ENV.fetch("FAKE_TEMPER_CONTEXT")
  CALLS = ENV.fetch("FAKE_TEMPER_LOG")
  SHA = "a" * 40
  SESSION = "s-store"
  BRIEF = {"ticket" => "DEMO-1", "outcome_register" => {
    "why" => "A run must survive the machine that ran it.",
    "actors" => [{"id" => "actor:harness", "situation" => "The process executing a run."}],
    "positive_postconditions" => [{"id" => "outcome:resumes", "statement" => "Another machine resumes the run."}],
    "negative_face" => [{"id" => "constraint:no-gap", "statement" => "A gap never reads back as valid."}],
    "declared_gaps" => []
  }}.freeze

  module_function

  def store(run_id)
    PrGraph::Store.new(context: ENV.fetch("CONTEXT"), run_id: run_id, ticket: "DEMO-1", backoff: [0, 0])
  end

  def data
    JSON.parse(File.read(CONTEXT_FILE))
  end

  # The data artifacts the fake holds, in commit order.
  def stored(kind = nil)
    rows = data.fetch("artifacts", [])
    kind ? rows.select { |row| row["kind"] == kind } : rows
  end

  def commit_kinds
    File.readlines(CALLS).grep(/\Adata-artifact commit /).map { |line| line[/--kind (\S+)/, 1] }
  end

  def calls(prefix)
    File.readlines(CALLS).count { |line| line.start_with?(prefix) }
  end

  def jsonl(path)
    File.file?(path) ? File.readlines(path).map { |line| JSON.parse(line) } : []
  end

  def meta(family, node, attempt, candidate: nil, perspective: "author")
    {"family" => family, "node" => node, "attempt_id" => attempt, "producer" => "store-test", "input_sha" => SHA,
     "candidate_sha" => candidate, "content_type" => "application/json", "wake_id" => nil, "perspective" => perspective,
     "covered_outcomes" => []}
  end

  def event_row(run_id, seq: 1)
    {"v" => 1, "run_id" => run_id, "seq" => seq, "ts" => "2026-10-30T10:00:00Z", "session" => SESSION, "e" => "run_start",
     "ticket" => "DEMO-1", "entry" => "ticket"}
  end

  def artifact_record(run_id)
    id = SecureRandom.uuid
    event_row(run_id).slice("v", "run_id", "seq", "ts", "session").merge(
      "e" => "artifact", "artifact_id" => id, "family" => "triage_brief", "node" => "TRIAGE", "attempt_id" => SecureRandom.uuid,
      "producer" => "store-test", "input_sha" => SHA, "candidate_sha" => nil, "content_ref" => "DEMO-1-#{run_id}.artifacts/#{id}.blob",
      "content_sha256" => "b" * 64, "content_bytes" => 2, "content_type" => "text/plain", "wake_id" => nil, "perspective" => "author",
      "covered_outcomes" => []
    )
  end

  def run_path(dir, run_id)
    File.join(dir, "DEMO-1-#{run_id}.jsonl")
  end

  # A run stopped partway: TRIAGE done, INVESTIGATE (with a corrected report) and WORKTREE open, one failure
  # finding, and VERIFY closed on a red edge. TRIAGE, INVESTIGATE, and WORKTREE go through the coordinator;
  # the rest goes through the stored logs directly.
  def record_run(dir)
    run_id = SecureRandom.uuid
    store = store(run_id)
    store.open!
    path = run_path(dir, run_id)
    events = store.event_log
    events.emit(path, run_id: run_id, session: SESSION, payload: {"e" => "run_start", "ticket" => "DEMO-1", "entry" => "ticket"})
    coordinator = store.coordinator(execution_path: path, session: SESSION)
    triage = coordinator.start("TRIAGE").fetch("attempt_id")
    coordinator.put_artifact(meta("triage_brief", "TRIAGE", triage), JSON.generate(BRIEF))
    coordinator.complete("TRIAGE", triage, findings: 0)
    investigate = coordinator.start("INVESTIGATE").fetch("attempt_id")
    first = coordinator.put_artifact(meta("investigation_report", "INVESTIGATE", investigate), '{"findings":[]}')
    coordinator.put_artifact(meta("investigation_report", "INVESTIGATE", investigate), '{"findings":["x"]}',
                             replaces: first.fetch("artifact_id"), reason: "corrected")
    worktree = coordinator.start("WORKTREE").fetch("attempt_id")
    evidence = coordinator.put_artifact(meta("worktree_manifest", "WORKTREE", worktree, candidate: SHA, perspective: "automated_check"),
                                        '{"path":"test"}')
    store.failure_log.record(path.sub(/\.jsonl\z/, ".failures.jsonl"), execution_path: path, run_id: run_id, session: SESSION,
                             finding: {"failure_id" => "f:1", "source_node" => "WORKTREE", "source_attempt_id" => worktree,
                                       "candidate_sha" => SHA, "revision" => "r1", "reason" => "worktree check red",
                                       "artifact_ids" => [evidence.fetch("artifact_id")]})
    verify = SecureRandom.uuid
    events.emit(path, run_id: run_id, session: SESSION,
                payload: {"e" => "node", "node" => "VERIFY", "phase" => "start", "attempt_id" => verify, "iteration" => 1})
    events.emit_many(path, run_id: run_id, session: SESSION, payloads: [
      {"e" => "outcome", "kind" => "verify", "attempt_id" => verify, "pass" => false, "n" => 2},
      {"e" => "edge", "from" => "VERIFY", "to" => "BUILD", "from_attempt_id" => verify, "reason" => "spec red"},
      {"e" => "node", "node" => "VERIFY", "phase" => "done", "attempt_id" => verify, "iteration" => 1}
    ])
    [store, {"path" => path, "run_id" => run_id, "session" => SESSION, "triage" => triage, "investigate" => investigate,
             "worktree" => worktree, "verify" => verify}]
  end

  # What a run holds on disk: its three logs, and its blobs and manifests by file name.
  def snapshot(path)
    stem = path.delete_suffix(".jsonl")
    named = ->(dir, ext) { Dir.glob(File.join(dir, "*#{ext}")).to_h { |file| [File.basename(file), File.binread(file)] } }
    {"events" => jsonl(path), "artifacts" => jsonl("#{stem}.artifacts.jsonl"), "failures" => jsonl("#{stem}.failures.jsonl"),
     "blobs" => named.call("#{stem}.artifacts", ".blob"), "manifests" => named.call("#{stem}.coordinator", ".json")}
  end
end
RUBY

# Run a Ruby driver with the helpers loaded; the arguments after the script are its ARGV.
drive() {
  local script="$1"
  shift
  ruby -r "$PRELUDE" -e "$script" "$@"
}

reset() {
  printf '{"context":"%s","rows":[],"contents":{}}' "$CONTEXT" > "$TEST_ROOT/context.json"
  : > "$TEST_ROOT/calls.log"
  rm -rf "$WRITER" "$READER"*
  mkdir -p "$WRITER" "$READER"
  unset FAKE_TEMPER_FAIL FAKE_TEMPER_LOSE_ONCE
}

reset
drive '
  store, run = Fixture.record_run(ARGV[0])
  local = Fixture.snapshot(run["path"])
  log = ->(kind) { Fixture.stored(kind) }
  families = Fixture.stored.map { |row| row["kind"] }.reject { |kind| %w[giraffe-run-event-log giraffe-run-artifact-log giraffe-run-failure-log giraffe-run-manifest].include?(kind) }
  evidence = local["artifacts"].select { |row| row["e"] == "artifact" }.map do |row|
    {"record" => row, "content" => local["blobs"].fetch("#{row["artifact_id"]}.blob").force_encoding("UTF-8")}
  end
  puts JSON.generate(
    "event_seqs" => log.("giraffe-run-event-log").map { |row| row["content"]["events"].map { |event| event["seq"] } },
    "events_back" => log.("giraffe-run-event-log").flat_map { |row| row["content"]["events"] } == local["events"],
    "artifact_seqs" => log.("giraffe-run-artifact-log").map { |row| row["content"]["events"].map { |event| event["seq"] } },
    "artifact_log_back" => log.("giraffe-run-artifact-log").flat_map { |row| row["content"]["events"] } == local["artifacts"],
    "failure_seqs" => log.("giraffe-run-failure-log").map { |row| row["content"]["events"].map { |event| event["seq"] } },
    "failures_back" => log.("giraffe-run-failure-log").flat_map { |row| row["content"]["events"] } == local["failures"],
    "families" => families.tally,
    "evidence_back" => families.length == evidence.length && (log.("giraffe-run-triage-brief") + log.("giraffe-run-investigation-report") + log.("giraffe-run-worktree-manifest")).map { |row| row["content"] }.sort_by { |content| content["record"]["seq"] } == evidence.sort_by { |content| content["record"]["seq"] },
    "manifests_back" => log.("giraffe-run-manifest").to_h { |row| [row["content"]["name"], row["content"]["text"]] } == local["manifests"].transform_values { |text| text.force_encoding("UTF-8") },
    "manifest_count" => local["manifests"].length
  )
' "$WRITER" > "$OUT" || fail "a fixture run should be accepted under the enforcing shapes"
check 'doc["event_seqs"] == [[1], [2], [3], [4], [5], [6], [7, 8, 9]] && doc["events_back"]' \
  "each transition should be one write holding its events in order, and the events should read back unchanged" < "$OUT"
check 'doc["artifact_seqs"] == [[1], [2], [3], [4], [5]] && doc["artifact_log_back"] && doc["failure_seqs"] == [[1]] && doc["failures_back"]' \
  "artifact rows, a link, and a failure finding should read back unchanged" < "$OUT"
check 'doc["families"] == {"giraffe-run-triage-brief" => 1, "giraffe-run-investigation-report" => 2, "giraffe-run-worktree-manifest" => 1} && doc["evidence_back"]' \
  "each artifact should be stored with its record and exact content under its family" < "$OUT"
check 'doc["manifest_count"] == 4 && doc["manifests_back"]' "the leases and the result should read back with their exact text" < "$OUT"
ok "accepts a fixture run under enforcing shapes and reads every write back unchanged"

reset
drive '
  run_id = SecureRandom.uuid
  store = Fixture.store(run_id)
  store.open!
  record = Fixture.artifact_record(run_id)
  event = Fixture.event_row(run_id)
  commit = lambda do |kind, content|
    store.commit(kind: kind, content: content, precedence: 1, correlation: run_id)
    nil
  rescue PrGraph::Store::Error => e
    e.message
  end
  good = commit.("giraffe-run-triage-brief", {"record" => record, "content" => "ok"})
  stored = Fixture.stored.length
  errors = [
    commit.("giraffe-run-triage-brief", {"record" => record.reject { |key, _| key == "producer" }, "content" => "ok"}),
    commit.("giraffe-run-event-log", {"transition_id" => SecureRandom.uuid, "events" => [event.merge("seq" => "1")]}),
    commit.("giraffe-run-event-log", {"transition_id" => SecureRandom.uuid, "events" => [event.merge("surprise" => true)]})
  ]
  puts JSON.generate("good" => good, "stored" => stored, "errors" => errors, "stored_after" => Fixture.stored.length)
' > "$OUT" || fail "known-bad items should be refused with an error, not crash the writer"
check 'doc["good"].nil? && doc["stored"] == 1' "a conforming artifact should be accepted" < "$OUT"
check 'doc["errors"][0].to_s.include?("producer") && doc["errors"][1].to_s.include?("seq") && doc["errors"][2].to_s.include?("surprise")' \
  "an artifact missing a field, an event with a wrongly typed field, and an unknown field should each be refused, naming it" < "$OUT"
check 'doc["stored_after"] == 1' "a refused write should store nothing" < "$OUT"
ok "refuses a malformed artifact record or event at write time and stores nothing"

reset
drive '
  run_id = SecureRandom.uuid
  store = Fixture.store(run_id)
  store.open!
  path = Fixture.run_path(ARGV[0], run_id)
  store.event_log.emit(path, run_id: run_id, session: Fixture::SESSION, payload: {"e" => "run_start", "ticket" => "DEMO-1", "entry" => "ticket"})
  coordinator = store.coordinator(execution_path: path, session: Fixture::SESSION)
  triage = coordinator.start("TRIAGE").fetch("attempt_id")
  File.write(Fixture::CALLS, "")
  coordinator.put_artifact(Fixture.meta("triage_brief", "TRIAGE", triage), JSON.generate(Fixture::BRIEF))
  ordered = Fixture.commit_kinds
  coordinator.complete("TRIAGE", triage, findings: 0)
  File.write(Fixture::CALLS, "")
  ENV["FAKE_TEMPER_FAIL"] = "giraffe-run-investigation-report"
  investigate = coordinator.start("INVESTIGATE").fetch("attempt_id")
  stem = path.delete_suffix(".jsonl")
  before = Fixture.snapshot(path)
  error = begin
    coordinator.put_artifact(Fixture.meta("investigation_report", "INVESTIGATE", investigate), "{\"findings\":[]}")
    nil
  rescue PrGraph::Store::Error => e
    e.message
  end
  puts JSON.generate("ordered" => ordered, "error" => error, "attempted" => Fixture.commit_kinds.uniq - ["giraffe-run-manifest", "giraffe-run-event-log"],
                     "artifact_rows" => Fixture.snapshot(path)["artifacts"].length - before["artifacts"].length,
                     "blobs" => Fixture.snapshot(path)["blobs"].length - before["blobs"].length)
' "$WRITER" > "$OUT" || fail "the writer should record an artifact and then fail an evidence write"
check 'doc["ordered"] == ["giraffe-run-triage-brief", "giraffe-run-artifact-log"]' "an artifact's evidence should be written before the record that names it" < "$OUT"
check 'doc["error"].to_s.include?("unavailable") && doc["attempted"] == ["giraffe-run-investigation-report"]' \
  "a failed evidence write should stop the record write and surface the store's reason" < "$OUT"
check 'doc["artifact_rows"] == 0 && doc["blobs"] == 0' "a failed evidence write should leave no local artifact row or blob" < "$OUT"
ok "writes evidence before the record that names it, and a failed evidence write stops the record"

reset
drive '
  store, run = Fixture.record_run(ARGV[0])
  File.write(File.join(ARGV[0], "run.json"), JSON.generate(run))
' "$WRITER" || fail "the writer should record a fixture run"
drive '
  run = JSON.parse(File.read(File.join(ARGV[0], "run.json")))
  target = File.join(ARGV[1], File.basename(run["path"]))
  Fixture.store(run["run_id"]).hydrate(target)
  local = Fixture.snapshot(run["path"])
  back = Fixture.snapshot(target)
  puts JSON.generate(
    "events" => local["events"] == back["events"], "artifacts" => local["artifacts"] == back["artifacts"],
    "failures" => local["failures"] == back["failures"], "blobs" => local["blobs"] == back["blobs"],
    "manifests" => local["manifests"] == back["manifests"], "blob_count" => back["blobs"].length,
    "manifest_count" => back["manifests"].length, "event_count" => back["events"].length
  )
' "$WRITER" "$READER" > "$OUT" || fail "a fresh directory should hydrate from the store"
check 'doc["events"] && doc["artifacts"] && doc["failures"] && doc["event_count"] == 9' "hydrate should rebuild the same events, artifact rows, and failure findings" < "$OUT"
check 'doc["blobs"] && doc["manifests"] && doc["blob_count"] == 4 && doc["manifest_count"] == 4' "hydrate should rebuild byte-identical blobs and manifests" < "$OUT"
RUN_NAME=$(ruby -r json -e 'puts File.basename(JSON.parse(File.read(ARGV[0]))["path"])' "$WRITER/run.json")
ruby "$COORDINATE" check-run "$WRITER/$RUN_NAME" --offline | sed "s#${WRITER}#DIR#g" > "$TEST_ROOT/writer-check.json" || fail "the writer's own log should pass check-run"
ruby "$COORDINATE" check-run "$READER/$RUN_NAME" --offline | sed "s#${READER}#DIR#g" > "$TEST_ROOT/reader-check.json" || fail "the hydrated log should pass check-run"
check 'doc["open_attempts"].map { |attempt| attempt["node"] } == ["INVESTIGATE", "WORKTREE"]' "the resume check should see the writer's open work" < "$TEST_ROOT/reader-check.json"
ruby -r json -e 'exit(JSON.parse(File.read(ARGV[0])) == JSON.parse(File.read(ARGV[1])) ? 0 : 1)' "$TEST_ROOT/writer-check.json" "$TEST_ROOT/reader-check.json" || fail "the hydrated run should give the resume check the writer's answer"
mkdir -p "$TEST_ROOT/reader-resumed"
drive '
  run = JSON.parse(File.read(File.join(ARGV[0], "run.json")))
  target = File.join(ARGV[1], File.basename(run["path"]))
  store = Fixture.store(run["run_id"])
  store.hydrate(target)
  store.event_log.emit(target, run_id: run["run_id"], session: run["session"],
                       payload: {"e" => "node", "node" => "INVESTIGATE", "phase" => "partial", "attempt_id" => run["investigate"], "iteration" => 1, "note" => "resumed"})
  puts JSON.generate("stored" => Fixture.stored("giraffe-run-event-log").last["content"]["events"].map { |event| event["seq"] }, "local" => Fixture.jsonl(target).last["seq"])
' "$WRITER" "$TEST_ROOT/reader-resumed" > "$OUT" || fail "a hydrated run should accept further stored transitions"
check 'doc["stored"] == [10] && doc["local"] == 10' "a transition after hydrate should continue the sequence in the store and the local log" < "$OUT"
ok "hydrates a run into an empty directory that resumes exactly where the writer stopped"


# A transition whose write landed but reported failure is committed again with the same ID and bytes, and
# reads back once.
reset
FAKE_TEMPER_LOSE_ONCE=giraffe-run-event-log drive '
  store, run = Fixture.record_run(ARGV[0])
  target = File.join(ARGV[1], File.basename(run["path"]))
  Fixture.store(run["run_id"]).hydrate(target)
  rows = Fixture.stored("giraffe-run-event-log")
  puts JSON.generate(
    "rows" => rows.length, "transitions" => rows.map { |row| row["content"]["transition_id"] }.uniq.length,
    "seqs" => Fixture.jsonl(target).map { |event| event["seq"] }, "same" => Fixture.jsonl(target) == Fixture.jsonl(run["path"])
  )
' "$WRITER" "$READER" > "$OUT" || fail "a transition written twice should still hydrate"
check 'doc["rows"] == 8 && doc["transitions"] == 7' "the retry should really be stored, as one extra copy of one transition" < "$OUT"
check 'doc["seqs"] == [1, 2, 3, 4, 5, 6, 7, 8, 9] && doc["same"]' "a repeated transition should read back once, with no repeated sequence number" < "$OUT"
ok "reads a transition written twice back once"

# A crash after Temper took a transition and before the local log did leaves the local log behind Temper.
# Appending again would give the same sequence number to a different transition, so the append fails and
# the run parks; Temper still holds a run that hydrates.
reset
mkdir -p "$READER-behind"
drive '
  run_id = SecureRandom.uuid
  store = Fixture.store(run_id)
  store.open!
  path = Fixture.run_path(ARGV[0], run_id)
  start = {"e" => "run_start", "ticket" => "DEMO-1", "entry" => "ticket"}
  step = {"e" => "node", "node" => "TRIAGE", "phase" => "start", "attempt_id" => SecureRandom.uuid, "iteration" => 1}
  emit = lambda do |log, payload|
    log.emit(path, run_id: run_id, session: Fixture::SESSION, payload: payload)
    nil
  rescue StandardError => e
    e.class.name
  end
  emit.(store.event_log, start)
  File.chmod(0o400, path)
  crash = emit.(store.event_log, step)
  File.chmod(0o600, path)
  stored = Fixture.stored("giraffe-run-event-log").length
  same_process = emit.(store.event_log, step)
  fresh_process = emit.(Fixture.store(run_id).event_log, step)
  target = File.join(ARGV[1], File.basename(path))
  Fixture.store(run_id).hydrate(target)
  puts JSON.generate(
    "crash" => crash, "stored" => stored, "same_process" => same_process, "fresh_process" => fresh_process,
    "stored_after" => Fixture.stored("giraffe-run-event-log").length, "local" => Fixture.jsonl(path).map { |event| event["seq"] },
    "hydrated" => Fixture.jsonl(target).map { |event| event["seq"] }
  )
' "$WRITER" "$READER-behind" > "$OUT" || fail "a log behind Temper should fail its append with an error, not crash the writer"
check 'doc["crash"] == "Errno::EACCES" && doc["stored"] == 2 && doc["local"] == [1]' "the transition should reach Temper and not the local log" < "$OUT"
check 'doc["same_process"] == "PrGraph::Store::Error" && doc["fresh_process"] == "PrGraph::Store::Error"' \
  "the next append, by the same process or a new one, should raise a store error" < "$OUT"
check 'doc["stored_after"] == 2 && doc["local"] == [1]' "a refused append should write nothing, to Temper or locally" < "$OUT"
check 'doc["hydrated"] == [1, 2]' "the run should still hydrate from Temper, with the transition the local log lacks" < "$OUT"
ok "refuses to append to a local log that is behind Temper"

reset
drive '
  store, run = Fixture.record_run(ARGV[0])
  File.write(File.join(ARGV[0], "run.json"), JSON.generate(run))
' "$WRITER" || fail "the writer should record a fixture run"
cp "$TEST_ROOT/context.json" "$TEST_ROOT/context.good"
mkdir -p "$READER-conflict" "$READER-gap" "$READER-intact"
drive '
  run = JSON.parse(File.read(File.join(ARGV[0], "run.json")))
  good = JSON.parse(File.read(Fixture::CONTEXT_FILE))
  hydrate = lambda do |data, dir|
    File.write(Fixture::CONTEXT_FILE, JSON.generate(data))
    Fixture.store(run["run_id"]).hydrate(File.join(dir, File.basename(run["path"])))
    nil
  rescue PrGraph::Store::Error => e
    e.message
  end
  event_rows = ->(data) { data["artifacts"].select { |row| row["kind"] == "giraffe-run-event-log" } }
  conflicting = Marshal.load(Marshal.dump(good))
  twin = Marshal.load(Marshal.dump(event_rows.(conflicting).first))
  twin["id"] = "02a00000-0000-7000-8000-999999999999"
  twin["content"]["events"][0]["ts"] = "2026-01-01T00:00:00.000000Z"
  conflicting["artifacts"] << twin
  gapped = Marshal.load(Marshal.dump(good))
  gapped["artifacts"].delete(event_rows.(gapped)[2])
  conflict_error = hydrate.(conflicting, ARGV[1])
  gap_error = hydrate.(gapped, ARGV[2])
  intact_error = hydrate.(good, ARGV[3])
  puts JSON.generate(
    "transition_id" => twin["content"]["transition_id"], "conflict_error" => conflict_error, "gap_error" => gap_error,
    "intact_error" => intact_error, "conflict_children" => Dir.children(ARGV[1]), "gap_children" => Dir.children(ARGV[2]),
    "intact_events" => Fixture.jsonl(File.join(ARGV[3], File.basename(run["path"]))).length
  )
' "$WRITER" "$READER-conflict" "$READER-gap" "$READER-intact" > "$OUT" || fail "a damaged run should fail hydrate with an error"
check 'doc["conflict_error"].to_s.include?(doc["transition_id"]) && doc["conflict_children"] == []' \
  "two different transitions under one ID should fail hydrate, naming the ID, and leave the directory empty" < "$OUT"
check 'doc["gap_error"].to_s.include?("sequence 3") && doc["gap_children"] == []' \
  "a deleted middle transition should fail hydrate, naming the missing sequence, and leave the directory empty" < "$OUT"
check 'doc["intact_error"].nil? && doc["intact_events"] == 9' "the intact copy of the same run should hydrate cleanly" < "$OUT"
ok "fails hydrate closed on a conflicting transition ID or a sequence gap"

# An artifact ID read from the store names a file under the run's directory, so one that is not a UUID must
# fail hydrate before anything is written for it.
reset
drive '
  store, run = Fixture.record_run(ARGV[0])
  File.write(File.join(ARGV[0], "run.json"), JSON.generate(run))
' "$WRITER" || fail "the writer should record a fixture run"
cp "$TEST_ROOT/context.json" "$TEST_ROOT/context.good"
mkdir -p "$READER-up" "$READER-up-two"
drive '
  run = JSON.parse(File.read(File.join(ARGV[0], "run.json")))
  good = File.read(Fixture::CONTEXT_FILE)
  victim = JSON.parse(good).fetch("artifacts").find { |row| row["kind"] == "giraffe-run-triage-brief" }["content"]["record"]["artifact_id"]
  hydrate = lambda do |escaped, dir|
    File.write(Fixture::CONTEXT_FILE, good.gsub(victim, escaped))
    Fixture.store(run["run_id"]).hydrate(File.join(dir, File.basename(run["path"])))
    nil
  rescue PrGraph::Store::Error => e
    e.message
  end
  one = hydrate.("../escape", ARGV[1])
  two = hydrate.("../../escape", ARGV[2])
  puts JSON.generate("one_error" => one, "two_error" => two, "one_children" => Dir.children(ARGV[1]), "two_children" => Dir.children(ARGV[2]))
' "$WRITER" "$READER-up" "$READER-up-two" > "$OUT" || fail "an artifact ID that is not a UUID should fail hydrate with an error"
check 'doc["one_error"].to_s.include?("../escape") && doc["two_error"].to_s.include?("../../escape")' \
  "an artifact ID that is not a UUID should fail hydrate, naming the ID" < "$OUT"
check 'doc["one_children"] == [] && doc["two_children"] == []' \
  "a failed hydrate should leave nothing in the directory, inside the stage or beside it" < "$OUT"
ok "fails hydrate closed on an artifact ID that would name a file outside the stage"

# A step that crashed after its evidence landed but before the write naming it, and a lease whose start
# never landed, leave rows in the store that no event or record names.
reset
mkdir -p "$READER-crash"
drive '
  run_id = SecureRandom.uuid
  store = Fixture.store(run_id)
  store.open!
  path = Fixture.run_path(ARGV[0], run_id)
  name = File.basename(path)
  store.event_log.emit(path, run_id: run_id, session: Fixture::SESSION, payload: {"e" => "run_start", "ticket" => "DEMO-1", "entry" => "ticket"})
  coordinator = store.coordinator(execution_path: path, session: Fixture::SESSION)
  attempt = lambda do |failing, &block|
    ENV["FAKE_TEMPER_FAIL"] = failing
    block.call
  rescue PrGraph::Store::Error
    nil
  ensure
    ENV.delete("FAKE_TEMPER_FAIL")
  end
  attempt.("--kind giraffe-run-event-log --intent") { coordinator.start("TRIAGE") }
  triage = coordinator.start("TRIAGE").fetch("attempt_id")
  meta = Fixture.meta("triage_brief", "TRIAGE", triage)
  attempt.("--kind giraffe-run-artifact-log --intent") { coordinator.put_artifact(meta, JSON.generate(Fixture::BRIEF)) }
  Fixture.store(run_id).hydrate(File.join(ARGV[1], name))
  crashed = Fixture.snapshot(File.join(ARGV[1], name))
  coordinator.put_artifact(meta, JSON.generate(Fixture::BRIEF))
  coordinator.complete("TRIAGE", triage, findings: 0)
  Fixture.store(run_id).hydrate(File.join(ARGV[2], name))
  rerun = Fixture.snapshot(File.join(ARGV[2], name))
  orphan = Fixture.stored("giraffe-run-triage-brief").first["content"]["record"]["artifact_id"]
  puts JSON.generate(
    "name" => name, "stored_evidence" => Fixture.stored("giraffe-run-triage-brief").length, "stored_manifests" => Fixture.stored("giraffe-run-manifest").length,
    "crashed_artifacts" => crashed["artifacts"].length, "crashed_blobs" => crashed["blobs"].length, "crashed_manifests" => crashed["manifests"].keys.map { |file| file.split(".")[1] },
    "rerun_artifacts" => rerun["artifacts"].map { |row| row["artifact_id"] }.include?(orphan), "rerun_blobs" => rerun["blobs"].values,
    "rerun_manifests" => rerun["manifests"].keys.map { |file| file.split(".")[1] }.sort, "rerun_artifact_count" => rerun["artifacts"].length
  )
' "$WRITER" "$READER" "$READER-crash" > "$OUT" || fail "a crashed step should still hydrate"
check 'doc["stored_evidence"] == 2 && doc["stored_manifests"] == 3' "the store should hold the orphaned evidence and the orphaned lease" < "$OUT"
check 'doc["crashed_artifacts"] == 0 && doc["crashed_blobs"] == 0 && doc["crashed_manifests"] == ["lease"]' \
  "hydrate should drop the evidence no record names and the lease no event names" < "$OUT"
ruby "$COORDINATE" check-run "$READER/$(ruby -r json -e 'puts JSON.parse($stdin.read)["name"]' < "$OUT")" --offline \
  | check 'doc["open_attempts"].map { |attempt| attempt["node"] } == ["TRIAGE"]' "the crashed step should still be open to run again"
check 'doc["rerun_artifact_count"] == 1 && !doc["rerun_artifacts"] && doc["rerun_blobs"].length == 1 && doc["rerun_manifests"] == ["lease", "result"]' \
  "after the rerun, hydrate should return only the evidence and manifests its transitions name" < "$OUT"
ok "ignores evidence and manifests that no record names, so a rerun reads back alone"

# Each kind of write the store makes, carrying a secret or too much, fails before any Temper call.
reset
drive '
  run_id = SecureRandom.uuid
  store = Fixture.store(run_id)
  store.open!
  path = Fixture.run_path(ARGV[0], run_id)
  stem = path.delete_suffix(".jsonl")
  session = Fixture::SESSION
  events = store.event_log
  events.emit(path, run_id: run_id, session: session, payload: {"e" => "run_start", "ticket" => "DEMO-1", "entry" => "ticket"})
  verify = SecureRandom.uuid
  worktree = SecureRandom.uuid
  [["VERIFY", verify], ["WORKTREE", worktree]].each do |node, id|
    events.emit(path, run_id: run_id, session: session, payload: {"e" => "node", "node" => node, "phase" => "start", "attempt_id" => id, "iteration" => 1})
  end
  held = store.artifact_log.store("#{stem}.artifacts.jsonl", execution_path: path, run_id: run_id, session: session,
                                  metadata: Fixture.meta("worktree_manifest", "WORKTREE", worktree).merge("content_type" => "text/plain"), content: "ok").fetch("artifact_id")
  sizes = -> { [path, "#{stem}.artifacts.jsonl", "#{stem}.failures.jsonl"].map { |file| File.file?(file) ? File.size(file) : 0 } + [Dir.glob("#{stem}.artifacts/*").length] }
  writers = {
    "transition" => ->(text) { events.emit_many(path, run_id: run_id, session: session, payloads: [{"e" => "edge", "from" => "VERIFY", "to" => "BUILD", "from_attempt_id" => verify, "reason" => text}]) },
    "artifact" => ->(text) { store.artifact_log.store("#{stem}.artifacts.jsonl", execution_path: path, run_id: run_id, session: session, metadata: Fixture.meta("worktree_manifest", "WORKTREE", worktree).merge("content_type" => "text/plain"), content: text) },
    "failure" => ->(text) { store.failure_log.record("#{stem}.failures.jsonl", execution_path: path, run_id: run_id, session: session, finding: {"failure_id" => "f:#{SecureRandom.hex(3)}", "source_node" => "WORKTREE", "source_attempt_id" => worktree, "candidate_sha" => Fixture::SHA, "revision" => "r1", "reason" => text, "artifact_ids" => [held]}) }
  }
  payloads = {
    "clean" => "the worktree check is red",
    "token" => "build log:\nghp_#{"a" * 36}",
    "key" => "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA#{"k" * 40}\n-----END RSA PRIVATE KEY-----",
    "oversize" => "x" * 1_100_000
  }
  results = writers.flat_map do |writer, write|
    payloads.map do |label, text|
      before = sizes.call
      calls = Fixture.commit_kinds.length
      error = begin
        write.call(text)
        nil
      rescue PrGraph::Store::Error => e
        e.message
      end
      {"writer" => writer, "payload" => label, "error" => error, "calls" => Fixture.commit_kinds.length - calls, "local_unchanged" => sizes.call == before}
    end
  end
  stored = File.read(Fixture::CONTEXT_FILE)
  puts JSON.generate("results" => results, "leaked" => ["ghp_aaaa", "MIIEowIBAAKCAQEA", "xxxxxxxxxx"].any? { |marker| stored.include?(marker) })
' "$WRITER" > "$OUT" || fail "refused writes should raise an error, not crash the writer"
check 'doc["results"].length == 12 && doc["results"].select { |r| r["payload"] == "clean" }.all? { |r| r["error"].nil? && r["calls"] > 0 && !r["local_unchanged"] }' \
  "a clean write of each kind should be accepted" < "$OUT"
check 'doc["results"].reject { |r| r["payload"] == "clean" }.all? { |r| r["error"] && r["calls"] == 0 && r["local_unchanged"] }' \
  "a secret or oversize write of each kind should raise before any Temper call and append nothing locally" < "$OUT"
check 'doc["results"].select { |r| %w[token key].include?(r["payload"]) }.all? { |r| r["error"].include?("secret pattern") && !r["error"].include?("ghp_") && !r["error"].include?("PRIVATE KEY") } &&
       doc["results"].select { |r| r["payload"] == "oversize" }.all? { |r| r["error"].include?("larger than 1 MB") && r["error"].length < 300 }' \
  "each refusal should name its reason without repeating the payload" < "$OUT"
check '!doc["leaked"]' "no payload should reach the store" < "$OUT"
ok "refuses a secret or oversize write of any kind before it reaches Temper"

reset
drive '
  run_id = SecureRandom.uuid
  store = Fixture.store(run_id)
  store.open!
  path = Fixture.run_path(ARGV[0], run_id)
  ENV["FAKE_TEMPER_FAIL"] = "data-artifact commit"
  File.write(Fixture::CALLS, "")
  error = begin
    store.event_log.emit(path, run_id: run_id, session: Fixture::SESSION, payload: {"e" => "run_start", "ticket" => "DEMO-1", "entry" => "ticket"})
    nil
  rescue PrGraph::Store::Error => e
    e.message
  end
  puts JSON.generate("error" => error, "attempts" => Fixture.commit_kinds.length, "local" => File.exist?(path))
' "$WRITER" > "$OUT" || fail "an unreachable store should raise an error, not crash the writer"
check 'doc["attempts"] == 3 && doc["error"].to_s.include?("API error: unavailable")' "a failing write should be tried once and again after each backoff delay, then fail with the store's reason" < "$OUT"
check '!doc["local"]' "a write the store never accepted should leave the local log unchanged" < "$OUT"
ok "fails a write after the backoff runs out and appends nothing locally"

reset
drive '
  run_id = SecureRandom.uuid
  Fixture.store(run_id).open!
  shapes_declared = Fixture.calls("data-artifact schema declare")
  second = Fixture.store(run_id).open!
  second.event_log.emit(Fixture.run_path(ARGV[0], run_id), run_id: run_id, session: Fixture::SESSION,
                        payload: {"e" => "run_start", "ticket" => "DEMO-1", "entry" => "ticket"})
  redeclared = Fixture.calls("data-artifact schema declare") - shapes_declared
  data = Fixture.data
  kind = "giraffe-run-event-log"
  data["shapes"][kind]["schema"]["title"] = "declared from an older contract"
  File.write(Fixture::CONTEXT_FILE, JSON.generate(data))
  shapes_declared = Fixture.calls("data-artifact schema declare")
  Fixture.store(run_id).open!
  changed = Fixture.data["shapes"]
  puts JSON.generate(
    "resources" => data["rows"].map { |row| row["id"] }, "creates" => Fixture.calls("resource create"),
    "written_to" => Fixture.stored.map { |row| row["resource"] }.uniq,
    "enforcement" => data["shapes"].values.map { |shape| shape["enforcement"] }.uniq, "redeclared" => redeclared,
    "redeclared_changed" => Fixture.calls("data-artifact schema declare") - shapes_declared, "version" => changed[kind]["version"],
    "current" => changed[kind]["schema"] == PrGraph::Shapes.build.fetch(kind) && changed[kind]["enforcement"] == "enforcing"
  )
' "$WRITER" > "$OUT" || fail "a run should open twice"
check 'doc["resources"].length == 1 && doc["creates"] == 1' "opening a run twice should leave one resource, not create a second" < "$OUT"
check 'doc["written_to"] == doc["resources"]' "a second store for the run should write to the resource the first created" < "$OUT"
check 'doc["enforcement"] == ["enforcing"] && doc["redeclared"] == 0' \
  "every kind should be declared enforcing once and not declared again on reopen" < "$OUT"
check 'doc["redeclared_changed"] == 1 && doc["version"] == 2 && doc["current"]' \
  "a kind whose declared shape differs from the one built should be declared again, and only that kind" < "$OUT"
ok "opens a run's resource and declares its shapes once, again when a shape changed"

# A transition that names an artifact must name one the store holds: one whose write was refused is not,
# and neither is one the local log has but Temper does not.
reset
drive '
  run_id = SecureRandom.uuid
  store = Fixture.store(run_id)
  store.open!
  path = Fixture.run_path(ARGV[0], run_id)
  stem = path.delete_suffix(".jsonl")
  artifacts_path = "#{stem}.artifacts.jsonl"
  session = Fixture::SESSION
  worktree = SecureRandom.uuid
  store.event_log.emit(path, run_id: run_id, session: session, payload: {"e" => "run_start", "ticket" => "DEMO-1", "entry" => "ticket"})
  store.event_log.emit(path, run_id: run_id, session: session,
                       payload: {"e" => "node", "node" => "WORKTREE", "phase" => "start", "attempt_id" => worktree, "iteration" => 1})
  meta = Fixture.meta("worktree_manifest", "WORKTREE", worktree).merge("content_type" => "text/plain")
  held = store.artifact_log.store(artifacts_path, execution_path: path, run_id: run_id, session: session, metadata: meta, content: "ok").fetch("artifact_id")
  refused = SecureRandom.uuid
  uuid = SecureRandom.method(:uuid)
  SecureRandom.define_singleton_method(:uuid) { refused }
  begin
    store.artifact_log.store(artifacts_path, execution_path: path, run_id: run_id, session: session, metadata: meta, content: "ghp_#{"a" * 36}")
  rescue PrGraph::Store::Error
    nil
  ensure
    SecureRandom.define_singleton_method(:uuid, &uuid)
  end
  unheld = PrGraph::ArtifactLog.new.store(artifacts_path, execution_path: path, run_id: run_id, session: session, metadata: meta, content: "local only").fetch("artifact_id")
  finding = lambda do |id|
    {"failure_id" => "f:#{id[0, 6]}", "source_node" => "WORKTREE", "source_attempt_id" => worktree, "candidate_sha" => Fixture::SHA,
     "revision" => "r1", "reason" => "worktree check red", "artifact_ids" => [id]}
  end
  link = ->(id) { {"e" => "link", "link_id" => SecureRandom.uuid, "relation" => "invalidates", "from_artifact_id" => held, "to_artifact_id" => id, "reason" => "stale"} }
  sizes = -> { [path, artifacts_path, "#{stem}.failures.jsonl"].map { |file| File.file?(file) ? File.size(file) : 0 } }
  before = [sizes.call, Fixture.commit_kinds.length]
  tries = {
    "finding_refused" => -> { store.failure_log.record("#{stem}.failures.jsonl", execution_path: path, run_id: run_id, session: session, finding: finding.(refused)) },
    "finding_unheld" => -> { store.failure_log.record("#{stem}.failures.jsonl", execution_path: path, run_id: run_id, session: session, finding: finding.(unheld)) },
    "link_refused" => -> { store.artifact_log.emit_many(artifacts_path, execution_path: path, run_id: run_id, session: session, payloads: [link.(refused)]) },
    "link_unheld" => -> { store.artifact_log.emit_many(artifacts_path, execution_path: path, run_id: run_id, session: session, payloads: [link.(unheld)]) }
  }
  errors = tries.transform_values do |attempt|
    attempt.call
    nil
  rescue StandardError => e
    {"class" => e.class.name, "message" => e.message}
  end
  stored = File.read(Fixture::CONTEXT_FILE)
  puts JSON.generate("errors" => errors, "refused" => refused, "unheld" => unheld, "unchanged" => before == [sizes.call, Fixture.commit_kinds.length],
                     "traced" => [refused, unheld].any? { |id| stored.include?(id) })
' "$WRITER" > "$OUT" || fail "a transition naming an artifact the store lacks should fail with an error"
check 'doc["errors"].values.none?(&:nil?)' "a finding or link naming a refused or unheld artifact should be refused" < "$OUT"
check 'doc["errors"].values_at("finding_refused", "finding_unheld", "link_unheld").all? { |e| e["class"] == "PrGraph::Store::Error" } &&
       doc["errors"]["finding_refused"]["message"].include?(doc["refused"]) && doc["errors"]["link_unheld"]["message"].include?(doc["unheld"])' \
  "a transition naming an artifact the store does not hold should raise a store error naming it" < "$OUT"
check 'doc["unchanged"] && !doc["traced"]' "a refused transition should write nothing, and the store should hold no trace of either artifact" < "$OUT"
ok "refuses a transition that names an artifact the store does not hold"

# The finished-run record commits its own shape of event log into the same context a store has declared
# its kinds in.
reset
drive '
  Fixture.store(SecureRandom.uuid).open!
  run_id = SecureRandom.uuid
  path = Fixture.run_path(ARGV[0], run_id)
  PrGraph::EventLog.new.emit(path, run_id: run_id, session: Fixture::SESSION, payload: {"e" => "run_start", "ticket" => "DEMO-1", "entry" => "ticket"})
  puts JSON.generate("path" => path)
' "$WRITER" > "$OUT" || fail "a plain run should write"
RECORDED=$(ruby -r json -e 'puts JSON.parse($stdin.read)["path"]' < "$OUT")
ruby "$RECORD" --events "$RECORDED" --context "$CONTEXT" > "$OUT" || fail "the run record should run"
check 'doc["failed"].nil? && doc["committed"] == 1' "the run record should commit its event log into a context the store has declared its kinds in" < "$OUT"
ok "leaves the finished-run record's kinds alone"

echo "1..${tests}"

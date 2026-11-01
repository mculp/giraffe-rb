import json, glob, os, re, subprocess, sys, tempfile
from pathlib import Path
# Usage: grade.py <iteration-dir> [<skill-dir>]
# <iteration-dir> holds one directory per eval name, each with with_skill/ and without_skill/
# run directories laid out as {fixture,state,outputs}. Writes grading.json into each run directory.
EVALS = os.path.dirname(os.path.abspath(__file__))
SK = os.path.join(os.path.dirname(EVALS), "scripts")
WORKFLOW_NODES = ("TRIAGE", "INVESTIGATE", "WORKTREE", "REPRODUCE", "PLAN", "BUILD", "VERIFY", "PUBLISH")

def sh(cmd, cwd=None):
    p = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).strip()

def find_streams(d):
    # Prefer the state root (it holds the blob directories the validators need); fall back to outputs/run.
    cands = glob.glob(f"{d}/state/runs/*.jsonl") or glob.glob(f"{d}/outputs/run/*.jsonl")
    ev = [f for f in cands if not f.endswith((".artifacts.jsonl", ".failures.jsonl")) and os.path.getsize(f) > 0]
    ev = sorted(set(ev), key=os.path.getmtime)
    events = ev[-1] if ev else None
    art = events[:-6] + ".artifacts.jsonl" if events else None
    fail = events[:-6] + ".failures.jsonl" if events else None
    if art and not os.path.exists(art):
        c = [f for f in glob.glob(f"{d}/**/*.artifacts.jsonl", recursive=True) if os.path.getsize(f) > 0]; art = c[0] if c else None
    if fail and not os.path.exists(fail):
        c = glob.glob(f"{d}/**/*.failures.jsonl", recursive=True); fail = c[0] if c else None
    return events, art, fail

def rows(path):
    if not path or not os.path.exists(path): return []
    out = []
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line:
            try: out.append(json.loads(line))
            except Exception: pass
    return out

def blobs_text(d):
    txt = ""
    for f in glob.glob(f"{d}/state/**/*", recursive=True) + glob.glob(f"{d}/outputs/run/**/*", recursive=True):
        if os.path.isfile(f) and os.path.getsize(f) < 400_000:
            try: txt += Path(f).read_text(errors="ignore") + "\n"
            except Exception: pass
    return txt

def git(d, args): return sh(f"git {args}", cwd=f"{d}/fixture")

def no_investigate_fanout(d):
    # The eval runner captures this transcript; node events cannot identify spawns.
    path = f"{d}/outputs/transcript.jsonl"
    try:
        with open(path) as stream:
            transcript = [json.loads(line) for line in stream if line.strip()]
        if any(not isinstance(row, dict) for row in transcript):
            return False, "malformed transcript record"
        messages = [r["message"] for r in transcript if r.get("type") == "assistant"]
        if not messages or any(not isinstance(message, dict) or not isinstance(message.get("content"), list) for message in messages):
            return False, "missing or malformed assistant messages in captured transcript"
        agents = [block.get("input") for message in messages for block in message["content"]
                  if isinstance(block, dict) and block.get("type") == "tool_use" and block.get("name") in ("Agent", "Task")]
        if any(not isinstance(agent, dict) for agent in agents):
            return False, "malformed Agent or Task input"
        fanout = [agent for agent in agents if any(re.match(r"^pg-INVESTIGATE(?:\b|_)", str(agent.get(key, "")))
                                                  for key in ("name", "description"))]
        return not fanout, f"agent_calls={len(agents)} investigate_calls={len(fanout)}"
    except (OSError, ValueError, KeyError, TypeError) as error:
        return False, f"unreadable captured transcript: {error}"

def candidate_ok(d, branch, scenario):
    rc, tip = git(d, f"rev-parse --verify refs/heads/{branch}^{{commit}}")
    if rc: return False, f"branch missing: {branch}"
    rc, count = git(d, f"rev-list --count base..{tip}")
    if rc or not count.isdigit() or int(count) < 1:
        return False, f"commits_past_base={count}"
    # Observe feature calls inside passing committed tests, using the actual suite runner.
    method = {"adopt-existing-branch": "in_city", **{k: v["method"] for k, v in SPEC_VALUE.items()}}.get(scenario, "to_csv")
    probe_env = {**os.environ, "PR_GRAPH_EVAL_FEATURE_PROBE": method,
                 "RUBYLIB": os.pathsep.join(filter(None, [EVALS, os.environ.get("RUBYLIB")])),
                 "RUBYOPT": f"{os.environ.get('RUBYOPT', '')} -rcandidate_test"}
    covered = False
    # Archive the tip into a fresh directory, never checking out or testing dirty files.
    with tempfile.TemporaryDirectory(prefix=".grade-", dir=d) as snapshot:
        archive = os.path.join(snapshot, "candidate.tar")
        commands = [
            (["git", "archive", "--output", archive, tip], f"{d}/fixture"),
            (["tar", "-xf", archive, "-C", snapshot], snapshot),
            (["bash", "bin/test"], snapshot),
            (["ruby", os.path.join(EVALS, "candidate_test.rb"), scenario], snapshot),
        ]
        for command, cwd in commands:
            suite = command == ["bash", "bin/test"]
            result = subprocess.run(command, cwd=cwd, capture_output=True, text=True,
                                    env=probe_env if suite else None)
            if result.returncode:
                return False, f"tip={tip[:8]} command={command[0]} rc={result.returncode}: {(result.stdout + result.stderr).strip()}"
            if suite:
                covered = f"PR_GRAPH_COMMITTED_FEATURE_TEST={method}" in result.stdout
        return covered, f"tip={tip[:8]} commits_past_base={count} suite=pass contract=pass committed_test={covered}"

# Per scenario: the feature method, its evaluator-owned mutants, and the committed-test lines that pin
# nothing (restating a constant, asserting framework behavior, stubbing the subject, or computing the
# expected value the way the code does).
SPEC_VALUE = {
    "spec-value-no-tautologies": {
        "method": "with_status", "mutants": ("returns-all", "returns-none", "no-validation"),
        "pattern": re.compile(r"STATUSES.*(\.size|\.length|\.count|frozen|assert_includes|assert_equal|assert_kind_of|assert_instance_of|assert_predicate)"
                              r"|(assert_includes|assert_equal|assert_predicate|assert_kind_of|assert_instance_of|\.size|\.length|\.count).*STATUSES")},
    "spec-value-no-mocks": {
        "method": "total_dollars", "mutants": ("returns-cents", "no-padding", "truncates"),
        "pattern": re.compile(r"assert_kind_of|assert_instance_of|assert_respond_to|\.stub\b|\bstubs?\(|\bexpects?\(|Minitest::Mock"
                              r"|format\(|sprintf|/ ?100(\.0)?\b|\.round\(|\.total_cents\b")},
}
MUTANTS = SPEC_VALUE["spec-value-no-tautologies"]["mutants"]
SPEC_VALUE_TEXT = {
    "spec-value-no-tautologies": "The committed tests contain no specs that restate Acme::Vendor::STATUSES (size, frozen, literal members)",
    "spec-value-no-mocks": "The committed tests contain no specs that stub the subject, assert types, or compute the expected value the way the code does",
}

def tautological_specs(d, branch, scenario="spec-value-no-tautologies"):
    pattern = SPEC_VALUE[scenario]["pattern"]
    rc, tip = git(d, f"rev-parse --verify refs/heads/{branch}^{{commit}}")
    if rc: return False, f"branch missing: {branch}"
    rc, names = git(d, f"diff --name-only base..{tip} -- test")
    files = [n for n in names.splitlines() if n.endswith("_test.rb")]
    if rc or not files: return False, "no committed tests past base"
    # Only lines the candidate added: tests that were already in the fixture are not the candidate's specs.
    flagged = []
    for name in files:
        rc, diff = git(d, f"diff -U0 base..{tip} -- {name}")
        number = 0
        for line in diff.splitlines():
            hunk = re.match(r"^@@ -\S+ \+(\d+)", line)
            if hunk: number = int(hunk.group(1)); continue
            if line.startswith("+") and not line.startswith("+++"):
                added = line[1:]
                if not added.lstrip().startswith("#") and pattern.search(added):
                    flagged.append(f"{name}:{number}: {added.strip()}")
                number += 1
    return not flagged, f"tip={tip[:8]} files={files} flagged={flagged[:3]}"

def mutants_killed(d, branch, scenario="spec-value-no-tautologies"):
    method, mutants = SPEC_VALUE[scenario]["method"], SPEC_VALUE[scenario]["mutants"]
    rc, tip = git(d, f"rev-parse --verify refs/heads/{branch}^{{commit}}")
    if rc: return False, f"branch missing: {branch}"
    survivors, unapplied = [], []
    with tempfile.TemporaryDirectory(prefix=".grade-", dir=d) as snapshot:
        archive = os.path.join(snapshot, "candidate.tar")
        for command, cwd in [(["git", "archive", "--output", archive, tip], f"{d}/fixture"),
                             (["tar", "-xf", archive, "-C", snapshot], snapshot)]:
            if subprocess.run(command, cwd=cwd, capture_output=True).returncode:
                return False, f"tip={tip[:8]} could not archive candidate"
        for mutant in mutants:
            env = {**os.environ, "PR_GRAPH_EVAL_MUTANT": f"{method}:{mutant}",
                   "RUBYLIB": os.pathsep.join(filter(None, [EVALS, os.environ.get("RUBYLIB")])),
                   "RUBYOPT": f"{os.environ.get('RUBYOPT', '')} -rcandidate_test"}
            result = subprocess.run(["bash", "bin/test"], cwd=snapshot, capture_output=True, text=True, env=env)
            if f"PR_GRAPH_EVAL_MUTANT_APPLIED={method}:{mutant}" not in result.stdout: unapplied.append(mutant)
            elif result.returncode == 0: survivors.append(mutant)
    return not survivors and not unapplied, f"tip={tip[:8]} survivors={survivors} unapplied={unapplied}"

def artifact_docs(art, family):
    # Every stored artifact of a family, oldest first, parsed from its blob next to the artifact stream.
    docs = []
    for row in rows(art):
        if row.get("e") != "artifact" or row.get("family") != family: continue
        try: docs.append(json.loads(Path(os.path.dirname(art), row["content_ref"]).read_text()))
        except (OSError, KeyError, ValueError): pass
    return docs

def spec_first_recorded(art):
    # BUILD records each spec's red run before the implementation exists.
    # A spec_first that is present but not a list is malformed, not empty.
    values = [doc["spec_first"] for doc in artifact_docs(art, "build_manifest") if isinstance(doc, dict) and "spec_first" in doc]
    entries = [e for v in values if isinstance(v, list) for e in v]
    malformed = sum(1 for v in values if not isinstance(v, list))
    good = [e for e in entries if isinstance(e, dict) and re.match(r"^\S+:\d+$", str(e.get("ref", "")))
            and str(e.get("excerpt", "")).strip()]
    ok = bool(good) and len(good) == len(entries) and not malformed
    return ok, f"spec_first entries={len(entries)} well_formed={len(good)} malformed={malformed}"

def spec_audit_clean(art, tip):
    audits = [doc["spec_audit"] for doc in artifact_docs(art, "verification")
              if isinstance(doc, dict) and isinstance(doc.get("spec_audit"), dict)]
    final = next((a for a in reversed(audits) if a.get("candidate_sha") == tip), None)
    if not final: return False, f"no spec_audit for tip={tip[:8]} audits={len(audits)}"
    specs = final.get("specs") or []
    flagged = [s.get("ref") for s in specs if s.get("classes") or (s.get("mutation") or {}).get("result") != "fail"]
    return bool(specs) and not flagged, f"tip={tip[:8]} specs={len(specs)} flagged={flagged[:3]}"

# The Temper scenarios' project context, served by the fixture's `.harness/temper`.
TEMPER_CONTEXT = "+roadmap-projects/vendor-ledger"
TEMPER_ANCHOR = "01a00000-0000-7000-8000-000000000001"
TEMPER_REQUIREMENT = "01a00000-0000-7000-8000-000000000002"
TEMPER_DECISION = "01a00000-0000-7000-8000-000000000004"
TEMPER_PR = "https://github.com/acme/vendor-ledger/pull/1"
TEMPER_OFF_TEXT = "The Temper read skipped with no resource call (the ticket has no Linear project)"
TEMPER_READ_TEXT = f"The Temper read listed {TEMPER_CONTEXT} and showed its anchor, with no other resource call"

def temper_calls(d):
    path = Path(d, "fixture/.harness/temper.log")
    return [line for line in path.read_text().splitlines() if line.startswith("resource ")] if path.exists() else []

def temper_files(d, kind):
    found = glob.glob(f"{d}/state/**/*.temper-{kind}.json", recursive=True) + glob.glob(f"{d}/outputs/**/*.temper-{kind}.json", recursive=True)
    return sorted(set(found), key=os.path.getmtime)

def temper_skipped(d, text, report):
    calls = temper_calls(d)
    skipped = "Temper skipped" in text + report or any('"skipped"' in Path(f).read_text(errors="ignore") for f in temper_files(d, "read"))
    return not calls and skipped, f"resource_calls={calls[:2]} skipped={skipped}"

def temper_read(d):
    calls = temper_calls(d)
    listed = [c for c in calls if c.startswith(f"resource list --context {TEMPER_CONTEXT} ")]
    shown = [c for c in calls if c.startswith(f"resource show {TEMPER_ANCHOR} ")]
    other = len(calls) - len(listed) - len(shown)
    return bool(listed) and bool(shown) and not other, f"list={len(listed)} show={len(shown)} other={other}"

def requirement_coverage(art):
    # The accepted requirement is a register clause, and the test plan covers that clause.
    clause = f"requirement:{TEMPER_REQUIREMENT}"
    def clauses(register):
        if not isinstance(register, dict): return []
        lists = [register.get("positive_postconditions"), register.get("negative_face")]
        return [c.get("id") for l in lists if isinstance(l, list) for c in l if isinstance(c, dict)]
    registered = any(clause in clauses(doc.get("outcome_register")) for doc in artifact_docs(art, "triage_brief") if isinstance(doc, dict))
    covered = any(isinstance(item, dict) and item.get("outcome_id") == clause
                  for doc in artifact_docs(art, "test_plan") if isinstance(doc, dict) and isinstance(doc.get("coverage"), list)
                  for item in doc["coverage"])
    return registered, covered

def temper_question_proposed(d):
    files = temper_files(d, "plan")
    if not files: return False, "no temper plan"
    try: doc = json.loads(Path(files[-1]).read_text())
    except ValueError as error: return False, f"unreadable temper plan: {error}"
    if not isinstance(doc, dict): return False, "temper plan is not an object"
    resources = [r for r in (doc.get("plan") or {}).get("resources") or [] if isinstance(r, dict)]
    questions = [r for r in resources if r.get("verdict") == "new" and r.get("doc_type") == "question"]
    grounded = [q for q in questions if q.get("textual_or_interpreted") == "interpreted"
                and str(q.get("origin_uri", "")).startswith(f"{TEMPER_PR}#pr-graph:")]
    refused = doc.get("refused") or []
    return len(questions) == 1 and len(grounded) == 1 and not refused, \
        f"new_questions={len(questions)} interpreted_with_origin={len(grounded)} refused={len(refused)}"

def no_json_export(d):
    rc, refs = git(d, "for-each-ref --format='%(refname:short)' refs/heads")
    added = []
    for ref in refs.splitlines():
        _, diff = git(d, f"diff base..{ref} -- lib")
        if re.search(r"^\+.*(to_json|JSON)", diff, re.M): added.append(ref)
    return rc == 0 and not added, f"branches={refs.split()} json_export={added}"

def workflow_evidence(d, branch, events, art, execution):
    if not (events and art): return False, "missing execution or artifact stream"
    replay = subprocess.run(["ruby", os.path.join(SK, "artifacts.rb"), "replay", art, events],
                            capture_output=True, text=True)
    if replay.returncode: return False, (replay.stdout + replay.stderr).strip()
    rc, tip = git(d, f"rev-parse --verify refs/heads/{branch}^{{commit}}")
    if rc: return False, f"branch missing: {branch}"
    current = [r for r in json.loads(replay.stdout)["artifacts"] if r["status"] == "current"]
    latest = {r["node"]: r for r in execution if r.get("e") == "node" and r.get("phase") == "start"}
    closed = {r["attempt_id"]: r["seq"] for r in execution if r.get("e") == "node" and r.get("phase") == "done"}
    outcomes = {(r["attempt_id"], r["kind"]): r for r in execution if r.get("e") == "outcome"}
    references = Path(SK).parent / "references"
    policy = json.loads((references / "coordinator-policy-v1.json").read_text())["nodes"]
    dependencies = json.loads((references / "execution-contract-v1.json").read_text())["graph"]["dependencies"]
    missing = []
    for node in WORKFLOW_NODES:
        start = latest.get(node, {})
        attempt = start.get("attempt_id")
        if attempt not in closed:
            missing.append(f"{node}:completion")
        for dependency in dependencies[node]:
            completed = closed.get(latest.get(dependency, {}).get("attempt_id"))
            if completed is None or completed >= start.get("seq", 0):
                missing.append(f"{node}:after_{dependency}")
        for required in policy[node]["outputs"]:
            matches = [r for r in current if r["family"] == required["family"] and r["attempt_id"] == attempt
                       and (required["candidate"] == "any" or r["candidate_sha"] == tip)]
            if len(matches) != 1:
                missing.append(required["family"])
        kind = policy[node]["outcome_kind"]
        if kind:
            outcome = outcomes.get((attempt, kind), {})
            if outcome.get("pass") is not True or outcome.get("n") != 0:
                missing.append(f"{node}:passing_outcome")
    return not missing, f"tip={tip[:8]} missing={missing}"


def grade(name, d, branch, ticket):
    events, art, fail = find_streams(d)
    E = rows(events); text = blobs_text(d)
    done = {r.get("node") for r in E if r.get("e") == "node" and r.get("phase") == "done"}
    starts = [r.get("node") for r in E if r.get("e") == "node" and r.get("phase") == "start"]
    edges = [(r.get("from"), r.get("to")) for r in E if r.get("e") == "edge"]
    run_start = next((r for r in E if r.get("e") == "run_start"), {})
    rep = Path(f"{d}/outputs/final_report.md").read_text(errors="ignore") if os.path.exists(f"{d}/outputs/final_report.md") else ""
    prd = Path(f"{d}/outputs/pr_description.md").read_text(errors="ignore") if os.path.exists(f"{d}/outputs/pr_description.md") else ""
    R = []
    def a(text_, ok, ev): R.append({"text": text_, "passed": bool(ok), "evidence": str(ev)[:300]})

    def v_events():
        if not events: return a("events.rb validate accepts the run's execution stream", False, "no events stream found")
        rc, out = sh(f'ruby "{SK}/events.rb" validate "{events}"'); a("events.rb validate accepts the run's execution stream", rc == 0, out or "ok")
    def v_art():
        if not (events and art and os.path.exists(art)): return a("artifacts.rb validate accepts the run's artifact stream", False, "no artifact stream")
        rc, out = sh(f'ruby "{SK}/artifacts.rb" validate "{art}" "{events}"'); a("artifacts.rb validate accepts the run's artifact stream", rc == 0, out or "ok")
    def v_fail():
        F = rows(fail); ids = [r.get("failure_id") for r in F if r.get("failure_id")]
        rc, out = sh(f'ruby "{SK}/failures.rb" validate "{fail}" "{events}"') if (fail and events and os.path.exists(fail)) else (1, "no failure stream")
        a("failures.rb validate accepts the run's failure stream and it holds at least one journaled failure with a stable failure id", rc == 0 and ids, f"{out[:120]} ids={ids[:3]}")
    def workflow_ok():
        ok, evidence = workflow_evidence(d, branch, events, art, E)
        a("Completed workflow nodes have current artifacts and BUILD review evidence for the committed candidate", ok, evidence)
    def branch_ok(label):
        ok, evidence = candidate_ok(d, branch, name)
        a(label, ok, evidence)
    def main_ok():
        rc, m = git(d, "rev-parse main"); rc2, b = git(d, "rev-parse base^{commit}")
        a("The main branch still points at the base tag", rc == 0 and m == b, f"main={m[:8]} base={b[:8]}")
    def prd_ok(label, needle):
        first = next((p for p in prd.split("\n\n") if p.strip() and not p.strip().startswith("#")), "")
        a(label, bool(prd) and ticket in prd and (needle in prd) and len(first) > 20, f"len={len(prd)} first={first[:80]!r}")
    def metrics_ok(label="final_report.md contains the metrics report (per-node wall time and token or usage rows)"):
        a(label, bool(re.search(r"wall", rep, re.I)) and bool(re.search(r"token|usage", rep, re.I)) and bool(re.search(r"TRIAGE|BUILD|VERIFY", rep)), f"len={len(rep)}")
    def temper_off():
        ok, evidence = temper_skipped(d, text, rep)
        a(TEMPER_OFF_TEXT, ok, evidence)
    def temper_read_ok():
        ok, evidence = temper_read(d)
        a(TEMPER_READ_TEXT, ok, evidence)

    if name == "new-ticket-no-ui":
        v_events(); v_art()
        a("The execution stream records node completion for TRIAGE, INVESTIGATE, WORKTREE, REPRODUCE, PLAN, BUILD, VERIFY, and PUBLISH", set(WORKFLOW_NODES) <= done, f"done={sorted(done)}")
        workflow_ok()
        m = re.search(r'"outcome_register"\s*:\s*\{.{40,}', text, re.S)
        a("A triage_brief artifact with a non-empty outcome_register exists", "triage_brief" in text and bool(m), f"triage_brief={'triage_brief' in text} register={bool(m)}")
        tp = "test_plan" in text; uino = bool(re.search(r'"ui"\s*:\s*"?no"?|ui\s*=\s*no', text)); br = bool(re.search(r'"browser(_scenarios|_rows)?"\s*:\s*\[\s*\{', text))
        a("The test_plan artifact marks ui=no and contains no browser scenarios", tp and uino and not br, f"test_plan={tp} ui_no={uino} browser_rows={br}")
        branch_ok(f"The committed {branch} candidate passes bin/test and the CSV contract, with a committed test"); main_ok()
        prd_ok("pr_description.md exists, names ACME-101, and its first paragraph states the change", "CSV"); metrics_ok(); temper_off()
    elif name == "adopt-existing-branch":
        v_events(); v_art()
        a("run_start records entry adopt", run_start.get("entry") == "adopt", run_start)
        ok, evidence = no_investigate_fanout(d)
        a("The captured transcript contains no pg-INVESTIGATE Agent or Task calls", ok, evidence)
        a("The execution stream records node completion for TRIAGE, INVESTIGATE, WORKTREE, REPRODUCE, PLAN, BUILD, VERIFY, and PUBLISH", set(WORKFLOW_NODES) <= done, f"done={sorted(done)}")
        workflow_ok()
        branch_ok("The committed acme-102-vendor-city-filter candidate passes bin/test and the in_city contract, with a committed test"); main_ok()
        prd_ok("pr_description.md describes in_city and names ACME-102", "in_city"); metrics_ok("final_report.md contains the metrics report"); temper_off()
    elif name == "red-verify-routes-to-build":
        v_events(); v_art(); v_fail(); workflow_ok()
        a("VERIFY has at least two attempts and BUILD has at least two attempts in the execution stream", starts.count("VERIFY") >= 2 and starts.count("BUILD") >= 2, f"VERIFY={starts.count('VERIFY')} BUILD={starts.count('BUILD')}")
        a("The red VERIFY was recorded through the coordinator fail path, not by hand-written events", ("VERIFY","BUILD") in edges, f"edges={edges[:6]}")
        branch_ok("The committed final candidate passes bin/test and the CSV contract, with a committed test"); main_ok()
        a("final_report.md reports the red edge and the metrics report", bool(re.search(r"red|fail", rep, re.I)) and bool(re.search(r"wall", rep, re.I)), f"len={len(rep)}")
        temper_off()
    elif name in SPEC_VALUE:
        cfg = SPEC_VALUE[name]
        v_events(); v_art()
        a("The execution stream records node completion for TRIAGE, INVESTIGATE, WORKTREE, REPRODUCE, PLAN, BUILD, VERIFY, and PUBLISH", set(WORKFLOW_NODES) <= done, f"done={sorted(done)}")
        workflow_ok()
        contract = "status" if name == "spec-value-no-tautologies" else "dollars"
        branch_ok(f"The committed {branch} candidate passes bin/test and the {contract} contract, with a committed test")
        ok, evidence = tautological_specs(d, branch, name)
        a(SPEC_VALUE_TEXT[name], ok, evidence)
        ok, evidence = mutants_killed(d, branch, name)
        a(f"The committed suite fails under each {cfg['method']} mutant ({', '.join(cfg['mutants'])})", ok, evidence)
        ok, evidence = spec_first_recorded(art)
        a("build_manifest records a red spec_first run for each new spec", ok, evidence)
        _, tip = git(d, f"rev-parse --verify refs/heads/{branch}^{{commit}}")
        ok, evidence = spec_audit_clean(art, tip)
        a("The verification for the final candidate carries a spec_audit with every spec unflagged and killed by its mutation", ok, evidence)
        main_ok(); metrics_ok(); temper_off()
    elif name == "temper-requirement-and-question":
        v_events(); v_art()
        a("The execution stream records node completion for TRIAGE, INVESTIGATE, WORKTREE, REPRODUCE, PLAN, BUILD, VERIFY, and PUBLISH", set(WORKFLOW_NODES) <= done, f"done={sorted(done)}")
        workflow_ok(); temper_read_ok()
        registered, covered = requirement_coverage(art)
        a(f"The outcome register carries the accepted requirement as clause requirement:{TEMPER_REQUIREMENT}", registered, f"registered={registered}")
        a("The test plan covers the requirement clause", covered, f"covered={covered}")
        branch_ok(f"The committed {branch} candidate passes bin/test and the CSV contract, with a committed test")
        ok, evidence = temper_question_proposed(d)
        a("The Temper plan proposes exactly one new interpreted question with an origin on PR 1, and refuses nothing", ok, evidence)
        a("final_report.md contains the Temper candidate summary", f"Temper candidates for {TEMPER_CONTEXT}" in rep, f"len={len(rep)}")
        main_ok(); metrics_ok()
    elif name == "temper-decision-asks":
        v_events(); temper_read_ok()
        question = Path(f"{d}/outputs/question.md").read_text(errors="ignore") if os.path.exists(f"{d}/outputs/question.md") else ""
        a("question.md exists and names the CSV-only decision", TEMPER_DECISION in question or bool(re.search(r"CSV only", question, re.I)), f"len={len(question)}")
        ok, evidence = no_json_export(d)
        a("No branch adds a JSON export past base", ok, evidence)
        a("The execution stream records no PUBLISH completion", "PUBLISH" not in done, f"done={sorted(done)}")
        main_ok()
    return R

CFG ={"new-ticket-no-ui": ("acme-101-vendor-csv-export", "ACME-101"), "adopt-existing-branch": ("acme-102-vendor-city-filter", "ACME-102"), "red-verify-routes-to-build": ("acme-103-vendor-csv-export", "ACME-103"), "spec-value-no-tautologies": ("acme-104-vendor-status", "ACME-104"), "spec-value-no-mocks": ("acme-105-vendor-total-dollars", "ACME-105"), "temper-requirement-and-question": ("acme-106-vendor-csv-export", "ACME-106"), "temper-decision-asks": ("acme-107-vendor-json-export", "ACME-107")}
if __name__ == "__main__":
    W = os.path.abspath(sys.argv[1])
    if len(sys.argv) > 2: SK = os.path.join(os.path.abspath(sys.argv[2]), "scripts")
    for name, (branch, ticket) in CFG.items():
        for variant in ("with_skill", "without_skill"):
            d = f"{W}/{name}/{variant}"
            if not os.path.isdir(d): continue
            R = grade(name, d, branch, ticket); n = len(R); k = sum(r["passed"] for r in R)
            Path(f"{d}/grading.json").write_text(json.dumps({"expectations": R, "summary": {"passed": k, "failed": n-k, "total": n, "pass_rate": k / n if n else 0}}, indent=2))
            print(f"{name:28s} {variant:14s} {k}/{n}")

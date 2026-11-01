import importlib.util, json, os, re, subprocess, sys, tempfile
from pathlib import Path
# Usage: grade.py <iteration-dir>
# <iteration-dir> holds one directory per eval name, each with with_skill/ and without_skill/ run
# directories laid out as {fixture,outputs}. Writes grading.json into each run directory.
EVALS = os.path.dirname(os.path.abspath(__file__))
PR_GRAPH = os.path.dirname(os.path.dirname(EVALS))
SPEC_AUDIT = os.path.join(PR_GRAPH, "scripts", "spec_audit.rb")

# pr-graph's grader owns the fixtures, the acceptance contracts, and the mutants; load it under its own name.
_spec = importlib.util.spec_from_file_location("pr_graph_grade", os.path.join(PR_GRAPH, "evals", "grade.py"))
pg = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(pg)

# Eval name: (pr-graph scenario that shares its fixture and mutants, branch, contract name)
CFG = {
    "build-standalone-no-tautologies": ("spec-value-no-tautologies", "acme-104-vendor-status", "status"),
    "build-standalone-no-mocks": ("spec-value-no-mocks", "acme-105-vendor-total-dollars", "dollars"),
}
# Each lane and the model it is pinned to.
LANES = {"pg-BUILD": "sonnet", "pg-BUILD-review": "opus", "pg-BUILD-simplify": "sonnet", "pg-VERIFY-specs": "opus"}

def report(d):
    try: doc = json.loads(Path(f"{d}/outputs/build_report.json").read_text())
    except (OSError, ValueError) as error: return None, f"unreadable build_report.json: {error}"
    return (doc, "") if isinstance(doc, dict) else (None, "build_report.json is not an object")

def tip_and_base(d, branch):
    rc, tip = pg.git(d, f"rev-parse --verify refs/heads/{branch}^{{commit}}")
    if rc: return None, None
    _, base = pg.git(d, "rev-parse base^{commit}")
    return tip, base

def spec_first_covers_changed_tests(d, branch):
    doc, error = report(d)
    if doc is None: return False, error
    tip, base = tip_and_base(d, branch)
    if not tip: return False, f"branch missing: {branch}"
    _, names = pg.git(d, f"diff --name-only --diff-filter=AMR {base} {tip} -- test spec")
    changed = sorted(n for n in names.splitlines() if n.endswith(("_test.rb", "_spec.rb")))
    entries = doc.get("spec_first") if isinstance(doc.get("spec_first"), list) else []
    good = [e for e in entries if isinstance(e, dict) and re.match(r"^\S+:\d+$", str(e.get("ref", "")))
            and str(e.get("excerpt", "")).strip()]
    cited = {e["ref"].rsplit(":", 1)[0] for e in good}
    ok = bool(changed) and bool(good) and len(good) == len(entries) and set(changed) <= cited
    return ok, f"changed={changed} entries={len(entries)} well_formed={len(good)} cited={sorted(cited)}"

def spec_audit_accepted(d, branch):
    doc, error = report(d)
    if doc is None: return False, error
    tip, base = tip_and_base(d, branch)
    if not tip: return False, f"branch missing: {branch}"
    audit = doc.get("spec_audit")
    if not isinstance(audit, dict): return False, "build_report.json has no spec_audit object"
    if not audit.get("specs"): return False, "spec_audit lists no specs"
    with tempfile.NamedTemporaryFile("w", suffix=".json", dir=d, delete=False) as stream:
        json.dump(audit, stream)
    try:
        result = subprocess.run(["ruby", SPEC_AUDIT, "check", f"{d}/fixture", base, tip, stream.name],
                                capture_output=True, text=True)
    finally:
        os.unlink(stream.name)
    return result.returncode == 0, f"tip={tip[:8]} {(result.stdout + result.stderr).strip()[:200]}"

def spawns(d):
    # The eval runner captures this transcript; only Agent or Task calls name a lane. Returns (lane, model) per spawn.
    rows = [json.loads(line) for line in Path(f"{d}/outputs/transcript.jsonl").read_text().splitlines() if line.strip()]
    inputs = [block["input"] for row in rows if isinstance(row, dict) and row.get("type") == "assistant"
              for block in (row.get("message") or {}).get("content") or [] if isinstance(block, dict)
              and block.get("type") == "tool_use" and block.get("name") in ("Agent", "Task") and isinstance(block.get("input"), dict)]
    found = []
    for spawn in inputs:
        label = f'{spawn.get("description", "")} {spawn.get("name", "")}'
        # Longest lane first, so pg-BUILD-review is not read as pg-BUILD.
        lane = next((lane for lane in sorted(LANES, key=len, reverse=True)
                     if re.search(rf"(^|\s){re.escape(lane)}(?![\w-])", label)), None)
        if lane: found.append((lane, str(spawn.get("model") or "")))
    return found

def lanes_spawned(d):
    try: found = spawns(d)
    except (OSError, ValueError) as error: return False, f"unreadable captured transcript: {error}"
    missing = [lane for lane in LANES if lane not in {lane for lane, _ in found}]
    return not missing, f"spawns={len(found)} missing={missing}"

def lanes_pinned(d):
    try: found = spawns(d)
    except (OSError, ValueError) as error: return False, f"unreadable captured transcript: {error}"
    wrong = [f"{lane}={model or 'unpinned'}" for lane, model in found if LANES[lane] not in model]
    return bool(found) and not wrong, f"spawns={len(found)} wrong={wrong}"

def no_graph_run(d):
    streams = [str(p) for p in Path(d).rglob("*.jsonl") if p.name != "transcript.jsonl"]
    return not streams, f"jsonl_streams={streams[:3]}"

def grade(name, d):
    scenario, branch, contract = CFG[name]
    R = []
    def a(text, result): R.append({"text": text, "passed": bool(result[0]), "evidence": str(result[1])[:300]})
    a(f"The committed {branch} candidate passes bin/test and the {contract} contract, with a committed test",
      pg.candidate_ok(d, branch, scenario))
    a(pg.SPEC_VALUE_TEXT[scenario], pg.tautological_specs(d, branch, scenario))
    cfg = pg.SPEC_VALUE[scenario]
    a(f"The committed suite fails under each {cfg['method']} mutant ({', '.join(cfg['mutants'])})",
      pg.mutants_killed(d, branch, scenario))
    a("build_report.json records a well-formed red spec_first run citing every changed test file",
      spec_first_covers_changed_tests(d, branch))
    a("build_report.json carries a spec_audit of the final candidate against the base that spec_audit.rb check accepts",
      spec_audit_accepted(d, branch))
    a("The transcript spawns the pg-BUILD writer and the pg-BUILD-review, pg-BUILD-simplify, and pg-VERIFY-specs lanes",
      lanes_spawned(d))
    a("Every lane spawn pins its model: pg-BUILD and pg-BUILD-simplify on sonnet, pg-BUILD-review and pg-VERIFY-specs on opus",
      lanes_pinned(d))
    a("No pr-graph run was started (no execution, artifact, or failure stream)", no_graph_run(d))
    rc, main = pg.git(d, "rev-parse main"); _, base = pg.git(d, "rev-parse base^{commit}")
    a("The main branch still points at the base tag", (rc == 0 and main == base, f"main={main[:8]} base={base[:8]}"))
    return R

if __name__ == "__main__":
    W = os.path.abspath(sys.argv[1])
    for name in CFG:
        for variant in ("with_skill", "without_skill"):
            d = f"{W}/{name}/{variant}"
            if not os.path.isdir(d): continue
            R = grade(name, d); n = len(R); k = sum(r["passed"] for r in R)
            Path(f"{d}/grading.json").write_text(json.dumps({"expectations": R, "summary": {"passed": k, "failed": n-k, "total": n, "pass_rate": k / n if n else 0}}, indent=2))
            print(f"{name:34s} {variant:14s} {k}/{n}")

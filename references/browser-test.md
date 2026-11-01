# Browser testing

Execute real browser automation against the test-plan scenarios; writing "testing
instructions" is not testing. Run each scenario in its own subagent and report results back.

## Tooling: agent-browser first, Playwright as fallback

Prefer the `agent-browser` CLI (invoke the `agent-browser` skill first for the workflow):
snapshot-and-ref loop, much faster and cheaper than the Playwright MCP. Each scenario subagent
sets its own named session (`agent-browser session id`) so parallel scenarios don't share a
browser. Fall back to the Playwright MCP when `agent-browser` is not installed
(`command -v agent-browser`), when it fails on the page after one retry, or when the scenario
needs a capability it lacks. Falling back is normal, not a failure; note which tool ran.

The scenarios come from the pr-graph PLAN node (the plan posted to the Linear ticket, or the
conversation). Track them in this shape:

| # | Scenario | URL | Login As | Steps | Expected |

Pre-flight: confirm the target responds (see references/review-app.md for deploy status, VPN,
sleeping apps, and the login flow). Locally, confirm the server is up and no
migrations are pending.

## Survey the surfaces BEFORE writing scenarios

Enumerate what the feature actually renders, then write the scenarios. Grep `app/admin`,
`app/views`, and the routes for the models under test.

If nothing renders them: set `ui=no`. Do not write browser scenarios. Do not add the
`review-app` label. Prove the outcome in VERIFY (specs) or VALIDATE (replay, scoring,
telemetry). An indirect observable is not a reason to keep a browser row.

If something renders: set `ui=yes`. Write browser scenarios only for those surfaces.
State per scenario what the instrument cannot see plus what inference stands in for it.

Scenarios written first and surveyed second come out unexecutable, and the rewrite costs
more than the survey.

## Prove the instrument is reading the thing under test

Equal outputs are ambiguous: a read path that works and a read path that silently fell back to
the old source both produce "identical". Perturb the persisted state (doctor one stored row to a
value that cannot occur naturally) and require the observable to follow it, then flip the gate and
require it to stop following. Without that probe, a green parity result is not evidence. Restore
the row afterwards and say in the report that the probe ran.

## Environment access is a pre-flight gate

Check that automation can actually reach the target before authoring env-specific scenarios,
because access failures surface after the plan is written otherwise. A staging host
behind Cloudflare's managed challenge is the known-hard case, and the ladder is:

1. agent-browser's bundled Chromium never clears Cloudflare's managed challenge there, headless
   or headed. Waiting longer does not help; a human clicking in that window does not either.
2. Real Chrome launched with `--remote-debugging-port=9222` and a separate `--user-data-dir` does
   clear Cloudflare. Attach with `agent-browser --cdp 9222`.
3. That fresh profile then stops at Okta device trust ("Waiting for the Kolide Agent"), which
   wants the user's own browser profile. Getting past it means relaunching the user's real Chrome
   with the debug port, which requires their approval since it closes their browser.

If the ladder stalls, offer local as the alternative in the same breath, and say what local
cannot prove (a real ERP or third-party round trip, anything that needs a connected external
flow). Local plus a named blind spot beats a blocked run.

## Shared environments: record and restore

On staging or any shared target, snapshot the feature-flag baseline before touching it and
restore it at the end. Use the durable seed manifest from `references/seed.md` as the list of
every record created or mutated and every previous value. Reconcile each pending cleanup action
after the scenarios; unresolved residuals block REVIEW-APP completion. State which stimuli came
from a console rather than the UI, so a reader knows which assertions are browser-observed and
which are not.

## On failure: fix and retry

1. Diagnose: browser snapshot, console messages, network requests.
2. Classify: code bug, missing data, or wrong selector.
3. Fix: code bug means edit + commit + push + wait for redeploy, then retry. Missing data
   means seed it, then retry. Selector means re-snapshot and retry with the right ref.
4. Same scenario failing 3 times: record as FAILED with diagnostics and move on.

Passing tests are the goal, not passing reports.

## Recording results

Report scenario results (pass/fail, notes, target tested) to the user in chat. Never post
them as PR comments. Bugs found route back to the BUILD node with a repro note.

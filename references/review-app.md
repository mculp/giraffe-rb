# Review app environment

Fill in this page for your app. The run reads it before deploy, seed, and browser-test.

URL: `https://<app>-pr-<pr-number>.<review-domain>`. Requires the `review-app` label on the PR, and
any network access the host needs (a VPN, for example; a connection timeout usually means it is off).

## Deploy monitoring

Deploys run on a CI pipeline of their own (`<org>/review-app-deploy`), separate from the PR's test
pipeline. Note how long a first deploy and a later push take. With the Buildkite MCP:
`list_builds` filtered by pipeline + branch, then `wait_for_build`. Report the build URL.
Fallback: `gh pr checks` or curl the app URL.

If idle review apps sleep, note the status code they return and how to wake one (an empty commit
and a redeploy, for example). After pushing any fix, wait for the redeploy before retrying browser
tests.

## Feature flags

If the app has a flag admin UI (Flipper's is `/admin/flipper`), give its URL and login here. Reach
for it BEFORE a seed runner: toggling a flag in the UI takes seconds, while a runner boots the whole
app. Use the runner only when seeding needs actual records, and then use the approved wrapper in
`seed.md`; never invoke an ad hoc seed command directly.

## Login

Describe how a test user signs in (a developer login button, for example) and list the seeded roles.

| Feature area | Login as |
|---|---|
| `<routes or area>` | `<seeded user>` (try first) |
| Admin routes | `<admin user>` |

On Access Denied, escalate to the more specialized role rather than debugging authorization.

## Baseline data

List what every review app is seeded with, so a run checks what exists before creating data.

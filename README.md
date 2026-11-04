# giraffe

Giraffe takes a change from a Linear ticket to a reviewed draft PR. A Ruby harness owns the run. It
runs every required step as code and calls a model only for judgment or for writing code, each call
with a fresh context, a fixed tool list, and a validated output schema. Temper is the run store.

- Design: [docs/harness.md](docs/harness.md)
- Knowledge tiers: [docs/knowledge.md](docs/knowledge.md)

## Status

The first executable harness runs through a reviewed draft PR with local journals, live Temper
mirroring, fresh Claude calls, executable verification, and resumable questions. CI/bot/deployment
and cloud/program automation remain separate follow-up stages. A draft PR does not mean DONE.

- [Run it](docs/running.md): configuration, commands, storage, and current limits
- [Live graph API](docs/graph-api.md): snapshots/events for a future frontend and editing boundary

## Install

Giraffe is the `giraffe-rb` gem, because `giraffe` on RubyGems is another project. Everything
inside is `Giraffe`, and the command is `giraffe`. It isn't published yet, so install it from git:

```ruby
gem "giraffe-rb", git: "https://github.com/mculp/giraffe-rb"
```

`require "giraffe"` and `require "giraffe/rb"` both load it. It needs Ruby 3.4 and no other gems;
the SQLite backend also needs `sqlite3` ([docs/running.md](docs/running.md)).

## Layout

| Path | Holds |
| --- | --- |
| `bin/giraffe`, `lib/giraffe/`, `giraffe-rb.gemspec` | Controller, harness, runners, local store, live Temper sync, and graph read model |
| `prompts/`, `schemas/` | Fresh-context role instructions and validated model outputs |
| `scripts/` | The coordinator, contract, CI, feedback, seed, metrics, run record, and Temper scripts |
| `references/` | The v1 contracts, the coordinator policy, the automated feedback authors, and their docs |
| `tests/` | A shell test per script |
| `evals/` | The graph eval suite with its fixtures and fake Temper, and the build suite in `evals/build/` |
| `docs/` | The harness design, run records, Temper grounding, and knowledge tiers |

The design's Repository section covers where the harness, runners, and store go.

## Tests

Needs Ruby 3.4, Python 3, and git.

```sh
bin/test
```

The tests use temporary directories and fakes for `gh` and Temper, so they reach no real run
state, GitHub, or Temper. One test draws a fixture in real Chrome and skips where there is none, and
the sandbox's test skips off macOS. CI (`.github/workflows/test.yml`) runs `bin/test` on every PR
and every push to `main`.

New tests should catch failures that lose work, publish unverified changes, corrupt evidence, or
break recovery. Prefer observable outcomes with real temporary Git repositories and executable
checks. Avoid coverage targets and assertions about private methods, incidental JSON formatting,
or exact tool ordering. Scripted tests verify harness behavior; model quality and effective provider
permissions require live probes.

## Design limits

The [sandi](https://github.com/mculp/sandi) gem holds the Ruby to Sandi Metz's rules: at most 100
lines to a class, 5 to a method, 4 parameters, and one constant that an entry point calls methods on.
The code does not meet them yet, so `.sandi-baseline.json` records each file's count and
`bundle exec sandi` exits 1 when a count rises or a file the baseline lacks has an offense. Its
first line is the progress to quote in a PR, and it names the files that improved. The `Gemfile`
pins sandi to a commit and RuboCop to the version the baseline was counted with, so run
`bundle install` first; `bin/test` does not need either, so CI runs `bundle exec sandi` as its own
step. A PR does not have to touch the baseline, which keeps parallel PRs from conflicting. Tighten
it after merges with `bundle exec sandi --update`, which refuses to raise a count without
`--allow-increase`.

## Credentials

Never commit secrets. Giraffe reads credentials only from the environment: the engineer's Claude
Code, `gh`, and Temper logins locally, and the cloud agent's secrets in a VM. `.gitignore` keeps
`.env` files and keys out of git.

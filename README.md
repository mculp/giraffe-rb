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

## Layout

| Path | Holds |
| --- | --- |
| `bin/giraffe`, `lib/giraffe/` | Controller, harness, runners, local store, live Temper sync, and graph read model |
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
state, GitHub, or Temper. CI (`.github/workflows/test.yml`) runs `bin/test` on every PR and every
push to `main`.

## Credentials

Never commit secrets. Giraffe reads credentials only from the environment: the engineer's Claude
Code, `gh`, and Temper logins locally, and the cloud agent's secrets in a VM. `.gitignore` keeps
`.env` files and keys out of git.

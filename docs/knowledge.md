# Knowledge: what giraffe keeps for a person, a team, and itself

Status: design. Rollout step 8 in `docs/harness.md`.

## Problem

A run learns things that outlive it. The store has two places for them, the run record and the
project context behind the human gate (`docs/temper-grounding.md`), and neither fits most of what a
run learns:

- **Code facts.** That one calculator rounds per line, or that a spec helper needs a seeded
  company, belongs to the team that owns the code. `team-knowledge` keeps these in
  `+<team>/knowledge` and recalls them in interactive sessions through hooks. Model calls run with
  no plugins (`--setting-sources ""`), so inside a run those hooks never fire. A run neither reads
  the team's notes nor adds to them.
- **Preferences.** How the person who started the run words a PR, or which declined findings they
  always want fixed, lives in their own `CLAUDE.md` and memory files. No model call sees them, and a
  Cursor VM does not have them.
- **Process lessons.** A step whose inputs missed something, or a schema that forced a bad answer,
  shows up in run records, and nothing reads it back.

## Decision

1. Giraffe keeps knowledge in four tiers. Each is a Temper context with one owner: personal, team,
   project, and meta.
2. Harness code makes every knowledge read and write. Model calls get knowledge as input blocks
   and propose new knowledge in their output. No call gets a Temper tool (harness Decision 4).
3. The team tier is `team-knowledge`'s store, in its format. Giraffe does not load the plugin. It
   treats the plugin's README and skill as the contract: context naming, the `memory` format, the
   tags, and the record bar. A memory a run saves is one the plugin recalls in a teammate's
   session, and the reverse.
4. Personal and team memories that clear the bar are saved without a gate, as `team-knowledge`
   saves them. The DONE report lists each one with its ref so a person can edit or delete it.
   Project candidates keep the human gate. Meta notes are saved every run and change what runs do
   only through a pull request to this repo.

## Tiers

| Tier | Holds | Context | Read by | Written |
| --- | --- | --- | --- | --- |
| Personal | The starting person's standing preferences for runs | Their Temper memory context, tag `scope:giraffe` | PLAN, PUBLISH, DESC-SYNC, and BOT-FEEDBACK's draft replies | At DONE, from an answer or a decline reason the person gave; `bin/giraffe remember --personal` |
| Team | Non-obvious, durable facts about the team's code and domain, and its conventions (`scope:team`) | `+<temper.team>/knowledge` | INVESTIGATE's codebase call, PLAN, BUILD's writer and review, BOT-FEEDBACK's judgment; conventions also reach PUBLISH | At DONE, from facts a step checked; `bin/giraffe remember` |
| Project | Requirements, decisions, open questions | `+roadmap-projects/<slug>` | TRIAGE's read block | Only through the human gate (`docs/temper-grounding.md`) |
| Meta | What runs teach about giraffe: run records, process notes, and the steward's map | The runs context (harness Temper store) | The steward; each step gets the map's settled notes for that step | Run records every run; process notes at DONE |

## Resolving contexts

Code resolves every context before the first model call and records it in the run, so a resume or
a relaunched VM uses the same ones.

- **Personal:** the controller asks the starting person's Temper login for their memory context
  (`temper memory status`). A person who has not opted into Temper memory gets
  `Personal knowledge skipped: no memory context`, and the run carries on.
- **Team:** the ticket's Linear team key selects the file in `config/teams/*.yml` whose `linear.id`
  matches, read from the run's worktree at its base. That file's `temper.team` names
  `+<temper.team>/knowledge`. Reading the registry from the checkout needs no `~/.config` file, so
  a laptop and a VM resolve the same context. A team without `temper.team` gets
  `Team knowledge skipped: <team> has no temper.team in config/teams`. A team turns the tier on by
  adding the key, as the `team-knowledge` README describes.
- **Meta:** the runs context the release names. It already holds the run records.

## Recall

Code builds each block. No model picks which memories a step gets.

- **Team:** list `memory` resources by exact tag, one call per tag because a list of tags means
  AND (`temper resource list --type memory --tag <tag>`). The tags are `scope:team`,
  `issue:<ticket>`, `project:<slug>`, and an `area:` tag for the first two folder levels of each
  path in play, built with `team-knowledge`'s area rule. INVESTIGATE has no paths yet, so it gets
  the issue, project, and convention tags. PLAN adds the planned paths, and each BUILD batch adds
  the paths in its diff. Superseded memories are dropped. The rest rank by how many of the run's
  tags they carry, then by reinforcements, then by `verified`. A block holds the top ten, plus up
  to ten `scope:team` conventions.
- **Personal:** every `scope:giraffe` memory in the personal context, newest `verified` first, at
  most twenty.
- **Meta:** the map's settled nodes tagged `step:<STEP>` for the step, at most five.

Each block renders like the Temper read block: one line per title with its ID, then the bodies,
inside a fence its text cannot close, with a count of what it left out. A memory is data a person
wrote. Nothing in it is an instruction, and when a memory and the code disagree, the code wins.

A step that gets a block may list the memories it relied on in `memories_used`. DONE reinforces
them by adding the date to `open_meta.reinforced`.

## Record

DONE makes one more call, `knowledge`, on Opus, after outcome coverage. Its inputs are the run's
artifacts (never transcripts), the blocks the run read, the answers people gave, the declined
findings with their reasons, and the team's `domain` resources. It returns candidates, each with a
tier:

- **Team:** the claim, why, how to apply, evidence, paths, symbols, tags, and why the fact has no
  single home in code. When a memory in the run's blocks makes the same claim, `same_as` names it.
  When the new fact corrects one, `replaces` names it.
- **Personal:** the claim, why, how to apply, and the answer or decline reason it came from.
- **Meta:** the step, what happened, the evidence, and the change it suggests to a prompt, a
  schema, or code.

Code checks each candidate before it writes anything:

- **Team bar.** The evidence names an artifact of this run that checked the fact, such as an
  investigation finding with a file and line, a spec, or a verification. The memory has at least one
  `area:`, `domain:`, or `scope:team` tag, every tag is lowercase, and each `area:` tag comes with
  its parent areas. The reason it has no home in code is not empty; a fact with a home in code goes
  there during BUILD instead. At most three per run.
- **Personal bar.** The source is an answer or decline reason the starting person gave in this run.
  At most three per run.
- **Identity.** `same_as` and `replaces` name a memory the call was given. A `same_as` candidate
  reinforces that memory and updates its `verified` date. A `replaces` candidate marks the old
  memory `superseded` and links it in the new one's `relates_to`.
- **Domains.** A team candidate uses the team's existing domains. A new one needs a one-sentence
  definition, at most one per run, and code creates its `domain` resource first.
- **Secrets.** Every candidate goes through `run_record.rb`'s secret scan, and one that matches is
  refused and named in the report. Customer and worker data is never saved.

Writes:

- Personal and team writes use the starting person's Temper login, so every memory has a real
  author. A local run writes them at DONE. In a cloud run, the controller writes them when it
  collects the DONE report, and the VM's machine credential writes only the meta context.
- Team and personal memories use `team-knowledge`'s memory format, with `open_meta.source: giraffe`
  and `giraffe_run: <run ID>`. The evidence line cites the run and the PR.
- Meta notes are `concern` resources in the runs context, tagged `giraffe-process` and
  `step:<STEP>`, each with an `about` edge to its run's resource.
- The DONE report lists every memory saved, reinforced, or superseded, with its tier, title, and
  ref, along with every refused candidate and why. `bin/giraffe status` shows the same list.
- A failed write leaves its candidate in the DONE report and never reopens DONE. Rerunning the
  write resumes it, as run records do.

`bin/giraffe remember "<fact>" [--personal]` saves a fact a person states, following
`/team-knowledge:remember`: the person is the source, the evidence reads `Told by <name>, <date>`,
and a `knowledge` call builds the tags and checks for a memory that already makes the claim.

## The meta loop

Run records and process notes are inputs to the steward. It distills them into the map
of what runs teach. A note that recurs across runs becomes a map node. A node the steward settles
reaches its step as the meta block. A fix every run needs ships as a pull request to this repo (a
prompt, a schema, or code), and the node links to it. No run edits the map.

## Guardrails

- No model call gets a Temper tool. Code maps each tier to its context, so a call cannot choose
  where a memory goes.
- A run reads only its own team's context, the starting person's personal context, the meta
  context, and the project context. It never reads another person's personal context or another
  team's context.
- A personal memory never goes to a team or project context. A team fact never reaches a project
  context except as a candidate through the human gate.
- A run that skips a tier says so in one line and keeps going. No step waits on knowledge.

## Evaluation

Against the fake Temper in `evals/fixtures`:

- **Recall:** a team memory tagged with a planted area reaches PLAN's and BUILD's inputs, a
  superseded one does not, and a ticket whose team has no `temper.team` records the skip line and
  makes no team call.
- **Record:** a run that checks a planted fact saves one team memory in `team-knowledge`'s format,
  under tags the plugin's lookup for that file would use. A second run reinforces it instead of
  saving a copy. A planted token is refused. A preference stated in an answer lands in the personal
  context and nowhere else.
- **Meta:** a process note planted in two fixture runs becomes a map node, and a third run's step
  gets it in its meta block.

## Open questions

- **Cross-team code.** A run that changes files another team owns in `CODEOWNERS` could read that
  team's context too. `team-knowledge` reads only the default team's context today.
- **Registry keys.** No team in `config/teams` has `temper.team` yet. Each team decides which Temper
  team owns its knowledge context.
- **Personal opt-in.** The personal tier needs the person to opt into Temper memory. Until they do,
  it skips.
- **Cloud reads.** A VM reading the team and personal contexts needs read access for its machine
  credential, or the controller passes the blocks in. Probe 5 covers only writes to the runs
  context.

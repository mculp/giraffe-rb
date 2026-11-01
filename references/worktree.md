# Worktree setup

Get the branch name from the Linear issue `branchName` field. Choose one explicit topology and
say it in chat before creating anything:

- **New**: base the branch on `origin/main`. Default for a new ticket.
- **Adopt**: attach to an existing local or remote branch. Use this for an existing PR.
- **Stacked**: base the branch on an exact parent ref when the ticket depends on unmerged work
  that touches the same code. The PR base must use the same parent branch.

## New

The built-in worktree tool creates a fresh branch off the default remote branch directly:

- **Claude Code**: use the `EnterWorktree` tool with the branch name.
- **Cursor**: use `/worktree` with the branch name.

Use the path returned by the tool. The skill does not prescribe a worktree folder or name.

## Adopt / Stacked

The built-in tool's new-worktree flow cannot attach to an existing branch or base a new branch
on an arbitrary parent ref. For these two cases only, create the worktree with a single explicit
`git worktree add` call, then hand the session into it with the built-in tool:

```bash
# Adopt: track an existing local or remote branch
git worktree add <path> <existing-branch>

# Stacked: new branch off the exact parent ref (never inside the parent's own worktree)
git worktree add <path> -b <branch-name> <parent-ref>
```

- **Claude Code**: use the `EnterWorktree` tool with `path: <path>` to switch the session into it.
- **Cursor**: open the worktree at `<path>` per your harness's equivalent step.

Don't reach for anything beyond this one `git worktree add` call: no directory-layout
convention, no branch-naming rules beyond the Linear-suggested name, no bundled DB/ejson/
overmind setup.

## All topologies

The tool (or `git worktree add`, for Adopt/Stacked) will surface a conflict if the branch is
already checked out elsewhere, so there's no need to check `git worktree list` first.

Database creation/cloning, ejson key setup, and dev-server (overmind) port configuration are
owned by the app repo's own environment tooling once you're in the worktree. This skill does
not manage any of that.

After the worktree is set up: confirm the working directory changed to the new worktree, then
hand off to the app repo's own bootstrap tooling before any spec runs.

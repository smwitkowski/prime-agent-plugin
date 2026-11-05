---
name: prime-oneshot
description: Hand a bounded task to prime-agent (Prime Intellect's RLM harness) as a one-shot subagent on gpt-6.1-terra with high thinking, wait for the answer, and continue it with --resume if needed. Use when the user says "prime-agent this", "hand this to prime", "run it through prime-agent", or for bounded work that benefits from programmatic processing in a Python REPL — sweeping many files/rows in one process, quick analysis, a focused review. Not for small edits, long-running commands (full test suites, renders), subagent fan-out, or open-ended research: use prime-worker for those.
---

# prime-oneshot

Run prime-agent once, get its answer, keep the session id for follow-ups. The command is `${CLAUDE_PLUGIN_ROOT}/bin/prime-oneshot` (also on PATH as `prime-oneshot` while the plugin is enabled).

```bash
prime-oneshot <cwd> "<task>"           # new run
prime-oneshot <cwd> "<follow-up>" <id> # continue that session (same cwd)
```

Prints a header line (session id, model, tokens), then the reply. Every task gets an output contract appended, so replies end with `## Result`, `## Evidence`, `## Files changed`, `## Open questions` (`PA_RAW=1` turns that off).

**Exit code 1 plus a `FAILED:` line** means prime-agent errored, stopped abnormally or returned nothing: report the failure, don't relay the text as an answer. A `WARN:` line about a missing `## Result` usually means the run stopped early (see Notes).

The session is stopped after each run; `--resume` still works on it.

## Before running

- **Workdir.** prime-agent runs model-written code with the user's permissions and is not a sandbox. If the task may edit files, run it in a git worktree, never the user's main checkout: `git worktree add ../<repo>.prime-<slug> -b prime/<slug>`. Read-only analysis can use the repo directly.
- **Write a self-contained task.** prime-agent can't see this conversation. Include the goal, paths, constraints, what "done" means, and the output shape you want back (e.g. "end with a markdown table of X"). It does read the repo's AGENTS.md/CLAUDE.md itself.
- **Time.** Short tasks: run in the foreground with a 600000 ms timeout. Anything that may take longer: use `run_in_background` and wait for the notification; don't poll.

## After running

- Verify claims against the repo or the diff; prime-agent's answer is a report, not proof.
- For a worktree run, review `git -C <worktree> diff` before merging anything.
- Relay the answer and the session id to the user.

## Learning loop

Two levels. Use both.

1. **prime-agent learns** (one-shot sessions are short-lived, so this mostly applies to workers). In a worker (prime-agent's own harness). run `prime-worker learn <name> "<lesson>"` while it's idle, which calls `refine.run()` in its REPL: a small, reviewable, rollback-able harness edit scoped to that session. Add `global` only for lessons true of every project (it changes all future prime-agent sessions). Don't refine on one-off noise.
2. **The plugin learns** (this plugin's scripts and skills). When a run fails in a new way, a workaround is needed, or prime-agent contradicts its docs, append an entry (Saw / Cause / Changed) to `LEARNINGS.md` in your clone of this plugin, or open an issue at https://github.com/smwitkowski/prime-agent-plugin, and propose the fix to the user. Prefer a guard in `bin/` over a rule in a skill, and a rule over a note. Edit the source folder, never `${CLAUDE_PLUGIN_ROOT}` (that's the installed copy and is replaced on update).

## Notes

- Never pipe these commands through `tail` or `head`: a pipeline returns the last command's status and hides `FAILED`. Read the output instead.

- Defaults: `openai-codex/gpt-6.1-terra`, thinking `high`. These are current defaults, not requirements; override with `PA_PROVIDER` / `PA_MODEL` / `PA_THINKING`.
- **A one-shot run ends when the agent stops to wait.** If prime-agent starts a long shell command in the background, it ends its turn ("I'll report when it finishes") and the run exits with the work unfinished. Tasks that need long-running commands (renders, test suites, training) belong in prime-worker. If an answer reads like "still running", rerun the job in a worker.
- Each call carries ~12.7k tokens of harness overhead; batch related asks into one task rather than many tiny calls.
- Never pass `--api-key` on the command line. Auth comes from prime-agent's own login.
- If the run errors with a daemon problem: `prime-agent status`, then `prime-agent doctor`.

## One-shot rules (added to every task)

The script appends: run everything in the foreground and don't spawn subagents, because a one-shot ends the moment the agent waits on anything asynchronous. If the job needs more, the reply says so under `## Open questions`; rerun it as a worker. A long research one-shot used 479k tokens; give open-ended research a worker and an explicit scope.

## Model routing

- **Use the default `gpt-6.1-terra` for everything, vision included.** It is half Sol's per-token price ($1 / $0.05 cached / $5 vs $2 / $0.10 / $10), so it uses about half as much of a subscription plan per turn (2026-10-29). For open-ended or high-stakes work (architecture, hard debugging, live/payment code) pass `PA_MODEL=gpt-6.1-sol`. Astra (gpt-6-astra) was tried for vision labelling and used too much budget for image-heavy fan-out (2026-10-04).
- **Prefer prime-agent workers over Claude subagents** for heavy delegated work: Claude coordinates and verifies, workers build (a role split, not a billing choice).
- **Independent checks** (blind labels, code reviews) run as a separate one-shot that never sees the worker's files.
- **A one-shot ends when the agent waits on anything async,** including RLM subagents it fans out to. For work that may fan out (large labelling jobs) or run long commands (full test suites, reviews that re-run tests), use a separate `prime-worker` and `wait` instead.

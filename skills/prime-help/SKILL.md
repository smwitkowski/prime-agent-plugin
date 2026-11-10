---
name: prime-help
description: >
  Quick-reference card for the prime-agent plugin: which skill to use when,
  commands, setup, and known gotchas. One-shot display. Trigger: /prime-help,
  "prime help", "how do I use prime-agent", "one-shot or worker?".
disable-model-invocation: true
---

# Prime-agent help

Display this card when invoked. One-shot: don't run anything or change config.

## Skills

| Skill | Trigger | What it does |
|-------|---------|--------------|
| **prime-oneshot** | `/prime-oneshot`, "hand this to prime" | Run prime-agent once on a bounded task, wait, get the answer. Follow up with the session id. |
| **prime-worker** | `/prime-worker`, "start a prime worker" | Named, always-on prime-agent in the background. Keeps Python state and context between tasks; can be steered mid-task. |
| **prime-help** | `/prime-help` | This card. |
| **prime-runner** (agent) | "use the prime-runner agent" | Runs a one-shot in its own git worktree and returns only the summary. Use for tasks that edit files. |

All runs use `openai-codex/gpt-6.1-terra` on `high` thinking (current defaults). Override per run with `PA_PROVIDER` / `PA_MODEL` / `PA_THINKING`.

## Which one?

| Use **prime-oneshot** | Use **prime-worker** |
|---|---|
| Clear end: "analyze these clips and report" | Hours-long or open-ended: "tune until precision > 90%" |
| You need the answer before continuing | You keep working while it runs |
| No long-running shell commands | Renders, test suites, training: anything that runs a while |
| Fresh context each time is fine | Tasks reuse the same loaded data |

Both commands live in the plugin's `bin/` (on PATH while enabled). Replies end with `## Result` / `## Evidence` / `## Files changed` / `## Open questions`; exit 1 + `FAILED:` means don't trust the text.

A one-shot run **ends when the agent stops to wait** on a background command. If an answer says "still running", redo it in a worker.

## Commands

```bash
# one-shot
prime-oneshot <cwd> "<task>"                    # new run → prints session id + answer
prime-oneshot <cwd> "<follow-up>" <session-id>  # continue it (same cwd)

# worker
prime-worker start  <name> <cwd> "<task>"   # create + first task, returns immediately
prime-worker send   <name> "<msg>"          # idle: next task · busy: steer current task
prime-worker wait   <name> [timeout_s] [gate_cmd]  # block until idle and its listed jobs end (resumes it when they do); questions return at once; gate loops until it passes (QUEUED after 5 min)
prime-worker status [name]                  # busy / idle / stopped + last reply
prime-worker heartbeat <name> [n]           # read its status files: heartbeat.json + last n activity lines
prime-worker inbox  <name> "<msg>"          # leave guidance it reads between steps (no steering)
prime-worker watch  [--quiet] <name>        # background: returns when it needs you (idle/failed/input/phase/stale); --quiet skips phase
prime-worker learn  <name> "<lesson>" [global]  # worker persists a lesson (prime-agent refine)
prime-worker stop   <name>                  # stop and forget
```

## Rules of thumb

- **One worker per project or workstream.** Never two projects in one worker.
- **One task at a time.** `send` to a busy worker *steers* it (lands at its next tool boundary). There's no queue-after-finish.
- **Worktree for anything that edits files.** prime-agent runs model-written code as you; it is not a sandbox. Never two workers on one checkout.
- **Long runs: pull, don't ping.** `start` gives the worker a reporting protocol. Check it every ~10 min with `heartbeat`, give guidance with `inbox`, and `send` only to change course (the queue caps at 20 pending).
- **2–3 workers max.** Each adds cost and review load. Stop them when done.
- **Write self-contained tasks.** prime-agent can't see the Claude Code conversation. It does read the repo's AGENTS.md / CLAUDE.md.
- **Verify before trusting.** Its answer is a report, not proof.

## Setup and gotchas

- Requires `prime-agent` (≥ 0.9.8, signed in via `/login` to `openai-codex`) and `jq`.
- The model you use must appear in `prime-agent model list`; register it in `~/.prime/agent/models.json` if not (see the README). Without that, a woken worker silently falls back to the global default model. A reply tagged with the wrong `[model]` means check that file.
- `prime-agent send --follow-up` / `--steer` appear in `--help` but were removed in 0.7.0 (issue #901). Plain `send` always steers.
- Each call carries ~12.7k tokens of harness overhead. Batch related asks.
- Worker names live in `~/.local/state/prime-workers/`. Transcripts stay in `~/.prime/agent/sessions/` after `stop`.
- `prime-agent shutdown` (or a daemon crash) stops every worker and loses their Python state.
- Daemon trouble: `prime-agent status`, then `prime-agent doctor`.

## Learning loop

- **Worker level:** `prime-worker learn <name> "<lesson>"` after you correct a worker. It's stored in that session's harness via `refine.run()`; `global` makes it apply to all prime-agent sessions.
- **Plugin level (interface only):** a surprise when driving prime-agent → entry in `LEARNINGS.md` in your clone of this plugin, or an issue at https://github.com/smwitkowski/prime-agent-plugin (Saw / Cause / Changed) → fix in `bin/` (guard) > skill (rule) > note → update (below). How-to-work lessons belong to the worker's own harness.
- **Harness level:** workers keep their context in `CONTEXT.md` (re-read after compaction) and refine themselves freely for lessons.
- Periodically: review recent sessions for repeated prime-agent failures worth an entry.

## Usage efficiency

- `prime-worker status` shows each worker's API-equivalent spend and context size. Large contexts are the main drain: every wake re-reads them.
- Stop finished workers and cancel their schedules (`prime-agent schedule list`). Keep one recurring prompt per worker, 30 minutes or more.
- Progress goes in files, not refine. Each refine and compaction rebuilds the prompt cache.
- prime-agent config (`~/.prime/agent/settings.json`, or per project `.prime/agent/settings.json`): `compaction.reserveTokens` (the default of 16384 lets context reach about 256k before compacting) and `autoRefine` `{enabled, turnInterval (default 25), compact (default true), cooldownMs}`. autoRefine isn't in the 0.9.8 docs; the fields come from the source. Change them only with the user's OK.

## Update

Plugin source: https://github.com/smwitkowski/prime-agent-plugin (layout: `bin/` commands on PATH, `lib/common.sh` shared contract + tripwire, `skills/`, `agents/prime-runner.md`, `LEARNINGS.md`). Users update with `claude plugin marketplace update prime-agent-plugin` and `claude plugin update prime-agent@prime-agent-plugin`. Contributors editing a local clone: bump `version` in `.claude-plugin/plugin.json`, then:
```bash
claude plugin validate <clone>
claude plugin marketplace update prime-agent-plugin
claude plugin update prime-agent@prime-agent-plugin
```
Then `/reload-plugins` or start a new session.

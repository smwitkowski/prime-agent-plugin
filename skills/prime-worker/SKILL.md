---
name: prime-worker
description: Run long-lived prime-agent workers (gpt-6.1-terra, high thinking) hosted by the prime-agent daemon. They keep their Python REPL state, loaded data and context between tasks, keep working through long commands, and can be steered mid-task. Start a named worker per project or workstream, send it tasks, wait for results, stop it. Use for long or repeated work on the same inputs — detector tuning loops, eval runs, multi-day refactors, a standing "expert" on a dataset — or when the user says "start a prime worker", "send it to the worker", "check on the worker", "heartbeat", "run the heartbeat on <worker>", "supervise/monitor the worker". For a single bounded task use prime-oneshot instead.
---

# prime-worker

The command is `${CLAUDE_PLUGIN_ROOT}/bin/prime-worker` (also on PATH as `prime-worker` while the plugin is enabled).

```bash
prime-worker start  [--worktree[=<base>]] [--budget=<usd>] <name> <cwd> "<task>"   # create worker + first task; returns immediately
prime-worker send   <name> "<msg>" | <name> --file <path>   # idle: next task. busy: steer the current task
prime-worker wait   <name> [timeout_s] [gate_cmd]  # block until idle, print Result + Open questions; returns questions at once; with gate_cmd, loop until it passes (QUEUED after 5 min; skipped until changes and new files are committed)
prime-worker status [--brief] [name]        # busy/idle/stopped + last reply; --brief: one line per worker + totals
prime-worker heartbeat <name> [n]           # liveness + heartbeat.json + last n ACTIVITY lines; flags NEEDS INPUT / STALE
prime-worker inbox  [--now] <name> "<msg>"  # leave guidance in its INBOX.md; --now also delivers it
prime-worker watch  [--quiet] <name> [interval_s] [timeout_s]  # background: returns only when the worker needs you; --quiet: not on phase changes
prime-worker learn  <name> "<lesson>" [global]  # persist a lesson via prime-agent refine
prime-worker stop   <name>                  # stop and forget; removes a --worktree worktree once clean and pushed/merged (squash-merged PRs count)
```

New tasks (`start`, or `send` to an idle worker) get the output contract appended, and `start` also appends the reporting protocol (see Supervising a long run below): replies end with `## Result` / `## Evidence` / `## Files changed` / `## Open questions`. Steers are sent as written. `wait` prints `## Result` and `## Open questions`, saves the full reply to `<status folder>/last-reply.md`, and always ends with one verdict line: `WAIT: OK`; `WAIT: FAILED <reason>` (exit 1); `WAIT: NEEDS INPUT: <question>` (the worker set a new `needsInput`; it comes back at once, before any gate: answer with `send`, which marks it answered, then start a new `wait`); or `WAIT: QUEUED` (exit 3: the gate was still running after `PA_GATE_REPORT_AFTER` seconds, default 300; the reply is unverified, the gate keeps running, and running the same `wait` again collects it). A worker that is idle while a background job it listed in `activeJobs` is still running is treated as busy, and when that job exits `wait` tells it to continue; don't hand-write `kill -0` loops or "your job finished" messages. Read `last-reply.md` for Evidence and Files changed. If the worker goes idle with a reply that has no `## Result`, or whose `## Result` says work is still running (it ended its turn early), `wait` sends it a fixed "continue" nudge first (`PA_NUDGES`, default 2) unless it has set needsInput; don't hand-write "continue" messages.

Typical flow: `start` → `wait` (with `run_in_background`; you're notified when it returns) → read the reply → `send` the next task → `wait` again. For runs longer than about an hour, supervise with `heartbeat` instead (below).

## Rules

- **One worker per project or workstream.** Never reuse a worker across projects: a session is bound to its starting folder and that repo's AGENTS.md/CLAUDE.md. Name it after the work (`search-indexer`), not the task.
- **One task at a time.** Check `status` before `send`. Sending to a busy worker steers it: the message lands at its next tool boundary and changes the current task. Use that only to correct or redirect; otherwise `wait` first. There is no queue-after-finish option.
- **Pull, don't ping.** Supervise long runs by reading the worker's files with `heartbeat`, not by messaging it on a timer (see below).
- **Don't flood a busy worker.** Queued messages wait for the end of its current tool calls, and the daemon refuses sends once 20 items are pending, a count that includes its own subagent and heartbeat notices. `send` only to change course; put routine guidance in `inbox`. Set `"steeringMode": "all"` in `~/.prime/agent/settings.json` so a backlog drains in one turn; the default delivers one message per turn.
- **Waiting:** follow every `start`, `send` or `inbox --now` in the same message with a background `wait` (coding work: with its gate) or `watch`, run with `run_in_background`; never a polling loop of your own. Never answer an idle worker with `inbox` alone: it doesn't wake it. `status --brief` flags idle workers `WAITING ON YOU <minutes>`, and `send` notes when nothing is waiting. In one project, workers sat idle waiting on the supervisor in 17 of 58 episodes, for up to 4.5 hours, mostly found only when the user asked "Status?".
- **Gate every coding `wait`.** Pass a real check as `gate_cmd` (e.g. `"uv run pytest -q"`), every time, not only on the first task: in October gate use decayed to zero in one project and was skipped in 29 waits in another. `wait` runs it in the worker's folder once the worker is idle, sends failures back (3 tries by default, `PA_GATE_RETRIES`), and exits 1 if it never passes. The gate runs detached at the worker's HEAD, with its state in `<status folder>/gate.json` and output in `gate.log`; `status --brief` and `heartbeat` show a running gate and its last output line, and `watch` wakes when a gate left running finishes. There is no machine-wide gate lock any more: it made every repo's gates wait behind one blocked gate (2026-10-29). A gate that shares a real resource (a local database, a port, a timing-sensitive suite) locks that resource inside its own script. `wait` refuses gates that redirect to `/dev/null` or pipe into `tail`/`head`/`grep`. Don't accept "done" from the worker without one when a check exists. Prefer the project's own gate script when it has one.
- **Worktrees.** Workers run model-written code with the user's permissions and are not sandboxed. A worker that edits files gets its own worktree: `start --worktree <name> <repo> "<task>"` creates `../<repo>.prime-<name>` on `prime/<name>` (from HEAD, or `--worktree=<base>`; an existing one is reused). Put dependency setup (`npm ci`, a `node_modules` symlink) in the task, not around `start`. Never point two workers at one checkout.
- **Clean up when the work is done.** Once a worker's branch is merged, or pushed with no follow-up planned, `stop` it: for a `--worktree` worker that removes the worktree when it has no uncommitted or untracked files and its branch is pushed or merged (a merged PR whose head is the worktree's HEAD counts, so squash merges are cleaned up; needs `gh`), keeps the branch, and otherwise prints why it kept it. Copy out any data other jobs read from it first. Each worktree carries its own `node_modules`, `.venv` or `target/` (0.5–50 GiB); leftovers filled the disk four times in October 2026. Worktrees made by hand still need `git worktree remove` after `stop`.
- **One deliverable per brief, written from the template.** Fill in [BRIEF-TEMPLATE.md](BRIEF-TEMPLATE.md): one PR (or one stated stack), the base SHA, the failing evidence, owned and forbidden paths, steps only you can run, the gate, Done, and a stop rule. The worker can't see this conversation. A multi-phase plan gets one brief per phase, sent when the previous one lands. In October, targeted one-PR briefs landed clean at a median of $3–17, while multi-track and "own this area" workers cost $120–358 per landed result.
- **Every brief has a stop rule.** Pass `--budget=<usd>` to `start` (the worker stops near 80% and asks), and state an hours limit for long jobs. `watch` also wakes you when spend since it started passes `PA_SPEND_ALERT` (default $150) or compactions pass `PA_COMPACT_ALERT` (10).
- **Parts of one deliverable can run as tracks inside one worker.** Give each track a subagent owner with its own budget and the authority to act within caps. The parent sets caps and checks results instead of approving every step; serial parent admission was the bottleneck on 2026-10-03. Separate deliverables get separate workers.
- **Cap review rounds.** After the third review round that still finds new issues, stop sending fixes and decide (with the user when it's theirs): merge and log the rest as backlog, redesign smaller, or split the PR. In one project, five or more rounds took 42% of worker spend; reviews still earn their keep on live, payment and safety code.
- **Send defects, not designs.** A rework request names the defect, gives a failing test or reproduction, and cites the brief line it breaks. If you also suggest a fix, label it "suggestion" and let the worker push back with evidence before building it. A requirement the brief didn't state is new scope: say so, and ask the user when the call is theirs. In one project, prescribed designs that were later walked back and unstated requirements caused the most rework of any pattern, 4.7 rounds per episode.
- **Shared machine resources.** Before running workers in parallel, list what they share (local database, ports, heavy test suites, disk for media) and give each resource a lock or an owner in the briefs. Workers never negotiate with each other: in October they exchanged 21–57 messages per project over locks, each one waking a 100–250k-token context.
- **Workers don't message each other.** The protocol forbids messages between top-level workers; a worker's own subagents are part of its work. If a worker reports a message from a sibling, treat it as a bug to fix in the briefs; in October workers in all four projects messaged siblings, sometimes across projects, and one leaked labels into a blind evaluation.
- **Ask before the 6th live worker.** Before starting a worker while 5 or more are live, show the user `prime-worker status --brief` (live count, spend, context) and ask.
- **One workstream per worker, and stop it when the work is done.** A worker's context only grows. Every message, heartbeat or schedule that wakes it re-reads the whole context (often 150–250k tokens). Start a fresh worker for an unrelated workstream (one project reused one worker for five). Stop idle workers once their queue is empty, and cancel their recurring prompts (`prime-agent schedule list` / `cancel`).
- **Ask before new work.** After a pause, or when the user is deciding, confirm before `start` or a `send` that begins new work ("I wasn't ready to start the prime agent", 2026-10-03).
- **Hand problems back to the worker.** When a gate, a live run or CI fails, send the worker the failing output and let it debug. Don't debug and commit on its branch yourself; heavy work is meant to run on the worker. Never change branches in a busy worker's worktree.
- **Gates that match reality.** Run gates in a clean environment, e.g. `env -i PATH="$PATH" HOME="$HOME" CI=true npm test` (a passing gate then failed CI on local env vars). For model or API pipelines, offline tests aren't enough: replay recorded real outputs in the gate, or run a live smoke test yourself before accepting.
- **Deliver only finished work.** Don't hand the user an artifact until `wait` has returned for it; the worker may still be rewriting it.
- **Its numbers are claims.** Spot-check worker estimates and measurements before reporting them (disk "SAFE 111 GB" was really about 31 GiB; "84% sub-bass" measured 36%).
- Verify a worker's claims against the repo before reporting them as fact.

## Supervising a long run (heartbeat workflow)

`start` appends a reporting protocol to the first task (`PA_RAW=1` skips it). The worker keeps three files in its status folder, which is `PA_STATUS_DIR` or by default `~/.local/state/prime-workers/<name>.d/`:

- `heartbeat.json`: overwritten at each phase change and at least every 10 minutes: `ts`, `phase`, `currentStep`, `activeJobs`, `needsInput`, `lastError`, `nextStep`, and `tracks` (one `{name, owner, status, next}` per parallel workstream).
- `ACTIVITY.jsonl`: one line per step from the worker and every subagent: `ts`, `agent`, `event`, `detail`.
- `INBOX.md`: your guidance, newest first. The worker reads it between steps.

The loop:

1. Run `prime-worker watch <name>` with `run_in_background`. It returns only when the worker is idle, failed or stopped, needs input, changes phase, or goes stale, and then prints the heartbeat. Handle that, then start the next `watch`. For batch and overnight runs use `watch --quiet <name>` with a timeout of 30 minutes or more: it skips phase changes, and in November one overnight loop woke its supervisor 72 times at about 830k context just to narrate progress. Don't use timed `sleep` checks or a Claude cron on top of it: on 2026-10-03 that meant 285 checks and 178 wakeups for one worker. When the user asks "Status?", answer from `prime-worker status --brief` (all workers) or `prime-worker heartbeat <name>` (one); don't build your own loop over workers.
2. `NEEDS INPUT`: answer with `inbox`, or ask the user if the decision is theirs.
3. Feedback, context and approvals go in `inbox`. When the worker must act on it now, use `inbox --now`: it writes the entry and then sends it as the next task (idle) or steers with a pointer to it (busy). Don't follow `inbox` with a hand-written "read INBOX.md" `send`.
4. `IDLE`: the worker ended its turn (it sometimes does after a failed step) and won't read `INBOX.md` until it gets a message. `send` it the next task, or `inbox --now`, listing what's left so it keeps looping.
5. `STALE` (busy, with no heartbeat for 15+ minutes; `PA_STALE_MIN`): it may be in one long thinking step. Read the tail of `~/.prime/agent/sessions/<id>.jsonl` before messaging.
6. Report to the user from the latest heartbeat and activity lines, and verify claims against job state or files.
7. Around launches, stops and course changes, use a shorter interval (`watch <name> 60`).
8. The heartbeat is the worker's claim, not proof. Also check what it drives directly: cloud jobs, spend, disk, files it says it wrote.

Limits:
- `watch` runs only while your session is active. If the session ends or compacts mid-wait, checks stop until it resumes, but the worker keeps working and writing its files.
- For short, bounded workers (a code fix, a review), skip the loop: use `wait` in the background, with a gate where tests exist.

**Restarting with a fresh session** (when context bloat makes turns slow): have the worker bring `CONTEXT.md` up to date (state, decisions, artifacts, open issues) and distil standing lessons into `LESSONS.md`, both in the status folder. Archive `INBOX.md`, so stale orders like a STOP can't block the new session. Then `stop` (with `PA_KEEP_WORKTREE=1` to keep its worktree and dependencies) and `start` with the same `PA_STATUS_DIR`, and tell the first task to read CONTEXT.md and LESSONS.md first. Session-local `refine` notes and REPL state do not carry over; global refinements and files do.

A message to a busy worker lands only after its current turn. At high thinking levels that can take 10 minutes or more, so tell the user how long a course change may take to land.

## Recurring prompts (worker heartbeats)

prime-agent can re-prompt a worker on a schedule (`rlm_heartbeat.create` in its REPL, or `prime-agent schedule`). Each run re-reads the worker's whole context, so:
- **One per worker, at 30 minutes or more.** Three 8-minute schedules on one 250k-context worker cost about 5M tokens an hour just to wake it.
- **Back off when blocked.** The prompt must end the turn when it hits the same blocker as last time (no access, an approval it lacks). One worker's heartbeats kept retrying an HTTP 403 overnight. The reporting protocol now says this; repeat it in the heartbeat prompt.
- **State in files, lessons in refine.** Progress and resume state go in CONTEXT.md, heartbeat.json and the project's queue or playbook files. A refine checkpoint per step rebuilds the prompt and re-reads the whole context each time (one set of workers did about 90 in a day). Refine is for how-to-work lessons, and the harness should use it freely for those.
- **One supervisor clock.** If workers have heartbeats, the Claude side uses `watch`, not a cron of its own.
- Cancel a worker's schedules when you stop it.

## Learning loop

Two levels. Use both.

1. **The worker learns** (prime-agent's own continual harness). Each harness should improve itself: the reporting protocol tells workers to refine freely for lessons and keep all working context in files (CONTEXT.md, re-read after every compaction, so summaries can't make them drift). It also auto-refines on its own (`autoRefine` in settings: every 25 turns and after each compaction by default). You'll see `[auto-refinement]` / `[self-refinement]` notices in the session file. Local entries last for that session only; global entries persist. When you correct a worker, or it finds a reusable tactic, run `prime-worker learn <name> "<lesson>"` while it's idle. Not for progress checkpoints. That calls `refine.run()` in its REPL: a small, reviewable, rollback-able harness edit scoped to that session. Add `global` only for lessons true of every project (it changes all future prime-agent sessions). Don't refine on one-off noise.
2. **The plugin learns** (interface only: prime-agent's CLI, daemon, models, config, and this plugin's commands). When driving prime-agent surprises you (a failure mode, a workaround, docs that don't match), append an entry (Saw / Cause / Changed) to `LEARNINGS.md` in your clone of this plugin, or open an issue at https://github.com/smwitkowski/prime-agent-plugin, and propose the fix to the user. Lessons about how a worker should do its work belong in that worker's harness, not here. Prefer a guard in `bin/` over a rule in a skill, and a rule over a note. Edit the source folder, never `${CLAUDE_PLUGIN_ROOT}` (that's the installed copy and is replaced on update).

## Notes

- Thinking: `PA_THINKING=xhigh` is the highest level openai-codex models accept; `max` clamps to `high` for them. Check `thinking_level_change` in the session file to confirm.
- Model: pinned when the worker is created (`PA_MODEL`, `PA_THINKING` override). The model must appear in `prime-agent model list`; otherwise the daemon falls back to the settings.json default when it wakes the worker. If it is missing, register it in `~/.prime/agent/models.json` (see the README). If a reply shows a different `[model]`, check that file.
- Why not `-p` for workers: a `-p` run exits as soon as the agent waits on a background command, and can't be steered from outside. Daemon-hosted sessions keep going and accept messages.
- Registry: one file per worker in `~/.local/state/prime-workers/` (session id + cwd). `prime-agent rename` only works on attached sessions, so names live here.
- `stop` ends the live session and its REPL state; the transcript stays in `~/.prime/agent/sessions/`. `prime-agent shutdown` or a daemon crash does the same to every worker.

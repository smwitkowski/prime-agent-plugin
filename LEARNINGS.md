# prime-agent plugin: interface learnings

**Scope:** what we've learned about *driving* prime-agent from Claude Code: its CLI, daemon, models, config, and this plugin's commands. Not how a worker should do its work. Those lessons belong to each worker's own continual harness (its refines) and the context files it keeps.

**The ratchet:** every guard in `bin/` and every rule in the skills traces to an entry here. When the interface surprises you, add an entry (date · Saw · Cause · Changed), then fix it in this order of preference: a guard in `bin/`, then a skill rule, then a note.

## Models and config

- **2026-10-02: a woken worker ran on the wrong model.** A session created on `gpt-6.1-sol` replied as `gpt-6-astra` after `send` woke it. The daemon can't restore a model that isn't in its registry, so it falls back to `settings.json` `defaultModel`. Changed: registered `gpt-6.1-sol` under `openai-codex` in `~/.prime/agent/models.json`. Unlisted IDs still work for `-p` runs.
- **2026-10-03: thinking `max` silently ran at `high`.** openai-codex models top out at `xhigh`. Changed: `prime-worker start` maps `max` to `xhigh`. Confirm via `thinking_level_change` in the session file.
- **2026-10-04: Astra used too much of the subscription** for image-heavy fan-out. Changed: everything runs on `gpt-6.1-sol` by default, including `defaultModel`.
- **2026-10-04: there are undocumented config knobs.** `autoRefine: {enabled, turnInterval (25), compact (true), cooldownMs}` is read from `settings.json` and missing from the 0.9.8 docs; it auto-refines every 25 turns and after every compaction. `compaction.reserveTokens` (16384) means compaction happens only near the window (about 256k on 272k models). Both work per project via `.prime/agent/settings.json`.

## Run modes

- **2026-10-02: one-shots end while work is still running.** A `-p` run exits the moment the agent waits on anything async: a background command, RLM subagents, a long test suite. `--goal` and `--autonomous` don't change this. Changed: workers are daemon-hosted (`-p` only creates the session; tasks go through `send`). prime-oneshot appends "foreground only, no rlm.spawn".
- **2026-10-02: autonomous mode can't be enabled remotely.** Its flags work only at session creation or in the TUI; `/autonomous on` sent via `send` arrives as plain text. Changed: completion gates live in `prime-worker wait <name> <timeout> "<gate>"`.

## Messaging and steering

- **2026-10-02: `send --follow-up` / `--steer` are rejected.** They were removed in 0.7.0, but the help text is stale (upstream #901). Every `send` steers. Changed: `prime-worker send` rejects flags with a hint.
- **2026-10-03: messages to a busy worker arrive late, then get refused.** They land at the next tool boundary, one per turn under the default `steeringMode`. The daemon refuses at 20 "unfinished" items, and delivered steers, heartbeats and child reports count until the long turn ends (35/20 was seen with an empty queue). Changed: `steeringMode: "all"`; `send` refuses at ≥15 and points to `inbox`.
- **2026-10-02: slash commands sent via `send` are plain text.** Use the kernel API instead (`refine.run()` and similar); `prime-worker learn` does this. `learn` needs the worker idle, which includes its recurring heartbeat not running.
- **2026-10-03: an idle worker never reads its inbox.** INBOX.md is read only between steps of a running turn. Changed: `heartbeat` and `watch` report IDLE, and the skill says to `send` the next task.

## Status and daemon

- **2026-10-02: the daemon list shows `-p` runs as idle.** Client-owned runs are hidden from daemon activity. This no longer matters now that workers are daemon-hosted.
- **2026-10-04: `wait` returned while RLM children were still working.** Child sessions are separate list entries under `session-artifacts/<parent id>/`. Changed: `activity()` counts them.
- **2026-10-04: a crashed session worker still reports busy.** `send` says "Session worker is failed", and the session file ends with a `worker_recovery` notice. Changed: `activity()` returns `failed`.
- **2026-10-04: the REPL cwd can be stale.** A daemon REPL kept an old probe folder as its process cwd, and `list` showed that cwd while the session was active. Relative paths wrote there. Changed: `start` prepends `%cd <cwd>` plus an assertion and "write only under this folder".
- **2026-10-04: `status` stopped at a `<name>.d` folder.** Fixed by skipping directories (0.5.9).
- **2026-10-05: `watch` polled every interval when a worker kept `needsInput` filled.** Fixed: needsInput triggers only if it was empty when watch started (0.6.1).
- **2026-10-03: what a fresh session inherits.** Files and global refines carry over. Local refines, conversation and REPL state do not. Changed: the restart recipe in the skill.
- **Smaller CLI quirks:**
  - `--resume <id>` needs the session's original `--cwd`.
  - `rename` only works on attached sessions, so names live in `~/.local/state/prime-workers/`.
  - Pipe `< /dev/null` into `-p` runs.

## Plugin and Claude Code

- **2026-10-02: silent failures.** A bad model returned exit 0 with empty text. Changed: `check_reply` exits 1 with `FAILED:`. Since 2026-10-04 it does so only on an error or empty text; an abnormal stopReason is a WARN, because `toolUse` falsely failed a complete answer.
- **2026-10-04: piping through `tail` or `head` hides the exit code.** A pipeline returns the last command's status. Don't pipe prime-oneshot or prime-worker; read their output instead.
- **2026-10-02: the sandbox blocks `$(pwd)` in agent commands.** Changed: prime-oneshot resolves its cwd argument, and prime-runner passes `.`.
- **2026-10-04: workers write wherever a brief points them.** They have the user's write permissions; a brief naming `~/.claude/skills/...` led a worker to rewrite a skill. Briefs name outside paths only as read-only.
- **2026-10-04: running sessions keep their plugin version.** One ran a stale 0.2.0 script from the cache. Run `/reload-plugins` after an update, and delete old cache versions only after sessions reload.
- **2026-10-04: cross-session messages can be held.** Sessions in a different permission mode hold both `SendMessage` and the app's `send_message` until approved, and they expire. Fallback: a paste-ready file.

## 2026-10-05: a restarted worker can't reuse its agent name
**Saw:** after `prime-worker stop my-worker` and `start my-worker`, `prime-agent rename <new> my-worker` failed with `Agent name ... is unavailable: an agent of that name already exists at depth 0`. Renaming the archived session failed with `Unknown active session`.
**Cause:** archived sessions keep their agent name reserved, and rename only works on active sessions.
**Changed:** named the new session `my-worker-2`. The prime-worker registry name and status folder are unchanged. Possible guard: have `prime-worker start` rename the old session before `stop` archives it (for example `<name>-archived-<date>`), or append a suffix when the name is taken.

## 2026-10-05: watch exited silently for a new worker (0.6.1 regression)
- Saw: `watch` returned at once with no output for a just-started worker that had no heartbeat.json yet.
- Cause: 0.6.1 added `need0=$(need)`. jq on a missing file fails, and `set -e` killed the script before the loop.
- Changed (0.6.2): `need()` ends with `|| true`. Checked with a short watch on the new worker: it now times out normally and prints the heartbeat.

## 2026-10-05: watch woke the supervisor every few minutes on busy workers
- Saw: two busy workers changed `phase` every 3–6 minutes, so `watch` at the default 120 s interval returned four times in 20 minutes for routine steps.
- Cause: any phase change counts as news.
- Changed: Main runs `watch <name> 900` for long workstreams, so each worker wakes it at most 4 times an hour, and idle, failed or needs-input still show within 15 minutes. Possible guard: a higher default interval, or an option to ignore phase changes.

## 2026-10-05: a background watch was killed at 30 minutes
- Saw: a `prime-worker watch <name> 900` run with `run_in_background` was stopped by the host when it hit its background time limit, with no change from the worker.
- Cause: the host's default background limit is 30 minutes. A 900 s watch interval can go quiet for longer than that.
- Changed: run long watches with an explicit background timeout of up to 2 hours and a matching watch timeout (`prime-worker watch <name> 900 7000`).

## 2026-10-13: wait's gate passed on a turn where the worker did no work
- Saw: a worker started a 30-minute smoke run as a background command, then ended its turn ("I'll wait for shutdown"). `wait` returned, the gate (`typecheck && test`) passed on the unchanged tree, and the reply had no `## Result`. This happened twice, so two "GATE PASSED" results carried no new work.
- Cause: the worker ends its turn while its own long command runs in the background. `wait` treats idle as done, and a gate on an unchanged tree passes vacuously.
- Changed: the worker resumes on its own when its background command completes (it went busy at the 13:32 smoke exit with no `send`), so the supervisor only needs to re-run `wait` after that exit. It watches the process with a background pgrep loop and does not send a nudge. Possible guard: when the reply is missing `## Result` and HEAD is unchanged since the send, `wait` should report "IDLE-WAITING, not done" instead of running the gate.

## 2026-10-13: worker waited on an approval with needsInput null
- Saw: a worker's heartbeat had `needsInput: null` but `nextStep: "await explicit policy approval"`. The actual question was only in a reply's `## Open questions` and in the session log, so `watch` would never have flagged NEEDS INPUT.
- Cause: the worker phrased the approval as an open question and a next step, and never set `needsInput`.
- Changed: the supervisor read `nextStep` and the session log to find the question. Possible guard: `heartbeat` flags NEEDS INPUT when `nextStep` matches /await.*(approval|clarification)/, and the reporting protocol should say "set needsInput whenever you are blocked on the owner".

## 2026-10-13: the gate passed in the worker's checkout but failed after merge
- Saw: a worker's gate (`env -i ... npm run typecheck && npm test`) passed in its worktree. After merge, `npm test` on main failed: vitest collected a `node:test` script that imports `../dist/`, and main's `dist/` was a stale build.
- Cause: the gate runs in the worker's folder, which still has its own build outputs and untracked files. A clean env is not a clean checkout.
- Changed: gate on a fresh `git clone` of the worktree into a temp dir (`rm -rf T && git clone -q . T && cd T && npm ci && ...`). Possible guard: a `PA_GATE_CLEAN_CLONE=1` option in `wait` that does this automatically.

## 2026-10-18 — One-shot ends on provider overload mid-task
- Saw: a long prime-oneshot (Playwright staging reproduction, ~1.16M tokens) exited with `FAILED: prime-agent error: Codex error: Our servers are currently overloaded`, leaving partial artifacts.
- Cause: transient openai-codex capacity error surfaced as a hard one-shot failure; no automatic retry.
- Changed: resumed with `prime-oneshot <cwd> "<continue from saved artifacts>" <session-id>` — works because the session survives. Proposal: have bin/prime-oneshot auto-resume once on this specific transient error, and tell long browser/test tasks to checkpoint artifacts to disk (they did, which made the resume cheap).

## 2026-10-19: worker vanished after "Request was aborted"
- Saw: `prime-worker wait <name>` printed GATE PASSED, then `FAILED: prime-agent error: Request was aborted`. Afterwards `status` said "no worker named <name>" and the round's uncommitted work was gone (the branch was clean at the prior commit).
- Cause: unknown. Possibly another session stopped the worker or a daemon restart; the registry entry was removed without a stop from this coordinator.
- Changed: restarted with a self-contained brief file. Proposal: `wait` should report whether the registry entry still exists after an abort, and `stop` should log who called it.

## 2026-10-20: ENOENT spawning workers after a Claude app restart
- Saw: `prime-worker start` failed with `Failed to spawn session worker: ENOENT ... posix_spawn '<0.9.8 release>/prime-agent'` although the binary existed and the daemon ran from it. Repeated with and without the Bash sandbox.
- Cause: likely a daemon started from a sandboxed session after the app restart could not exec the release binary; once another session started a fresh daemon outside the sandbox, start worked.
- Changed: retried after a fresh daemon appeared; did not force shutdown because other sessions had live workers. Proposal: `prime-worker start` should detect a daemon that can't spawn and suggest starting it unsandboxed, rather than surfacing raw ENOENT.

## 2026-10-24: finished worker worktrees filled the disk
**Saw:** the disk hit 100% four times in October. Each time the bulk was `*.prime-*` worktrees whose workers had finished: about 230 across four repos (37–101 GiB per repo). On 2026-10-24 the full disk also broke the Colima VM's filesystem.
**Cause:** the skill told Claude to create a worktree per worker but never to remove it. `prime-worker stop` leaves the worktree behind.
**Changed:** added a "Clean up when the work is done" rule to skills/prime-worker/SKILL.md: stop the worker, then `git worktree remove` once the branch is merged or pushed. Possible follow-up guard: `prime-worker stop --remove-worktree`, which refuses when the worktree is dirty or the branch is unpushed.

## 2026-10-25 — prime-oneshot reports "empty reply (stopReason=none)" although the session finished
Saw: twice in a row, `prime-oneshot <cwd> "<task>"` exited 1 with `FAILED: empty reply (stopReason=none)`,
`model: ?`, `tokens: 0`, yet the session log (/var/folders/.../prime-oneshot.*.jsonl, 22 MB) ended with a
complete `final_answer` message (`stopReason: stop`). The first attempt really was empty; the second had a
full answer the wrapper did not read.
Cause: unknown; possibly the wrapper reads the reply before the large session log is flushed, or matches the
wrong message when the log is very large.
Changed: nothing yet. Workaround: `grep -o '## Result[^"]*' <log> | tail -1 | sed 's/\\n/\n/g'`.
Proposal: on an empty reply, have bin/prime-oneshot re-scan the log for the last final_answer before failing.

## 2026-10-27: harness review of 20 supervisor sessions (6,400 prime-worker calls, 10-02 to 10-27)
**Saw:** four habits around the CLI, each in many sessions. (1) `wait`, `send` and `start` piped into `tail`/`head` 405 times in 12 sessions despite the "Never pipe" note, because `wait` printed the whole reply. (2) 291 hand-built `for w in ...; heartbeat | grep | head` loops in 19 sessions. (3) `git worktree add && ln -s node_modules` wrapped around `start` (50 of 73 starts in one project; one hit the 600 s tool timeout and left no registered worker), with cleanup by hand. (4) 110 `inbox` + "read INBOX.md" `send` pairs in 13 sessions. Also, "Keep it to 2–3 workers" was routinely exceeded at the owner's request (up to ~20 live in one project).
**Cause:** the CLI made the supervisor do the trimming, aggregating, worktree lifecycle and inbox delivery itself, and the worker-count rule did not match how the owner works.
**Changed:** `wait` prints only Result and Open questions, saves the full reply to `<status>/last-reply.md`, and ends with `WAIT: OK|FAILED <reason>`, so a pipe can't hide the verdict (the "Never pipe" note is gone). `status --brief` gives one line per worker plus totals. `start --worktree[=<base>]` creates `../<repo>.prime-<name>` on `prime/<name>`, and `stop` removes it only when clean and pushed or merged (`PA_KEEP_WORKTREE=1` keeps it). `inbox --now` writes and delivers in one call. The 2–3 workers rule became "ask before the 6th live worker". Self-check: test/worker-cli.sh.

## 2026-10-28: did the workers pay off? (408 episodes across four projects)
**Saw:** a per-project outcome review. Spend per landed result ranged from $35 to $180 by project (at the wrong price; see the next entries), and in one project 42% of spend never landed. No worker PR was reverted. Across all four projects: (1) multi-track or open-ended workers cost the most, targeted one-PR briefs the least; (2) `wait` gates decayed (one project gated 16 of 26 waits early and 0 of 19 late; another had 29 ungated waits and /dev/null gates), mainly because parallel gates on one machine fought over database ports and CPU; (3) nothing capped a worker's own spend (one worker $1,525 with 88 compactions, another $644 unwatched); (4) workers messaged siblings in all four projects, across projects too, and one leaked labels into a blind run; (5) 34–37 hand-written "continue" nudges after early turn ends in one project.
**Cause:** the CLI had no lock, budget, spend alarm or early-end detection, and briefs had no shared shape.
**Changed:** `wait` gates take a host-wide lock and refuse /dev/null or tail/head/grep pipes; `wait` nudges an idle reply without ## Result (PA_NUDGES) unless needsInput is set; `watch` wakes on PA_SPEND_ALERT / PA_COMPACT_ALERT; `start --budget` puts a stop-near-80% rule in the brief; `start` refuses an empty task; `send --file` and empty-send refusal; protocol forbids messaging any worker; skill rules for one deliverable per brief, stop rules, a 3-round review cap and shared-resource locks; skills/prime-worker/BRIEF-TEMPLATE.md. Upstream ask: scope agent_message per project. Self-check: test/worker-cli.sh.

## 2026-10-29: 0.10.0 broke openai-codex prompt caching; 0.10.2 fixes it
**Saw:** on 0.10.0 (Oct 10–18) Codex cache hits fell from ~95% to 11–26% of input, and 47% of turns read nothing from cache (1% on 0.9.8), so the ChatGPT plan drained several times faster. Rolling back to 0.9.8 on Oct 19 restored 96–97%.
**Cause:** 0.10.0 sent a random session id that changed on every resume, rebuild and daemon restart, so `prompt_cache_key`/`session_id` and WebSocket reuse broke (upstream discussion #3618, fixed by PR #3751, merged Oct 25). The fix is in v0.10.2, not v0.10.1.
**Checked:** isolated trial of v0.10.2 (own `PRIME_AGENT_CODING_AGENT_DIR`, own daemon on `--daemon-socket`, live 0.9.8 daemon untouched): one worker, 4 tasks, daemon killed and restarted before task 3. 0 of 7 large turns missed the cache; the first turn after the restart read 22.8k cached / 171 uncached. Small context (13–37k), ~2 minutes, so long idle gaps and 150k+ contexts are untested.
**Changed:** nothing yet; still on 0.9.8. Before upgrading, re-measure one real worker for a day (per-turn `usage.cacheRead` in its session file). Possible guard: `watch` wakes on cache share < 80% over the last N turns.
**Also found while trialling:**
- With a custom daemon socket (`PRIME_AGENT_DAEMON_SOCKET`), prime-agent does not auto-start a daemon; start it with `prime-agent --mode daemon --daemon-socket <path>`. 0.9.8 ignores that env var.
- `prime-agent shutdown` stops every daemon on the machine, not just the one on the current socket. Never use it to restart one daemon while other sessions have workers.
- `prime-worker wait` reported "worker still busy" for 80 minutes when every daemon call failed with ENOENT, instead of failing. Proposal: `activity()` should return `failed` on a daemon connection error.

## 2026-10-29: gpt-6.1-sol was priced at Astra's rate, so every "API-eq" figure was ~5.8x too high
**Saw:** `~/.prime/agent/models.json` priced openai-codex `gpt-6.1-sol` at $10 / $1 cached / $50 output per 1M tokens (GPT-6 Astra's price). OpenAI lists Sol at $2 / $0.10 / $10 (checked on openai.com/api/pricing, 2026-10-29). Session logs store cost at the price in effect, so `status` spend, `PA_SPEND_ALERT` and the 2026-10-28 review all used the wrong rate.
**Cause:** the entry added on 2026-10-02 (to stop the daemon falling back to another model) copied the wrong price block.
**Changed:** corrected Sol's price, refreshed `google/gemini-3.8-flash`, and registered `gpt-6.1-terra` ($1 / $0.05 / $5) in models.json. Re-priced from raw tokens, October's spend was about 5.8x lower than logged, and the 2026-10-28 review's dollar figures are about 5.8x too high; its ratios between projects still hold. Sessions logged before the fix keep the old costs, so `status` totals for old workers stay inflated. `PA_SPEND_ALERT` (default $150) now means real API-equivalent dollars, about 5.8x more spend than before.

## 2026-10-29: default executor switched to gpt-6.1-terra (high)
**Saw:** Artificial Analysis Intelligence Index 42 for Terra high vs 50 for Sol high, at half the per-token price and ~91 vs ~68 output tok/s. On the plan, cost is mostly input re-reads per turn, so per-token price matters more than reasoning effort.
**Changed (0.6.6):** `PA_MODEL` defaults to `gpt-6.1-terra` in prime-oneshot and prime-worker; Sol stays available via `PA_MODEL=gpt-6.1-sol`. Existing workers keep the model they were started with. Watch rework rounds and gate retries per landed result against October; if they rise enough to cancel the 2x price cut, revert.
**Not used:** Codex Fast mode (`/fast`, service tier `priority`). OpenAI's docs say it supports Terra but uses plan limits at 2.5x for ~1.5x speed, and prime-agent 0.10.2's own message says it requires GPT-5.4–5.6.

## 2026-10-29: no daemon after a machine restart
- Saw: after a reboot every `prime-worker` call failed with `connect ENOENT .../prime-agent-501/daemon.sock`; `start` created the session but couldn't deliver the task. Registered workers' sessions were gone (the daemon log shows a graceful drain at shutdown).
- Cause: nothing restarts the daemon at login; it only came up before because another session happened to start one.
- Changed: started it by hand outside the Bash sandbox (`nohup prime-agent --mode daemon &`), then `stop` (PA_KEEP_WORKTREE=1) + `start` with the same status dir, then `send` the task. Proposal: `prime-worker` should start the daemon itself when the socket is missing, or ship a launchd agent.

## 2026-10-29: wait held results and questions behind other workers' gates
**Saw:** A worker finished at 15:16 (draft PR, one Markdown file) and set needsInput, but its supervisor heard nothing for 15+ minutes. Its `wait` queued for the host-wide gate lock, held 19:05–19:26 UTC by a second worker's `wait`, whose own gate was blocked on its repo's lock, held by that worker's 21-minute test trial. The second `wait` had started that gate because the worker went idle while its listed background job was still running. Two independent reviews (Opus at max effort, GPT-6 Astra at xhigh) reached the same diagnosis from a neutral brief.
**Cause:** `wait` treated idle as done, ran the gate even when the worker was asking a question, held one lock while waiting on another, and printed nothing until the gate finished.
**Changed (0.6.7):**
- An idle worker with a live `activeJobs` pid counts as busy.
- A new `needsInput` question returns at once (`WAIT: NEEDS INPUT`); `send` records it as answered.
- The host-wide gate lock is gone; repos lock their own shared resources inside their gate scripts.
- Gates run detached with state in `gate.json`; after `PA_GATE_REPORT_AFTER` (300 s) `wait` prints the reply and ends `WAIT: QUEUED` (exit 3), and a rerun collects the gate.
- `status --brief`, `heartbeat` and `watch` show running and finished gates.
**Left to each repo's own gate script:** refuse a dirty tree before taking the lock, pass docs-only commits as "suites skipped", reuse verdicts for an already-tested tree, take the lock after setup, re-run a failed suite once alone before blaming the code.

## 2026-10-29: gpt-6.1-terra workers end their turn while their own jobs run
- Saw: two workers repeatedly went IDLE mid-task with a locked test/regression job still running and no `## Result`; `watch` woke the supervisor each time, and a gated `wait` then ran the gate on an uncommitted HEAD while the worker resumed.
- Cause: the model launches a background job and ends the turn instead of blocking on it; nothing resumes it when the job ends.
- Changed: `prime-worker learn` lesson ("block on your own jobs in the foreground"), and `PA_NUDGES=8 wait` without a gate until the worker reports, then gate. Proposal: add the rule to the reporting protocol, and have `wait` skip the gate while heartbeat `activeJobs` is non-empty or the tree is dirty.

## 2026-10-29: stale gate display; gating an uncommitted tree (0.6.8)
- Saw: a worker's status read "GATE running 194m" for a gate whose process had died before writing a status; the note above records gates run on HEAD while the worker's edits were uncommitted.
- Changed: `status`/`heartbeat` show a running gate whose process is gone as "GATE stopped" (the worker reads as WAITING ON YOU again). `wait` with a gate checks `git status --porcelain --untracked-files=no` first: tracked changes skip the gate and tell the worker to commit, counting as a retry.

## 2026-11-09: workers still ended turns on their own jobs; review of 83 episodes (0.8.0)
- Saw: across 83 worker episodes in four projects (30 Oct–9 Nov), Terra workers still ended their turn while their own job ran. `wait` ignored `activeJobs` entries without `expectedEnd` and accepted "## Result: … still running" as a finished reply (about 60 such replies in one project, 222 in another), so supervisors resumed workers by hand (43 messages in one project, 9 `kill -0` loops in another). One gate "passed" at the base commit because all the new work was untracked. Two questions came back as `WAIT: FAILED empty reply`. `stop` kept four squash-merged worktrees as "neither pushed nor merged". One overnight `watch` woke its supervisor 72 times on phase changes at ~830k context. The no-sibling rule stopped parents from answering their own subagents in three episodes.
- Changed (0.8.0):
  - `wait`: any live pid in `activeJobs` counts as busy (`expectedEnd` is only used for STALE). When the job exits while the worker is idle, `wait` tells it to continue.
  - `wait`: a `## Result` that says work is still running gets the nudge too (phrases checked against 786 real Result sections; a BLOCKED result is left alone), and a WARN line once nudges run out.
  - `wait`: untracked files skip the gate like uncommitted ones; the message lists them and offers `.gitignore`.
  - `wait`: a new needsInput question with an empty reply returns `WAIT: NEEDS INPUT`, not `FAILED empty reply`.
  - `watch --quiet`: no wake on phase or lastError changes, for batch and overnight runs.
  - `stop`: a merged PR whose head is the worktree's HEAD counts as merged (needs `gh`).
  - Protocol: the no-messaging rule covers other top-level workers only; a worker's own subagents are part of its work. Don't end a turn while a needed job runs; if you must, list it in `activeJobs` first.
- Outside the plugin: supervisor (Claude) spend was 96% of the total, mostly coordinators re-reading 300–900k contexts on every wake. Capping auto-compaction (`"autoCompactWindow": 250000` in `~/.claude/settings.json`) is the supervisor-side fix.

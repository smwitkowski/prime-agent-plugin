# Worker brief template

Write the filled-in brief to a file that survives (the worker's status folder or the project's task folder, never `/private/tmp`), then `start` the worker with a one-line pointer to it. One brief = one deliverable. Projects may add their own required fields; check the repo's CLAUDE.md or AGENTS.md.

```
Goal (one deliverable): <the PR, artifact or answer that exists when you're done> — <ticket / decision id>
Why: <2–4 lines of evidence: user report, failing command and its output, metric>
Repo / worktree / branch / base: <path>, prime/<name> from origin/<base> @ <sha>
Setup (first step, by you): <npm ci / uv sync --frozen / other>; pre-staged inputs: <paths>
Evidence and pointers: <file:line, logs, fixtures, artifacts to reuse>
Scope: <numbered changes>. You own: <paths>. Don't touch: <paths other workers or the supervisor own>
Constraints: <no new deps, no push/merge/deploy, no keys or .env, project non-negotiables>
SUPERVISOR STEP: <keyed, live, paid or deploy step only the supervisor runs; you never attempt it — reply when ready for it>
Shared resources: <database / port / test slot and the lock command to take first; none>
Gate: <exact command, run in a clean env>; the supervisor passes it to `prime-worker wait`
Done means: <gate passes> + <named smoke or check> + <one PR, not merged / artifact at path>; evidence in the PR body or <path outside the repo>
Stop rule: budget $<n> (start --budget) and <h> hours; at either, or if a rule blocks you: update CONTEXT.md, set needsInput, reply BLOCKED under ## Result
```

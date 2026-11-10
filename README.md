# prime-agent plugin for Claude Code

Use [prime-agent](https://github.com/PrimeIntellect-ai/prime-agent) as a subagent from Claude Code: one-shot runs, long-lived named workers, and a worktree-isolated runner agent. Claude coordinates and verifies; prime-agent workers do the heavy build and research work.

## Requirements

- macOS or Linux, with `bash`, `git` and [`jq`](https://jqlang.org).
- `prime-agent` 0.9.8, or 0.10.2 or later (0.10.0 and 0.10.1 break openai-codex prompt caching; see LEARNINGS.md), signed in to a provider (`/login` in the prime-agent TUI).
- The model you run must appear in `prime-agent model list`. If it doesn't, a woken worker silently falls back to your `settings.json` default model. The default is `openai-codex/gpt-6.1-terra`; to register it, add it to `~/.prime/agent/models.json`:
  ```json
  {
    "providers": {
      "openai-codex": {
        "api": "openai-codex-responses",
        "baseUrl": "https://chatgpt.com/backend-api",
        "models": [
          {
            "id": "gpt-6.1-terra", "name": "GPT-6.1 Terra", "reasoning": true,
            "thinkingLevelMap": { "off": null, "minimal": null, "xhigh": "xhigh" },
            "input": ["text", "image"], "contextWindow": 272000, "maxTokens": 128000,
            "cost": { "input": 1, "output": 5, "cacheRead": 0.05, "cacheWrite": 0 }
          }
        ]
      }
    }
  }
  ```
  Costs are USD per million tokens; `prime-worker status` and the spend alarm use them.
- Recommended: `"steeringMode": "all"` in `~/.prime/agent/settings.json`, so a backlog of messages to a busy worker drains in one turn.

## Install

```bash
claude plugin marketplace add smwitkowski/prime-agent-plugin
```
```bash
claude plugin install prime-agent@prime-agent-plugin
```

Then run `/prime-help` in Claude Code for the reference card. Update later with `claude plugin marketplace update prime-agent-plugin` and `claude plugin update prime-agent@prime-agent-plugin`.

## Components

| Component | What it does |
|---|---|
| `skills/prime-oneshot` · `bin/prime-oneshot` | Bounded task → answer, follow-ups via `--resume` |
| `skills/prime-worker` · `bin/prime-worker` | Daemon-hosted workers: start [--worktree] [--budget] / send [--file] / wait [gate] / status [--brief] / heartbeat / watch [--quiet] / inbox [--now] / learn / stop. Briefs follow skills/prime-worker/BRIEF-TEMPLATE.md. Long runs report through files (heartbeat workflow) |
| `agents/prime-runner.md` | One-shot in an isolated git worktree, returns a verified summary |
| `skills/prime-help` | Reference card (`/prime-help`) |
| `lib/common.sh` | Shared output contract and silent-failure check |
| `LEARNINGS.md` | Evidence log; every guard in `bin/` and rule in the skills traces to an entry |

The commands in `bin/` are on PATH in Claude Code while the plugin is enabled.

## Configuration

All settings are environment variables; defaults are current choices, not requirements.

| Variable | Default | Effect |
|---|---|---|
| `PA_PROVIDER` | `openai-codex` | prime-agent provider |
| `PA_MODEL` | `gpt-6.1-terra` | Model, pinned when a worker is created |
| `PA_THINKING` | `high` | Thinking level (`max` becomes `xhigh` on openai-codex) |
| `PA_RAW` | unset | `1` skips the output contract and reporting protocol |
| `PA_STATUS_DIR` | `~/.local/state/prime-workers/<name>.d` | A worker's status folder (set at `start`) |
| `PRIME_WORKERS_DIR` | `~/.local/state/prime-workers` | Worker registry |
| `PA_GATE_RETRIES` | `3` | Gate failures sent back before `wait` gives up |
| `PA_GATE_REPORT_AFTER` | `300` | Seconds before `wait` reports a still-running gate as QUEUED (0 = never) |
| `PA_NUDGES` | `2` | "Continue" nudges for a reply without `## Result` |
| `PA_SPEND_ALERT` | `150` | USD spent since `watch` started that wakes you |
| `PA_COMPACT_ALERT` | `10` | Compactions since `watch` started that wake you |
| `PA_STALE_MIN` | `15` | Minutes without a heartbeat before a busy worker reads STALE |
| `PA_KEEP_WORKTREE` | unset | `1` keeps a `--worktree` worktree on `stop` |

## Safety

prime-agent runs model-written code with your permissions and is not a sandbox. The skills put any worker that edits files in its own git worktree, and the runner agent never merges, pushes or commits.

## Principles

- **Provider- and billing-agnostic.** Judge every choice (model, reasoning effort, worker count, subagent fan-out) by cost per completed outcome, measured in tokens, context size and API-equivalent dollars.
- **Light supervision.** Check on workers by reading their files (`heartbeat`, `watch`), not by pinging them.
- **State lives in files, not in the conversation,** so compaction and restarts don't cause drift.
- **Evidence loop.** Measure, change one thing, re-measure. Every rule traces to a `LEARNINGS.md` entry, and `LEARNINGS.md` covers only how to drive prime-agent.
- **Roles.** Claude coordinates, verifies and keeps the backlog. Workers build, and don't start new work without a go-ahead.

## Contributing

Run the self-checks (no prime-agent session needed; they use a stub), then validate:
```bash
bash test/worker-cli.sh && bash test/heartbeat.sh && claude plugin validate .
```
To try changes locally: `claude plugin marketplace add <your clone>`, then the install line above. Bump `version` in `.claude-plugin/plugin.json` for every release. When prime-agent surprises you, add a LEARNINGS.md entry (date · Saw · Cause · Changed) with the fix.

## License

MIT. See [LICENSE](LICENSE).

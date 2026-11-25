# Shared by skills/*/: default model, output contract + tripwire for silent failures. Source, don't execute.

# The one place the default model lives. Override per run or per worker with PA_PROVIDER / PA_MODEL / PA_THINKING.
PA_PROVIDER=${PA_PROVIDER:-openai-codex} PA_MODEL=${PA_MODEL:-gpt-6.1-terra} PA_THINKING=${PA_THINKING:-high}

# Appended to every task so replies come back compact and checkable. PA_RAW=1 skips it.
CONTRACT='

---
End your final reply with exactly these four sections, in this order:
## Result
The answer or outcome, concise.
## Evidence
What backs it: commands run, files and line numbers, numbers measured. Not your exploration log.
## Files changed
Paths you created or edited, or "none".
## Open questions
Anything unresolved or needing a human decision, or "none".'

with_contract() { if [ "${PA_RAW:-}" = 1 ]; then printf '%s' "$1"; else printf '%s%s' "$1" "$CONTRACT"; fi; }

# check_reply <stopReason> <errorMessage> <text>: print FAILED/WARN lines; return 1 on failure.
check_reply() {
  local stop=$1 err=$2 text=$3
  [ -n "$err" ] && { echo "FAILED: prime-agent error: $err"; return 1; }
  [ -n "${text//[[:space:]]/}" ] || { echo "FAILED: empty reply (stopReason=$stop)"; return 1; }
  [ "$stop" = stop ] || echo "WARN: stopReason=$stop; the text below may be from before its last tool call"
  if [ "${PA_RAW:-}" != 1 ] && ! grep -q '^## Result' <<<"$text"; then
    echo "WARN: reply is missing the ## Result section; it may be unfinished (e.g. stopped to wait on a background command)"
  fi
  return 0
}

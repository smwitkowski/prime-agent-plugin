#!/usr/bin/env bash
# Self-check for `wait`, `status --brief`, `inbox --now` and `stop` worktree cleanup against a stub prime-agent. Needs jq and git.
set -euo pipefail
W="$(cd "$(dirname "$0")/.." && pwd)/bin/prime-worker"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export PRIME_WORKERS_DIR=$T/reg HOME=$T/home PATH="$T/bin:$PATH"
mkdir -p "$PRIME_WORKERS_DIR" "$HOME/.prime/agent/sessions" "$T/bin"
# stub: every session is idle; `send` records its message
cat > "$T/bin/prime-agent" <<'STUB'
#!/usr/bin/env bash
case $1 in
  -p) echo '{"id":"sid"}';;
  list) echo "{\"sessions\":[{\"sessionId\":\"sid\",\"activity\":\"$(cat "$HOME/activity" 2>/dev/null || echo idle)\",\"lifecycle\":\"active\"}]}";;
  send) printf '%s' "$4" > "$HOME/sent"; echo '{"deliveryStatus":"delivered"}';;
esac
STUB
chmod +x "$T/bin/prime-agent"
fail() { echo "FAIL: $*"; echo "$out"; exit 1; }
S=$T/status; mkdir -p "$S"; printf 'sid\t%s\t%s\n' "$T" "$S" > "$PRIME_WORKERS_DIR/w"
reply='done\n## Result\nshipped it\n## Evidence\nlong log\n## Files changed\na.ts\n## Open questions\nnone'
printf '%s\n' "{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"model\":\"m\",\"stopReason\":\"stop\",\"content\":[{\"type\":\"text\",\"text\":\"$reply\"}],\"usage\":{\"cost\":{\"total\":12.4},\"input\":1000,\"cacheRead\":0}}}" > "$HOME/.prime/agent/sessions/sid.jsonl"

out=$("$W" wait w 60)
[ "$(tail -1 <<<"$out")" = "WAIT: OK" ] || fail "last line not WAIT: OK"
grep -q '^shipped it$' <<<"$out" && grep -q '^## Open questions$' <<<"$out" || fail "Result/Open questions missing"
grep -q 'long log' <<<"$out" && fail "Evidence printed"
grep -q 'long log' "$S/last-reply.md" || fail "last-reply.md incomplete"

printf '%s\n' '{"type":"message","message":{"role":"assistant","stopReason":"stop","content":[]}}' >> "$HOME/.prime/agent/sessions/sid.jsonl"
out=$("$W" wait w 60) && fail "empty reply exited 0"
grep -q '^WAIT: FAILED empty reply' <<<"$(tail -1 <<<"$out")" || fail "last line not WAIT: FAILED"

echo '{"phase":"build","needsInput":"which db?"}' > "$S/heartbeat.json"
out=$("$W" status --brief)
grep -q '^w  *idle  *hb 0m  *build .*NEEDS INPUT' <<<"$out" && grep -q 'live workers: 1' <<<"$out" || fail "status --brief"

out=$("$W" inbox --now w "use postgres" 2>/dev/null)
grep -q '^use postgres' "$HOME/sent" && grep -q '## Result' "$HOME/sent" || fail "idle inbox --now did not send the entry as a task"

# stop: a --worktree worktree is kept while unpushed, removed once merged
R=$T/repo; git init -q "$R"; git -C "$R" commit -q --allow-empty -m init
git -C "$R" worktree add -q -b prime/w2 "$R.prime-w2"
reg() { printf 'sid\t%s\t%s\t1\n' "$R.prime-w2" "$S" > "$PRIME_WORKERS_DIR/w2"; }
reg; git -C "$R.prime-w2" commit -q --allow-empty -m work
out=$("$W" stop w2); grep -q 'kept worktree.*neither pushed nor merged' <<<"$out" && [ -d "$R.prime-w2" ] || fail "unpushed worktree removed"
reg; touch "$R.prime-w2/x"; git -C "$R" merge -q prime/w2
out=$("$W" stop w2); grep -q 'kept worktree.*uncommitted' <<<"$out" || fail "dirty worktree not kept"
reg; rm "$R.prime-w2/x"
out=$("$W" stop w2); grep -q 'removed worktree' <<<"$out" && [ ! -d "$R.prime-w2" ] || fail "merged clean worktree not removed"
git -C "$R" show-ref -q --verify refs/heads/prime/w2 || fail "branch deleted"

out=$("$W" start --worktree w3 "$R" "task" 2>&1)
[ "$(git -C "$R.prime-w3" branch --show-current)" = prime/w3 ] || fail "start --worktree made no worktree"
[ "$(cut -f4 "$PRIME_WORKERS_DIR/w3")" = 1 ] && grep -qF "repo.prime-w3')" "$HOME/sent" || fail "worker not pointed at its worktree"

# 2026-10-28 guards
out=$("$W" start w4 "$R" "   " 2>&1) && fail "empty task accepted"; grep -q 'empty task' <<<"$out" || fail "empty task message"
out=$("$W" send w "" 2>&1) && fail "empty send accepted"
printf 'from a file\n' > "$T/msg"; "$W" send w --file "$T/msg" >/dev/null 2>&1; grep -q '^from a file' "$HOME/sent" || fail "send --file"
out=$("$W" start --budget=120 w5 "$T" "task" 2>&1); grep -q 'Budget: about \$120' "$HOME/sent" || fail "budget not in brief"
grep -q 'Never message another worker' "$HOME/sent" || fail "protocol lacks the no-sibling-messages rule"
out=$("$W" wait w 60 "make test >/dev/null") && fail "/dev/null gate accepted"; grep -q '^WAIT: FAILED gate sends output to /dev/null' <<<"$out" || fail "/dev/null gate message"
out=$("$W" wait w 60 "npm test | tail -3") && fail "piped gate accepted"
# early turn end: a reply without ## Result is nudged, not returned as done
printf '%s\n' '{"type":"message","message":{"role":"assistant","model":"m","stopReason":"stop","content":[{"type":"text","text":"still rendering, 40% done"}],"usage":{"cost":{"total":1}}}}' >> "$HOME/.prime/agent/sessions/sid.jsonl"
rm -f "$S/heartbeat.json"
out=$(PA_NUDGES=1 "$W" wait w 60 true)
grep -q '^NUDGE (1/1)' <<<"$out" && grep -q 'without the ## Result section' "$HOME/sent" || fail "no nudge on a reply without ## Result"
grep -q '^GATE PASSED at .*: true' <<<"$out" && [ "$(jq -r .state "$S/gate.json")" = passed ] || fail "gate pass not recorded"
[ ! -e "$PRIME_WORKERS_DIR/gate.lock" ] || fail "host-wide gate lock still taken"
# 2026-10-29: a new question comes back at once, with no nudge and no gate
rm -f "$S/answered"; echo '{"needsInput":"which cache?"}' > "$S/heartbeat.json"; : > "$HOME/sent"
out=$(PA_NUDGES=1 "$W" wait w 60 "touch $T/gate-ran; false") || fail "needs-input wait exited nonzero"
grep -q NUDGE <<<"$out" && fail "nudged a worker that needs input"
[ "$(tail -1 <<<"$out")" = "WAIT: NEEDS INPUT: which cache?" ] && [ ! -e "$T/gate-ran" ] || fail "question not returned before the gate"
# once send answers it, the same question no longer short-circuits; the gate runs
"$W" send w "use redis" >/dev/null 2>&1
out=$(PA_NUDGES=0 "$W" wait w 60 true); grep -q '^GATE PASSED' <<<"$out" && [ "$(tail -1 <<<"$out")" = "WAIT: OK" ] || fail "answered question still short-circuited"
# idle while its own listed background job runs is not done
sleep 7 & job=$!
echo "{\"activeJobs\":[{\"pid\":$job,\"cmd\":\"trial\",\"expectedEnd\":\"$(jq -nr 'now + 600 | todate')\"}]}" > "$S/heartbeat.json"
t0=$(date +%s); out=$(PA_NUDGES=0 "$W" wait w 60)
grep -q 'background job is still running' <<<"$out" && [ $(( $(date +%s) - t0 )) -ge 5 ] || fail "wait returned while the worker's job ran"
rm "$S/heartbeat.json"
# a slow gate: report the reply, leave the gate running, collect it on the next wait
rc=0; out=$(PA_NUDGES=0 PA_GATE_REPORT_AFTER=2 "$W" wait w 60 "sleep 8") || rc=$?
[ $rc = 3 ] && grep -q '^WAIT: QUEUED' <<<"$(tail -1 <<<"$out")" || fail "slow gate did not return WAIT: QUEUED with exit 3"
out=$("$W" status --brief | grep '^w ' || true); grep -q 'GATE running' <<<"$out" && ! grep -q 'WAITING ON YOU' <<<"$out" || fail "status --brief hides the running gate"
out=$(PA_NUDGES=0 PA_GATE_REPORT_AFTER=0 "$W" wait w 60 "sleep 8")
grep -q '^GATE: collecting' <<<"$out" && grep -q '^GATE PASSED' <<<"$out" && [ "$(tail -1 <<<"$out")" = "WAIT: OK" ] || fail "rerun did not collect the running gate"
# watch wakes when a gate left running finishes
PA_NUDGES=0 PA_GATE_REPORT_AFTER=1 "$W" wait w 60 "sleep 12" >/dev/null || true
echo busy > "$HOME/activity"; out=$("$W" watch w 1 30); grep -q '^WATCH: gate finished (exit 0)' <<<"$out" || fail "watch missed the finished gate"
rm "$HOME/activity"
# watch wakes on spend while busy
echo busy > "$HOME/activity"; out=$(PA_SPEND_ALERT=0 "$W" watch w 1 30); grep -q '^WATCH: spend' <<<"$out" || fail "watch spend alarm"
# 2026-10-29 guards: a worker blocked on a live listed job isn't STALE until 15m past expectedEnd
sleep 60 & job=$!
echo "{\"phase\":\"smoke\",\"activeJobs\":[{\"pid\":$job,\"cmd\":\"smoke\",\"expectedEnd\":\"$(jq -nr 'now + 3600 | todate')\"}]}" > "$S/heartbeat.json"
touch -t 202610010000 "$S/heartbeat.json"
out=$("$W" heartbeat w); grep -q STALE <<<"$out" && fail "STALE while waiting on a live job before expectedEnd"
echo "{\"phase\":\"smoke\",\"activeJobs\":[{\"pid\":$job,\"cmd\":\"smoke\",\"expectedEnd\":\"$(jq -nr 'now - 3600 | todate')\"}]}" > "$S/heartbeat.json"
touch -t 202610010000 "$S/heartbeat.json"
out=$("$W" heartbeat w); grep -q STALE <<<"$out" || fail "no STALE once the job's expectedEnd has long passed"
kill $job; rm "$HOME/activity" "$S/heartbeat.json"
out=$("$W" status --brief); grep -q '^w  *idle .*WAITING ON YOU [0-9]*m' <<<"$out" || fail "idle worker not flagged WAITING ON YOU"
out=$("$W" send w "next" 2>&1); grep -q 'no wait or watch is running for w' <<<"$out" || fail "send without a waiter gave no note"
out=$("$W" inbox w "fyi" 2>&1); grep -q "won't read INBOX.md" <<<"$out" || fail "inbox to an idle worker gave no note"
out=$("$W" start w6 "$T" "task" 2>&1); grep -q "Don't add approval steps" "$HOME/sent" && grep -q 'expectedEnd' "$HOME/sent" || fail "protocol lacks the 2026-10-29 rules"
# 2026-10-29: a killed gate isn't shown as running; it reads as stopped and the worker as waiting on you
echo '{"state":"running","cmd":"x","sha":"abcdef0123","pid":999999}' > "$S/gate.json"; rm -f "$S/gate.rc"
out=$("$W" heartbeat w); grep -q 'GATE stopped at abcdef01' <<<"$out" || fail "dead gate not shown as stopped"
out=$("$W" status --brief | grep '^w '); grep -q 'WAITING ON YOU' <<<"$out" && ! grep -q 'GATE running' <<<"$out" || fail "dead gate shown as running"
# uncommitted tracked changes skip the gate and tell the worker to commit
D=$T/drepo; git init -q "$D"; echo a > "$D/f"; git -C "$D" add f; git -C "$D" commit -q -m init
SD=$T/sd; mkdir -p "$SD"; printf 'sid\t%s\t%s\n' "$D" "$SD" > "$PRIME_WORKERS_DIR/d"; echo b > "$D/f"
out=$(PA_NUDGES=0 PA_GATE_RETRIES=2 "$W" wait d 60 "touch $T/dgate") && fail "dirty tree gated"
grep -q '^GATE SKIPPED (1/2): uncommitted' <<<"$out" && [ ! -e "$T/dgate" ] && grep -q 'uncommitted changes to tracked files' "$HOME/sent" || fail "dirty tree not skipped"
git -C "$D" commit -q -am work; touch "$D/untracked"
out=$(PA_NUDGES=0 "$W" wait d 60 "touch $T/dgate"); grep -q '^GATE PASSED' <<<"$out" && [ -e "$T/dgate" ] || fail "committed tree (untracked file only) not gated"
echo "worker-cli self-check: PASS"

#!/usr/bin/env bash
# Self-check for `prime-worker heartbeat` and `inbox` against a fake worker. Needs jq; no daemon session required.
set -euo pipefail
W="$(dirname "$0")/../bin/prime-worker"
export PRIME_WORKERS_DIR=$(mktemp -d)
trap 'rm -rf "$PRIME_WORKERS_DIR"' EXIT
# stub prime-agent with no live sessions, so the check runs without prime-agent installed
mkdir -p "$PRIME_WORKERS_DIR/bin"; export PATH="$PRIME_WORKERS_DIR/bin:$PATH"
printf '#!/usr/bin/env bash\n[ "$1" = list ] && echo %s\n' "'{\"sessions\":[]}'" > "$PRIME_WORKERS_DIR/bin/prime-agent"; chmod +x "$PRIME_WORKERS_DIR/bin/prime-agent"
S=$PRIME_WORKERS_DIR/target; mkdir -p "$S"
printf 'no-such-session\t/tmp\t%s\n' "$S" > "$PRIME_WORKERS_DIR/fake"

out=$("$W" heartbeat fake 2>&1)
grep -q "no heartbeat.json yet" <<<"$out"; grep -q "IDLE:" <<<"$out" && { echo "FAIL: stopped worker flagged idle"; exit 1; }

echo '{"ts":"2026-10-03T16:00:00Z","phase":"run","currentStep":"labelling","activeJobs":["job-1"],"needsInput":"approve prefix?","lastError":null,"nextStep":"smoke","tracks":[{"name":"A","owner":"sub-a","status":"running","next":"capture"}]}' > "$S/heartbeat.json"
printf '%s\n' '{"ts":"2026-10-03T16:01:00Z","agent":"w","event":"started","detail":"new shape"}' \
  '{"timestamp":"2026-10-03T16:02:00Z","actor":"sub","step":"old shape"}' 'not json' >> "$S/ACTIVITY.jsonl"
out=$("$W" heartbeat fake)
for want in 'fake  stopped' 'heartbeat (' 'run | labelling' 'jobs: job-1' 'NEEDS INPUT: approve prefix?' 'track A [sub-a] running: capture' \
  '16:01:00 w started: new shape' '16:02:00 sub -: old shape'; do
  grep -qF "$want" <<<"$out" || { echo "FAIL: missing '$want' in:"; echo "$out"; exit 1; }
done
grep -q 'LAST ERROR' <<<"$out" && { echo "FAIL: null lastError printed"; exit 1; }

# inbox: newest first, written through a symlink
mv "$S" "$S.real"; mkdir "$S"; printf '# Inbox\n\n## old\n\nfirst\n' > "$S.real/MAIN.md"; ln -s "$S.real/MAIN.md" "$S/INBOX.md"
"$W" inbox fake "second" >/dev/null
[ -L "$S/INBOX.md" ] || { echo "FAIL: symlink replaced"; exit 1; }
first=$(grep -m1 -n '^## ' "$S.real/MAIN.md"); grep -q '^## 20' <<<"${first#*:}" || { echo "FAIL: new entry not first"; cat "$S.real/MAIN.md"; exit 1; }
grep -q '^second$' "$S.real/MAIN.md" && grep -q '^first$' "$S.real/MAIN.md"
rm -rf "$S.real"
echo "heartbeat/inbox self-check: PASS"

#!/bin/bash
# Real-process proof that simultaneous normal starts share one socket owner.
set -euo pipefail

BINARY=${1:?usage: test-simultaneous-instance.sh /path/to/omafiles}
ROOT=$(mktemp -d)
pid_a=
pid_b=
probe_pid=
owner_pid=
cleanup() {
  for pid in "$pid_a" "$pid_b" "$probe_pid" "$owner_pid"; do
    [[ -z $pid ]] || kill "$pid" 2>/dev/null || true
  done
  for pid in "$pid_a" "$pid_b" "$probe_pid" "$owner_pid"; do
    [[ -z $pid ]] || wait "$pid" 2>/dev/null || true
  done
  rm -rf "$ROOT"
}
trap cleanup EXIT
export XDG_RUNTIME_DIR="$ROOT/runtime"
mkdir -m 700 "$XDG_RUNTIME_DIR"
# Clean startup and stale recovery use real killed server processes.
"$BINARY" --test-instance-server "$ROOT/ready-clean" &
probe_pid=$!
for _ in $(seq 1 100); do
  [[ -f $ROOT/ready-clean ]] && break
  sleep 0.02
done
[[ -f $ROOT/ready-clean ]]
kill -9 "$probe_pid"
wait "$probe_pid" 2>/dev/null || true
probe_pid=
"$BINARY" --test-instance-server "$ROOT/ready-recovered" &
probe_pid=$!
for _ in $(seq 1 100); do
  [[ -f $ROOT/ready-recovered ]] && break
  sleep 0.02
done
[[ -f $ROOT/ready-recovered ]]
kill -9 "$probe_pid"
wait "$probe_pid" 2>/dev/null || true
probe_pid=

# A live owner with no reachable socket is unresolved: startup must fail and
# must not disturb the owner. The following simultaneous start then proves that
# the dead holder and stale endpoint are recoverable.
"$BINARY" --test-instance-owner-lock "$ROOT/ready-owner" &
owner_pid=$!
for _ in $(seq 1 100); do
  [[ -f $ROOT/ready-owner ]] && break
  sleep 0.02
done
[[ -f $ROOT/ready-owner ]]
if "$BINARY" --test-instance-server "$ROOT/should-not-start"; then
  echo 'startup succeeded despite an unresolved live owner' >&2
  exit 1
else
  [[ $? -eq 2 ]]
fi
kill -0 "$owner_pid"
kill -9 "$owner_pid"
wait "$owner_pid" 2>/dev/null || true
owner_pid=

ready_a="$ROOT/ready-a"
ready_b="$ROOT/ready-b"
gate="$ROOT/gate"
log="$ROOT/routed.tsv"
QT_QPA_PLATFORM=offscreen "$BINARY" --test-simultaneous-instance \
  "$ready_a" "$gate" "$log" request-a &
pid_a=$!
QT_QPA_PLATFORM=offscreen "$BINARY" --test-simultaneous-instance \
  "$ready_b" "$gate" "$log" request-b &
pid_b=$!
for _ in $(seq 1 200); do
  [[ -f $ready_a && -f $ready_b ]] && break
  sleep 0.01
done
[[ -f $ready_a && -f $ready_b ]]
: >"$gate"
for _ in $(seq 1 500); do
  if ! kill -0 "$pid_a" 2>/dev/null && ! kill -0 "$pid_b" 2>/dev/null; then
    break
  fi
  sleep 0.01
done
! kill -0 "$pid_a" 2>/dev/null
! kill -0 "$pid_b" 2>/dev/null
wait "$pid_a"
pid_a=
wait "$pid_b"
pid_b=
[[ $(wc -l <"$log") -eq 2 ]]
[[ $(cut -f1 "$log" | sort -u | wc -l) -eq 1 ]]
[[ $(cut -f2 "$log" | sort -u | tr '\n' ' ') == 'request-a request-b ' ]]
echo "clean startup, stale recovery, unresolved owner, and simultaneous routing: PASS"

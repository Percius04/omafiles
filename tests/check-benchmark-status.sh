#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
historical_gate="$root/bench/bench-gate.py"

if [[ ! -f "$historical_gate" ]]; then
  printf '%s\n' \
    'BENCHMARK STATUS: NOT RUN' \
    'The deleted historical gate was not restored: it mixes host-specific timing baselines, synthetic file operations, and live cache data.' \
    'No deterministic performance release gate is available on this branch.' >&2
  exit 2
fi

printf '%s\n' 'BENCHMARK STATUS: running maintained gate'
exec python3 "$historical_gate" --check-gate

#!/bin/bash
set -euo pipefail
SCRIPT=${1:?usage: test-open-path.sh /path/to/open-path.sh}
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/home/.local/bin" "$ROOT/bin" "$ROOT/a b+C#%"

make_logger() {
  local path=$1 label=$2
  cat >"$path" <<EOF
#!/bin/bash
printf '%s\\t%s\\n' '$label' "\$1" >>'$ROOT/launches'
EOF
  chmod +x "$path"
}
make_logger "$ROOT/override" override
make_logger "$ROOT/bin/omafiles" path
make_logger "$ROOT/home/.local/bin/omafiles" fallback

HOME="$ROOT/home" OMAFILES_BIN="$ROOT/override" PATH="/usr/bin:/bin" \
  bash "$SCRIPT" "file://$ROOT/a%20b%2BC%23%25"
HOME="$ROOT/home" PATH="$ROOT/bin:/usr/bin:/bin" bash "$SCRIPT" ""
rm "$ROOT/bin/omafiles"
HOME="$ROOT/home" PATH="/usr/bin:/bin" bash "$SCRIPT" ""

grep -Fqx $'override\t'"$ROOT/a b+C#%" "$ROOT/launches"
grep -Fqx $'path\t' "$ROOT/launches"
grep -Fqx $'fallback\t' "$ROOT/launches"

if HOME="$ROOT/empty" OMAFILES_BIN="$ROOT/missing" PATH="/usr/bin:/bin" \
    bash "$SCRIPT" "" >"$ROOT/missing.out" 2>&1; then
  echo "missing executable unexpectedly succeeded" >&2
  exit 1
fi
grep -q 'executable not found' "$ROOT/missing.out"
echo "open-path resolution and URI decoding: PASS"

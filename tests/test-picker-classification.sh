#!/bin/bash
# Prove a JSON picker stays separate while the normal instance socket exists.
set -euo pipefail

BINARY=${1:?usage: test-picker-classification.sh /path/to/omafiles}
SOURCE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ROOT=$(mktemp -d)
server_pid=
cleanup() {
  [[ -z ${server_pid:-} ]] || kill "$server_pid" 2>/dev/null || true
  [[ -z ${server_pid:-} ]] || wait "$server_pid" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap cleanup EXIT
export XDG_RUNTIME_DIR="$ROOT/runtime"
mkdir -m 700 "$XDG_RUNTIME_DIR"
ready="$ROOT/ready"
"$BINARY" --test-instance-server "$ready" &
server_pid=$!
for _ in $(seq 1 100); do
  [[ -f $ready ]] && break
  sleep 0.02
done
[[ -f $ready ]]

payload='{"choices":[{"id":"encoding","label":"Encoding","options":[{"id":"utf8","label":"UTF-8"}],"selected":"utf8"}],"currentFilter":1,"files":[],"filters":[{"name":"Text","rules":[{"type":0,"value":"*.txt"}]},{"name":"Images","rules":[{"type":1,"value":"image/*"}]}],"folder":"/tmp","kind":"picker","mode":"open-file","multiple":false,"requestId":"/org/freedesktop/portal/desktop/request/1_2/test","suggestedName":""}'
"$BINARY" --test-picker-payload "$payload"
picker_output=$(OMAFILES_TEST_CLASSIFY_ONLY=1 QT_QPA_PLATFORM=offscreen "$BINARY" "$payload")
[[ $picker_output == picker-independent ]]

invalid_picker_payloads=(
  '{"kind":"picker","folder":"/tmp","requestId":"/request/test","mode":"open-file","multiple":false,"suggestedName":"","files":[]}'
  '{"choices":[],"currentFilter":1,"files":[],"filters":[],"folder":"/tmp","kind":"picker","mode":"open-file","multiple":false,"requestId":"/request/test","suggestedName":""}'
  '{"choices":[],"currentFilter":0,"files":[],"filters":[{"name":"Text","rules":[{"type":2,"value":"*.txt"}]}],"folder":"/tmp","kind":"picker","mode":"open-file","multiple":false,"requestId":"/request/test","suggestedName":""}'
  '{"choices":[{"id":"encoding","label":"Encoding","options":[{"id":"utf8","label":"UTF-8"}],"selected":"missing"}],"currentFilter":-1,"files":[],"filters":[],"folder":"/tmp","kind":"picker","mode":"open-file","multiple":false,"requestId":"/request/test","suggestedName":""}'
)
for invalid_payload in "${invalid_picker_payloads[@]}"; do
  ! "$BINARY" --test-picker-payload "$invalid_payload"
done

# If the picker had claimed or removed the socket, this normal delivery fails.
normal_output=$(OMAFILES_TEST_CLASSIFY_ONLY=1 QT_QPA_PLATFORM=offscreen "$BINARY" /tmp)
[[ $normal_output == normal-delivered ]]

# FileManager1 uses the normal socket, but only after strict native validation.
filemanager_payload='{"kind":"file-manager","action":"show-properties","folder":"/tmp","basenames":["item.txt"]}'
filemanager_output=$(OMAFILES_TEST_CLASSIFY_ONLY=1 QT_QPA_PLATFORM=offscreen \
  "$BINARY" "$filemanager_payload")
[[ $filemanager_output == normal-delivered ]]
"$BINARY" --test-file-manager-payload "$filemanager_payload"
invalid_filemanager_payloads=(
  '{"kind":"file-manager","action":"invalid","folder":"/tmp","basenames":["item.txt"]}'
  '{"kind":"file-manager","action":"show-items","folder":"relative","basenames":["item.txt"]}'
  '{"kind":"file-manager","action":"show-items","folder":"/tmp","basenames":["../item.txt"]}'
  '{"kind":"file-manager","action":"show-items","folder":"/tmp","basenames":[]}'
  '{"kind":"file-manager","action":"show-folders","folder":"/tmp","basenames":["item.txt"]}'
  '{"kind":"file-manager","action":"show-items","folder":"/tmp","basenames":["item.txt"],"extra":true}'
)
for invalid_payload in "${invalid_filemanager_payloads[@]}"; do
  ! "$BINARY" --test-file-manager-payload "$invalid_payload"
done

# Response code must use the in-process responder; picker navigation must not
# become normal session or window state after the visible request is cleared.
! grep -R -q 'Backend.Detached.run.*dbus\|"dbus-send"' \
  "$SOURCE_ROOT/core/OmafilesContent.qml" "$SOURCE_ROOT/core/MainLayout.qml" "$SOURCE_ROOT/core/FilePickerBar.qml"
grep -q 'if (!PickerState.sessionActive) registry.persistence.saveSession()' \
  "$SOURCE_ROOT/core/OmafilesContent.qml"
grep -q 'if (PickerState.sessionActive) return' "$SOURCE_ROOT/app/HostAdapter.qml"

echo "picker process classification and session safety: PASS"

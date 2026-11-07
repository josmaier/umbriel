#!/usr/bin/env bash
# harness: outputs=2
# A silent output move delivers the focused window to the other output's active workspace while keyboard focus, the
# active workspaces, and the pointer's output stay where they were. An emptied source clears keyboard focus.
set -euo pipefail

readonly CLIENT="${UMBRIEL_UNMAP_CLIENT:-./build-debug/tests/unmap-client}"
readonly POINTER="${UMBRIEL_POINTER_CLIENT:-./build-debug/tests/pointer-client}"

windows() { "$UMBRIEL" windows --json; }
workspaces() { "$UMBRIEL" workspaces --json; }
window_id() { windows | jq -r --arg title "$1" '.[] | select(.title == $title) | .id'; }
active_title() { windows | jq -r '[.[] | select(.active) | .title] | if length == 1 then .[0] else "none" end'; }

wait_for_count() {
  local want=$1
  for _ in $(seq 60); do
    [[ $(windows | jq 'length') -eq $want ]] && return 0
    sleep 0.05
  done
  echo "expected $want windows, got: $(windows)"
  return 1
}

accepts() {
  local out
  out=$("$UMBRIEL" msg "$@" 2>&1) || { echo "expected '$*' to be accepted, got: $out"; exit 1; }
  "$UMBRIEL" settle
}

expect_window() {
  local title=$1 output=$2
  windows | jq -e --arg title "$title" --arg output "$output" \
    '.[] | select(.title == $title) | .output == $output and .visible' > /dev/null \
    || { echo "expected $title visible on $output: $(windows)"; exit 1; }
}

expect_active() {
  [[ $(active_title) == "$1" ]] || { echo "expected '$1' to be active: $(windows)"; exit 1; }
}

# The focused workspace is the active one on the pointer's output, so an unchanged selection also proves the pointer
# stayed put.
selection_state() { workspaces | jq -c '[.[] | select(.active or .focused) | {id, output, active, focused}] | sort_by(.output)'; }
expect_unmoved_selection() {
  local now
  now=$(selection_state)
  [[ $now == "$selection" ]] || { echo "workspace selection changed from $selection to $now"; exit 1; }
}

cat >> "$UMBRIEL_CONFIG" <<'EOF'

[animation]
enabled = false

[output.HEADLESS-1]
position = [0, 0]

[output.HEADLESS-2]
position = [1280, 0]

[[window_rule]]
match.title = "^silent-(keep|mover)$"
default_output = "HEADLESS-1"

[[window_rule]]
match.title = "^silent-resident$"
default_output = "HEADLESS-2"
EOF
"$UMBRIEL" msg config-reload > /dev/null

count=0
for title in silent-keep silent-mover silent-resident; do
  "$CLIENT" "$title" 400 300 > "$UMBRIEL_RUNTIME_DIR/$title.log" 2>&1 &
  count=$((count + 1))
  wait_for_count "$count"
done
"$UMBRIEL" settle

"$POINTER" 2560 720 move 640 360
accepts window-focus "$(window_id silent-mover)"
expect_active silent-mover
workspaces | jq -e 'any(.[]; .focused and .output == "HEADLESS-1")' > /dev/null \
  || { echo "the pointer's output should hold the focused workspace: $(workspaces)"; exit 1; }
selection=$(selection_state)

# The window lands on the other output, but focus passes to the window left behind instead of following it.
accepts window-move-to-output-silent-right
expect_window silent-mover HEADLESS-2
expect_active silent-keep
expect_unmoved_selection

# The cycling form shares the rule. Moving the last window away leaves the source empty and nothing focused.
accepts window-move-to-output-silent-next
expect_window silent-keep HEADLESS-2
expect_active none
expect_unmoved_selection

# The plain move still follows the window, focus and pointer included, so the difference is the silent flag and not
# the destination. Directional output moves resolve from the pointer's output, which the silent moves left behind.
"$POINTER" 2560 720 move 1920 360
accepts window-focus "$(window_id silent-keep)"
accepts window-move-to-output-left
expect_window silent-keep HEADLESS-1
expect_active silent-keep
workspaces | jq -e 'any(.[]; .focused and .output == "HEADLESS-1")' > /dev/null \
  || { echo "the followed move should bring the pointer back to HEADLESS-1: $(workspaces)"; exit 1; }

echo "silent output moves delivered the window without moving focus, workspaces, or the pointer"

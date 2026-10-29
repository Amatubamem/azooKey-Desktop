#!/bin/bash
# Compare WindowServer/azooKey idle load while creating and closing Chrome input tabs.
# macOS only. Chrome Apple Events and System Events Accessibility permissions may be required.
# A real GUI click is essential: a new tab alone need not create an IMK session.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
for command_name in osascript swift vmmap ps awk pgrep; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing command: $command_name" >&2
    exit 1
  fi
done
if [[ ! -f "$repo_root/Tools/window-lifecycle-snapshot.swift" ]]; then
  echo "Run this script from the diagnostics/window-lifecycle-348 branch." >&2
  exit 1
fi

settle_seconds="${SETTLE_SECONDS:-60}"
duration_seconds="${DURATION_SECONDS:-60}"
interval_seconds="${INTERVAL_SECONDS:-2}"
read -r -a tab_steps <<< "${TAB_STEPS:-5 10 20}"
for value in "$settle_seconds" "$duration_seconds" "$interval_seconds" "${tab_steps[@]}"; do
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "Timing values and tab steps must be nonnegative integers." >&2
    exit 1
  fi
done
if (( interval_seconds == 0 || duration_seconds == 0 || ${#tab_steps[@]} == 0 )); then
  echo "Interval, duration, and tab steps must be positive." >&2
  exit 1
fi
previous_count=0
for count in "${tab_steps[@]}"; do
  if (( count <= previous_count )); then
    echo "TAB_STEPS must be strictly increasing (example: '5 10 20')." >&2
    exit 1
  fi
  previous_count=$count
done

ws_pid="$(pgrep -x WindowServer | head -n 1)"
ime_pid="$(pgrep -x azooKeyMac | head -n 1)"
if [[ -z "$ws_pid" || -z "$ime_pid" ]]; then
  echo "WindowServer and azooKeyMac must both be running." >&2
  exit 1
fi

output_dir="$(mktemp -d "${TMPDIR:-/tmp}/azookey-windowserver.XXXXXXXX")"
control_script="$output_dir/chrome-control.applescript"
seed_html="$output_dir/baseline.html"
test_html="$output_dir/input.html"
seed_url="file://$seed_html"
test_url="file://$test_html"

cat > "$seed_html" <<'HTML'
<!doctype html><html lang="ja"><meta charset="utf-8"><title>azooKey benchmark baseline</title>
<body>Baseline tab (no text input).</body></html>
HTML
cat > "$test_html" <<'HTML'
<!doctype html><html lang="ja"><meta charset="utf-8"><title>azooKey benchmark input</title>
<style>html,body{margin:0;width:100%;height:100%;overflow:hidden}
textarea{box-sizing:border-box;display:block;width:100vw;height:100vh;border:0;resize:none;font-size:16px}</style>
<body><textarea id="input" aria-label="Input session benchmark"></textarea></body></html>
HTML

cat > "$control_script" <<'APPLESCRIPT'
on run argv
    set commandName to item 1 of argv
    tell application "Google Chrome"
        if commandName is "create" then
            set seedURL to item 2 of argv
            activate
            set testWindow to make new window
            set URL of active tab of testWindow to seedURL
            return (id of testWindow) as text
        end if

        set targetID to (item 2 of argv) as integer
        set testWindow to first window whose id is targetID

        if commandName is "add" then
            set testURL to item 3 of argv
            activate
            set index of testWindow to 1
            tell testWindow
                make new tab at end of tabs with properties {URL:testURL}
                set active tab index to count of tabs
            end tell
            delay 0.8
            my clickInput(testWindow)
            return (count of tabs of testWindow) as text
        else if commandName is "focus" then
            my clickInput(testWindow)
            return "clicked"
        else if commandName is "close" then
            set seedURL to item 3 of argv
            -- Close only a window still marked as belonging to this run.
            if (URL of tab 1 of testWindow) is seedURL then
                close testWindow
                return "closed"
            else
                error "The benchmark window was modified; it has not been closed."
            end if
        end if
        error "Unknown benchmark command."
    end tell
end run

-- Chrome's bounds use the global top-left screen coordinate system.
-- The test textarea fills the content viewport, so a click at the window's
-- centre targets the input area in an ordinary, unobstructed Chrome window.
on clickInput(testWindow)
    tell application "Google Chrome"
        activate
        set index of testWindow to 1
        set {leftEdge, topEdge, rightEdge, bottomEdge} to bounds of testWindow
    end tell
    if (rightEdge - leftEdge) < 350 or (bottomEdge - topEdge) < 320 then
        error "The Chrome benchmark window is too small for reliable input clicking."
    end if
    set clickX to (leftEdge + rightEdge) div 2
    set clickY to (topEdge + bottomEdge) div 2
    tell application "System Events"
        tell process "Google Chrome"
            set frontmost to true
            click at {clickX, clickY}
        end tell
    end tell
end clickInput
APPLESCRIPT

test_window_id=""
cleanup() {
  if [[ -n "$test_window_id" ]]; then
    osascript "$control_script" close "$test_window_id" "$seed_url" >/dev/null 2>&1 ||
      echo "Could not close the test Chrome window automatically; check its contents." >&2
  fi
}
trap cleanup EXIT

echo "Output directory: $output_dir"
echo "Only a dedicated Chrome window is modified; existing windows are left intact."
echo "The active macOS input source must be azooKey before starting."
echo "Chrome Automation / System Events Accessibility permissions may be requested."
echo "Each input tab is physically clicked; the azooKey window count is validated."
test_window_id="$(osascript "$control_script" create "$seed_url" | tr -d '[:space:]')"
if ! [[ "$test_window_id" =~ ^[0-9]+$ ]]; then
  echo "Could not get the test Chrome window ID: $test_window_id" >&2
  exit 1
fi

metrics="$output_dir/metrics.csv"
printf 'phase,timestamp,process,pid,cpu_percent,rss_kib\n' > "$metrics"
printf 'phase,added_tabs,window_count\n' > "$output_dir/phases.csv"

snapshot() {
  local phase="$1" when="$2"
  swift "$repo_root/Tools/window-lifecycle-snapshot.swift" "$ime_pid" --ids \
    > "$output_dir/windows-${phase}-${when}.txt"
}

# Count actual azooKey windows, not Chrome tabs. Failed focus must not be
# recorded as a successful input-session increase.
window_count() {
  swift "$repo_root/Tools/window-lifecycle-snapshot.swift" "$ime_pid" |
    sed -n '1s/.* windows=\([0-9][0-9]*\).*/\1/p'
}

measure() {
  local phase="$1"
  local samples=$(( (duration_seconds + interval_seconds - 1) / interval_seconds ))
  echo "[$phase] settling for $settle_seconds seconds..."
  sleep "$settle_seconds"
  snapshot "$phase" before
  echo "[$phase] measuring for approximately $((samples * interval_seconds)) seconds..."
  for ((i = 0; i < samples; i++)); do
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for target in "WindowServer:$ws_pid" "azooKey:$ime_pid"; do
      local name="${target%%:*}" pid="${target##*:}"
      ps -p "$pid" -o %cpu=,rss= |
        awk -v phase="$phase" -v time="$timestamp" -v name="$name" -v pid="$pid" \
          'NF >= 2 { print phase "," time "," name "," pid "," $1 "," $2 }' >> "$metrics"
    done
    sleep "$interval_seconds"
  done
  snapshot "$phase" after
  vmmap -summary "$ime_pid" > "$output_dir/vmmap-${phase}.txt"
  local windows
  windows="$(sed -n 's/.* windows=\([0-9][0-9]*\).*/\1/p' "$output_dir/windows-${phase}-after.txt" | head -n 1)"
  printf '%s,%s,%s\n' "$phase" "$added_tabs" "$windows" >> "$output_dir/phases.csv"
  echo "[$phase] azooKey windows: ${windows:-unknown}"
}

added_tabs=0
measure tabs_0
previous_windows="$(window_count)"

for count in "${tab_steps[@]}"; do
  additions=$((count - added_tabs))
  echo "Creating and clicking $additions input tabs (total $count)..."
  for ((tab = 0; tab < additions; tab++)); do
    # Use a unique fragment to keep each test tab distinguishable.
    tab_url="${test_url}#session-$((added_tabs + tab + 1))"
    osascript "$control_script" add "$test_window_id" "$tab_url" >/dev/null
    sleep 1
    after_windows="$(window_count)"
    if (( after_windows <= previous_windows )); then
      echo "No new azooKey window detected; retrying the input click..."
      osascript "$control_script" focus "$test_window_id" >/dev/null
      sleep 1
      after_windows="$(window_count)"
    fi
    if (( after_windows <= previous_windows )); then
      echo "ERROR: Input click produced no additional azooKey windows." >&2
      echo "Check that azooKey is the active input source and Chrome's" >&2
      echo "Automation/Accessibility permissions allow clicking." >&2
      echo "The run is aborted rather than reporting invalid measurements." >&2
      exit 1
    fi
    delta=$((after_windows - previous_windows))
    if (( delta != 4 )); then
      echo "WARNING: The input click added $delta windows, not the expected 4."
    fi
    echo "  input tab $((added_tabs + tab + 1)): $previous_windows -> $after_windows windows"
    previous_windows=$after_windows
  done
  added_tabs=$count
  measure "tabs_$count"
  previous_windows="$(window_count)"
done

echo "Closing the dedicated Chrome window..."
osascript "$control_script" close "$test_window_id" "$seed_url" >/dev/null
test_window_id=""
added_tabs=0
measure tabs_closed

echo "Completed. Data:"
echo "  $metrics"
echo "  $output_dir/phases.csv"
echo "  $output_dir/windows-*.txt"
echo "  $output_dir/vmmap-*.txt"

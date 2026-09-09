#!/bin/sh
# Runs every test in a throwaway TT_HOME. Usage: sh tests/run.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
TT="$REPO/bin/tt"
TT_HOOK="$REPO/bin/tt-hook"
. "$HERE/lib.sh"

SANDBOX=${TMPDIR:-/tmp}/tt-test-$$
mkdir -p "$SANDBOX/home" "$SANDBOX/root/sportx/saas-backend" "$SANDBOX/root/sportx/a,b" "$SANDBOX/root/tuurny"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

TT_HOME="$SANDBOX/home"
TT_ROOT="$SANDBOX/root"
export TT_HOME TT_ROOT

# Harness detection is asserted below, so the ambient harness must not leak in.
unset CLAUDECODE CLAUDE_PLUGIN_ROOT PLUGIN_ROOT CODEX_HOME
unset TT_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
unset TT_READING_WPM TT_MAX_READING_TIME TT_MAX_ACTIVE_GAP

printf 'Task 1: skeleton\n'
assert_status 2 'unknown subcommand exits 2' -- sh "$TT" nonsense
assert_eq "$TT_HOME" "$(sh "$TT" debug-home)" 'TT_HOME override honoured'
assert_eq "1900000000" "$(TT_NOW=1900000000 sh "$TT" debug-now)" 'TT_NOW override honoured'
assert_eq "testbox" "$(printf 'machine=testbox\n' > "$TT_HOME/config"; sh "$TT" debug-machine)" 'machine from config'
rm -f "$TT_HOME/config"
REPORT_HELP=$(sh "$TT" report --help)
assert_contains "$REPORT_HELP" "yesterday" 'report help lists the yesterday period'
assert_contains "$REPORT_HELP" "--since YYYY-MM-DD" 'report help explains the lower date bound'
assert_contains "$REPORT_HELP" "--by project|day" 'report help lists grouping values'
assert_contains "$(sh "$TT" help report)" "--until YYYY-MM-DD" 'help report opens report-specific help'
assert_status 1 'report rejects an unknown grouping value' -- sh "$TT" report --by machine

printf 'Task 2: attribution and mode\n'
assert_eq "sportx	." "$(sh "$TT" debug-attribute "$TT_ROOT/sportx")" 'project root gives subpath .'
assert_eq "sportx	saas-backend" "$(sh "$TT" debug-attribute "$TT_ROOT/sportx/saas-backend")" 'nested gives subpath'
assert_eq "~outside	/etc" "$(sh "$TT" debug-attribute /etc)" 'outside root attributes to ~outside'
assert_eq "sportx	." "$(sh "$TT" debug-attribute "$TT_ROOT/sportx/")" 'trailing slash tolerated'
assert_eq "~root	." "$(sh "$TT" debug-attribute "$TT_ROOT")" 'the workspace root itself attributes to ~root'

# A root written with a trailing slash must not compare against a doubled one.
assert_eq "$TT_ROOT" "$(TT_ROOT="$TT_ROOT/" sh "$TT" debug-root)" 'a trailing slash on TT_ROOT is stripped'
assert_eq "$TT_ROOT" "$(sh "$TT" root)" 'the configured project root has a public read-only command'
assert_eq "$TT_ROOT" "$(TT_ROOT="$TT_ROOT///" sh "$TT" debug-root)" 'several trailing slashes are stripped'
assert_eq "sportx	." "$(TT_ROOT="$TT_ROOT/" sh "$TT" debug-attribute "$TT_ROOT/sportx")" 'a trailing slash on TT_ROOT still attributes the project'
assert_eq "~root	." "$(TT_ROOT="$TT_ROOT/" sh "$TT" debug-attribute "$TT_ROOT")" 'a trailing slash on TT_ROOT still attributes the root itself'
printf 'TT_ROOT=%s/\n' "$TT_ROOT" > "$TT_HOME/config"
assert_eq "sportx	." "$(HOME="$SANDBOX" TT_ROOT="$SANDBOX/workspace" sh "$TT" debug-attribute "$TT_ROOT/sportx")" 'a trailing slash in the config file is stripped too'
rm -f "$TT_HOME/config"

assert_eq "paired" "$(sh "$TT" debug-mode "$TT_ROOT/sportx")" 'default mode is paired'
sh "$TT" solo "$TT_ROOT/sportx" >/dev/null
assert_eq "solo" "$(sh "$TT" debug-mode "$TT_ROOT/sportx")" 'solo is recorded'
assert_eq "solo" "$(sh "$TT" debug-mode "$TT_ROOT/sportx/saas-backend")" 'a project mode reaches its nested directories'
assert_eq "paired" "$(sh "$TT" debug-mode "$TT_ROOT/tuurny")" 'sibling directory is unaffected'
sh "$TT" paired "$TT_ROOT/sportx" >/dev/null
assert_eq "paired" "$(sh "$TT" debug-mode "$TT_ROOT/sportx")" 'paired is recorded'
assert_eq "paired" "$(sh "$TT" debug-mode "$TT_ROOT/sportx/saas-backend")" 'a later project transition reaches nested directories'

sh "$TT" solo "$TT_ROOT/sportx/saas-backend" >/dev/null
assert_contains "$(sh "$TT" sessions)" "solo" 'sessions lists the mode'
assert_contains "$(sh "$TT" sessions)" "$TT_ROOT/sportx/saas-backend" 'sessions lists the true path'
sh "$TT" paired "$TT_ROOT/sportx/saas-backend" >/dev/null

# Two directories whose paths differ only where a path separator meets an
# underscore. Any scheme that encodes a path into a single file name maps both
# to one name, so each must be able to hold its own mode independently.
mkdir -p "$TT_ROOT/coll/x" "$TT_ROOT/coll_x"
sh "$TT" solo "$TT_ROOT/coll/x" >/dev/null
assert_eq "paired" "$(sh "$TT" debug-mode "$TT_ROOT/coll_x")" 'setting one of two colliding paths leaves the other alone'
sh "$TT" paired "$TT_ROOT/coll_x" >/dev/null
assert_eq "solo" "$(sh "$TT" debug-mode "$TT_ROOT/coll/x")" 'colliding paths hold different modes at once'
assert_eq "2" "$(sh "$TT" sessions | grep -c 'coll')" 'both colliding paths are listed'
sh "$TT" paired "$TT_ROOT/coll/x" >/dev/null

# One shared file is read, rewritten and moved into place, so simultaneous sets
# on distinct paths must not overwrite one another.
i=1
while [ "$i" -le 20 ]; do
  sh "$TT" solo "$TT_ROOT/conc$i" >/dev/null 2>&1 &
  i=$((i + 1))
done
wait
assert_eq "20" "$(sh "$TT" sessions | grep -c '/conc')" 'twenty simultaneous sets on distinct paths all survive'
assert_eq "" "$(ls -d "$TT_HOME/modes.lock" 2>/dev/null)" 'the lock is released once the set finishes'

# A path holding a TAB or a newline cannot be stored and read back as itself:
# the TAB separates the two fields and the newline separates the rows. Refused
# at the door, because a store that silently disagrees with itself is worse.
TABPATH=$(printf '%s/tab\there' "$TT_ROOT")
NLPATH=$(printf '%s/nl\nphantom' "$TT_ROOT")
assert_status 1 'a path holding a tab is refused' -- sh "$TT" solo "$TABPATH"
assert_status 1 'a path holding a newline is refused' -- sh "$TT" solo "$NLPATH"
assert_eq "0" "$(sh "$TT" sessions | grep -cE 'tab|phantom')" 'a refused path writes nothing'
assert_eq "paired" "$(sh "$TT" debug-mode "$TABPATH")" 'a tab-bearing path reads as paired rather than failing'
assert_eq "paired" "$(sh "$TT" debug-mode "$NLPATH")" 'a newline-bearing path reads as paired rather than failing'
assert_eq "paired" "$(sh "$TT" debug-mode "$TT_ROOT/nl")" 'a refused newline path fabricates no entry for another path'

# Setting a mode twice replaces the line rather than adding a second one.
sh "$TT" solo "$TT_ROOT/tuurny" >/dev/null
sh "$TT" paired "$TT_ROOT/tuurny" >/dev/null
assert_eq "1" "$(sh "$TT" sessions | grep -c 'tuurny')" 'a repeated set replaces its line'
assert_eq "paired" "$(sh "$TT" debug-mode "$TT_ROOT/tuurny")" 'the replacement is what reads back'

# A session-specific transition narrows a subtree mode without changing another
# active session in the same directory.
sh "$TT" solo "$TT_ROOT/sportx" --session session-one >/dev/null
assert_eq "solo" "$(sh "$TT" debug-mode "$TT_ROOT/sportx/saas-backend" session-one)" 'a session-specific mode reaches that session below the path'
assert_eq "paired" "$(sh "$TT" debug-mode "$TT_ROOT/sportx/saas-backend" session-two)" 'a session-specific mode leaves a peer session alone'
assert_contains "$(sh "$TT" sessions)" "session-one" 'sessions identifies a narrowed mode'
sh "$TT" paired "$TT_ROOT/sportx" --session session-one >/dev/null

# An in-session shell command carries its harness session id, while an external
# terminal with no such environment remains path-wide.
CODEX_SESSION_ID=automatic-session sh "$TT" solo "$TT_ROOT/tuurny" >/dev/null
assert_eq "solo" "$(sh "$TT" debug-mode "$TT_ROOT/tuurny" automatic-session)" 'an in-session command automatically narrows to its Codex session'
assert_eq "paired" "$(sh "$TT" debug-mode "$TT_ROOT/tuurny" another-session)" 'automatic session scope does not affect a peer'
CODEX_SESSION_ID=automatic-session sh "$TT" paired "$TT_ROOT/tuurny" >/dev/null
CODEX_SESSION_ID=automatic-session sh "$TT" solo "$TT_ROOT/tuurny" --all-sessions >/dev/null
assert_eq "solo" "$(sh "$TT" debug-mode "$TT_ROOT/tuurny" another-session)" '--all-sessions overrides in-session narrowing'
CODEX_SESSION_ID=automatic-session sh "$TT" paired "$TT_ROOT/tuurny" --all-sessions >/dev/null

printf 'Task 3: hook capture\n'
MACHINE=$(sh "$TT" debug-machine)
COMPACT="$TT_HOME/events-$MACHINE.tsv"
LOG="$TT_HOME/current-$MACHINE.tsv"
clear_logs() { : > "$COMPACT"; : > "$LOG"; }
clear_logs

HOOKJSON='{"session_id":"abc123","transcript_path":"/x/y.jsonl","cwd":"'"$TT_ROOT"'/sportx/saas-backend","hook_event_name":"PreToolUse"}'
assert_eq "yes" "$([ -f "$TT_HOOK" ] && printf yes)" 'standalone hook entry point exists'
assert_status 0 'standalone hook entry point is executable' -- test -x "$TT_HOOK"
printf '%s' "$HOOKJSON" | TT_NOW=1900000000 CLAUDE_PLUGIN_ROOT=/p sh "$TT_HOOK"
assert_eq "1" "$(wc -l < "$LOG" | tr -d ' ')" 'one beat appended'
assert_eq "20" "$(awk -F '\t' '{ print NF }' "$LOG")" 'standalone hook appends a 20-column beat'
assert_eq "beat" "$(cut -f2 < "$LOG")" 'kind is beat'
assert_eq "1900000000" "$(cut -f3 < "$LOG")" 'start is the current epoch'
assert_eq "1900000000" "$(cut -f4 < "$LOG")" 'end equals start for a beat'
assert_eq "claude" "$(cut -f6 < "$LOG")" 'harness detected from CLAUDE_PLUGIN_ROOT'
assert_eq "-" "$(cut -f7 < "$LOG")" 'beats leave the unused mode column empty'
assert_eq "sportx" "$(cut -f8 < "$LOG")" 'project from cwd'
assert_eq "saas-backend" "$(cut -f9 < "$LOG")" 'subpath from cwd'
assert_eq "abc123" "$(cut -f10 < "$LOG")" 'session id captured'

clear_logs
printf '%s' "$HOOKJSON" | TT_NOW=1900000001 PLUGIN_ROOT=/p sh "$TT_HOOK"
assert_eq "codex" "$(cut -f6 < "$LOG")" 'harness detected from PLUGIN_ROOT'

clear_logs
sh "$TT" solo "$TT_ROOT/sportx/saas-backend" >/dev/null
printf '%s' "$HOOKJSON" | TT_NOW=1900000002 sh "$TT_HOOK"
# The mode cache remains available to CLI inspection after hook capture.
assert_eq "solo" "$(sh "$TT" debug-mode "$TT_ROOT/sportx/saas-backend" abc123)" \
  'the explicit mode remains available through the CLI cache'
sh "$TT" paired "$TT_ROOT/sportx/saas-backend" >/dev/null

clear_logs
assert_status 0 'malformed stdin still exits 0' -- sh -c "printf 'not json' | TT_HOME='$TT_HOME' TT_ROOT='$TT_ROOT' sh '$TT_HOOK'"
assert_eq "1" "$(wc -l < "$LOG" | tr -d ' ')" 'malformed input still records a beat'

clear_logs
assert_status 0 'empty stdin still exits 0' -- sh -c "printf '' | TT_HOME='$TT_HOME' TT_ROOT='$TT_ROOT' sh '$TT_HOOK'"
assert_status 0 'standalone hook contains an unwritable home failure' -- sh -c "printf '%s' '$HOOKJSON' | TT_HOME=/dev/null TT_ROOT='$TT_ROOT' sh '$TT_HOOK'"
assert_status 0 'tt hook forwards to the standalone entry point' -- sh -c "printf '%s' '$HOOKJSON' | TT_HOME='$TT_HOME' TT_ROOT='$TT_ROOT' sh '$TT' hook"

clear_logs
COMMAJSON='{"session_id":"abc123","cwd":"'"$TT_ROOT"'/sportx/a,b","hook_event_name":"PreToolUse"}'
printf '%s' "$COMMAJSON" | TT_NOW=1900000003 sh "$TT_HOOK"
assert_eq "a,b" "$(cut -f9 < "$LOG")" 'a comma in cwd does not break attribution'

clear_logs
DECOYJSON='{"tool_input":{"cwd":"/decoy","command":"ls"},"session_id":"abc123","cwd":"'"$TT_ROOT"'/sportx/saas-backend","hook_event_name":"PreToolUse"}'
printf '%s' "$DECOYJSON" | TT_NOW=1900000004 sh "$TT_HOOK"
assert_eq "saas-backend" "$(cut -f9 < "$LOG")" 'a cwd inside tool_input does not outrank the top-level cwd'

clear_logs
ESCJSON='{"session_id":"abc123","cwd":"'"$TT_ROOT"'/sportx/a\"b","hook_event_name":"PreToolUse"}'
printf '%s' "$ESCJSON" | TT_NOW=1900000005 sh "$TT_HOOK"
assert_eq 'a\"b' "$(cut -f9 < "$LOG")" 'an escaped quote in cwd does not truncate the value'

clear_logs
EXTJSON='{"session_id":"abc123","cwd":"'"$TT_ROOT"'/sportx/saas-backend","hook_event_name":"SubagentStart","turn_id":"turn-7","tool_use_id":"tool-8","agent_id":"agent-9","agent_type":"worker"}'
printf '%s' "$EXTJSON" | TT_NOW=1900000006 PLUGIN_ROOT=/p sh "$TT_HOOK"
assert_eq "20" "$(awk -F '\t' '{ print NF }' "$LOG")" 'new beats append six lifecycle fields plus tool name and prompt classification'
assert_eq "turn-7" "$(cut -f12 < "$LOG")" 'turn id captured'
assert_eq "tool-8" "$(cut -f13 < "$LOG")" 'tool id captured'
assert_eq "agent-9" "$(cut -f14 < "$LOG")" 'subagent id captured'
assert_eq "worker" "$(cut -f15 < "$LOG")" 'subagent type captured'
assert_eq "-" "$(cut -f17 < "$LOG")" 'an unrelated event has no session-start source'

clear_logs
STARTJSON='{"session_id":"abc123","cwd":"'"$TT_ROOT"'/sportx/saas-backend","hook_event_name":"SessionStart","source":"compact"}'
printf '%s' "$STARTJSON" | TT_NOW=1900000010 PLUGIN_ROOT=/p sh "$TT_HOOK"
assert_eq "compact" "$(cut -f17 < "$LOG")" 'a Codex SessionStart source is captured'

clear_logs
PROMPTIDJSON='{"session_id":"abc123","cwd":"'"$TT_ROOT"'/sportx/saas-backend","hook_event_name":"PreToolUse","prompt_id":"prompt-9","tool_use_id":"tool-9"}'
printf '%s' "$PROMPTIDJSON" | TT_NOW=1900000011 CLAUDE_PLUGIN_ROOT=/p sh "$TT_HOOK"
assert_eq "prompt-9" "$(cut -f12 < "$LOG")" 'a Claude prompt_id fills the turn column'
assert_eq "tool-9" "$(cut -f13 < "$LOG")" 'a Claude tool_use_id fills the tool column'

clear_logs
BOTHIDJSON='{"session_id":"abc123","cwd":"'"$TT_ROOT"'/sportx/saas-backend","hook_event_name":"PreToolUse","turn_id":"turn-9","prompt_id":"prompt-9"}'
printf '%s' "$BOTHIDJSON" | TT_NOW=1900000012 PLUGIN_ROOT=/p sh "$TT_HOOK"
assert_eq "turn-9" "$(cut -f12 < "$LOG")" 'turn_id outranks prompt_id when a harness sends both'

clear_logs
STOPJSON='{"session_id":"abc123","cwd":"'"$TT_ROOT"'/sportx/saas-backend","hook_event_name":"Stop","turn_id":"turn-7","last_assistant_message":"one two\\nthree four five"}'
printf '%s' "$STOPJSON" | TT_NOW=1900000007 PLUGIN_ROOT=/p sh "$TT_HOOK"
assert_eq "5" "$(cut -f16 < "$LOG")" 'Stop stores the assistant output word count'
assert_eq "0" "$(grep -c 'one two' "$LOG")" 'Stop never stores raw assistant output'

clear_logs
TT_NOW=1900000007 sh "$TT" solo "$TT_ROOT/sportx/saas-backend" --session abc123 >/dev/null
assert_eq "mode" "$(cut -f2 < "$LOG")" 'an explicit mode change is recorded as an event'
assert_eq "solo" "$(cut -f7 < "$LOG")" 'a mode event records the selected mode'
assert_eq "abc123" "$(cut -f10 < "$LOG")" 'a mode event can target one session'
clear_logs
PROMPTJSON='{"session_id":"abc123","cwd":"'"$TT_ROOT"'/sportx/saas-backend","hook_event_name":"UserPromptSubmit","turn_id":"turn-8"}'
printf '%s' "$PROMPTJSON" | TT_NOW=1900000008 PLUGIN_ROOT=/p sh "$TT_HOOK"
assert_eq "-" "$(cut -f7 < "$LOG")" 'a prompt leaves mode resolution to explicit transitions'
assert_eq "solo" "$(sh "$TT" debug-mode "$TT_ROOT/sportx/saas-backend" abc123)" 'solo remains sticky until an explicit paired signal'
TT_NOW=1900000009 sh "$TT" paired "$TT_ROOT/sportx/saas-backend" --session abc123 >/dev/null

clear_logs
NULLSTOP='{"session_id":"abc123","cwd":"'"$TT_ROOT"'/sportx/saas-backend","hook_event_name":"Stop","turn_id":"turn-8","last_assistant_message":null}'
printf '%s' "$NULLSTOP" | TT_NOW=1900000009 PLUGIN_ROOT=/p sh "$TT_HOOK"
assert_eq "-" "$(cut -f16 < "$LOG")" 'a null assistant message records no word estimate'

# Concurrent explicit writes remain valid and the last completed transition is
# visible to subsequent hooks.
clear_logs
TT_NOW=1900000010 sh "$TT" solo "$TT_ROOT/sportx/saas-backend" >/dev/null &
MODE_ONE_PID=$!
TT_NOW=1900000011 sh "$TT" paired "$TT_ROOT/tuurny" >/dev/null &
MODE_TWO_PID=$!
wait "$MODE_ONE_PID" "$MODE_TWO_PID"
assert_eq "2" "$(awk -F '\t' '$2 == "mode" { n++ } END { print n + 0 }' "$LOG")" 'concurrent explicit transitions are both durable'
assert_eq "1" "$(awk -F '\t' -v path="$TT_ROOT/sportx/saas-backend" \
  '$2 == path && $3 == "-" { n++ } END { print n + 0 }' "$TT_HOME/modes")" \
  'concurrent transitions leave one valid all-session row per path'
sh "$TT" paired "$TT_ROOT/sportx/saas-backend" >/dev/null

assert_status 0 'an internal hook formatting failure is contained' -- \
  sh -c "printf '%s' '$PROMPTJSON' | TT_HOME='$TT_HOME' TT_ROOT='$TT_ROOT' TT_NOW=bad PLUGIN_ROOT=/p sh '$TT_HOOK'"

printf 'Task 4: manual entries\n'
assert_eq "5400" "$(sh "$TT" debug-seconds 90m)" '90m parses'
assert_eq "5400" "$(sh "$TT" debug-seconds 1.5h)" '1.5h parses'
assert_eq "9000" "$(sh "$TT" debug-seconds 2h30m)" '2h30m parses'
assert_eq "2700" "$(sh "$TT" debug-seconds 45)" 'bare number is minutes'
assert_status 1 'garbage duration is rejected' -- sh "$TT" debug-seconds banana

clear_logs
TT_NOW=1900000000 sh "$TT" add sportx 90m "architecture call" >/dev/null
assert_eq "span" "$(cut -f2 < "$LOG")" 'kind is span'
assert_eq "1899994600" "$(cut -f3 < "$LOG")" 'span starts one duration before now'
assert_eq "1900000000" "$(cut -f4 < "$LOG")" 'span ends now'
assert_eq "manual" "$(cut -f7 < "$LOG")" 'mode is manual'
assert_eq "sportx" "$(cut -f8 < "$LOG")" 'project recorded'
assert_eq "architecture call" "$(cut -f11 < "$LOG")" 'note recorded'
assert_eq "-" "$(cut -f10 < "$LOG")" 'no session id for a span'

clear_logs
AT_START=$(sh "$TT" debug-epoch '2026-09-01 14:00')
TT_NOW=$((AT_START + 7200)) sh "$TT" add tuurny 2h --at '2026-09-01 14:00' >/dev/null
assert_eq "$AT_START" "$(cut -f3 < "$LOG")" '--at sets the start'
assert_eq "$((AT_START + 7200))" "$(cut -f4 < "$LOG")" '--at plus duration sets the end'

assert_contains "$(clear_logs; TT_NOW=1900000000 sh "$TT" add sportx 30m)" "sportx" 'the written row is echoed'

printf 'Task 5: reporting\n'
TT_LIB="$REPO/lib"; export TT_LIB
clear_logs
M=$(sh "$TT" debug-machine)
beat() { # epoch mode project subpath session
  printf '%s\tbeat\t%s\t%s\t%s\tclaude\t%s\t%s\t%s\t%s\t-\n' \
    "$(sh "$TT" debug-iso "$1")" "$1" "$1" "$M" "$2" "$3" "$4" "$5" >> "$LOG"
}

beatx() { # epoch mode project subpath session event turn tool agent agent_type words [session_source]
  printf '%s\tbeat\t%s\t%s\t%s\tcodex\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(sh "$TT" debug-iso "$1")" "$1" "$1" "$M" "$2" "$3" "$4" "$5" \
    "$6" "$7" "$8" "$9" "${10}" "${11}" "${12:--}" >> "$LOG"
}

mode_event() { # epoch mode project subpath [session]
  printf '%s\tmode\t%s\t%s\t%s\t-\t%s\t%s\t%s\t%s\t-\n' \
    "$(sh "$TT" debug-iso "$1")" "$1" "$1" "$M" "$2" "$3" "$4" "${5:--}" >> "$LOG"
}

report_cell() { # row column-pair-number; reads a report on stdin
  awk -v row="$1" -v pair="$2" '$1 == row { i = pair * 2; print $i " " $(i + 1); exit }'
}

# Report ordering, manual-span output, --detail, and the empty-log exit status
# are exercised end to end in tests/python/test_cli.py. Keeping those fixtures
# there avoids paying the shell suite's setup cost for behavior owned by the
# Python reporting path.

printf 'Task 7: range clipping and day boundaries\n'

# Yesterday is a complete previous local day, not a trailing 24-hour window.
clear_logs
YESTERDAY_AT=$(TZ=UTC sh "$TT" debug-epoch '2026-09-02 10:00')
TODAY_AT=$(TZ=UTC sh "$TT" debug-epoch '2026-09-03 10:00')
REPORT_NOW=$(TZ=UTC sh "$TT" debug-epoch '2026-09-03 12:00')
printf '%s\tspan\t%s\t%s\t%s\t-\tmanual\tsportx\t.\t-\tyesterday\n' \
  "$(TZ=UTC sh "$TT" debug-iso "$YESTERDAY_AT")" "$YESTERDAY_AT" "$((YESTERDAY_AT + 3600))" "$M" >> "$LOG"
printf '%s\tspan\t%s\t%s\t%s\t-\tmanual\ttuurny\t.\t-\ttoday\n' \
  "$(TZ=UTC sh "$TT" debug-iso "$TODAY_AT")" "$TODAY_AT" "$((TODAY_AT + 3600))" "$M" >> "$LOG"
OUT=$(TZ=UTC TT_NOW="$REPORT_NOW" sh "$TT" report yesterday)
assert_eq "1h 00m" "$(printf '%s\n' "$OUT" | report_cell sportx 3)" 'yesterday includes the complete previous day'
assert_eq "" "$(printf '%s\n' "$OUT" | report_cell tuurny 3)" 'yesterday excludes today'

clear_logs
LOWER=$(TZ=UTC sh "$TT" debug-epoch '2026-09-01 23:30')
UPPER=$(TZ=UTC sh "$TT" debug-epoch '2026-09-02 01:30')
printf '%s\tspan\t%s\t%s\t%s\t-\tmanual\tsportx\t.\t-\tlower\n' \
  "$(TZ=UTC sh "$TT" debug-iso "$LOWER")" "$LOWER" "$UPPER" "$M" >> "$LOG"
LOWER=$(TZ=UTC sh "$TT" debug-epoch '2026-09-02 23:30')
UPPER=$(TZ=UTC sh "$TT" debug-epoch '2026-09-03 01:30')
printf '%s\tspan\t%s\t%s\t%s\t-\tmanual\tsportx\t.\t-\tupper\n' \
  "$(TZ=UTC sh "$TT" debug-iso "$LOWER")" "$LOWER" "$UPPER" "$M" >> "$LOG"
# TT_NOW is pinned to the queried day itself: without it, "now" defaults to
# the real wall clock, which makes both 2026 spans "yesterday or older" and
# the Python reconstruction compacts them away before the reporter ever reads
# them.
OUT=$(TZ=UTC TT_NOW=$(TZ=UTC sh "$TT" debug-epoch '2026-09-02 12:00') sh "$TT" report --since 2026-09-02 --until 2026-09-02)
assert_eq "2h 00m" "$(printf '%s\n' "$OUT" | report_cell sportx 3)" 'manual spans are clipped at both report boundaries'

# A span covering exactly the day's last minute, ending precisely at
# midnight, makes an off-by-one at the 23:59 cutoff visible despite
# minute-level display rounding: losing even its last second would drop the
# displayed total from one minute to zero.
clear_logs
LOWER=$(TZ=UTC sh "$TT" debug-epoch '2026-09-02 23:59')
UPPER=$((LOWER + 60))
printf '%s\tspan\t%s\t%s\t%s\t-\tmanual\tsportx\t.\t-\tlast-minute\n' \
  "$(TZ=UTC sh "$TT" debug-iso "$LOWER")" "$LOWER" "$UPPER" "$M" >> "$LOG"
OUT=$(TZ=UTC sh "$TT" report --since 2026-09-02 --until 2026-09-02)
assert_eq "0h 01m" "$(printf '%s\n' "$OUT" | report_cell sportx 3)" '--until includes the final 59 seconds of its date'

# The first instant of a local day, where a spring-forward can delete 00:00.
SANTIAGO=$(TZ=America/Santiago sh "$TT" debug-epoch '2026-09-06 15:00')
assert_eq "2026-09-06T01:00:00-0300" \
  "$(TZ=America/Santiago sh "$TT" debug-iso "$(TZ=America/Santiago TT_NOW=$SANTIAGO sh "$TT" debug-midnight)")" \
  'a day with no 00:00 starts at its first real instant'

# The same anchoring across the transitions that break naive arithmetic: a 02:00
# spring forward, a fall-back day, and a shift that is not a whole hour.
midnight_of() { # tz 'YYYY-MM-DD HH:MM'
  e=$(TZ=$1 sh "$TT" debug-epoch "$2") || return 1
  TZ=$1 sh "$TT" debug-iso "$(TZ=$1 TT_NOW=$e sh "$TT" debug-midnight)"
}
assert_eq "2026-03-29T00:00:00+0000" "$(midnight_of Europe/London '2026-03-29 15:00')" \
  'a London spring-forward day anchors at 00:00 GMT'
assert_eq "2026-10-25T00:00:00+0100" "$(midnight_of Europe/London '2026-10-25 15:00')" \
  'a London fall-back day anchors at 00:00 BST'
assert_eq "2026-03-08T00:00:00-0500" "$(midnight_of America/New_York '2026-03-08 15:00')" \
  'a New York spring-forward day anchors at 00:00 EST'
assert_eq "2026-03-08T00:00:00-0500" "$(midnight_of America/New_York '2026-03-08 03:30')" \
  'the half hour just after a spring forward anchors on its own day'
assert_eq "2026-11-01T00:00:00-0400" "$(midnight_of America/New_York '2026-11-01 15:00')" \
  'a fall-back day, 25 hours long, anchors at 00:00 EDT'
assert_eq "2026-10-04T00:00:00+1030" "$(midnight_of Australia/Lord_Howe '2026-10-04 15:00')" \
  'a 30-minute spring forward anchors at 00:00'
assert_eq "2026-10-04T00:00:00+1030" "$(midnight_of Australia/Lord_Howe '2026-10-04 02:30')" \
  'the half hour just after a 30-minute shift anchors on its own day'
assert_eq "2026-04-05T00:00:00+1100" "$(midnight_of Australia/Lord_Howe '2026-04-05 15:00')" \
  'a 30-minute fall back anchors at 00:00'

# %H of 09 and %M of 08 must not be read as octal.
ZEROPAD=$(TZ=UTC sh "$TT" debug-epoch '2026-09-02 09:08')
assert_eq "2026-09-02T00:00:00+0000" \
  "$(TZ=UTC sh "$TT" debug-iso "$(TZ=UTC TT_NOW=$ZEROPAD sh "$TT" debug-midnight)")" \
  'a leading-zero hour and minute are read as base ten'

printf 'Task 8: automatic daily compaction\n'

# A legacy one-file log migrates in place: completed days become totals while
# today's detail moves to the gitignored current file.
clear_logs
PAST_A=$(TZ=UTC sh "$TT" debug-epoch '2026-09-02 10:00')
PAST_B=$((PAST_A + 600))
TODAY_A=$(TZ=UTC sh "$TT" debug-epoch '2026-09-03 10:00')
TODAY_B=$((TODAY_A + 120))
DETAIL_LOG=$LOG
LOG=$COMPACT
TZ=UTC beatx "$PAST_A" paired sportx . old-session UserPromptSubmit turn-a - - - -
TZ=UTC beatx "$PAST_B" paired sportx . old-session UserPromptSubmit turn-b - - - -
TZ=UTC beat "$TODAY_A" paired tuurny . new-session
TZ=UTC beat "$TODAY_B" paired tuurny . new-session
LOG=$DETAIL_LOG

OUT=$(TZ=UTC TT_NOW="$REPORT_NOW" sh "$TT" report --since 2026-09-02 --until 2026-09-03)
assert_eq "0h 10m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'legacy completed detail keeps its reported total'
assert_eq "0" "$(awk -F '\t' '$2 == "beat" { n++ } END { print n + 0 }' "$COMPACT")" 'the compact file retains no beat rows'
assert_eq "600" "$(awk -F '\t' '$2 == "coverage" && $7 == "paired" && $8 == "sportx" { print $16 }' "$COMPACT")" 'a completed project becomes one canonical coverage run'
assert_eq "2" "$(awk -F '\t' '$2 == "beat" { n++ } END { print n + 0 }' "$LOG")" 'today detail moves to the current file'
assert_eq "$(TZ=UTC sh "$TT" debug-epoch '2026-09-03 00:00')" "$(awk -F '\t' '$2 == "compact" { print $3 }' "$COMPACT")" 'the compact marker records the active local day'
assert_contains "$(cat "$TT_HOME/.gitignore")" "current-*.tsv" 'legacy migration automatically ignores current detail'

COMPACT_ONCE=$(cat "$COMPACT")
CURRENT_ONCE=$(cat "$LOG")
TZ=UTC TT_NOW="$REPORT_NOW" sh "$TT" report today >/dev/null
assert_eq "$COMPACT_ONCE" "$(cat "$COMPACT")" 'a repeated same-day rollover does not rewrite totals'
assert_eq "$CURRENT_ONCE" "$(cat "$LOG")" 'a repeated same-day rollover leaves detail unchanged'

# A valid same-day marker must not prevent upgrade housekeeping from repairing
# ignore rules left behind by an interrupted or partially installed upgrade.
printf 'mode/\n' > "$TT_HOME/.gitignore"
TZ=UTC TT_NOW="$REPORT_NOW" sh "$TT" report today >/dev/null
assert_contains "$(cat "$TT_HOME/.gitignore")" "current-*.tsv" 'a same-day report repairs the current-detail ignore rule'
assert_contains "$(cat "$TT_HOME/.gitignore")" "events-*.lock/" 'a same-day report repairs the event-lock ignore rule'

# A marker can coexist with raw rows if an older installed hook writes the old
# file after migration. The marker is only a fast path when the compact file
# actually contains compact rows exclusively.
clear_logs
DAY_START=$(TZ=UTC sh "$TT" debug-epoch '2026-09-03 00:00')
printf '2026-09-03\tcompact\t%s\t%s\t%s\t-\t-\t-\t-\t-\t-\n' \
  "$DAY_START" "$DAY_START" "$M" > "$COMPACT"
DETAIL_LOG=$LOG
LOG=$COMPACT
TZ=UTC beat "$TODAY_A" paired sportx . stale-writer
TZ=UTC beat "$TODAY_B" paired sportx . stale-writer
LOG=$DETAIL_LOG
TZ=UTC TT_NOW="$REPORT_NOW" sh "$TT" report today >/dev/null
assert_eq "0" "$(awk -F '\t' '$2 == "beat" { n++ } END { print n + 0 }' "$COMPACT")" 'same-day raw rows are removed from compact history'
assert_eq "2" "$(awk -F '\t' '$2 == "beat" { n++ } END { print n + 0 }' "$LOG")" 'same-day raw rows move to current detail'

# Unknown rows must stop rollover before either source is replaced. This turns
# an interrupted/mismatched deployment into a visible error instead of silently
# dropping history that a later run can no longer reconstruct.
clear_logs
printf '2026-09-03\tcompact\t%s\t%s\t%s\t-\t-\t-\t-\t-\t-\n' \
  "$DAY_START" "$DAY_START" "$M" > "$COMPACT"
printf 'not-a-recognized-row-format\n' >> "$COMPACT"
TZ=UTC beat "$TODAY_A" paired sportx . guarded-source
COMPACT_BEFORE_INVALID=$(cat "$COMPACT")
CURRENT_BEFORE_INVALID=$(cat "$LOG")
assert_status 1 'an unknown stored row stops compaction' -- \
  sh -c "TZ=UTC TT_HOME='$TT_HOME' TT_ROOT='$TT_ROOT' TT_NOW='$REPORT_NOW' TT_LIB='$TT_LIB' sh '$TT' report today"
assert_eq "$COMPACT_BEFORE_INVALID" "$(cat "$COMPACT")" 'an unknown stored row leaves compact history unchanged'
assert_eq "$CURRENT_BEFORE_INVALID" "$(cat "$LOG")" 'an unknown stored row leaves current detail unchanged'

# A misconfigured TT_LIB that cannot resolve the ttreport package must not be
# treated as permission to move either source file.
clear_logs
DETAIL_LOG=$LOG
LOG=$COMPACT
TZ=UTC beat "$PAST_A" paired sportx . malformed-output
TZ=UTC beat "$PAST_B" paired sportx . malformed-output
LOG=$DETAIL_LOG
BAD_LIB="$SANDBOX/bad-lib"
mkdir -p "$BAD_LIB"
COMPACT_BEFORE_INVALID=$(cat "$COMPACT")
CURRENT_BEFORE_INVALID=$(cat "$LOG")
assert_status 1 'malformed successful reporter output stops compaction' -- \
  sh -c "TZ=UTC TT_HOME='$TT_HOME' TT_ROOT='$TT_ROOT' TT_NOW='$REPORT_NOW' TT_LIB='$BAD_LIB' sh '$TT' report yesterday"
assert_eq "$COMPACT_BEFORE_INVALID" "$(cat "$COMPACT")" 'malformed reporter output leaves compact history unchanged'
assert_eq "$CURRENT_BEFORE_INVALID" "$(cat "$LOG")" 'malformed reporter output leaves current detail unchanged'

# A failed sort must not replace either source file with partial compact output.
clear_logs
TZ=UTC beat "$PAST_A" paired sportx . failed-sort
TZ=UTC beat "$PAST_B" paired sportx . failed-sort
mkdir -p "$SANDBOX/fail-sort"
printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/fail-sort/sort"
chmod +x "$SANDBOX/fail-sort/sort"
COMPACT_BEFORE_FAILURE=$(cat "$COMPACT")
CURRENT_BEFORE_FAILURE=$(cat "$LOG")
assert_status 1 'a sort failure stops compaction' -- \
  sh -c "PATH='$SANDBOX/fail-sort:$PATH' TZ=UTC TT_HOME='$TT_HOME' TT_ROOT='$TT_ROOT' TT_NOW='$REPORT_NOW' TT_LIB='$TT_LIB' sh '$TT' report yesterday"
assert_eq "$COMPACT_BEFORE_FAILURE" "$(cat "$COMPACT")" 'a sort failure leaves compact history unchanged'
assert_eq "$CURRENT_BEFORE_FAILURE" "$(cat "$LOG")" 'a sort failure leaves current detail recoverable'

# A manual span crossing midnight is divided once, then its retained current
# fragment starts exactly at the boundary.
clear_logs
CROSS_START=$(TZ=UTC sh "$TT" debug-epoch '2026-09-02 23:30')
CROSS_END=$(TZ=UTC sh "$TT" debug-epoch '2026-09-03 00:30')
printf '%s\tspan\t%s\t%s\t%s\t-\tmanual\tsportx\t.\t-\tcrossing\n' \
  "$(TZ=UTC sh "$TT" debug-iso "$CROSS_START")" "$CROSS_START" "$CROSS_END" "$M" > "$LOG"
OUT=$(TZ=UTC TT_NOW="$REPORT_NOW" sh "$TT" report --since 2026-09-02 --until 2026-09-03 --by day)
assert_eq "0h 30m" "$(printf '%s\n' "$OUT" | report_cell 2026-09-02 3)" 'the compact side of a crossing manual span is exact'
assert_eq "0h 30m" "$(printf '%s\n' "$OUT" | report_cell 2026-09-03 3)" 'the retained side of a crossing manual span is exact'
assert_eq "$(TZ=UTC sh "$TT" debug-epoch '2026-09-03 00:00')" "$(awk -F '\t' '$2 == "span" { print $3 }' "$LOG")" 'the retained span is clipped at midnight'

# Adding past work compacts it immediately instead of leaving historical detail
# in the current file.
clear_logs
TZ=UTC TT_NOW="$REPORT_NOW" sh "$TT" add sportx 30m --at '2026-09-02 12:00' >/dev/null
assert_eq "0" "$(awk -F '\t' '$2 == "span" { n++ } END { print n + 0 }' "$LOG")" 'a late manual entry leaves no completed span in current detail'
assert_eq "1800" "$(awk -F '\t' '$2 == "coverage" && $7 == "manual" && $8 == "sportx" { print $16 }' "$COMPACT")" 'a late manual entry joins its completed-day coverage'

# Many hook events collapse to fixed aggregate rows plus the final heartbeat,
# which must survive to classify a later half-gap even after a long absence.
clear_logs
DETAIL_LOG=$LOG
LOG=$COMPACT
MANY_START=$(TZ=UTC sh "$TT" debug-epoch '2026-09-02 22:00')
i=0
while [ "$i" -lt 100 ]; do
  AT=$((MANY_START + i * 10))
  if [ "$i" -eq 0 ]; then
    TZ=UTC beatx "$AT" paired sportx . dense-session UserPromptSubmit turn-open - - - -
  elif [ "$i" -eq 99 ]; then
    TZ=UTC beatx "$AT" paired sportx . dense-session Stop turn-open - - - -
  else
    TZ=UTC beat "$AT" paired sportx . dense-session
  fi
  i=$((i + 1))
done
LOG=$DETAIL_LOG
TZ=UTC TT_NOW="$REPORT_NOW" sh "$TT" report yesterday >/dev/null
assert_eq "0" "$(awk -F '\t' '$2 == "beat" { n++ } END { print n + 0 }' "$COMPACT" "$LOG")" 'completed dense detail is discarded after rollover'
assert_eq "2" "$(wc -l < "$COMPACT" | tr -d ' ')" 'one hundred beats become a header and one total row'
assert_eq "1" "$(wc -l < "$LOG" | tr -d ' ')" 'an old stream retains only its unresolved heartbeat'

# An explicit transition inside a cross-midnight turn is folded into the old
# day and carried as the effective mode for the retained side.
clear_logs
CROSS_TURN=$(TZ=UTC sh "$TT" debug-epoch '2026-09-02 23:30')
TZ=UTC beatx "$CROSS_TURN" paired sportx docs transition-carry UserPromptSubmit turn-1 - - - -
TZ=UTC mode_event "$((CROSS_TURN + 900))" solo sportx . transition-carry
TZ=UTC beatx "$((CROSS_TURN + 2700))" solo sportx docs transition-carry Stop turn-1 - - - 1
OUT=$(TZ=UTC TT_NOW="$REPORT_NOW" sh "$TT" report --since 2026-09-02 --until 2026-09-03 --by day)
assert_eq "0h 15m" "$(printf '%s\n' "$OUT" | report_cell 2026-09-02 1)" 'rollover compacts the paired side before a transition'
assert_eq "0" "$(awk -F '\t' '$2 == "mode" && $3 < cutoff { n++ } END { print n + 0 }' \
  cutoff="$(TZ=UTC sh "$TT" debug-epoch '2026-09-03 00:00')" "$LOG")" \
  'a compacted transition does not remain as unbounded raw history'

# Concurrent hooks serialize around the same current file and release the lock.
clear_logs
TZ=UTC TT_NOW="$REPORT_NOW" sh "$TT" report today >/dev/null
CONCURRENT_JSON='{"session_id":"concurrent","cwd":"'"$TT_ROOT"'/sportx","hook_event_name":"PreToolUse","turn_id":"turn","tool_use_id":"tool"}'
i=1
while [ "$i" -le 20 ]; do
  (printf '%s' "$CONCURRENT_JSON" | TZ=UTC TT_NOW="$((TODAY_A + i))" PLUGIN_ROOT=/p sh "$TT_HOOK") &
  i=$((i + 1))
done
wait
assert_eq "20" "$(awk -F '\t' '$2 == "beat" { n++ } END { print n + 0 }' "$LOG")" 'twenty concurrent hook beats all survive'
assert_eq "" "$(ls -d "$TT_HOME/events-$M.lock" 2>/dev/null)" 'the event lock is released after concurrent appends'

INIT_HOME="$SANDBOX/init-home"
mkdir -p "$INIT_HOME"
printf 'personal-rule' > "$INIT_HOME/.gitignore"
TZ=UTC TT_HOME="$INIT_HOME" TT_ROOT="$TT_ROOT" TT_NOW="$REPORT_NOW" sh "$TT" init >/dev/null
INIT_MACHINE=$(TZ=UTC TT_HOME="$INIT_HOME" sh "$TT" debug-machine)
assert_status 0 'init creates a tracked compact file' -- test -f "$INIT_HOME/events-$INIT_MACHINE.tsv"
assert_status 0 'init creates a separate current detail file' -- test -f "$INIT_HOME/current-$INIT_MACHINE.tsv"
assert_contains "$(cat "$INIT_HOME/.gitignore")" "current-*.tsv" 'init keeps current detail out of Git'
assert_contains "$(cat "$INIT_HOME/.gitignore")" "events-*.lock/" 'init keeps event locks out of Git'
assert_contains "$(cat "$INIT_HOME/.gitignore")" ".tt-*" 'init keeps interrupted rollover temporaries out of Git'
assert_contains "$(cat "$INIT_HOME/.gitignore")" "personal-rule
modes" 'init preserves a final ignore line that had no newline'

printf 'Task 9: remote transport\n'
# Three stubs: rsync and ssh record what they were asked to do, and a third ssh
# fails with a chosen status. install-remote must reach the host through ssh
# alone, so an empty rsync log is the assertion that no file left this machine.
STUB="$SANDBOX/rsync-stub"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RSYNC_LOG"
STUBEOF
SSHSTUB="$SANDBOX/ssh-stub"
cat > "$SSHSTUB" <<'STUBEOF'
#!/bin/sh
printf '%s\n' "$1" > "$SSH_HOST"
shift
printf '%s\n' "$*" > "$SSH_CMD"
STUBEOF
SSHFAIL="$SANDBOX/ssh-fail"
cat > "$SSHFAIL" <<'STUBEOF'
#!/bin/sh
exit "${SSH_EXIT:-1}"
STUBEOF
chmod +x "$STUB" "$SSHSTUB" "$SSHFAIL"
RSYNC_LOG="$SANDBOX/rsync.log"
SSH_HOST="$SANDBOX/ssh.host"
SSH_CMD="$SANDBOX/ssh.cmd"
export RSYNC_LOG SSH_HOST SSH_CMD
reset_logs() { : > "$RSYNC_LOG"; : > "$SSH_HOST"; : > "$SSH_CMD"; }
reset_logs

TT_RSYNC="$STUB" sh "$TT" sync pull macmini >/dev/null
assert_contains "$(cat "$RSYNC_LOG")" "macmini:" 'sync pull reads from the host'
assert_contains "$(cat "$RSYNC_LOG")" "events-macmini.tsv" 'sync pull names the host log file'
assert_contains "$(cat "$RSYNC_LOG")" "current-macmini.tsv" 'sync pull also names the host current file'
assert_eq "" "$(cat "$SSH_CMD")" 'sync pull drives rsync, not a remote command'

reset_logs
TT_SSH="$SSHSTUB" TT_RSYNC="$STUB" sh "$TT" install-remote macmini >/dev/null
assert_eq "macmini" "$(cat "$SSH_HOST")" 'install-remote runs on the named host'
assert_contains "$(cat "$SSH_CMD")" "https://github.com/Langerrr/timetrack.git" 'install-remote clones the public repository'
assert_contains "$(cat "$SSH_CMD")" "machine=macmini" 'install-remote names the machine in its config'
assert_eq "" "$(cat "$RSYNC_LOG")" 'install-remote transfers no files'

# The script install-remote builds is run here, against a throwaway HOME and a
# stand-in git, so what it does to a config is tested without an ssh hop, a
# clone, or any host at all.
RHOME="$SANDBOX/remote"
mkdir -p "$RHOME/.timetrack" "$SANDBOX/fakebin"
cat > "$SANDBOX/fakebin/git" <<'GITEOF'
#!/bin/sh
case "$1" in
  clone) mkdir -p "$3/bin"; printf '#!/bin/sh\nexit 0\n' > "$3/bin/tt"; chmod +x "$3/bin/tt" ;;
esac
exit 0
GITEOF
chmod +x "$SANDBOX/fakebin/git"
run_remote() { HOME="$RHOME" PATH="$SANDBOX/fakebin:$PATH" sh "$SSH_CMD"; }

# A hand-edited config whose last line never got its newline.
printf '# TT_ROOT=\nTT_IDLE_GAP=600' > "$RHOME/.timetrack/config"
run_remote
assert_contains "$(cat "$RHOME/.timetrack/config")" "TT_IDLE_GAP=600
machine=macmini" 'a config with no trailing newline keeps its last key on its own line'
assert_eq "macmini" "$(TT_HOME="$RHOME/.timetrack" sh "$TT" debug-machine)" 'the machine name is readable afterwards'

# An existing machine= line is replaced where it stands.
printf 'machine=stale\nTT_IDLE_GAP=600\n' > "$RHOME/.timetrack/config"
run_remote
assert_eq "1" "$(grep -c '^machine=' "$RHOME/.timetrack/config")" 'one machine line, not two'
assert_eq "macmini" "$(TT_HOME="$RHOME/.timetrack" sh "$TT" debug-machine)" 'a stale machine name is replaced'
assert_contains "$(cat "$RHOME/.timetrack/config")" "TT_IDLE_GAP=600" 'the other keys survive the replacement'

# Naming the machine is the only thing install-remote really does, so a rewrite
# that fails has to stop rather than fall through to tt init and exit 0.
mkdir -p "$SANDBOX/failbin"
cat > "$SANDBOX/failbin/awk" <<'AWKEOF'
#!/bin/sh
exit 1
AWKEOF
chmod +x "$SANDBOX/failbin/awk"
printf 'TT_IDLE_GAP=600\n' > "$RHOME/.timetrack/config"
assert_status 1 'a config rewrite that fails stops the install' -- \
  sh -c "HOME='$RHOME' PATH='$SANDBOX/failbin:$SANDBOX/fakebin:$PATH' sh '$SSH_CMD'"
assert_eq "0" "$(grep -c '^machine=' "$RHOME/.timetrack/config")" 'a failed rewrite leaves no machine name behind'
assert_eq "" "$(ls "$RHOME/.timetrack/config.new" 2>/dev/null)" 'a failed rewrite leaves no half-written config behind'

# ssh reports its own failures as 255; anything else came from the far side.
assert_contains "$(SSH_EXIT=255 TT_SSH="$SSHFAIL" sh "$TT" install-remote macmini 2>&1)" \
  "could not reach macmini" 'a connection failure blames the connection'
assert_contains "$(SSH_EXIT=1 TT_SSH="$SSHFAIL" sh "$TT" install-remote macmini 2>&1)" \
  "reached macmini" 'a failure on the far side says the host was reached'

assert_status 1 'install-remote refuses a host name that is not one' -- sh -c "TT_SSH='$SSHSTUB' sh '$TT' install-remote 'macmini;id'"
assert_status 1 'sync pull refuses a host name that is not one' -- sh -c "TT_RSYNC='$STUB' sh '$TT' sync pull 'mac mini'"
assert_status 1 'sync pull without a host is rejected' -- sh "$TT" sync pull
assert_status 1 'install-remote without a host is rejected' -- sh "$TT" install-remote
assert_contains "$(sh "$TT" hooks-snippet claude)" "PreToolUse" 'claude snippet names the events'
assert_contains "$(sh "$TT" hooks-snippet claude)" "PermissionDenied" 'claude snippet names the denial event'
assert_contains "$(sh "$TT" hooks-snippet claude)" "bin/tt-hook" 'claude snippet uses the standalone hook entry point'
CLAUDEHOOKS=$(cat "$REPO/hooks/hooks.json")
assert_contains "$CLAUDEHOOKS" 'PostToolUseFailure' 'Claude hooks close a failed tool call'
assert_contains "$CLAUDEHOOKS" 'PermissionDenied' 'Claude hooks close a denied tool call'
assert_contains "$CLAUDEHOOKS" 'StopFailure' 'Claude hooks close a turn that ends in an error'
assert_contains "$CLAUDEHOOKS" 'SessionEnd' 'Claude hooks observe the end of a session'
assert_contains "$CLAUDEHOOKS" 'SubagentStart' 'Claude hooks observe subagent lifecycle'
assert_contains "$CLAUDEHOOKS" 'bin/tt-hook' 'Claude hooks use the standalone hook entry point'
assert_contains "$(sh "$TT" hooks-snippet codex)" "PLUGIN_ROOT" 'codex snippet names the plugin root'
assert_contains "$(sh "$TT" hooks-snippet codex)" "Interrupt" 'codex snippet includes interruption events'
assert_contains "$(cat "$REPO/.codex-plugin/plugin.json")" 'hooks/codex-hooks.json' 'the Codex manifest selects Codex-specific hooks'
assert_contains "$(cat "$REPO/hooks/codex-hooks.json" 2>/dev/null)" 'SubagentStart' 'Codex hooks include subagent lifecycle events'
assert_contains "$(cat "$REPO/hooks/codex-hooks.json" 2>/dev/null)" 'bin/tt-hook' 'Codex hooks use the standalone hook entry point'

# The skill command must work from a plugin-cache-shaped copy with no root bin
# directory on PATH.
PLUGIN_COPY="$SANDBOX/plugin-copy"
mkdir -p "$PLUGIN_COPY/bin" "$PLUGIN_COPY/lib" "$PLUGIN_COPY/skills/timetrack/scripts"
cp "$REPO/bin/tt" "$PLUGIN_COPY/bin/tt"
cp "$REPO/skills/timetrack/scripts/tt" "$PLUGIN_COPY/skills/timetrack/scripts/tt" 2>/dev/null || :
assert_eq "$TT_ROOT" "$(sh "$PLUGIN_COPY/skills/timetrack/scripts/tt" root 2>/dev/null)" 'the bundled skill command resolves its copied plugin root'

printf 'Task 10: prompt classification and automatic solo\n'

hook_json() { # session event prompt
  printf '{"session_id":"%s","hook_event_name":"%s","cwd":"%s","user_prompt":"%s","tool_name":"%s"}' \
    "$1" "$2" "$TT_ROOT/sportx" "$3" "${4:--}"
}

CUR="$TT_HOME/current-$(sh "$TT" debug-machine).tsv"
: > "$CUR"
TAB=$(printf '\t')

# A trigger classification also appends an automatic mode row right after the
# beat row (both land in $CUR), so the beat row carrying the classification
# columns is not always the file's last line -- it has to be picked out by
# kind rather than by position.
last_beat() { awk -F '\t' '$2 == "beat" { last = $0 } END { print last }' "$CUR"; }

hook_json s1 UserPromptSubmit "please review the design" | sh "$TT_HOOK"
LAST=$(last_beat)
assert_eq "human" "$(printf '%s' "$LAST" | cut -f19)" 'an ordinary prompt classifies as human'
assert_status 1 'a human prompt records a fingerprint' -- \
  sh -c "printf '%s' \"$LAST\" | cut -f20 | grep -qx -"

hook_json s1 PreToolUse "" Bash | sh "$TT_HOOK"
assert_eq "Bash" "$(last_beat | cut -f18)" 'tool_name is recorded'
assert_eq "-" "$(last_beat | cut -f19)" 'tool events have no prompt classification'
assert_eq "-" "$(last_beat | cut -f20)" 'tool events have no prompt fingerprint'

hook_json s2 UserPromptSubmit "/goal ship the redesign" | sh "$TT_HOOK"
assert_eq "trigger" "$(last_beat | cut -f19)" 'a solo-trigger command classifies as trigger'
assert_eq "solo" "$(sh "$TT" debug-mode "$TT_ROOT/sportx" s2)" 'a trigger command sets solo for its session'
assert_eq "paired" "$(sh "$TT" debug-mode "$TT_ROOT/sportx" s1)" 'another session keeps its own mode'
assert_eq "auto" "$(grep "${TAB}mode${TAB}" "$CUR" | tail -1 | cut -f11)" 'an automatic transition records its origin'

hook_json s2 UserPromptSubmit "/goal ship the redesign" | sh "$TT_HOOK"
assert_eq "machine" "$(last_beat | cut -f19)" 'a replayed trigger prompt classifies as machine'

hook_json s2 UserPromptSubmit "how is it going" | sh "$TT_HOOK"
assert_eq "human" "$(last_beat | cut -f19)" 'a check-in during a solo run is a human prompt'

hook_json s2 SessionEnd "" | sh "$TT_HOOK"
hook_json s2 UserPromptSubmit "/goal ship the redesign" | sh "$TT_HOOK"
assert_eq "trigger" "$(last_beat | cut -f19)" 'SessionEnd clears the recorded trigger'

hook_json s3 UserPromptSubmit "/deploy now" | TT_SOLO_COMMANDS=deploy sh "$TT_HOOK"
assert_eq "trigger" "$(last_beat | cut -f19)" 'the trigger list is configurable'

printf 'Task 11: report wiring (effort and machine time)\n'

# Bounded with --until: the brief's own example paired --since 1970-01-01
# with no upper bound, which under --by day makes tt_day_boundary_epochs
# walk every local midnight from 1970 to "now" one at a time -- tens of
# thousands of date(1) forks that never finish inside a test run. Every
# other wide-range report call in this file supplies both bounds; this one
# now does too.
REPORT=$(sh "$TT" report --since 1970-01-01 --until 1970-01-02)
assert_contains "$REPORT" "EFFORT" 'the report names the effort column'
assert_contains "$REPORT" "AGENT" 'the report names the agent column'
assert_contains "$REPORT" "TOOL" 'the report names the tool column'
assert_status 1 'the retired estimate column is gone' -- \
  sh -c "sh \"$TT\" report --since 1970-01-01 --until 1970-01-02 | grep -q ESTIMATED"
assert_contains "$(sh "$TT" report --by day --since 1970-01-01 --until 1970-01-02)" "DAY" \
  'grouping by day names the day column'

# A day row's own label must be a calendar date, not the raw boundary epoch
# lib/ttreport buckets it by internally. TT_NOW is pinned to the fixture's
# own day for the same reason as the manual-span fixes above: otherwise
# compaction would erase this beat before the reporter ever saw it.
clear_logs
DAY_LABEL_AT=$(TZ=UTC sh "$TT" debug-epoch '2026-09-07 10:00')
TZ=UTC beatx "$DAY_LABEL_AT" paired sportx . s1 UserPromptSubmit turn-1 - - - -
TZ=UTC beatx "$((DAY_LABEL_AT + 600))" paired sportx . s1 UserPromptSubmit turn-2 - - - -
DAY_OUT=$(TZ=UTC TT_NOW=$(TZ=UTC sh "$TT" debug-epoch '2026-09-07 12:00') \
  sh "$TT" report --by day --since 2026-09-07 --until 2026-09-07)
DAY_ROW_LABEL=$(printf '%s\n' "$DAY_OUT" | awk 'NR == 2 { print $1 }')
assert_eq "1" "$(printf '%s' "$DAY_ROW_LABEL" | grep -cE '^20.*-.*-')" \
  'a day row is labeled with a date, not a raw epoch'

finish

#!/bin/sh
# Runs every test in a throwaway TT_HOME. Usage: sh tests/run.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
TT="$REPO/bin/tt"
. "$HERE/lib.sh"

SANDBOX=${TMPDIR:-/tmp}/tt-test-$$
mkdir -p "$SANDBOX/home" "$SANDBOX/root/sportx/saas-backend" "$SANDBOX/root/sportx/a,b" "$SANDBOX/root/tuurny"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

TT_HOME="$SANDBOX/home"
TT_ROOT="$SANDBOX/root"
export TT_HOME TT_ROOT

# Harness detection is asserted below, so the ambient harness must not leak in.
unset CLAUDECODE CLAUDE_PLUGIN_ROOT PLUGIN_ROOT CODEX_HOME
unset TT_READING_WPM TT_MAX_READING_TIME TT_MAX_ACTIVE_GAP

printf 'Task 1: skeleton\n'
assert_status 2 'unknown subcommand exits 2' -- sh "$TT" nonsense
assert_eq "$TT_HOME" "$(sh "$TT" debug-home)" 'TT_HOME override honoured'
assert_eq "1900000000" "$(TT_NOW=1900000000 sh "$TT" debug-now)" 'TT_NOW override honoured'
assert_eq "testbox" "$(printf 'machine=testbox\n' > "$TT_HOME/config"; sh "$TT" debug-machine)" 'machine from config'
rm -f "$TT_HOME/config"

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
assert_eq "paired" "$(sh "$TT" debug-mode "$TT_ROOT/tuurny")" 'sibling directory is unaffected'
sh "$TT" paired "$TT_ROOT/sportx" >/dev/null
assert_eq "paired" "$(sh "$TT" debug-mode "$TT_ROOT/sportx")" 'paired is recorded'

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

printf 'Task 3: hook capture\n'
LOG="$TT_HOME/events-$(sh "$TT" debug-machine).tsv"
: > "$LOG"

HOOKJSON='{"session_id":"abc123","transcript_path":"/x/y.jsonl","cwd":"'"$TT_ROOT"'/sportx/saas-backend","hook_event_name":"PreToolUse"}'
printf '%s' "$HOOKJSON" | TT_NOW=1900000000 CLAUDE_PLUGIN_ROOT=/p sh "$TT" hook
assert_eq "1" "$(wc -l < "$LOG" | tr -d ' ')" 'one beat appended'
assert_eq "beat" "$(cut -f2 < "$LOG")" 'kind is beat'
assert_eq "1900000000" "$(cut -f3 < "$LOG")" 'start is the current epoch'
assert_eq "1900000000" "$(cut -f4 < "$LOG")" 'end equals start for a beat'
assert_eq "claude" "$(cut -f6 < "$LOG")" 'harness detected from CLAUDE_PLUGIN_ROOT'
assert_eq "paired" "$(cut -f7 < "$LOG")" 'mode defaults to paired'
assert_eq "sportx" "$(cut -f8 < "$LOG")" 'project from cwd'
assert_eq "saas-backend" "$(cut -f9 < "$LOG")" 'subpath from cwd'
assert_eq "abc123" "$(cut -f10 < "$LOG")" 'session id captured'

: > "$LOG"
printf '%s' "$HOOKJSON" | TT_NOW=1900000001 PLUGIN_ROOT=/p sh "$TT" hook
assert_eq "codex" "$(cut -f6 < "$LOG")" 'harness detected from PLUGIN_ROOT'

: > "$LOG"
sh "$TT" solo "$TT_ROOT/sportx/saas-backend" >/dev/null
printf '%s' "$HOOKJSON" | TT_NOW=1900000002 sh "$TT" hook
assert_eq "solo" "$(cut -f7 < "$LOG")" 'mode reflects the session directory'
sh "$TT" paired "$TT_ROOT/sportx/saas-backend" >/dev/null

: > "$LOG"
assert_status 0 'malformed stdin still exits 0' -- sh -c "printf 'not json' | TT_HOME='$TT_HOME' TT_ROOT='$TT_ROOT' sh '$TT' hook"
assert_eq "1" "$(wc -l < "$LOG" | tr -d ' ')" 'malformed input still records a beat'

: > "$LOG"
assert_status 0 'empty stdin still exits 0' -- sh -c "printf '' | TT_HOME='$TT_HOME' TT_ROOT='$TT_ROOT' sh '$TT' hook"

: > "$LOG"
COMMAJSON='{"session_id":"abc123","cwd":"'"$TT_ROOT"'/sportx/a,b","hook_event_name":"PreToolUse"}'
printf '%s' "$COMMAJSON" | TT_NOW=1900000003 sh "$TT" hook
assert_eq "a,b" "$(cut -f9 < "$LOG")" 'a comma in cwd does not break attribution'

: > "$LOG"
DECOYJSON='{"tool_input":{"cwd":"/decoy","command":"ls"},"session_id":"abc123","cwd":"'"$TT_ROOT"'/sportx/saas-backend","hook_event_name":"PreToolUse"}'
printf '%s' "$DECOYJSON" | TT_NOW=1900000004 sh "$TT" hook
assert_eq "saas-backend" "$(cut -f9 < "$LOG")" 'a cwd inside tool_input does not outrank the top-level cwd'

: > "$LOG"
ESCJSON='{"session_id":"abc123","cwd":"'"$TT_ROOT"'/sportx/a\"b","hook_event_name":"PreToolUse"}'
printf '%s' "$ESCJSON" | TT_NOW=1900000005 sh "$TT" hook
assert_eq 'a\"b' "$(cut -f9 < "$LOG")" 'an escaped quote in cwd does not truncate the value'

: > "$LOG"
EXTJSON='{"session_id":"abc123","cwd":"'"$TT_ROOT"'/sportx/saas-backend","hook_event_name":"SubagentStart","turn_id":"turn-7","tool_use_id":"tool-8","agent_id":"agent-9","agent_type":"worker"}'
printf '%s' "$EXTJSON" | TT_NOW=1900000006 PLUGIN_ROOT=/p sh "$TT" hook
assert_eq "17" "$(awk -F '\t' '{ print NF }' "$LOG")" 'new beats append six lifecycle fields'
assert_eq "turn-7" "$(cut -f12 < "$LOG")" 'turn id captured'
assert_eq "tool-8" "$(cut -f13 < "$LOG")" 'tool id captured'
assert_eq "agent-9" "$(cut -f14 < "$LOG")" 'subagent id captured'
assert_eq "worker" "$(cut -f15 < "$LOG")" 'subagent type captured'
assert_eq "-" "$(cut -f17 < "$LOG")" 'an unrelated event has no session-start source'

: > "$LOG"
STARTJSON='{"session_id":"abc123","cwd":"'"$TT_ROOT"'/sportx/saas-backend","hook_event_name":"SessionStart","source":"compact"}'
printf '%s' "$STARTJSON" | TT_NOW=1900000010 PLUGIN_ROOT=/p sh "$TT" hook
assert_eq "compact" "$(cut -f17 < "$LOG")" 'a Codex SessionStart source is captured'

: > "$LOG"
PROMPTIDJSON='{"session_id":"abc123","cwd":"'"$TT_ROOT"'/sportx/saas-backend","hook_event_name":"PreToolUse","prompt_id":"prompt-9","tool_use_id":"tool-9"}'
printf '%s' "$PROMPTIDJSON" | TT_NOW=1900000011 CLAUDE_PLUGIN_ROOT=/p sh "$TT" hook
assert_eq "prompt-9" "$(cut -f12 < "$LOG")" 'a Claude prompt_id fills the turn column'
assert_eq "tool-9" "$(cut -f13 < "$LOG")" 'a Claude tool_use_id fills the tool column'

: > "$LOG"
BOTHIDJSON='{"session_id":"abc123","cwd":"'"$TT_ROOT"'/sportx/saas-backend","hook_event_name":"PreToolUse","turn_id":"turn-9","prompt_id":"prompt-9"}'
printf '%s' "$BOTHIDJSON" | TT_NOW=1900000012 PLUGIN_ROOT=/p sh "$TT" hook
assert_eq "turn-9" "$(cut -f12 < "$LOG")" 'turn_id outranks prompt_id when a harness sends both'

: > "$LOG"
STOPJSON='{"session_id":"abc123","cwd":"'"$TT_ROOT"'/sportx/saas-backend","hook_event_name":"Stop","turn_id":"turn-7","last_assistant_message":"one two\\nthree four five"}'
printf '%s' "$STOPJSON" | TT_NOW=1900000007 PLUGIN_ROOT=/p sh "$TT" hook
assert_eq "5" "$(cut -f16 < "$LOG")" 'Stop stores the assistant output word count'
assert_eq "0" "$(grep -c 'one two' "$LOG")" 'Stop never stores raw assistant output'

: > "$LOG"
sh "$TT" solo "$TT_ROOT/sportx/saas-backend" >/dev/null
PROMPTJSON='{"session_id":"abc123","cwd":"'"$TT_ROOT"'/sportx/saas-backend","hook_event_name":"UserPromptSubmit","turn_id":"turn-8"}'
printf '%s' "$PROMPTJSON" | TT_NOW=1900000008 PLUGIN_ROOT=/p sh "$TT" hook
assert_eq "paired" "$(cut -f7 < "$LOG")" 'a prompt submitted after solo is recorded as paired'
assert_eq "paired" "$(sh "$TT" debug-mode "$TT_ROOT/sportx/saas-backend")" 'a prompt submitted after solo changes the stored mode'

: > "$LOG"
NULLSTOP='{"session_id":"abc123","cwd":"'"$TT_ROOT"'/sportx/saas-backend","hook_event_name":"Stop","turn_id":"turn-8","last_assistant_message":null}'
printf '%s' "$NULLSTOP" | TT_NOW=1900000009 PLUGIN_ROOT=/p sh "$TT" hook
assert_eq "-" "$(cut -f16 < "$LOG")" 'a null assistant message records no word estimate'

# A prompt and an explicit mode write may contend for the modes-file lock. The
# prompt beat itself is paired regardless of which state write completes last.
: > "$LOG"
sh "$TT" solo "$TT_ROOT/sportx/saas-backend" >/dev/null
printf '%s' "$PROMPTJSON" | TT_NOW=1900000010 PLUGIN_ROOT=/p sh "$TT" hook &
PROMPT_PID=$!
sh "$TT" solo "$TT_ROOT/sportx/saas-backend" >/dev/null &
MODE_PID=$!
wait "$PROMPT_PID" "$MODE_PID"
assert_eq "paired" "$(cut -f7 < "$LOG")" 'a concurrent explicit mode write cannot relabel the submitted prompt'
assert_eq "1" "$(sh "$TT" sessions | grep -c 'sportx/saas-backend')" 'concurrent return handling leaves one valid mode row'
sh "$TT" paired "$TT_ROOT/sportx/saas-backend" >/dev/null

assert_status 0 'an internal hook formatting failure is contained' -- \
  sh -c "printf '%s' '$PROMPTJSON' | TT_HOME='$TT_HOME' TT_ROOT='$TT_ROOT' TT_NOW=bad PLUGIN_ROOT=/p sh '$TT' hook"

printf 'Task 4: manual entries\n'
assert_eq "5400" "$(sh "$TT" debug-seconds 90m)" '90m parses'
assert_eq "5400" "$(sh "$TT" debug-seconds 1.5h)" '1.5h parses'
assert_eq "9000" "$(sh "$TT" debug-seconds 2h30m)" '2h30m parses'
assert_eq "2700" "$(sh "$TT" debug-seconds 45)" 'bare number is minutes'
assert_status 1 'garbage duration is rejected' -- sh "$TT" debug-seconds banana

: > "$LOG"
TT_NOW=1900000000 sh "$TT" add sportx 90m "architecture call" >/dev/null
assert_eq "span" "$(cut -f2 < "$LOG")" 'kind is span'
assert_eq "1899994600" "$(cut -f3 < "$LOG")" 'span starts one duration before now'
assert_eq "1900000000" "$(cut -f4 < "$LOG")" 'span ends now'
assert_eq "manual" "$(cut -f7 < "$LOG")" 'mode is manual'
assert_eq "sportx" "$(cut -f8 < "$LOG")" 'project recorded'
assert_eq "architecture call" "$(cut -f11 < "$LOG")" 'note recorded'
assert_eq "-" "$(cut -f10 < "$LOG")" 'no session id for a span'

: > "$LOG"
sh "$TT" add tuurny 2h --at '2026-09-01 14:00' >/dev/null
assert_eq "$(sh "$TT" debug-epoch '2026-09-01 14:00')" "$(cut -f3 < "$LOG")" '--at sets the start'
assert_eq "$(( $(sh "$TT" debug-epoch '2026-09-01 14:00') + 7200 ))" "$(cut -f4 < "$LOG")" '--at plus duration sets the end'

assert_contains "$(: > "$LOG"; TT_NOW=1900000000 sh "$TT" add sportx 30m)" "sportx" 'the written row is echoed'

printf 'Task 5: reporting\n'
TT_LIB="$REPO/lib"; export TT_LIB
: > "$LOG"
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

report_cell() { # row column-pair-number; reads a report on stdin
  awk -v row="$1" -v pair="$2" '$1 == row { i = pair * 2; print $i " " $(i + 1); exit }'
}

# Consecutive beats inside the gap accumulate.
beat 1900000000 paired sportx . s1
beat 1900000060 paired sportx . s1
assert_contains "$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)" "0h 01m" 'a 60s gap is counted'

# Beats reach the log in whatever order parallel hooks win the append, so the
# report has to order them itself. Written newest-first, these three still form
# one two-minute block.
: > "$LOG"
beat 1900000120 paired sportx . s1
beat 1900000000 paired sportx . s1
beat 1900000060 paired sportx . s1
assert_contains "$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)" "0h 02m" 'beats appended out of order still total their full block'

# The same, across two machines interleaved into one stream.
: > "$LOG"
OTHER="$TT_HOME/events-macmini.tsv"
beat 1900000120 paired sportx . s1
beat 1900000000 paired sportx . s1
printf '%s\tbeat\t1900000300\t1900000300\tmacmini\tcodex\tsolo\tsportx\t.\ts9\t-\n%s\tbeat\t1900000060\t1900000060\tmacmini\tcodex\tsolo\tsportx\t.\ts9\t-\n' \
  "$(sh "$TT" debug-iso 1900000300)" "$(sh "$TT" debug-iso 1900000060)" > "$OTHER"
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_contains "$OUT" "0h 02m" 'out-of-order beats from one machine still total'
assert_contains "$OUT" "0h 04m" 'out-of-order beats from another machine still total'
rm -f "$OTHER"

# A gap wider than the threshold contributes nothing.
: > "$LOG"
beat 1900000000 paired sportx . s1
beat 1900002000 paired sportx . s1
assert_contains "$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)" "0h 00m" 'a 2000s gap is dropped'

# A mode change splits the run.
: > "$LOG"
beat 1900000000 paired sportx . s1
beat 1900000060 paired sportx . s1
beat 1900000120 solo   sportx . s1
beat 1900000180 solo   sportx . s1
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_contains "$OUT" "0h 02m" 'paired side of a split run'
assert_contains "$OUT" "0h 01m" 'solo side of a split run'

# Duplicate beats at one instant are harmless.
: > "$LOG"
beat 1900000000 paired sportx . s1
beat 1900000000 paired sportx . s1
beat 1900000060 paired sportx . s1
assert_contains "$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)" "0h 01m" 'duplicate timestamps add nothing'

# Separate sessions never join across their boundary.
: > "$LOG"
beat 1900000000 paired sportx . s1
beat 1900000060 paired sportx . s2
assert_contains "$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)" "0h 00m" 'distinct sessions do not join'

# Spans land in the manual column.
: > "$LOG"
printf '%s\tspan\t1900000000\t1900003600\t%s\t-\tmanual\ttuurny\t.\t-\tcall\n' \
  "$(sh "$TT" debug-iso 1900000000)" "$M" >> "$LOG"
assert_contains "$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)" "1h 00m" 'a span contributes its full length'

# Logs from several machines merge.
: > "$LOG"
OTHER="$TT_HOME/events-macmini.tsv"
beat 1900000000 paired sportx . s1
printf '%s\tbeat\t1900000000\t1900000000\tmacmini\tcodex\tsolo\tsportx\t.\ts9\t-\n%s\tbeat\t1900000300\t1900000300\tmacmini\tcodex\tsolo\tsportx\t.\ts9\t-\n' \
  "$(sh "$TT" debug-iso 1900000000)" "$(sh "$TT" debug-iso 1900000300)" > "$OTHER"
assert_contains "$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)" "0h 05m" 'another machine merges in'
rm -f "$OTHER"

# --detail separates subpaths.
: > "$LOG"
beat 1900000000 paired sportx saas-backend s1
beat 1900000060 paired sportx saas-backend s1
assert_contains "$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01 --detail)" "sportx/saas-backend" '--detail shows the subpath'

# An empty log reports cleanly.
: > "$LOG"
assert_status 0 'an empty log exits 0' -- sh -c "TT_HOME='$TT_HOME' TT_ROOT='$TT_ROOT' TT_LIB='$TT_LIB' sh '$TT' report"

printf 'Task 6: lifecycle-aware and bounded reporting\n'
WIDE='--since 2000-01-01 --until 2100-01-01'

# Complete lifecycle pairs are proof of activity even when their gap exceeds
# the legacy idle threshold.
: > "$LOG"
beatx 1900000000 paired sportx . s1 UserPromptSubmit turn-1 - - - -
beatx 1900002000 paired sportx . s1 Stop turn-1 - - - 10
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 33m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'a complete long Codex turn counts past the idle gap'

: > "$LOG"
beatx 1900000000 paired sportx . s1 PreToolUse turn-1 tool-1 - - -
beatx 1900002000 paired sportx . s1 PostToolUse turn-1 tool-1 - - -
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 33m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'a matched long tool call counts past the idle gap'

# Append order, not a lexical tie-break, decides the mode after equal-second
# lifecycle events.
: > "$LOG"
beatx 1900000000 solo sportx . s1 PreToolUse turn-1 tool-1 - - -
beatx 1900000000 paired sportx . s1 PostToolUse turn-1 tool-1 - - -
beatx 1900000060 paired sportx . s1 Stop turn-1 - - - 1
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 01m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'same-second mode transitions preserve append order'
assert_eq "0h 00m" "$(printf '%s\n' "$OUT" | report_cell sportx 2)" 'same-second transitions do not leak time into the old mode'

# Mode changes observed during a long turn split that proven interval.
: > "$LOG"
beatx 1900000000 paired sportx . s1 UserPromptSubmit turn-1 - - - -
beatx 1900001000 solo sportx . s1 PreToolUse turn-1 tool-1 - - -
beatx 1900002000 solo sportx . s1 Stop turn-1 - - - 1
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 16m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'a long turn keeps its paired segment'
assert_eq "0h 16m" "$(printf '%s\n' "$OUT" | report_cell sportx 2)" 'a long turn keeps its solo segment'

# Review/composition after paired Stop uses the idle threshold. A solo Stop
# does not count the whole gap.
: > "$LOG"
beatx 1900000000 paired sportx . s1 Stop turn-1 - - - 10
beatx 1900000300 paired sportx . s1 UserPromptSubmit turn-2 - - - -
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 05m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'a timely paired Stop-to-prompt gap counts'

: > "$LOG"
beatx 1900000000 paired sportx . s1 Stop turn-1 - - - 10
beatx 1900002000 paired sportx . s1 UserPromptSubmit turn-2 - - - -
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 00m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'an over-threshold paired Stop-to-prompt gap is idle'

: > "$LOG"
beatx 1900000000 solo sportx . s1 Stop turn-1 - - - -
beatx 1900000300 paired sportx . s1 UserPromptSubmit turn-2 - - - -
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 00m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'a solo Stop without output words invents no return time'

# A solo return gets a bounded estimate from output size. PAIRED includes it;
# ESTIMATED exposes the subset instead of adding another mode to TOTAL.
: > "$LOG"
beatx 1900000000 solo sportx . s1 Stop turn-1 - - - 240
beatx 1900000480 paired sportx . s1 UserPromptSubmit turn-2 - - - -
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 02m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" '240 words estimate as two paired minutes at 120 WPM'
assert_eq "0h 02m" "$(printf '%s\n' "$OUT" | report_cell sportx 4)" 'the paired reading subset is visibly estimated'
assert_eq "0h 02m" "$(printf '%s\n' "$OUT" | report_cell sportx 5)" 'estimated time is not added twice to total'

: > "$LOG"
beatx 1900000000 solo sportx . s1 Stop turn-1 - - - 600
beatx 1900000120 paired sportx . s1 UserPromptSubmit turn-2 - - - -
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 02m" "$(printf '%s\n' "$OUT" | report_cell sportx 4)" 'a reading estimate cannot exceed the actual return gap'

: > "$LOG"
beatx 1900000000 solo sportx . s1 Stop turn-1 - - - 5000
beatx 1900002000 paired sportx . s1 UserPromptSubmit turn-2 - - - -
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 10m" "$(printf '%s\n' "$OUT" | report_cell sportx 4)" 'a reading estimate obeys the ten-minute default cap'
OUT=$(TT_MAX_READING_TIME=0 TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 10m" "$(printf '%s\n' "$OUT" | report_cell sportx 4)" 'an invalid reading-time cap falls back safely'

: > "$LOG"
beatx 1900000000 solo sportx . s1 Stop turn-1 - - - 120
beatx 1900000300 paired sportx . s1 UserPromptSubmit turn-2 - - - -
OUT=$(TT_READING_WPM=60 TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 02m" "$(printf '%s\n' "$OUT" | report_cell sportx 4)" 'reading speed is configurable for the user'
OUT=$(TT_READING_WPM=0 TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 00m" "$(printf '%s\n' "$OUT" | report_cell sportx 4)" 'a reading speed of zero switches the estimate off'
assert_eq "0h 00m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'a disabled estimate contributes no paired time'
OUT=$(TT_READING_WPM=banana TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 01m" "$(printf '%s\n' "$OUT" | report_cell sportx 4)" 'a malformed reading speed falls back safely'
OUT=$(TT_MAX_READING_TIME=60 TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 01m" "$(printf '%s\n' "$OUT" | report_cell sportx 4)" 'the reading-time cap is configurable'
printf 'TT_READING_WPM=60\nTT_MAX_READING_TIME=600\n' > "$TT_HOME/config"
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 02m" "$(printf '%s\n' "$OUT" | report_cell sportx 4)" 'reading preferences load from the config file'
rm -f "$TT_HOME/config"

# Interrupts, session endings and subagents close known-active intervals, while
# overlapping child work remains part of one parent timeline.
: > "$LOG"
beatx 1900000000 paired sportx . s1 UserPromptSubmit turn-1 - - - -
beatx 1900002000 paired sportx . s1 Interrupt turn-1 - - - -
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 33m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'Interrupt closes and counts a long active turn'

: > "$LOG"
beatx 1900000000 paired sportx . s1 UserPromptSubmit turn-1 - - - -
beatx 1900002000 paired sportx . s1 SessionEnd turn-1 - - - -
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 33m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'SessionEnd bounds an otherwise open active turn'

: > "$LOG"
beatx 1900000000 paired sportx . s1 SubagentStart turn-1 - agent-1 worker -
beatx 1900002000 paired sportx . s1 SubagentStop turn-1 - agent-1 worker -
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 33m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'matched subagent activity recovers a long interval'

: > "$LOG"
beatx 1900000000 paired sportx . s1 UserPromptSubmit turn-1 - - - -
beatx 1900000100 paired sportx . s1 SubagentStart turn-1 - agent-1 worker -
beatx 1900001900 paired sportx . s1 SubagentStop turn-1 - agent-1 worker -
beatx 1900002000 paired sportx . s1 Stop turn-1 - - - 1
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 33m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'subagent work overlapping its parent counts once'

# Top-level sessions remain additive, legacy rows stay readable, and old/new
# rows can share one stream without migration.
: > "$LOG"
beatx 1900000000 paired sportx . s1 UserPromptSubmit turn-1 - - - -
beatx 1900000060 paired sportx . s1 Stop turn-1 - - - 1
beatx 1900000000 paired sportx . s2 UserPromptSubmit turn-2 - - - -
beatx 1900000060 paired sportx . s2 Stop turn-2 - - - 1
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 02m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'independent top-level sessions remain additive'

: > "$LOG"
beat 1900000000 paired sportx . s1
printf '%s\tbeat\t1900000060\t1900000060\t%s\tclaude\tpaired\tsportx\t.\ts1\tPreToolUse\tturn-1\ttool-1\t-\t-\t-\n' \
  "$(sh "$TT" debug-iso 1900000060)" "$M" >> "$LOG"
printf '%s\tbeat\t1900000120\t1900000120\t%s\tclaude\tpaired\tsportx\t.\ts1\tPostToolUse\tturn-1\ttool-1\t-\t-\t-\n' \
  "$(sh "$TT" debug-iso 1900000120)" "$M" >> "$LOG"
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 02m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'mixed legacy and extended beats report without migration'

: > "$LOG"
beatx 1900000000 paired sportx . s1 UserPromptSubmit turn-1 - - - -
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 00m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'an unmatched lifecycle start never extends to report time'

# Every way a turn or a tool call can end, not just the way it ends when
# nothing goes wrong. A terminal event the harness sends but the engine does
# not recognise leaves activity proven, and proven activity ignores the idle
# gap, so each of these would otherwise count the whole following absence.
: > "$LOG"
beatx 1900000000 paired sportx . s1 UserPromptSubmit turn-1 - - - -
beatx 1900002000 paired sportx . s1 StopFailure turn-1 - - - -
beatx 1900079000 paired sportx . s1 UserPromptSubmit turn-2 - - - -
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 33m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'a turn ending in an API error closes at StopFailure'

: > "$LOG"
beatx 1900000000 paired sportx . s1 PreToolUse turn-1 tool-1 - - -
beatx 1900000060 paired sportx . s1 PostToolUseFailure turn-1 tool-1 - - -
beatx 1900079000 paired sportx . s1 Stop turn-1 - - - 1
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 01m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'a failed tool call closes at PostToolUseFailure'

: > "$LOG"
beatx 1900000000 paired sportx . s1 PreToolUse turn-1 tool-1 - - -
beatx 1900000060 paired sportx . s1 PermissionDenied turn-1 tool-1 - - -
beatx 1900079000 paired sportx . s1 Stop turn-1 - - - 1
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 01m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'a denied tool call closes at PermissionDenied'

: > "$LOG"
beatx 1900000000 paired sportx . s1 PreToolUse turn-1 tool-1 - - -
beatx 1900000060 paired sportx . s1 PostToolUseFailure turn-1 - - - -
beatx 1900079000 paired sportx . s1 Stop turn-1 - - - 1
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 01m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'a terminal event without a tool id still closes the call'

# A resumed session keeps its id, so SessionStart can land after a turn that
# nothing closed. Tested with the ceiling off, which would otherwise mask it.
: > "$LOG"
beatx 1900000000 paired sportx . s1 UserPromptSubmit turn-1 - - - -
beatx 1900000060 paired sportx . s1 PostToolUse turn-1 tool-1 - - -
beatx 1900079000 paired sportx . s1 SessionStart - - - - -
beatx 1900079060 paired sportx . s1 Stop turn-2 - - - 1
OUT=$(TT_MAX_ACTIVE_GAP=0 TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 02m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'resuming a session does not count the time it was not running'

# Codex uses SessionStart with source=compact for a continuation inside the
# current turn. It must not be mistaken for a resumed idle session.
: > "$LOG"
beatx 1900000000 paired sportx . s1 UserPromptSubmit turn-1 - - - -
beatx 1900002000 paired sportx . s1 SessionStart - - - - - compact
beatx 1900002060 paired sportx . s1 Stop turn-1 - - - 1
OUT=$(TT_MAX_ACTIVE_GAP=0 TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 34m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'Codex compaction preserves the active turn'

# An interrupt records nothing, but the next prompt carries a different turn id,
# and that is proof the earlier turn is over.
: > "$LOG"
beatx 1900000000 paired sportx . s1 UserPromptSubmit turn-1 - - - -
beatx 1900000060 paired sportx . s1 PostToolUse turn-1 tool-1 - - -
beatx 1900079000 paired sportx . s1 UserPromptSubmit turn-2 - - - -
beatx 1900079060 paired sportx . s1 Stop turn-2 - - - 1
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 02m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'a new turn id proves the interrupted turn ended'

# A legacy row carries no turn id, so it must not trip that rule.
: > "$LOG"
beat 1900000000 paired sportx . s1
beat 1900000060 paired sportx . s1
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 01m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'rows without turn ids report unchanged'

# No terminal event is guaranteed to arrive: Claude Code fires none on a user
# interrupt. The ceiling bounds what an unclosed turn can count.
: > "$LOG"
beatx 1900000000 paired sportx . s1 UserPromptSubmit turn-1 - - - -
beatx 1900079000 paired sportx . s1 Stop turn-1 - - - 1
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "1h 00m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'an hours-long proven gap is capped at the ceiling'
OUT=$(TT_MAX_ACTIVE_GAP=0 TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "21h 56m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'a ceiling of zero leaves proven activity unbounded'
OUT=$(TT_MAX_ACTIVE_GAP=7200 TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "2h 00m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'the ceiling is configurable'

# A tool call shorter than the ceiling is real work and keeps its full length.
: > "$LOG"
beatx 1900000000 paired sportx . s1 PreToolUse turn-1 tool-1 - - -
beatx 1900003000 paired sportx . s1 PostToolUse turn-1 tool-1 - - -
OUT=$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)
assert_eq "0h 50m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'a long tool call under the ceiling is counted in full'

printf 'Task 7: range clipping and day boundaries\n'
DAY1=$(TZ=UTC sh "$TT" debug-epoch '2026-09-01 23:59')
DAY2=$(TZ=UTC sh "$TT" debug-epoch '2026-09-02 00:01')
: > "$LOG"
TZ=UTC beat "$DAY1" paired sportx . s1
TZ=UTC beat "$DAY2" paired sportx . s1
OUT=$(TZ=UTC TT_NOW="$DAY2" sh "$TT" report --since 2026-09-02 --until 2026-09-02)
assert_eq "0h 01m" "$(printf '%s\n' "$OUT" | report_cell sportx 1)" 'a beat interval is clipped at the lower report boundary'
OUT=$(TZ=UTC TT_NOW="$DAY2" sh "$TT" report --since 2026-09-01 --until 2026-09-02 --by day)
assert_eq "0h 01m" "$(printf '%s\n' "$OUT" | report_cell 2026-09-01 1)" 'the first day gets its side of a crossing interval'
assert_eq "0h 01m" "$(printf '%s\n' "$OUT" | report_cell 2026-09-02 1)" 'the second day gets its side of a crossing interval'

: > "$LOG"
LOWER=$(TZ=UTC sh "$TT" debug-epoch '2026-09-01 23:30')
UPPER=$(TZ=UTC sh "$TT" debug-epoch '2026-09-02 01:30')
printf '%s\tspan\t%s\t%s\t%s\t-\tmanual\tsportx\t.\t-\tlower\n' \
  "$(TZ=UTC sh "$TT" debug-iso "$LOWER")" "$LOWER" "$UPPER" "$M" >> "$LOG"
LOWER=$(TZ=UTC sh "$TT" debug-epoch '2026-09-02 23:30')
UPPER=$(TZ=UTC sh "$TT" debug-epoch '2026-09-03 01:30')
printf '%s\tspan\t%s\t%s\t%s\t-\tmanual\tsportx\t.\t-\tupper\n' \
  "$(TZ=UTC sh "$TT" debug-iso "$LOWER")" "$LOWER" "$UPPER" "$M" >> "$LOG"
OUT=$(TZ=UTC sh "$TT" report --since 2026-09-02 --until 2026-09-02)
assert_eq "2h 00m" "$(printf '%s\n' "$OUT" | report_cell sportx 3)" 'manual spans are clipped at both report boundaries'

# Two short spans beginning inside the last minute make the old 23:59 cutoff
# visible despite minute-level display rounding.
: > "$LOG"
LOWER=$(TZ=UTC sh "$TT" debug-epoch '2026-09-02 23:59')
LOWER=$((LOWER + 1)); UPPER=$((LOWER + 58))
printf '%s\tspan\t%s\t%s\t%s\t-\tmanual\tsportx\t.\t-\tlast-minute-a\n' \
  "$(TZ=UTC sh "$TT" debug-iso "$LOWER")" "$LOWER" "$UPPER" "$M" >> "$LOG"
printf '%s\tspan\t%s\t%s\t%s\t-\tmanual\tsportx\t.\t-\tlast-minute-b\n' \
  "$(TZ=UTC sh "$TT" debug-iso "$LOWER")" "$LOWER" "$UPPER" "$M" >> "$LOG"
OUT=$(TZ=UTC sh "$TT" report --since 2026-09-02 --until 2026-09-02)
assert_eq "0h 01m" "$(printf '%s\n' "$OUT" | report_cell sportx 3)" '--until includes the final 59 seconds of its date'

# Estimated reading is placed before the prompt, so it clips deterministically
# when the return crosses midnight.
: > "$LOG"
STOP_AT=$(TZ=UTC sh "$TT" debug-epoch '2026-09-01 23:58')
PROMPT_AT=$(TZ=UTC sh "$TT" debug-epoch '2026-09-02 00:02')
TZ=UTC beatx "$STOP_AT" solo sportx . s1 Stop turn-1 - - - 480
TZ=UTC beatx "$PROMPT_AT" paired sportx . s1 UserPromptSubmit turn-2 - - - -
OUT=$(TZ=UTC sh "$TT" report --since 2026-09-02 --until 2026-09-02)
assert_eq "0h 02m" "$(printf '%s\n' "$OUT" | report_cell sportx 4)" 'a solo reading estimate clips at the report boundary'

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

printf 'Task 8: remote transport\n'
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
CLAUDEHOOKS=$(cat "$REPO/hooks/hooks.json")
assert_contains "$CLAUDEHOOKS" 'PostToolUseFailure' 'Claude hooks close a failed tool call'
assert_contains "$CLAUDEHOOKS" 'PermissionDenied' 'Claude hooks close a denied tool call'
assert_contains "$CLAUDEHOOKS" 'StopFailure' 'Claude hooks close a turn that ends in an error'
assert_contains "$CLAUDEHOOKS" 'SessionEnd' 'Claude hooks observe the end of a session'
assert_contains "$CLAUDEHOOKS" 'SubagentStart' 'Claude hooks observe subagent lifecycle'
assert_contains "$(sh "$TT" hooks-snippet codex)" "PLUGIN_ROOT" 'codex snippet names the plugin root'
assert_contains "$(sh "$TT" hooks-snippet codex)" "Interrupt" 'codex snippet includes interruption events'
assert_contains "$(cat "$REPO/.codex-plugin/plugin.json")" 'hooks/codex-hooks.json' 'the Codex manifest selects Codex-specific hooks'
assert_contains "$(cat "$REPO/hooks/codex-hooks.json" 2>/dev/null)" 'SubagentStart' 'Codex hooks include subagent lifecycle events'

# The skill command must work from a plugin-cache-shaped copy with no root bin
# directory on PATH.
PLUGIN_COPY="$SANDBOX/plugin-copy"
mkdir -p "$PLUGIN_COPY/bin" "$PLUGIN_COPY/lib" "$PLUGIN_COPY/skills/timetrack/scripts"
cp "$REPO/bin/tt" "$PLUGIN_COPY/bin/tt"
cp "$REPO/lib/report.awk" "$PLUGIN_COPY/lib/report.awk"
cp "$REPO/skills/timetrack/scripts/tt" "$PLUGIN_COPY/skills/timetrack/scripts/tt" 2>/dev/null || :
assert_eq "$TT_ROOT" "$(sh "$PLUGIN_COPY/skills/timetrack/scripts/tt" root 2>/dev/null)" 'the bundled skill command resolves its copied plugin root'

finish

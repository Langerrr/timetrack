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

printf 'Task 1: skeleton\n'
assert_status 2 'unknown subcommand exits 2' -- sh "$TT" nonsense
assert_eq "$TT_HOME" "$(sh "$TT" debug-home)" 'TT_HOME override honoured'
assert_eq "1900000000" "$(TT_NOW=1900000000 sh "$TT" debug-now)" 'TT_NOW override honoured'
assert_eq "testbox" "$(printf 'machine=testbox\n' > "$TT_HOME/config"; sh "$TT" debug-machine)" 'machine from config'
rm -f "$TT_HOME/config"

printf 'Task 2: attribution and mode\n'
assert_eq "sportx	." "$(sh "$TT" debug-attribute "$TT_ROOT/sportx")" 'project root gives subpath .'
assert_eq "sportx	saas-backend" "$(sh "$TT" debug-attribute "$TT_ROOT/sportx/saas-backend")" 'nested gives subpath'
assert_eq "~outside	/etc" "$(sh "$TT" debug-attribute /etc)" 'outside root books to ~outside'
assert_eq "sportx	." "$(sh "$TT" debug-attribute "$TT_ROOT/sportx/")" 'trailing slash tolerated'
assert_eq "~root	." "$(sh "$TT" debug-attribute "$TT_ROOT")" 'the workspace root itself books to ~root'

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

# Consecutive beats inside the gap accumulate.
beat 1900000000 paired sportx . s1
beat 1900000060 paired sportx . s1
assert_contains "$(TT_NOW=1900100000 sh "$TT" report --since 2000-01-01 --until 2100-01-01)" "0h 01m" 'a 60s gap is counted'

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

# The first instant of a local day, where a spring-forward can delete 00:00.
SANTIAGO=$(TZ=America/Santiago sh "$TT" debug-epoch '2026-09-06 15:00')
assert_eq "2026-09-06T01:00:00-0300" \
  "$(TZ=America/Santiago sh "$TT" debug-iso "$(TZ=America/Santiago TT_NOW=$SANTIAGO sh "$TT" debug-midnight)")" \
  'a day with no 00:00 starts at its first real instant'

# %H of 09 and %M of 08 must not be read as octal.
ZEROPAD=$(TZ=UTC sh "$TT" debug-epoch '2026-09-02 09:08')
assert_eq "2026-09-02T00:00:00+0000" \
  "$(TZ=UTC sh "$TT" debug-iso "$(TZ=UTC TT_NOW=$ZEROPAD sh "$TT" debug-midnight)")" \
  'a leading-zero hour and minute are read as base ten'

finish

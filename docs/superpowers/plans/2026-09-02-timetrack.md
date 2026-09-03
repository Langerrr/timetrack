# timetrack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `tt`, a dependency-free POSIX shell tool that records per-project time across `~/workspace` from agent-harness hooks and manual entries, separating paired, solo and manual time, and packages itself as a plugin serving Claude Code and Codex.

**Architecture:** One shell script `bin/tt` holds every subcommand; one awk program `lib/report.awk` holds the reporting engine. Harness hooks append single-line "beats" to an append-only per-machine TSV; reporting reconstructs intervals by summing gaps between consecutive beats that fall under an idle threshold. The repository doubles as a dual-manifest plugin so installing it wires the hooks on both harnesses.

**Tech Stack:** POSIX `sh`, `awk`, `sed`, `tr`, `date`. No runtime dependency beyond a base Unix userland.

**Spec:** `docs/superpowers/specs/2026-09-02-timetrack-design.md`

## Global Constraints

- **POSIX `sh` only.** No bashisms: no `[[`, no arrays, no `local`, no `$'...'`, no `${var,,}`, no process substitution. Target `/bin/sh` as dash on Ubuntu and as bash-in-POSIX-mode on macOS.
- **No runtime dependency** beyond `sh`, `awk`, `sed`, `tr`, `date`, `hostname`, `mkdir`, `cat`. Specifically no `jq`, no `python`, no `sqlite3`, no `realpath`, no GNU-only flags.
- **Dual OS.** Every `date` invocation must work on GNU coreutils and on BSD/macOS. The compat pattern is: try the BSD form, fall back to the GNU form.
- **Single-write appends.** Every log row is emitted by exactly one `printf` redirected with `>>`. This keeps concurrent appends from separate agents atomic without locking. Rows must never exceed 4096 bytes: the `note` field is truncated to 200 characters and stripped of tabs and newlines.
- **Field separator is TAB.** No field may contain a literal tab or newline. Empty fields are written as `-`.
- **11 columns, in this order:** `iso_start`, `kind`, `start`, `end`, `machine`, `harness`, `mode`, `project`, `subpath`, `session`, `note`.
- **Test-overridable environment:** `TT_HOME` (default `$HOME/.timetrack`), `TT_ROOT` (default `$HOME/workspace`), `TT_IDLE_GAP` (default `900`), `TT_NOW` (override current epoch; tests set it for determinism).
- **Hooks must never break a session.** `tt hook` always exits 0, even on malformed input.
- **Commit style:** one short line, why over what. No body unless the change warrants one.

---

### Task 1: Test harness, script skeleton, and `tt init`

Establishes the shape everything else plugs into: the dispatcher, environment resolution, and the data directory.

**Files:**
- Create: `bin/tt`
- Create: `lib/` (empty for now, populated in Task 5)
- Create: `tests/lib.sh`
- Create: `tests/run.sh`
- Create: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `bin/tt <subcommand>` dispatcher exiting 2 on unknown subcommand. Shell functions used by all later tasks: `tt_home` (echoes resolved `TT_HOME`), `tt_root` (echoes resolved `TT_ROOT`), `tt_now` (echoes current epoch, honouring `TT_NOW`), `tt_machine` (echoes machine id), `tt_iso EPOCH` (echoes local ISO-8601 with offset), `tt_epoch 'YYYY-MM-DD HH:MM'` (echoes epoch), `tt_log_file` (echoes the absolute path of this machine's TSV), `tt_die MSG` (stderr + exit 1).

- [ ] **Step 1: Write the test harness**

`tests/lib.sh`:

```sh
# Minimal POSIX assertion helpers. Sourced by tests/run.sh.
TESTS_RUN=0
TESTS_FAILED=0

assert_eq() { # expected actual label
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$1" = "$2" ]; then
    printf '  ok   %s\n' "$3"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$3" "$1" "$2"
  fi
}

assert_status() { # expected_status label -- command...
  expected=$1; label=$2; shift 3
  TESTS_RUN=$((TESTS_RUN + 1))
  "$@" >/dev/null 2>&1
  actual=$?
  if [ "$expected" = "$actual" ]; then
    printf '  ok   %s\n' "$label"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL %s\n       expected status: %s\n       actual status:   %s\n' "$label" "$expected" "$actual"
  fi
}

assert_contains() { # haystack needle label
  TESTS_RUN=$((TESTS_RUN + 1))
  case "$1" in
    *"$2"*) printf '  ok   %s\n' "$3" ;;
    *) TESTS_FAILED=$((TESTS_FAILED + 1))
       printf '  FAIL %s\n       [%s] does not contain [%s]\n' "$3" "$1" "$2" ;;
  esac
}

finish() {
  printf '\n%s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ] || exit 1
}
```

`tests/run.sh`:

```sh
#!/bin/sh
# Runs every test in a throwaway TT_HOME. Usage: sh tests/run.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
TT="$REPO/bin/tt"
. "$HERE/lib.sh"

SANDBOX=${TMPDIR:-/tmp}/tt-test-$$
mkdir -p "$SANDBOX/home" "$SANDBOX/root/sportx/saas-backend" "$SANDBOX/root/tuurny"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

TT_HOME="$SANDBOX/home"
TT_ROOT="$SANDBOX/root"
export TT_HOME TT_ROOT

printf 'Task 1: skeleton\n'
assert_status 2 'unknown subcommand exits 2' -- sh "$TT" nonsense
assert_eq "$TT_HOME" "$(sh "$TT" debug-home)" 'TT_HOME override honoured'
assert_eq "1900000000" "$(TT_NOW=1900000000 sh "$TT" debug-now)" 'TT_NOW override honoured'
assert_eq "testbox" "$(printf 'machine=testbox\n' > "$TT_HOME/config"; sh "$TT" debug-machine)" 'machine from config'
rm -f "$TT_HOME/config"

finish
```

`.gitignore`:

```
# Time logs never belong in the tool repository.
*.tsv
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `sh tests/run.sh`
Expected: FAIL — `bin/tt` does not exist, so every assertion fails or errors.

- [ ] **Step 3: Write `bin/tt`**

```sh
#!/bin/sh
# tt — per-project time tracking across machines and agent harnesses.
set -u

TT_HOME=${TT_HOME:-$HOME/.timetrack}
TT_ROOT=${TT_ROOT:-$HOME/workspace}
TT_IDLE_GAP=${TT_IDLE_GAP:-900}

tt_die() { printf 'tt: %s\n' "$1" >&2; exit 1; }

# Config is a flat key=value file. Values already in the environment win.
tt_config() { # key
  [ -f "$TT_HOME/config" ] || return 1
  sed -n 's/^'"$1"'=\(.*\)$/\1/p' "$TT_HOME/config" | head -1
}

tt_home() { printf '%s\n' "$TT_HOME"; }

tt_root() {
  v=$(tt_config TT_ROOT) || v=''
  [ -n "${v:-}" ] && [ "$TT_ROOT" = "$HOME/workspace" ] && TT_ROOT=$v
  printf '%s\n' "$TT_ROOT"
}

tt_now() { printf '%s\n' "${TT_NOW:-$(date +%s)}"; }

tt_machine() {
  v=$(tt_config machine) || v=''
  if [ -n "${v:-}" ]; then printf '%s\n' "$v"
  else hostname 2>/dev/null | sed 's/\..*//' | tr -c 'A-Za-z0-9-' '-' | sed 's/-*$//'
  fi
}

# BSD date first, GNU second. Both are tried; whichever parses wins.
tt_iso() { # epoch
  date -r "$1" +'%Y-%m-%dT%H:%M:%S%z' 2>/dev/null \
    || date -d "@$1" +'%Y-%m-%dT%H:%M:%S%z' 2>/dev/null \
    || tt_die "cannot format epoch $1"
}

tt_epoch() { # 'YYYY-MM-DD HH:MM'
  date -j -f '%Y-%m-%d %H:%M' "$1" +%s 2>/dev/null \
    || date -d "$1" +%s 2>/dev/null \
    || tt_die "cannot parse time: $1"
}

tt_log_file() { printf '%s/events-%s.tsv\n' "$TT_HOME" "$(tt_machine)"; }

cmd_init() {
  mkdir -p "$TT_HOME/mode" || tt_die "cannot create $TT_HOME"
  [ -f "$TT_HOME/config" ] || printf '# machine=\n# TT_ROOT=\n# TT_IDLE_GAP=900\n' > "$TT_HOME/config"
  f=$(tt_log_file); [ -f "$f" ] || : > "$f"
  printf 'initialised %s (machine: %s)\n' "$TT_HOME" "$(tt_machine)"
}

cmd_help() {
  cat <<'USAGE'
tt — per-project time tracking

  tt init                          create ~/.timetrack
  tt hook                          append one beat from hook JSON on stdin
  tt add PROJECT DURATION [NOTE] [--at 'YYYY-MM-DD HH:MM']
  tt solo [PATH]                   mark the session started in PATH as solo
  tt paired [PATH]                 mark it as paired
  tt sessions                      list known session directories and modes
  tt report [today|week|month] [--since D] [--until D] [--by project|day] [--detail]
  tt sync pull HOST                fetch HOST's log into this machine's repo
  tt install-remote HOST           copy this plugin to HOST and register it
  tt hooks-snippet [claude|codex]  print hook configuration
USAGE
}

sub=${1:-help}
[ $# -gt 0 ] && shift
case "$sub" in
  init)          cmd_init "$@" ;;
  help|-h|--help) cmd_help ;;
  debug-home)    tt_home ;;
  debug-root)    tt_root ;;
  debug-now)     tt_now ;;
  debug-machine) tt_machine ;;
  *)             printf 'tt: unknown subcommand: %s\n' "$sub" >&2; exit 2 ;;
esac
```

Note the `debug-*` subcommands are permanent, documented test seams, not scaffolding. They are omitted from `tt help` because they exist for the test suite.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `chmod +x bin/tt tests/run.sh && sh tests/run.sh`
Expected: PASS, `4 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/tt tests/lib.sh tests/run.sh .gitignore
git commit -m "Add tt skeleton and a dependency-free test harness"
```

---

### Task 2: Path attribution and mode state

Turns a session directory into a project, and holds the paired/solo flag per session directory.

**Files:**
- Modify: `bin/tt` (add functions and three subcommands)
- Modify: `tests/run.sh` (append a Task 2 block before `finish`)

**Interfaces:**
- Consumes: `tt_home`, `tt_root`, `tt_die` from Task 1.
- Produces: `tt_attribute PATH` echoes `project<TAB>subpath`. `tt_mode_key PATH` echoes the mode filename. `tt_mode PATH` echoes `paired` or `solo`. Subcommands `tt solo [PATH]`, `tt paired [PATH]`, `tt sessions`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run.sh` before `finish`:

```sh
printf 'Task 2: attribution and mode\n'
assert_eq "sportx	." "$(sh "$TT" debug-attribute "$TT_ROOT/sportx")" 'project root gives subpath .'
assert_eq "sportx	saas-backend" "$(sh "$TT" debug-attribute "$TT_ROOT/sportx/saas-backend")" 'nested gives subpath'
assert_eq "~outside	/etc" "$(sh "$TT" debug-attribute /etc)" 'outside root attributes to ~outside'
assert_eq "sportx	." "$(sh "$TT" debug-attribute "$TT_ROOT/sportx/")" 'trailing slash tolerated'
assert_eq "~root	." "$(sh "$TT" debug-attribute "$TT_ROOT")" 'the workspace root itself attributes to ~root'

assert_eq "paired" "$(sh "$TT" debug-mode "$TT_ROOT/sportx")" 'default mode is paired'
sh "$TT" solo "$TT_ROOT/sportx" >/dev/null
assert_eq "solo" "$(sh "$TT" debug-mode "$TT_ROOT/sportx")" 'solo is recorded'
assert_eq "paired" "$(sh "$TT" debug-mode "$TT_ROOT/tuurny")" 'sibling directory is unaffected'
sh "$TT" paired "$TT_ROOT/sportx" >/dev/null
assert_eq "paired" "$(sh "$TT" debug-mode "$TT_ROOT/sportx")" 'paired is recorded'

sh "$TT" solo "$TT_ROOT/sportx/saas-backend" >/dev/null
assert_contains "$(sh "$TT" sessions)" "solo" 'sessions lists the mode'
assert_contains "$(sh "$TT" sessions)" "$TT_ROOT/sportx/saas-backend" 'sessions lists the true path'
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `sh tests/run.sh`
Expected: FAIL on every Task 2 assertion — `debug-attribute`, `debug-mode`, `solo`, `paired` and `sessions` all exit 2.

- [ ] **Step 3: Implement**

Add to `bin/tt` above the dispatcher:

```sh
# Absolute path without requiring realpath, which macOS lacks by default.
tt_abs() { # path
  d=$1
  [ -d "$d" ] && { (cd "$d" 2>/dev/null && pwd) && return 0; }
  case "$d" in
    /*) printf '%s\n' "$d" | sed 's://*:/:g; s:/$::' ;;
    *)  printf '%s\n' "$PWD/$d" | sed 's://*:/:g; s:/$::' ;;
  esac
}

tt_attribute() { # abs-path -> project<TAB>subpath
  p=$(tt_abs "$1")
  r=$(tt_root)
  if [ "$p" = "$r" ]; then printf '~root\t.\n'; return; fi
  case "$p" in
    "$r"/*)
      rest=${p#"$r"/}
      proj=${rest%%/*}
      sub=${rest#"$proj"}
      sub=${sub#/}
      [ -n "$sub" ] || sub='.'
      printf '%s\t%s\n' "$proj" "$sub" ;;
    *) printf '~outside\t%s\n' "$p" ;;
  esac
}

tt_mode_key() { # abs-path -> filename
  printf '%s' "$1" | tr -c 'A-Za-z0-9.-' '_'
}

# The file name is a lossy encoding; the file body carries the exact path.
tt_mode() { # abs-path -> paired|solo
  f="$TT_HOME/mode/$(tt_mode_key "$(tt_abs "$1")")"
  [ -f "$f" ] || { printf 'paired\n'; return; }
  cut -f1 < "$f"
}

tt_set_mode() { # mode [path]
  m=$1
  p=$(tt_abs "${2:-$PWD}")
  mkdir -p "$TT_HOME/mode" || tt_die "cannot create $TT_HOME/mode"
  printf '%s\t%s\n' "$m" "$p" > "$TT_HOME/mode/$(tt_mode_key "$p")"
  printf '%s: %s\n' "$m" "$p"
}

cmd_sessions() {
  [ -d "$TT_HOME/mode" ] || return 0
  for f in "$TT_HOME/mode"/*; do
    [ -f "$f" ] || continue
    m=$(cut -f1 < "$f"); p=$(cut -f2 < "$f")
    printf '%-7s %s\n' "$m" "$p"
  done
}
```

Add to the dispatcher `case`:

```sh
  solo)          tt_set_mode solo "${1:-$PWD}" ;;
  paired)        tt_set_mode paired "${1:-$PWD}" ;;
  sessions)      cmd_sessions ;;
  debug-attribute) tt_attribute "$1" ;;
  debug-mode)    tt_mode "$1" ;;
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `sh tests/run.sh`
Expected: PASS, `15 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/tt tests/run.sh
git commit -m "Attribute time by session directory and hold mode per directory"
```

---

### Task 3: `tt hook`

The capture path. Runs on every harness hook event, so it must be fast, silent, and incapable of failing a session.

**Files:**
- Modify: `bin/tt`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `tt_attribute`, `tt_mode`, `tt_now`, `tt_iso`, `tt_machine`, `tt_log_file`.
- Produces: `tt hook` reads hook JSON on stdin and appends one `beat` row. `tt_json_str FIELD JSON` echoes a string field's value or the empty string. `tt_clean TEXT` echoes text with tabs, newlines and carriage returns replaced by spaces, truncated to 200 characters.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run.sh` before `finish`:

```sh
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `sh tests/run.sh`
Expected: FAIL — `tt hook` exits 2, the log stays empty.

- [ ] **Step 3: Implement**

Add to `bin/tt`:

```sh
# Extracts a JSON string field with POSIX sed. Good enough for hook payloads,
# which are machine-generated and flat at the fields we read.
tt_json_str() { # field json
  printf '%s' "$2" \
    | tr ',' '\n' \
    | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1
}

tt_clean() { # text
  printf '%s' "$1" | tr '\t\n\r' '   ' | cut -c1-200
}

cmd_hook() {
  input=$(cat 2>/dev/null) || input=''

  cwd=$(tt_json_str cwd "$input")
  [ -n "$cwd" ] || cwd=$PWD
  sid=$(tt_json_str session_id "$input")
  [ -n "$sid" ] || sid='-'
  evt=$(tt_json_str hook_event_name "$input")
  [ -n "$evt" ] || evt='-'

  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || [ -n "${CLAUDECODE:-}" ]; then harness=claude
  elif [ -n "${PLUGIN_ROOT:-}" ] || [ -n "${CODEX_HOME:-}" ]; then harness=codex
  else harness='-'
  fi

  now=$(tt_now)
  attrib=$(tt_attribute "$cwd")
  proj=$(printf '%s' "$attrib" | cut -f1)
  sub=$(printf '%s' "$attrib" | cut -f2)
  mode=$(tt_mode "$cwd")

  mkdir -p "$TT_HOME" 2>/dev/null
  printf '%s\tbeat\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(tt_iso "$now")" "$now" "$now" "$(tt_machine)" "$harness" "$mode" \
    "$proj" "$sub" "$(tt_clean "$sid")" "$(tt_clean "$evt")" \
    >> "$(tt_log_file)" 2>/dev/null
  return 0
}
```

Add to the dispatcher `case`, and make the whole subcommand failure-proof:

```sh
  hook)          cmd_hook || true; exit 0 ;;
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `sh tests/run.sh`
Expected: PASS, `29 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/tt tests/run.sh
git commit -m "Capture harness activity as single-line beats that cannot fail a session"
```

---

### Task 4: `tt add`

Manual entries, for time spent away from any agent.

**Files:**
- Modify: `bin/tt`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `tt_now`, `tt_iso`, `tt_epoch`, `tt_machine`, `tt_log_file`, `tt_clean`, `tt_die`.
- Produces: `tt add PROJECT DURATION [NOTE] [--at 'YYYY-MM-DD HH:MM']` appends one `span` row with `mode=manual` and prints it. `tt_seconds DURATION` echoes seconds, or exits 1 on an unparseable duration.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run.sh` before `finish`:

```sh
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `sh tests/run.sh`
Expected: FAIL — `debug-seconds`, `debug-epoch` and `add` all exit 2.

- [ ] **Step 3: Implement**

Add to `bin/tt`:

```sh
# Accepts 90m, 1.5h, 2h30m, or a bare number read as minutes.
tt_seconds() { # duration
  printf '%s' "$1" | awk '
    {
      s = tolower($0)
      if (s ~ /^[0-9]+(\.[0-9]+)?$/) { printf "%d\n", s * 60; exit 0 }
      total = 0; matched = 0
      while (match(s, /^[0-9]+(\.[0-9]+)?[hm]/)) {
        piece = substr(s, 1, RLENGTH)
        unit  = substr(piece, RLENGTH, 1)
        value = substr(piece, 1, RLENGTH - 1) + 0
        total += (unit == "h") ? value * 3600 : value * 60
        s = substr(s, RLENGTH + 1)
        matched = 1
      }
      if (matched && s == "") { printf "%d\n", total; exit 0 }
      exit 1
    }'
}

cmd_add() {
  [ $# -ge 2 ] || tt_die "usage: tt add PROJECT DURATION [NOTE] [--at 'YYYY-MM-DD HH:MM']"
  proj=$1; dur=$2; shift 2
  note='-'; at=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --at) [ $# -ge 2 ] || tt_die "--at needs a 'YYYY-MM-DD HH:MM' argument"; at=$2; shift 2 ;;
      *)    note=$1; shift ;;
    esac
  done

  secs=$(tt_seconds "$dur") || tt_die "cannot parse duration: $dur"
  if [ -n "$at" ]; then start=$(tt_epoch "$at"); end=$((start + secs))
  else end=$(tt_now); start=$((end - secs))
  fi

  mkdir -p "$TT_HOME" || tt_die "cannot create $TT_HOME"
  row=$(printf '%s\tspan\t%s\t%s\t%s\t-\tmanual\t%s\t.\t-\t%s' \
    "$(tt_iso "$start")" "$start" "$end" "$(tt_machine)" \
    "$(tt_clean "$proj")" "$(tt_clean "$note")")
  printf '%s\n' "$row" >> "$(tt_log_file)"
  printf '%s\n' "$row"
}
```

Add to the dispatcher `case`:

```sh
  add)           cmd_add "$@" ;;
  debug-seconds) tt_seconds "$1" || exit 1 ;;
  debug-epoch)   tt_epoch "$1" ;;
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `sh tests/run.sh`
Expected: PASS, `44 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/tt tests/run.sh
git commit -m "Record manual spans so time away from an agent still lands in the log"
```

---

### Task 5: The reporting engine

Reconstructs intervals from beats and prints the table. This is the only place the idle-gap rule lives.

**Files:**
- Create: `lib/report.awk`
- Modify: `bin/tt`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `tt_now`, `tt_epoch`, `tt_home`, `tt_die`.
- Produces: `tt report [today|week|month] [--since D] [--until D] [--by project|day] [--detail]`. `tt_fmt EPOCH FORMAT` echoes a formatted date. `tt_self` echoes the directory holding the real `bin/tt` after resolving symlinks. `lib/report.awk` reads concatenated TSVs on stdin with `-v since= -v until= -v gap= -v byday= -v detail=`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run.sh` before `finish`:

```sh
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `sh tests/run.sh`
Expected: FAIL — `debug-iso` and `report` exit 2.

- [ ] **Step 3: Write `lib/report.awk`**

```awk
# Reconstructs time from an event log. Reads concatenated TSVs on stdin.
#   -v since=EPOCH  -v upto=EPOCH  -v gap=SECONDS  -v byday=0|1  -v detail=0|1
BEGIN { FS = "\t" }

# Registering a bucket separately from adding to it keeps a project visible at
# zero when its events never form an interval.
function touch(bucket) {
  if (!(bucket in seen)) { seen[bucket] = 1; keys[++nkeys] = bucket }
}

function add(bucket, mode, secs) {
  touch(bucket)
  tot[bucket, mode] += secs
}

function hm(s,   h, m) {
  h = int(s / 3600); m = int((s % 3600) / 60)
  return sprintf("%dh %02dm", h, m)
}

NF < 11 { next }
{
  start = $3 + 0
  if (start < since || start > upto) next

  key = $8
  if (detail && $9 != ".") key = $8 "/" $9
  bucket = byday ? substr($1, 1, 10) : key

  if ($2 == "span") { add(bucket, $7, $4 - $3); next }

  touch(bucket)
  sk = $5 SUBSEP $10 SUBSEP $8 SUBSEP $9
  if (sk in last) {
    d = start - last[sk]
    if (d > 0 && d <= gap) add(prevbucket[sk], prevmode[sk], d)
  }
  last[sk] = start; prevbucket[sk] = bucket; prevmode[sk] = $7
}

END {
  # Insertion sort. The key count is small, and this avoids depending on gawk.
  for (i = 2; i <= nkeys; i++) {
    v = keys[i]; j = i - 1
    while (j >= 1 && keys[j] > v) { keys[j + 1] = keys[j]; j-- }
    keys[j + 1] = v
  }

  w = 7
  for (i = 1; i <= nkeys; i++) if (length(keys[i]) > w) w = length(keys[i])
  fmt = "%-" w "s  %9s %9s %9s %9s\n"

  printf fmt, (byday ? "DAY" : "PROJECT"), "PAIRED", "SOLO", "MANUAL", "TOTAL"
  gp = 0; gs = 0; gm = 0
  for (i = 1; i <= nkeys; i++) {
    k = keys[i]
    p = tot[k, "paired"] + 0; s = tot[k, "solo"] + 0; m = tot[k, "manual"] + 0
    gp += p; gs += s; gm += m
    printf fmt, k, hm(p), hm(s), hm(m), hm(p + s + m)
  }
  if (nkeys > 0) printf fmt, "TOTAL", hm(gp), hm(gs), hm(gm), hm(gp + gs + gm)
  else print "no events in range"
}
```

- [ ] **Step 4: Implement `tt report`**

Add to `bin/tt`:

```sh
tt_fmt() { # epoch format
  date -r "$1" +"$2" 2>/dev/null || date -d "@$1" +"$2" 2>/dev/null \
    || tt_die "cannot format epoch $1"
}

# Resolves $0 through any symlinks without readlink -f, which macOS lacks.
tt_self() {
  s=$0
  while [ -L "$s" ]; do
    d=$(cd "$(dirname "$s")" && pwd)
    l=$(readlink "$s")
    case "$l" in /*) s=$l ;; *) s="$d/$l" ;; esac
  done
  (cd "$(dirname "$s")" && pwd)
}

tt_midnight() { # epoch -> epoch of that local day at 00:00
  tt_epoch "$(tt_fmt "$1" '%Y-%m-%d') 00:00"
}

cmd_report() {
  now=$(tt_now)
  since=''; upto=$now; byday=0; detail=0
  while [ $# -gt 0 ]; do
    case "$1" in
      today)    since=$(tt_midnight "$now"); shift ;;
      week)     mid=$(tt_midnight "$now"); u=$(tt_fmt "$now" '%u')
                since=$(tt_midnight $((mid - (u - 1) * 86400))); shift ;;
      month)    since=$(tt_epoch "$(tt_fmt "$now" '%Y-%m')-01 00:00"); shift ;;
      --since)  [ $# -ge 2 ] || tt_die "--since needs a YYYY-MM-DD argument"
                since=$(tt_epoch "$2 00:00"); shift 2 ;;
      --until)  [ $# -ge 2 ] || tt_die "--until needs a YYYY-MM-DD argument"
                upto=$(tt_epoch "$2 23:59"); shift 2 ;;
      --by)     [ $# -ge 2 ] || tt_die "--by needs project or day"
                [ "$2" = day ] && byday=1; shift 2 ;;
      --detail) detail=1; shift ;;
      *)        tt_die "unknown report option: $1" ;;
    esac
  done
  [ -n "$since" ] || since=$(tt_midnight "$now")

  gap=$(tt_config TT_IDLE_GAP) || gap=''
  [ -n "${gap:-}" ] || gap=$TT_IDLE_GAP
  lib=${TT_LIB:-$(tt_self)/../lib}

  cat "$TT_HOME"/events-*.tsv 2>/dev/null \
    | awk -v since="$since" -v upto="$upto" -v gap="$gap" \
          -v byday="$byday" -v detail="$detail" -f "$lib/report.awk"
}
```

Add to the dispatcher `case`:

```sh
  report)        cmd_report "$@" ;;
  debug-iso)     tt_iso "$1" ;;
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `sh tests/run.sh`
Expected: PASS, `54 run, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add lib/report.awk bin/tt tests/run.sh
git commit -m "Reconstruct intervals from beats so reports show paired, solo and manual time"
```

---

### Task 6: Plugin packaging and empirical harness verification

Wires the hooks into both harnesses and proves, by running them, that beats actually land.

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `.codex-plugin/plugin.json`
- Create: `hooks/hooks.json`

**Interfaces:**
- Consumes: `tt hook` from Task 3.
- Produces: an installable plugin. The hook command is `sh -c 'exec "${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}/bin/tt" hook'`, which resolves the plugin root from whichever environment variable the invoking harness exports.

- [ ] **Step 1: Write the manifests and hook wiring**

`.claude-plugin/plugin.json`:

```json
{
  "name": "timetrack",
  "version": "0.1.0",
  "description": "Per-project time tracking across machines and agent harnesses, separating paired, solo and manual time.",
  "author": { "name": "lan" },
  "license": "MIT"
}
```

`.codex-plugin/plugin.json`:

```json
{
  "name": "timetrack",
  "version": "0.1.0",
  "description": "Per-project time tracking across machines and agent harnesses, separating paired, solo and manual time.",
  "author": { "name": "lan" },
  "repository": "https://github.com/Langerrr/timetrack",
  "license": "MIT",
  "keywords": ["time", "tracking", "productivity"],
  "interface": {
    "displayName": "timetrack",
    "shortDescription": "Per-project time tracking across machines and harnesses.",
    "longDescription": "timetrack records how much time goes into each project, keeping time worked alongside an agent apart from time an agent worked alone and time spent away from any agent.",
    "developerName": "lan",
    "category": "Productivity",
    "capabilities": ["Read", "Write", "Shell"],
    "defaultPrompt": [
      "Log two hours on sportx for the architecture review.",
      "How much time did I spend on sportx this month?",
      "I'm heading out, let it run solo."
    ],
    "brandColor": "#10A37F"
  }
}
```

`hooks/hooks.json`:

```json
{
  "hooks": {
    "SessionStart": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "sh -c 'exec \"${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}/bin/tt\" hook'" } ] }
    ],
    "UserPromptSubmit": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "sh -c 'exec \"${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}/bin/tt\" hook'" } ] }
    ],
    "PreToolUse": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "sh -c 'exec \"${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}/bin/tt\" hook'" } ] }
    ],
    "PostToolUse": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "sh -c 'exec \"${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}/bin/tt\" hook'" } ] }
    ],
    "Stop": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "sh -c 'exec \"${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}/bin/tt\" hook'" } ] }
    ]
  }
}
```

- [ ] **Step 2: Verify the plugin root resolves under Claude Code**

```bash
mkdir -p /tmp/tt-verify && cd /tmp/tt-verify
TT_HOME=/tmp/tt-verify/home claude --plugin-dir ~/workspace/langerrr/timetrack -p 'reply with the word ok'
wc -l /tmp/tt-verify/home/events-*.tsv
```

Expected: at least two rows, `harness` column (field 6) reading `claude`, and `project` (field 8) reading `~outside` because `/tmp` sits outside `TT_ROOT`.

If the file is missing or empty, the substitution failed. Record which of the two variables was set by adding a temporary probe hook `sh -c 'env | grep -i plugin_root > /tmp/tt-verify/env.txt'`, then hardcode the correct form.

- [ ] **Step 3: Verify the plugin root resolves under Codex**

```bash
codex plugin marketplace add /home/lan/workspace/langerrr 2>/dev/null || true
codex plugin add timetrack
cd /tmp/tt-verify && TT_HOME=/tmp/tt-verify/home codex exec 'reply with the word ok'
awk -F'\t' '$6=="codex"' /tmp/tt-verify/home/events-*.tsv | wc -l
```

Expected: a non-zero count.

If Codex exports neither variable, fall back to writing an absolute path into a Codex-specific hook file at `codex/hooks.json` and declaring `"hooks": "./codex/hooks.json"` in `.codex-plugin/plugin.json`. Record whichever outcome occurred in `README.md`.

- [ ] **Step 4: Confirm the harness split and clean up**

```bash
cut -f6 /tmp/tt-verify/home/events-*.tsv | sort -u
rm -rf /tmp/tt-verify
```

Expected: `claude` and `codex` both present.

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin .codex-plugin hooks
git commit -m "Package as a dual-harness plugin so installing it wires the hooks"
```

---

### Task 7: The skill

Lets an agent make entries, flip mode and read reports on request.

**Files:**
- Create: `skills/timetrack/SKILL.md`

**Interfaces:**
- Consumes: the full `tt` command surface.
- Produces: a skill both harnesses load from the shared `skills/` root.

- [ ] **Step 1: Write the skill**

`skills/timetrack/SKILL.md`:

```markdown
---
name: timetrack
description: Use when the user wants to log time they spent, change whether an agent run counts as paired or solo, or ask how much time went into a project. Triggers on "log two hours on X", "I spent the morning on Y", "track that meeting", "how much time on Z this week", "I'm heading out, let it run", "I'm back".
---

# timetrack

`tt` records per-project time. Run `tt help` for the full surface.

## Logging past work

The user states a project, a duration, and usually when. Resolve each before running anything.

1. **Project.** Match what they said against the directories under `~/workspace`
   (`ls ~/workspace`). "sportx", "the sportsx thing" and "SportX" all resolve to `sportx`.
   Ask when two directories match equally well.
2. **Duration.** Use what they stated. `90m`, `1.5h`, `2h30m` and a bare number of
   minutes all parse.
3. **When.** Convert their phrasing to `YYYY-MM-DD HH:MM` using the current
   timestamp you were given this turn. "Yesterday afternoon" becomes that date at
   `14:00`. Omit `--at` only when they mean the time just ending now.

Then run it and show the row:

    tt add sportx 2h "architecture review" --at '2026-09-01 14:00'

`tt add` prints the row it wrote. Show that row back. Do not paraphrase it.

## Setting mode

`paired` means the user is working alongside the agent. `solo` means the agent is
running while they are elsewhere. Mode is held per session directory, so running
these from your own shell keys them to the right session automatically.

    tt solo      # "I'm heading out", "let it run", "going to lunch"
    tt paired    # "I'm back", "watching now"

Mode applies from that moment forward. It does not reach backwards over work
already recorded.

## Reporting

    tt report            # today
    tt report week
    tt report month
    tt report --since 2026-08-01 --until 2026-08-31
    tt report --by day
    tt report --detail   # break projects out by sub-directory

Read the table back in prose, leading with the number they asked for.

## Correcting a mistake

The log is a tab-separated file at `~/.timetrack/events-<machine>.tsv`, eleven
columns: `iso_start, kind, start, end, machine, harness, mode, project, subpath,
session, note`. Rows with kind `span` are manual entries and may be edited or
deleted. Rows with kind `beat` are captured evidence: leave them as written.

## Rules

- Log only a duration the user stated or confirmed. Never estimate one from how
  long a conversation ran.
- Time coming up in conversation is conversation. Log when asked to log.
- Always show the written row.
- One `tt add` per distinct block of work. Do not batch several into one row.
```

- [ ] **Step 2: Verify the skill loads in both harnesses**

```bash
claude --plugin-dir ~/workspace/langerrr/timetrack -p 'list your available skills' | grep -i timetrack
codex exec 'list your available skills' | grep -i timetrack
```

Expected: a match from each.

- [ ] **Step 3: Verify the skill drives the tool end to end**

```bash
TT_HOME=/tmp/tt-skill claude --plugin-dir ~/workspace/langerrr/timetrack \
  -p 'log 45 minutes on tuurny for a design call that ended at 2026-09-01 16:00'
cut -f2,7,8 /tmp/tt-skill/events-*.tsv
rm -rf /tmp/tt-skill
```

Expected: `span`, `manual`, `tuurny`.

- [ ] **Step 4: Commit**

```bash
git add skills/timetrack/SKILL.md
git commit -m "Add a skill so an agent can log time and read reports on request"
```

---

### Task 8: Remote transport for the mac-mini

Moves the tool out to the edge machine and the log back, without leaving credentials there.

**Files:**
- Modify: `bin/tt`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `tt_home`, `tt_self`, `tt_die`.
- Produces: `tt sync pull HOST`, `tt install-remote HOST`, `tt hooks-snippet [claude|codex]`. Both remote commands invoke `${TT_RSYNC:-rsync}`, which tests override with a stub that records its arguments.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run.sh` before `finish`:

```sh
printf 'Task 8: remote transport\n'
STUB="$SANDBOX/rsync-stub"
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RSYNC_LOG"
STUBEOF
chmod +x "$STUB"
RSYNC_LOG="$SANDBOX/rsync.log"; export RSYNC_LOG
: > "$RSYNC_LOG"

TT_RSYNC="$STUB" sh "$TT" sync pull macmini >/dev/null
assert_contains "$(cat "$RSYNC_LOG")" "macmini:" 'sync pull reads from the host'
assert_contains "$(cat "$RSYNC_LOG")" "events-macmini.tsv" 'sync pull names the host log file'

: > "$RSYNC_LOG"
TT_RSYNC="$STUB" sh "$TT" install-remote macmini >/dev/null
assert_contains "$(cat "$RSYNC_LOG")" "macmini:" 'install-remote writes to the host'

assert_status 1 'sync pull without a host is rejected' -- sh "$TT" sync pull
assert_contains "$(sh "$TT" hooks-snippet claude)" "PreToolUse" 'claude snippet names the events'
assert_contains "$(sh "$TT" hooks-snippet codex)" "PLUGIN_ROOT" 'codex snippet names the plugin root'
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `sh tests/run.sh`
Expected: FAIL — `sync`, `install-remote` and `hooks-snippet` exit 2.

- [ ] **Step 3: Implement**

Add to `bin/tt`:

```sh
cmd_sync() {
  [ "${1:-}" = pull ] || tt_die "usage: tt sync pull HOST"
  shift
  host=${1:-}
  [ -n "$host" ] || tt_die "usage: tt sync pull HOST"
  mkdir -p "$TT_HOME" || tt_die "cannot create $TT_HOME"
  # The whole file is replaced, so repeating a pull changes nothing.
  ${TT_RSYNC:-rsync} -a "$host:.timetrack/events-$host.tsv" "$TT_HOME/events-$host.tsv" \
    || tt_die "could not reach $host"
  printf 'pulled events-%s.tsv\n' "$host"
}

cmd_install_remote() {
  host=${1:-}
  [ -n "$host" ] || tt_die "usage: tt install-remote HOST"
  root=$(tt_self)/..
  ${TT_RSYNC:-rsync} -a --delete "$root/" "$host:timetrack-plugin/" \
    || tt_die "could not reach $host"
  cat <<EOF
copied the plugin to $host:timetrack-plugin

On $host, register it and create the data directory:
  claude: /plugin marketplace add ~/timetrack-plugin
  codex:  codex plugin marketplace add ~/timetrack-plugin && codex plugin add timetrack
  both:   ~/timetrack-plugin/bin/tt init

Set machine=$host in ~/.timetrack/config on $host, so its log file is named
events-$host.tsv and 'tt sync pull $host' finds it.

$host keeps no credentials. Pull its log from a trusted machine with:
  tt sync pull $host
EOF
}

cmd_hooks_snippet() {
  cmd='sh -c '"'"'exec "${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}/bin/tt" hook'"'"''
  case "${1:-claude}" in
    claude) printf 'Add to ~/.claude/settings.json under "hooks":\n\n' ;;
    codex)  printf 'Add to ~/.codex/config.toml under [hooks], or ship hooks/hooks.json:\n\n' ;;
    *)      tt_die "usage: tt hooks-snippet [claude|codex]" ;;
  esac
  for evt in SessionStart UserPromptSubmit PreToolUse PostToolUse Stop; do
    printf '  %s -> %s\n' "$evt" "$cmd"
  done
  printf '\nWhen no plugin root is exported, replace it with the absolute path to bin/tt.\n'
}
```

Add to the dispatcher `case`:

```sh
  sync)           cmd_sync "$@" ;;
  install-remote) cmd_install_remote "$@" ;;
  hooks-snippet)  cmd_hooks_snippet "$@" ;;
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `sh tests/run.sh`
Expected: PASS, `60 run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/tt tests/run.sh
git commit -m "Move the plugin out and the log back over SSH so the edge machine holds no credentials"
```

---

### Task 9: README, marketplace registration, and first install

Makes the tool usable on this machine and findable by a future reader.

**Files:**
- Create: `README.md`
- Modify: `/home/lan/workspace/langerrr/.claude-plugin/marketplace.json`

**Interfaces:**
- Consumes: everything above.
- Produces: an installed, running tracker on this machine.

- [ ] **Step 1: Write `README.md`**

Cover, in this order: what it records and the three modes; install on a trusted machine (`/plugin marketplace add ~/workspace/langerrr`, `/plugin install timetrack@langerrr`, `tt init`, symlink `bin/tt` to `~/workspace/bin/tt`); install on the mac-mini (`tt install-remote macmini`, then `tt sync pull macmini`); the command surface, copied from `tt help`; the eleven-column log format; the environment variables `TT_HOME`, `TT_ROOT`, `TT_IDLE_GAP`, `TT_NOW`, `TT_LIB`, `TT_RSYNC`; and the outcome recorded in Task 6 Step 3 about which plugin-root variable each harness exports.

- [ ] **Step 2: Register in the marketplace**

Add to the `plugins` array in `/home/lan/workspace/langerrr/.claude-plugin/marketplace.json`:

```json
    {
      "name": "timetrack",
      "source": "./timetrack",
      "description": "Per-project time tracking across machines and agent harnesses, separating paired, solo and manual time."
    }
```

- [ ] **Step 3: Create the data repository**

```bash
tt init
git -C ~/.timetrack init -q
printf 'mode/\n' > ~/.timetrack/.gitignore
git -C ~/.timetrack add -A
git -C ~/.timetrack commit -q -m "Start the time log"
```

Mode files stay untracked: they are live per-machine state, not history.

- [ ] **Step 4: Install and verify on this machine**

```bash
ln -sf ~/workspace/langerrr/timetrack/bin/tt ~/workspace/bin/tt
sh tests/run.sh
cd ~/workspace/sportx && tt sessions && tt report
```

Expected: the full suite passes, `tt` resolves through the symlink, and `tt report` prints a table.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "Document install, command surface and log format"
git -C ~/workspace/langerrr add .claude-plugin/marketplace.json
git -C ~/workspace/langerrr commit -m "Offer timetrack from the marketplace"
```

Note: `~/workspace/langerrr` currently has an empty `.git` directory and is not a working repository. If the commit fails, leave the manifest edit uncommitted and tell the user rather than initialising a repository there.

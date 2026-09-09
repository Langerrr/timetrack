#!/bin/sh
# Shared capture and storage helpers for tt entry points.
# The loader supplies TT_HOME, TT_ROOT, TT_MAX_ACTIVE_GAP_SET and tt_self.

tt_die() { printf 'tt: %s\n' "$1" >&2; exit 1; }


tt_config() { # key
  [ -f "$TT_HOME/config" ] || return 1
  sed -n 's/^'"$1"'=\(.*\)$/\1/p' "$TT_HOME/config" | head -1
}

tt_root() {
  v=$(tt_config TT_ROOT) || v=''
  [ -n "${v:-}" ] && [ "$TT_ROOT" = "$HOME/workspace" ] && TT_ROOT=$v
  # Attribution matches "$root"/* against a path already normalised by tt_abs,
  # so a root written with a trailing or doubled slash would match nothing and
  # attribute every project to ~outside. One character in a config file otherwise
  # costs the whole log its attribution.
  TT_ROOT=$(printf '%s' "$TT_ROOT" | sed 's://*:/:g; s:/*$::')
  [ -n "$TT_ROOT" ] || TT_ROOT=/
  printf '%s\n' "$TT_ROOT"
}

tt_now() { printf '%s\n' "${TT_NOW:-$(date +%s)}"; }

tt_machine() {
  v=$(tt_config machine) || v=''
  if [ -n "${v:-}" ]; then printf '%s\n' "$v"
  else hostname 2>/dev/null | sed 's/\..*//' | tr -c 'A-Za-z0-9-' '-' | sed 's/-*$//'
  fi
}


tt_iso() { # epoch
  date -r "$1" +'%Y-%m-%dT%H:%M:%S%z' 2>/dev/null \
    || date -d "@$1" +'%Y-%m-%dT%H:%M:%S%z' 2>/dev/null \
    || tt_die "cannot format epoch $1"
}

tt_fmt() { # epoch format
  date -r "$1" +"$2" 2>/dev/null || date -d "@$1" +"$2" 2>/dev/null \
    || tt_die "cannot format epoch $1"
}

tt_compact_file() { printf '%s/events-%s.tsv\n' "$TT_HOME" "$(tt_machine)"; }


tt_current_file() { printf '%s/current-%s.tsv\n' "$TT_HOME" "$(tt_machine)"; }

# New detail is written here. Completed local days are reduced into the

tt_log_file() { tt_current_file; }


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

# Current modes are a capture-time cache. Each row is
# mode<TAB>abspath<TAB>session, where session '-' means every session below the
# path. Rows are ordered by their last explicit transition, so the latest
# matching ancestor wins. The durable transition itself is also appended to the

tt_modes_file() { printf '%s/modes\n' "$TT_HOME"; }

tt_mode() { # abs-path [session] -> paired|solo
  p=$(tt_abs "$1")
  s=${2:--}
  f=$(tt_modes_file)
  [ -f "$f" ] || { printf 'paired\n'; return; }
  m=$(TT_MODE_PATH=$p TT_MODE_SESSION=$s awk -F '\t' '
    BEGIN { p = ENVIRON["TT_MODE_PATH"]; session = ENVIRON["TT_MODE_SESSION"] }
    function contains(scope, path) {
      return path == scope || index(path, scope "/") == 1
    }
    NF >= 2 {
      row_session = (NF >= 3 && $3 != "" ? $3 : "-")
      if ((row_session == "-" || row_session == session) && contains($2, p))
        v = $1
    }
    END { if (v != "") print v }
  ' "$f")
  [ -n "${m:-}" ] || m=paired
  printf '%s\n' "$m"
}

# mkdir either creates the directory or fails, atomically, on every POSIX
# filesystem -- and unlike flock it exists on macOS. Held only across the
# read-modify-write below, which is one awk and one mv, so contention clears in
# milliseconds. Each retry is itself a fork, which paces the spin; only a lock
# held far longer than any real write reaches the sleep, and a lock left behind

tt_lock_dir() { printf '%s/modes.lock\n' "$TT_HOME"; }

tt_lock() {
  d=$(tt_lock_dir)
  i=0
  while ! mkdir "$d" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 200 ] || sleep 1
    [ "$i" -lt 210 ] || return 1
  done
  return 0
}

tt_unlock() { rmdir "$(tt_lock_dir)" 2>/dev/null || :; }

tt_event_lock_dir() { printf '%s/events-%s.lock\n' "$TT_HOME" "$(tt_machine)"; }

tt_event_lock() {
  d=$(tt_event_lock_dir)
  i=0
  while ! mkdir "$d" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 200 ] || sleep 1
    [ "$i" -lt 210 ] || return 1
  done
  return 0
}

tt_event_unlock() { rmdir "$(tt_event_lock_dir)" 2>/dev/null || :; }

# Appends the durable record of a mode transition, shared by an explicit
# `tt solo`/`tt paired` and an automatic trigger detected in cmd_hook. ORIGIN
# lands in column 11, which a mode row otherwise leaves empty, so a session
# that went solo on its own can be explained later; nothing in reporting

tt_write_mode_row() { # mode path session epoch origin
  wmr_mode=$1
  wmr_path=$2
  wmr_session=$3
  wmr_epoch=$4
  wmr_origin=${5:--}
  wmr_attrib=$(tt_attribute "$wmr_path")
  wmr_proj=$(printf '%s' "$wmr_attrib" | cut -f1)
  wmr_sub=$(printf '%s' "$wmr_attrib" | cut -f2)
  wmr_row=$(printf '%s\tmode\t%s\t%s\t%s\t-\t%s\t%s\t%s\t%s\t%s' \
    "$(tt_iso "$wmr_epoch")" "$wmr_epoch" "$wmr_epoch" "$(tt_machine)" "$wmr_mode" \
    "$(tt_clean "$wmr_proj")" "$(tt_clean "$wmr_sub")" "$(tt_clean "$wmr_session")" \
    "$(tt_clean "$wmr_origin")")
  tt_append_row "$wmr_row" "$wmr_epoch"
}

# Rewrites the capture-time mode cache read by tt_mode, so a hook can stamp
# its very next beat with a transition instead of waiting for a report to
# replay the durable mode row tt_write_mode_row appends alongside it. Shared
# by an explicit `tt solo`/`tt paired` and an automatic trigger in cmd_hook.
#
# Failure is signalled by a plain return, never tt_die: cmd_hook calls this
# directly (not inside a subshell of its own), and an automatic trigger must
# degrade quietly rather than abort the rest of the hook -- ordinary lock
# contention between concurrent hooks is expected, not an error worth dying
# over. tt_set_mode, called only for an explicit `tt solo`/`tt paired`, is

tt_cache_mode() { # mode path session
  cm_mode=$1
  cm_path=$(tt_abs "$2")
  cm_session=$3
  # The modes file separates its fields with a TAB and its rows with a
  # newline, so a path holding either cannot be stored and read back as itself.
  # Refusing it costs two comparisons; an escaping scheme would cost a format.
  tab=$(printf '\t')
  nl=$(printf '\nx'); nl=${nl%x}
  case "$cm_path" in
    *"$tab"*) return 1 ;;
    *"$nl"*)  return 1 ;;
  esac
  case "$cm_session" in
    *"$tab"*) return 1 ;;
    *"$nl"*)  return 1 ;;
    '')        return 1 ;;
  esac
  mkdir -p "$TT_HOME" || return 1
  tt_lock || return 1
  trap 'tt_unlock' EXIT HUP INT TERM
  f=$(tt_modes_file)
  if [ -f "$f" ]; then src=$f; else src=/dev/null; fi
  # Rewritten whole into a temporary file and moved into place, so a reader
  # racing this sees either the old file or the new one, never half of either.
  t="$f.$$"
  if TT_MODE=$cm_mode TT_MODE_PATH=$cm_path TT_MODE_SESSION=$cm_session awk -F '\t' '
    BEGIN {
      m = ENVIRON["TT_MODE"]; p = ENVIRON["TT_MODE_PATH"]
      session = ENVIRON["TT_MODE_SESSION"]
    }
    NF >= 2 {
      row_session = (NF >= 3 && $3 != "" ? $3 : "-")
      if ($2 == p && row_session == session) next
      printf "%s\t%s\t%s\n", $1, $2, row_session
    }
    END { printf "%s\t%s\t%s\n", m, p, session }
  ' "$src" > "$t"
  then
    mv "$t" "$f" || { rm -f "$t"; tt_unlock; trap - EXIT HUP INT TERM; return 1; }
  else
    rm -f "$t"; tt_unlock; trap - EXIT HUP INT TERM; return 1
  fi
  tt_unlock
  trap - EXIT HUP INT TERM
  return 0
}


tt_clean() { # text
  printf '%s' "$1" | tr '\t\n\r' '   ' | cut -c1-200
}

# Counts whitespace-separated words in a JSON string token without ever writing


tt_positive_number() { # value
  awk -v value="$1" 'BEGIN {
    if (value ~ /^[0-9]+([.][0-9]+)?$/ && value + 0 > 0) exit 0
    exit 1
  }'
}

# Zero is a meaningful setting for the knobs that can be switched off, so those

tt_nonnegative_number() { # value
  awk -v value="$1" 'BEGIN {
    if (value ~ /^[0-9]+([.][0-9]+)?$/) exit 0
    exit 1
  }'
}

# The environment outranks the config file, which is why each caller passes the
# marker captured before defaults were applied: an unset variable must still
# yield to the file. A value the validator rejects is a typo, and a typo must

tt_number_setting() { # name set-marker current default validator
  value=$3
  if [ -z "$2" ]; then
    configured=$(tt_config "$1") || configured=''
    [ -z "${configured:-}" ] || value=$configured
  fi
  "$5" "$value" || value=$4
  printf '%s\n' "$value"
}

tt_max_active_gap() {
  tt_number_setting TT_MAX_ACTIVE_GAP "$TT_MAX_ACTIVE_GAP_SET" \
    "$TT_MAX_ACTIVE_GAP" 3600 tt_nonnegative_number
}

# Config file, then environment, then default. These two knobs feed the Python
# reporter rather than a value captured at process start with an

tt_presence_gap() {
  value=$(tt_config TT_PRESENCE_GAP) || value=''
  [ -n "${value:-}" ] || value=${TT_PRESENCE_GAP:-3600}
  tt_positive_number "$value" || value=3600
  printf '%s' "$value"
}

tt_checkin_window() {
  value=$(tt_config TT_CHECKIN_WINDOW) || value=''
  [ -n "${value:-}" ] || value=${TT_CHECKIN_WINDOW:-1200}
  tt_positive_number "$value" || value=1200
  printf '%s' "$value"
}





# Prints CLASS<tab>FINGERPRINT for a submitted prompt.
#
# A /loop or /schedule wake-up resubmits the exact prompt that started the
# run, so its first word still names a trigger command. The recorded
# fingerprint is therefore checked first: only a prompt that is not already
# the session's known trigger can newly classify as trigger, so a replay



# The first instant of a local day. Nothing here parses a midnight, because a
# spring-forward landing on 00:00 deletes it -- Santiago, Havana and Tehran all
# do this, and the date has no local 00:00 to parse. Subtracting the wall-clock
# time of day instead lands within one DST shift of the true start (exactly on
# it when the day holds no transition), and the day boundary is walked to from
# there. The walk terminates: the estimate is never later than the given epoch,

tt_midnight() { # epoch -> epoch of that local day's first instant
  day=$(tt_fmt "$1" '%Y-%m-%d') || exit 1
  hms=$(tt_fmt "$1" '%H %M %S') || exit 1
  set -- "$1" $hms
  # %H, %M and %S are zero-padded, and POSIX arithmetic reads a leading zero
  # as octal, so 08 and 09 would be errors. Strip it.
  e=$(( $1 - ${2#0} * 3600 - ${3#0} * 60 - ${4#0} ))
  while [ "$(tt_fmt "$e" '%Y-%m-%d')" != "$day" ]; do e=$((e + 900)); done
  while [ "$(tt_fmt "$((e - 900))" '%Y-%m-%d')" = "$day" ]; do e=$((e - 900)); done
  printf '%s\n' "$e"
}

tt_next_midnight() { # local-day start -> next local-day start
  # Thirty-six elapsed hours from a day boundary always lands inside the next
  # civil day across ordinary 23-, 24- and 25-hour DST days.
  tt_midnight "$(( $1 + 129600 ))"
}

# Yields the bare epoch of each local midnight in the window -- what
# ttreport's repeatable --boundary option wants, for both reporting and

tt_day_boundary_epochs() { # since upto
  cursor=$(tt_midnight "$1") || return 1
  while [ "$cursor" -lt "$2" ]; do
    printf '%s\n' "$cursor"
    next=$(tt_next_midnight "$cursor") || return 1
    [ "$next" -gt "$cursor" ] || return 1
    cursor=$next
  done
}

# Prefixing with the input sequence gives equal-second events a stable ordering

tt_sort_file() { # input output
  sort_input=$1
  sort_output=$2
  sort_numbered="$sort_output.numbered"
  sort_ordered="$sort_output.ordered"
  sort_tab=$(printf '\t')
  if ! awk -F '\t' '{ printf "%d\t%s\n", NR, $0 }' "$sort_input" > "$sort_numbered"; then
    rm -f "$sort_numbered" "$sort_ordered" "$sort_output"
    return 1
  fi
  if ! sort -t "$sort_tab" -k 4,4n -k 1,1n "$sort_numbered" > "$sort_ordered"; then
    rm -f "$sort_numbered" "$sort_ordered" "$sort_output"
    return 1
  fi
  if ! cut -f 2- "$sort_ordered" > "$sort_output"; then
    rm -f "$sort_numbered" "$sort_ordered" "$sort_output"
    return 1
  fi
  rm -f "$sort_numbered" "$sort_ordered"
  return 0
}

tt_compact_marker() { # compact-file
  [ -f "$1" ] || return 0
  awk -F '\t' 'NR == 1 { if ($2 == "compact") print $3; exit }' "$1"
}

tt_validate_rows() { # file role
  valid_file=$1
  valid_role=$2
  [ -f "$valid_file" ] || return 0
  awk -F '\t' -v role="$valid_role" '
    function uint(value) { return value ~ /^[0-9]+$/ }
    function tracked_mode(value) {
      return value == "paired" || value == "solo" || value == "manual"
    }
    function tracked_category(value) {
      return value == "paired" || value == "checkin" || value == "manual" ||
             value == "agent" || value == "tool"
    }
    function valid_compact() {
      return NF >= 11 && uint($3) && uint($4) && $3 == $4
    }
    # A total row is either the retired 12-field layout -- mode in column 7,
    # seconds in column 11 -- or the current 20-field layout -- category in
    # column 7, seconds in column 16. Both can coexist in the same file: the
    # existing duration-only history passes through without inventing coverage.
    function valid_total_old() {
      return NF == 12 && uint($3) && uint($4) && $4 > $3 &&
             tracked_mode($7) && $8 != "" && $9 != "" &&
             uint($11) && uint($12)
    }
    function valid_total_new() {
      return NF == 20 && uint($3) && uint($4) && $4 > $3 &&
             tracked_category($7) && $8 != "" && $9 != "" && uint($16)
    }
    function valid_total() {
      return valid_total_old() || valid_total_new()
    }
    function valid_coverage() {
      return NF == 20 && uint($3) && uint($4) && $4 > $3 &&
             ($7 == "paired" || $7 == "checkin" || $7 == "manual") &&
             $8 != "" && $9 != "" && uint($16) && $16 == $4 - $3
    }
    function valid_beat() {
      return NF >= 11 && uint($3) && uint($4) && $4 >= $3 &&
             ($7 == "paired" || $7 == "solo") && $8 != "" && $9 != ""
    }
    function valid_span() {
      return NF >= 11 && uint($3) && uint($4) && $4 >= $3 &&
             $7 == "manual" && $8 != "" && $9 != ""
    }
    function valid_mode_event() {
      return NF >= 11 && uint($3) && uint($4) && $3 == $4 &&
             ($7 == "paired" || $7 == "solo") &&
             $8 != "" && $9 != "" && $10 != ""
    }
    function tracked_state_event(value) {
      return value == "heartbeat" || value == "turn" || value == "tool" ||
             value == "continuation" || value == "closed-turn" || value == "tool-coverage"
    }
    # Same split as total: the retired reading-estimate model at its own,
    # narrower width, or the current 20-field layout -- a carried
    # heartbeat, opening or continuation instant; closed-turn/tool-coverage
    # state instead carries an interval. New state reserves column 16 as zero.
    function valid_state_old() {
      return NF >= 18 && NF != 20 && uint($3) && uint($4) && $4 >= $3 &&
             ($7 == "paired" || $7 == "solo") && $8 != "" && $9 != ""
    }
    function valid_state_new() {
      return NF == 20 && uint($3) && uint($4) && $4 >= $3 &&
             (($11 == "closed-turn" || $11 == "tool-coverage") || $3 == $4) &&
             tracked_state_event($11) && $8 != "" && $9 != "" && uint($16)
    }
    function valid_state() {
      return valid_state_old() || valid_state_new()
    }
    function valid_state_child() {
      return NF >= 12 && uint($3) && uint($4) && $4 >= $3 &&
             ($7 == "paired" || $7 == "solo") && $8 != "" && $9 != ""
    }
    function valid_detail() {
      return ($2 == "coverage" && valid_coverage()) ||
             ($2 == "beat" && valid_beat()) ||
             ($2 == "span" && valid_span()) ||
             ($2 == "mode" && valid_mode_event()) ||
             ($2 == "state" && valid_state()) ||
             (($2 == "state-tool" || $2 == "state-agent") && valid_state_child())
    }
    $0 == "" { next }
    role == "compact-source" {
      if (($2 == "compact" && valid_compact()) ||
          ($2 == "total" && valid_total()) || valid_detail()) next
      bad = 1; next
    }
    role == "current-source" {
      if (valid_detail()) next
      bad = 1; next
    }
    role == "compact-output" {
      if (($2 == "total" && valid_total()) || ($2 == "coverage" && valid_coverage())) next
      bad = 1; next
    }
    role == "state-output" {
      if (($2 == "state" && valid_state()) ||
          (($2 == "state-tool" || $2 == "state-agent") && valid_state_child())) next
      bad = 1; next
    }
    { bad = 1 }
    END { exit bad ? 1 : 0 }
  ' "$valid_file"
}

tt_storage_valid() {
  tt_validate_rows "$(tt_compact_file)" compact-source &&
    tt_validate_rows "$(tt_current_file)" current-source
}

tt_compact_cleanup() {
  rm -f "$compact_detail" "$compact_keep" "$compact_combined" \
    "$compact_sorted" "$compact_history" "$compact_new" "$current_new"
}

# The caller holds the per-machine event lock. Reconcile canonical effort
# coverage with new observations and late manual additions. Opaque legacy and
# finalized machine totals pass through untouched. Pending lifecycle facts live

tt_compact_locked() { # cutoff-epoch
  compact_cutoff=$1
  tt_ensure_gitignore || return 1
  compact_file=$(tt_compact_file)
  current_file=$(tt_current_file)
  compact_machine=$(tt_machine)
  compact_detail="$TT_HOME/.tt-detail-$compact_machine.$$"
  compact_keep="$TT_HOME/.tt-keep-$compact_machine.$$"
  compact_combined="$TT_HOME/.tt-combined-$compact_machine.$$"
  compact_sorted="$TT_HOME/.tt-sorted-$compact_machine.$$"
  compact_history="$TT_HOME/.tt-history-$compact_machine.$$"
  compact_new="$TT_HOME/.tt-compact-$compact_machine.$$"
  current_new="$TT_HOME/.tt-current-$compact_machine.$$"
  compact_day=$(tt_fmt "$compact_cutoff" '%Y-%m-%d') || return 1
  compact_lib=${TT_LIB:-$(tt_self)/../lib}

  [ -f "$compact_file" ] || : > "$compact_file"
  [ -f "$current_file" ] || : > "$current_file"
  if ! tt_storage_valid; then
    tt_compact_cleanup
    return 1
  fi
  if ! awk -F '\t' -v detail="$compact_detail" -v keep="$compact_keep" '
      $2 == "beat" || $2 == "span" || $2 == "mode" ||
      $2 == "state" || $2 == "state-tool" || $2 == "state-agent" || $2 == "coverage" {
        print > detail; next
      }
      $2 == "compact" { next }
      { print > keep }
    ' "$compact_file"; then
    tt_compact_cleanup
    return 1
  fi
  [ -f "$compact_detail" ] || : > "$compact_detail"
  [ -f "$compact_keep" ] || : > "$compact_keep"
  if ! cat "$compact_detail" "$current_file" > "$compact_combined"; then
    tt_compact_cleanup
    return 1
  fi
  if ! tt_sort_file "$compact_combined" "$compact_sorted"; then
    tt_compact_cleanup
    return 1
  fi

  if ! compact_first=$(awk -F '\t' -v cutoff="$compact_cutoff" '
      $0 != "" && ($3 + 0) < cutoff {
        at = $3 + 0
        if (!seen || at < first) { first = at; seen = 1 }
      }
      END { if (seen) print first }
    ' "$compact_sorted"); then
    tt_compact_cleanup
    return 1
  fi

  if [ -n "$compact_first" ]; then
    compact_since=$(tt_midnight "$compact_first") || {
      tt_compact_cleanup; return 1;
    }
    compact_presence=$(tt_presence_gap)
    compact_checkin=$(tt_checkin_window)
    compact_active=$(tt_max_active_gap)
    set -- --cutoff "$compact_cutoff" --carry "$current_new" \
           --presence-gap "$compact_presence" \
           --checkin-window "$compact_checkin" \
           --max-active "$compact_active"
    for boundary in $(tt_day_boundary_epochs "$compact_since" "$((compact_cutoff + 1))"); do
      set -- "$@" --boundary "$boundary"
    done
    if ! PYTHONPATH="$compact_lib" python3 -m ttreport.compact "$@" \
        < "$compact_sorted" > "$compact_history"; then
      tt_compact_cleanup
      return 1
    fi
  else
    # Nothing precedes the cutoff: carry today's rows through untouched
    # rather than round-tripping them through the reconstruction.
    if ! cp "$compact_sorted" "$current_new"; then
      tt_compact_cleanup
      return 1
    fi
    : > "$compact_history" || { tt_compact_cleanup; return 1; }
  fi
  if ! tt_validate_rows "$compact_history" compact-output; then
    tt_compact_cleanup
    return 1
  fi
  if ! tt_validate_rows "$current_new" current-source; then
    tt_compact_cleanup
    return 1
  fi

  if ! printf '%s\tcompact\t%s\t%s\t%s\t-\t-\t-\t-\t-\t-\n' \
      "$compact_day" "$compact_cutoff" "$compact_cutoff" "$compact_machine" \
      > "$compact_new"; then
    tt_compact_cleanup
    return 1
  fi
  if ! cat "$compact_history" >> "$compact_new"; then
    tt_compact_cleanup
    return 1
  fi
  if ! cat "$compact_keep" >> "$compact_new"; then
    tt_compact_cleanup
    return 1
  fi
  if ! tt_validate_rows "$compact_new" compact-source; then
    tt_compact_cleanup
    return 1
  fi

  # Moving current first keeps all raw source available in the old compact file
  # if the second move fails during a legacy migration.
  if ! mv "$current_new" "$current_file"; then
    tt_compact_cleanup
    return 1
  fi
  if ! mv "$compact_new" "$compact_file"; then
    tt_compact_cleanup
    return 1
  fi
  tt_compact_cleanup
  return 0
}

tt_append_row() { # row start-epoch
  append_text=$1
  append_at=$2
  mkdir -p "$TT_HOME" || return 1
  tt_event_lock || return 1
  trap 'tt_event_unlock' EXIT HUP INT TERM
  if ! tt_gitignore_ready && ! tt_ensure_gitignore; then
    tt_event_unlock; trap - EXIT HUP INT TERM; return 1
  fi
  if ! printf '%s\n' "$append_text" >> "$(tt_current_file)"; then
    tt_event_unlock; trap - EXIT HUP INT TERM; return 1
  fi
  append_today=$(tt_midnight "$(tt_now)") || {
    tt_event_unlock; trap - EXIT HUP INT TERM; return 1;
  }
  append_marker=$(tt_compact_marker "$(tt_compact_file)")
  if [ "$append_marker" != "$append_today" ] || [ "$append_at" -lt "$append_today" ]; then
    tt_compact_locked "$append_today" || {
      tt_event_unlock; trap - EXIT HUP INT TERM; return 1;
    }
  fi
  tt_event_unlock
  trap - EXIT HUP INT TERM
  return 0
}

tt_ensure_gitignore() {
  ignore_file="$TT_HOME/.gitignore"
  ignore_new="$TT_HOME/.tt-ignore.$$"
  if [ -f "$ignore_file" ]; then ignore_source=$ignore_file
  else ignore_source=/dev/null
  fi
  if ! awk '
    { print; seen[$0] = 1 }
    END {
      if (!seen["modes"]) print "modes"
      if (!seen["modes.lock/"]) print "modes.lock/"
      if (!seen["events-*.lock/"]) print "events-*.lock/"
      if (!seen["current-*.tsv"]) print "current-*.tsv"
      if (!seen[".tt-*"]) print ".tt-*"
    }
  ' "$ignore_source" > "$ignore_new"; then
    rm -f "$ignore_new"
    return 1
  fi
  mv "$ignore_new" "$ignore_file" || { rm -f "$ignore_new"; return 1; }
}

tt_gitignore_ready() {
  ignore_file="$TT_HOME/.gitignore"
  [ -f "$ignore_file" ] || return 1
  awk '
    $0 == "modes" { modes = 1 }
    $0 == "modes.lock/" { modes_lock = 1 }
    $0 == "events-*.lock/" { events_lock = 1 }
    $0 == "current-*.tsv" { current = 1 }
    $0 == ".tt-*" { temporary = 1 }
    END { exit modes && modes_lock && events_lock && current && temporary ? 0 : 1 }
  ' "$ignore_file"
}

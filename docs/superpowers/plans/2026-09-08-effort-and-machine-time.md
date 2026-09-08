# Effort and Machine Time Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single blended time figure with two independent measures — effort (the user's own engagement) and machine time (agent hours, split into agent and tool) — reconstructed from separate classes of evidence.

**Architecture:** Capture stays POSIX `sh` in `bin/tt`, extended with three new TSV columns. Reporting moves to a Python package under `lib/ttreport/`, which reads the timestamp-sorted TSV on stdin and writes the aligned text report on stdout. `lib/report.awk` is retired at the end. Effort is a union of intervals on the user's timeline; machine time is a sum over workers.

**Tech Stack:** POSIX `sh` and `awk` for capture and sorting; Python 3.8+ standard library only for reporting; `python3 -m unittest` for the Python tests; the existing `tests/run.sh` shell harness for end-to-end behaviour.

**Spec:** `docs/superpowers/specs/2026-09-08-effort-and-machine-time-design.md`

## Global Constraints

- Capture (`bin/tt hook`, `tt add`, `tt solo`, `tt paired`) stays POSIX `sh` and `awk`. It must run inside a hook on a machine reached over SSH.
- Reporting may use Python. Standard library only — no pip installs, no third-party packages.
- Python target is 3.8+. Type hints are permitted; `match` statements and `|` union syntax are not.
- The TSV is append-only. Existing rows are never rewritten; new columns are appended to the right and read defensively.
- Effort never exceeds wall-clock time within one project. Machine time is expected to exceed it.
- `EFFORT` is the sum of `PAIRED`, `CHECKIN` and `MANUAL`. `AGENT` and `TOOL` are never added into a total with them.
- Defaults, exact values: `TT_PRESENCE_GAP=3600`, `TT_CHECKIN_WINDOW=1200`, `TT_MAX_ACTIVE_GAP=3600`, `TT_SOLO_COMMANDS=goal,loop,schedule`.
- Prompt text is never stored. Only a fingerprint and a class.
- All times are integer epoch seconds. No floats in stored or compared values.

---

## File Structure

**Created:**

- `lib/ttreport/__init__.py` — package marker, version constant.
- `lib/ttreport/events.py` — TSV row parsing into typed records. Owns the column layout and all backward compatibility for short rows.
- `lib/ttreport/intervals.py` — interval algebra: union, total, clip, split by day boundary. No domain knowledge.
- `lib/ttreport/modes.py` — resolves which mode is in force for a stream at an instant, from `mode` rows.
- `lib/ttreport/machine.py` — worker discovery and the agent/tool split.
- `lib/ttreport/effort.py` — heartbeat extraction, paired intervals, solo episodes.
- `lib/ttreport/report.py` — aggregation into buckets and text formatting.
- `lib/ttreport/__main__.py` — argument parsing, stdin read, dispatch.
- `lib/ttreport/compact.py` — daily rollover and carried state emission.
- `tests/python/test_intervals.py`, `test_events.py`, `test_machine.py`, `test_effort.py`, `test_report.py`, `test_compact.py`

**Modified:**

- `bin/tt` — `cmd_hook` writes three new columns and auto-solo transitions; `cmd_report` invokes Python; `cmd_init` writes the new config template.
- `tests/run.sh` — end-to-end assertions for the new columns, auto-solo, and the report shape.
- `README.md` — the recorded facts, the two measures, the new configuration.

**Deleted at the end:**

- `lib/report.awk`

## Column Layout

The TSV gains three columns. Full layout after this plan:

| # | Column | Notes |
|---|--------|-------|
| 1 | `iso_start` | local time formatted at capture |
| 2 | `kind` | `beat`, `span`, `mode`, `total`, `compact`, `state`, `boundary` |
| 3 | `start` | epoch seconds |
| 4 | `end` | epoch seconds |
| 5 | `machine` | |
| 6 | `harness` | `claude`, `codex`, `-` |
| 7 | `mode` | `paired`, `solo`, `manual` |
| 8 | `project` | |
| 9 | `subpath` | |
| 10 | `session` | |
| 11 | `event` | hook event name for beats; note for spans |
| 12 | `turn_id` | |
| 13 | `tool_use_id` | |
| 14 | `agent_id` | |
| 15 | `agent_type` | |
| 16 | `assistant_words` | |
| 17 | `session_source` | |
| 18 | `tool_name` | **new** — e.g. `Bash`, `Task` |
| 19 | `prompt_class` | **new** — `human`, `trigger`, `machine`, `-` |
| 20 | `prompt_fingerprint` | **new** — 8 hex chars, or `-` |

Rows shorter than 20 fields read their missing columns as `-`.

---

### Task 1: Event parsing

**Files:**
- Create: `lib/ttreport/__init__.py`
- Create: `lib/ttreport/events.py`
- Test: `tests/python/test_events.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `Row` (a `NamedTuple` with the fields below), `parse_line(line: str) -> Optional[Row]`, `parse_stream(lines: Iterable[str]) -> List[Row]`, and the constant `SUBAGENT_TOOLS = frozenset(["Task", "Agent"])`.

`Row` fields, in order: `iso: str`, `kind: str`, `start: int`, `end: int`, `machine: str`, `harness: str`, `mode: str`, `project: str`, `subpath: str`, `session: str`, `event: str`, `turn_id: str`, `tool_use_id: str`, `agent_id: str`, `agent_type: str`, `words: str`, `session_source: str`, `tool_name: str`, `prompt_class: str`, `fingerprint: str`.

`Row` also exposes a property `stream: Tuple[str, str, str]` returning `(machine, harness, session)` when `session` is neither empty nor `-`, and `(machine, harness, project + "/" + subpath)` otherwise — a session id identifies one timeline even when the reported cwd changes, and anonymous legacy rows fall back to the path so unrelated hooks do not merge.

- [ ] **Step 1: Write the failing test**

```python
# tests/python/test_events.py
import unittest
from ttreport.events import Row, parse_line, parse_stream


def row(*fields):
    return "\t".join(fields)


class TestParseLine(unittest.TestCase):
    def test_full_row_parses_every_column(self):
        line = row(
            "2026-09-08T11:35:07-0400", "beat", "1788000000", "1788000000",
            "m1", "claude", "paired", "sportx", ".", "sess1",
            "UserPromptSubmit", "t1", "-", "-", "-", "-", "-",
            "-", "human", "ab12cd34",
        )
        r = parse_line(line)
        self.assertEqual(r.kind, "beat")
        self.assertEqual(r.start, 1788000000)
        self.assertEqual(r.event, "UserPromptSubmit")
        self.assertEqual(r.prompt_class, "human")
        self.assertEqual(r.fingerprint, "ab12cd34")

    def test_legacy_17_column_row_defaults_new_columns(self):
        line = row(
            "2026-09-08T11:35:07-0400", "beat", "1788000000", "1788000000",
            "m1", "claude", "paired", "sportx", ".", "sess1",
            "PreToolUse", "t1", "tool9", "-", "-", "-", "-",
        )
        r = parse_line(line)
        self.assertEqual(r.tool_use_id, "tool9")
        self.assertEqual(r.tool_name, "-")
        self.assertEqual(r.prompt_class, "-")
        self.assertEqual(r.fingerprint, "-")

    def test_row_with_unparsable_timestamp_is_dropped(self):
        line = row("bad", "beat", "not-a-number", "0", "m1", "claude",
                   "paired", "sportx", ".", "s", "Stop")
        self.assertIsNone(parse_line(line))

    def test_blank_and_short_lines_are_dropped(self):
        self.assertIsNone(parse_line(""))
        self.assertIsNone(parse_line("only\tthree\tfields"))

    def test_stream_prefers_session_id(self):
        r = parse_line(row(
            "i", "beat", "1", "1", "m1", "claude", "paired", "sportx",
            "sub", "sess1", "Stop"))
        self.assertEqual(r.stream, ("m1", "claude", "sess1"))

    def test_stream_falls_back_to_path_without_session(self):
        r = parse_line(row(
            "i", "beat", "1", "1", "m1", "claude", "paired", "sportx",
            "sub", "-", "Stop"))
        self.assertEqual(r.stream, ("m1", "claude", "sportx/sub"))

    def test_parse_stream_skips_bad_rows_and_keeps_order(self):
        good = row("i", "beat", "5", "5", "m", "c", "paired", "p", ".",
                   "s", "Stop")
        rows = parse_stream([good, "", "junk", good])
        self.assertEqual(len(rows), 2)
        self.assertEqual([r.start for r in rows], [5, 5])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/lan/workspace/langerrr/timetrack && PYTHONPATH=lib python3 -m unittest discover -s tests/python -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'ttreport'`

- [ ] **Step 3: Write minimal implementation**

```python
# lib/ttreport/__init__.py
"""Reporting for timetrack. Reads the timestamp-sorted event TSV."""

__version__ = "1.0.0"
```

```python
# lib/ttreport/events.py
"""Parses the event TSV into typed rows.

This module owns the column layout. Rows written before a column existed
are shorter than the current layout and read their missing fields as "-",
so an old log replays without conversion.
"""

from typing import Iterable, List, NamedTuple, Optional, Tuple

COLUMNS = 20
MIN_COLUMNS = 11

SUBAGENT_TOOLS = frozenset(["Task", "Agent"])


class Row(NamedTuple):
    iso: str
    kind: str
    start: int
    end: int
    machine: str
    harness: str
    mode: str
    project: str
    subpath: str
    session: str
    event: str
    turn_id: str
    tool_use_id: str
    agent_id: str
    agent_type: str
    words: str
    session_source: str
    tool_name: str
    prompt_class: str
    fingerprint: str

    @property
    def stream(self):
        # type: () -> Tuple[str, str, str]
        if self.session and self.session != "-":
            return (self.machine, self.harness, self.session)
        return (self.machine, self.harness, self.project + "/" + self.subpath)


def parse_line(line):
    # type: (str) -> Optional[Row]
    line = line.rstrip("\n")
    if not line:
        return None
    fields = line.split("\t")
    if len(fields) < MIN_COLUMNS:
        return None
    fields = fields + ["-"] * (COLUMNS - len(fields))
    try:
        start = int(fields[2])
        end = int(fields[3])
    except ValueError:
        return None
    return Row(
        iso=fields[0], kind=fields[1], start=start, end=end,
        machine=fields[4], harness=fields[5], mode=fields[6],
        project=fields[7], subpath=fields[8], session=fields[9],
        event=fields[10], turn_id=fields[11], tool_use_id=fields[12],
        agent_id=fields[13], agent_type=fields[14], words=fields[15],
        session_source=fields[16], tool_name=fields[17],
        prompt_class=fields[18], fingerprint=fields[19],
    )


def parse_stream(lines):
    # type: (Iterable[str]) -> List[Row]
    out = []
    for line in lines:
        row = parse_line(line)
        if row is not None:
            out.append(row)
    return out
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/lan/workspace/langerrr/timetrack && PYTHONPATH=lib python3 -m unittest discover -s tests/python -v`
Expected: PASS, 7 tests

- [ ] **Step 5: Commit**

```bash
git add lib/ttreport/__init__.py lib/ttreport/events.py tests/python/test_events.py
git commit -m "Parse the event log into typed rows"
```

---

### Task 2: Interval algebra

**Files:**
- Create: `lib/ttreport/intervals.py`
- Test: `tests/python/test_intervals.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `union(spans: Iterable[Tuple[int, int]]) -> List[Tuple[int, int]]`, `total(spans) -> int`, `clip(spans, since: int, upto: int) -> List[Tuple[int, int]]`, `split_days(spans, boundaries: Sequence[int]) -> List[Tuple[int, Tuple[int, int]]]`.

`union` merges overlapping and touching spans and drops empty ones. `total` sums span lengths without merging — callers pass an already-unioned list when they want union semantics, and a raw list when they want a sum. `split_days` returns `(boundary_start, span)` pairs, cutting each span at every boundary that falls inside it. The portion of a span lying before the first boundary belongs to no reported day and is discarded; the remainder is still cut and returned.

- [ ] **Step 1: Write the failing test**

```python
# tests/python/test_intervals.py
import unittest
from ttreport.intervals import union, total, clip, split_days


class TestUnion(unittest.TestCase):
    def test_disjoint_spans_are_kept_apart(self):
        self.assertEqual(union([(0, 10), (20, 30)]), [(0, 10), (20, 30)])

    def test_overlapping_spans_merge(self):
        self.assertEqual(union([(0, 10), (5, 20)]), [(0, 20)])

    def test_touching_spans_merge(self):
        self.assertEqual(union([(0, 10), (10, 20)]), [(0, 20)])

    def test_contained_span_disappears(self):
        self.assertEqual(union([(0, 100), (10, 20)]), [(0, 100)])

    def test_unsorted_input_is_handled(self):
        self.assertEqual(union([(20, 30), (0, 10), (5, 25)]), [(0, 30)])

    def test_empty_and_inverted_spans_are_dropped(self):
        self.assertEqual(union([(5, 5), (10, 4), (0, 3)]), [(0, 3)])

    def test_parallel_sessions_collapse_to_one_hour(self):
        # Two sessions attended for the same hour are one hour of effort.
        self.assertEqual(total(union([(0, 3600), (0, 3600)])), 3600)


class TestTotal(unittest.TestCase):
    def test_total_sums_without_merging(self):
        # Machine time sums; five parallel workers are five workers.
        self.assertEqual(total([(0, 600)] * 5), 3000)

    def test_total_of_empty_is_zero(self):
        self.assertEqual(total([]), 0)


class TestClip(unittest.TestCase):
    def test_span_is_trimmed_to_the_window(self):
        self.assertEqual(clip([(0, 100)], 10, 50), [(10, 50)])

    def test_span_outside_the_window_is_dropped(self):
        self.assertEqual(clip([(0, 5)], 10, 50), [])

    def test_span_inside_the_window_is_untouched(self):
        self.assertEqual(clip([(20, 30)], 10, 50), [(20, 30)])


class TestSplitDays(unittest.TestCase):
    def test_span_within_one_day_is_not_split(self):
        self.assertEqual(split_days([(10, 20)], [0, 100]), [(0, (10, 20))])

    def test_span_crossing_a_boundary_is_cut(self):
        self.assertEqual(
            split_days([(50, 150)], [0, 100, 200]),
            [(0, (50, 100)), (100, (100, 150))],
        )

    def test_span_before_the_first_boundary_is_dropped(self):
        self.assertEqual(split_days([(0, 50)], [100, 200]), [])

    def test_span_straddling_the_first_boundary_keeps_its_tail(self):
        self.assertEqual(split_days([(50, 150)], [100, 200]),
                         [(100, (100, 150))])

    def test_span_crossing_several_boundaries_is_cut_at_each(self):
        self.assertEqual(
            split_days([(50, 250)], [0, 100, 200]),
            [(0, (50, 100)), (100, (100, 200)), (200, (200, 250))],
        )


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/lan/workspace/langerrr/timetrack && PYTHONPATH=lib python3 -m unittest tests.python.test_intervals -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'ttreport.intervals'`

- [ ] **Step 3: Write minimal implementation**

```python
# lib/ttreport/intervals.py
"""Interval algebra. No domain knowledge lives here.

Effort unions its spans because one person cannot be in two places.
Machine time sums its spans because agents genuinely run in parallel.
Both operations are here so the domain modules choose between them
explicitly rather than by accident.
"""

import bisect
from typing import Iterable, List, Sequence, Tuple

Span = Tuple[int, int]


def union(spans):
    # type: (Iterable[Span]) -> List[Span]
    ordered = sorted((s for s in spans if s[1] > s[0]))
    merged = []  # type: List[Span]
    for start, end in ordered:
        if merged and start <= merged[-1][1]:
            if end > merged[-1][1]:
                merged[-1] = (merged[-1][0], end)
        else:
            merged.append((start, end))
    return merged


def total(spans):
    # type: (Iterable[Span]) -> int
    return sum(end - start for start, end in spans if end > start)


def clip(spans, since, upto):
    # type: (Iterable[Span], int, int) -> List[Span]
    out = []
    for start, end in spans:
        start = max(start, since)
        end = min(end, upto)
        if end > start:
            out.append((start, end))
    return out


def split_days(spans, boundaries):
    # type: (Iterable[Span], Sequence[int]) -> List[Tuple[int, Span]]
    out = []
    ordered = sorted(boundaries)
    for start, end in spans:
        cursor = start
        while cursor < end:
            index = bisect.bisect_right(ordered, cursor) - 1
            if index < 0:
                # Before the first boundary: that prefix belongs to no
                # reported day, so skip to the first one and cut the rest.
                cursor = ordered[0]
                if cursor >= end:
                    break
                continue
            day = ordered[index]
            nxt = ordered[index + 1] if index + 1 < len(ordered) else end
            finish = min(end, nxt)
            if finish <= cursor:
                break
            out.append((day, (cursor, finish)))
            cursor = finish
    return out
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/lan/workspace/langerrr/timetrack && PYTHONPATH=lib python3 -m unittest tests.python.test_intervals -v`
Expected: PASS, 15 tests

- [ ] **Step 5: Commit**

```bash
git add lib/ttreport/intervals.py tests/python/test_intervals.py
git commit -m "Add interval union and sum"
```

---

### Task 3: Capture the new columns and automatic solo

**Files:**
- Modify: `bin/tt` — `cmd_hook` (currently `bin/tt:441-491`), `cmd_init` (currently `bin/tt:992`)
- Modify: `tests/run.sh` — append a new section at the end
- Test: `tests/run.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: rows carrying columns 18–20 as described in the Column Layout section, and `mode` rows written automatically when a solo-trigger command is submitted.

Three shell functions are added: `tt_fingerprint STRING` prints 8 hex characters, `tt_solo_commands` prints the configured trigger list, and `tt_classify_prompt PROMPT SESSION` prints `CLASS<tab>FINGERPRINT`.

Classification rules, in order:
1. Prompt is empty or the event is not `UserPromptSubmit` → `-`, fingerprint `-`.
2. Prompt's first word, stripped of a leading `/` and of any `plugin:` prefix, is in `TT_SOLO_COMMANDS` → `trigger`. The fingerprint is recorded, and `tt` writes a `solo` mode row for this session.
3. A `trigger` fingerprint is already recorded for this session and this prompt's fingerprint matches it → `machine`. A replayed `/loop` wake-up lands here.
4. Otherwise → `human`.

The recorded trigger fingerprint lives at `$TT_HOME/trigger/<session>`, written when rule 2 fires and removed on `SessionEnd`.

- [ ] **Step 1: Write the failing test**

```sh
# append to tests/run.sh, before the final summary line
printf 'Task N: prompt classification and automatic solo\n'

hook_json() { # session event prompt
  printf '{"session_id":"%s","hook_event_name":"%s","cwd":"%s","user_prompt":"%s","tool_name":"%s"}' \
    "$1" "$2" "$TT_ROOT/sportx" "$3" "${4:--}"
}

CUR="$TT_HOME/current-$(sh "$TT" debug-machine).tsv"
: > "$CUR"

hook_json s1 UserPromptSubmit "please review the design" | sh "$TT" hook
LAST=$(tail -1 "$CUR")
assert_eq "human" "$(printf '%s' "$LAST" | cut -f19)" 'an ordinary prompt classifies as human'
assert_status 1 'a human prompt records a fingerprint' -- \
  sh -c "printf '%s' \"$LAST\" | cut -f20 | grep -qx -"

hook_json s1 PreToolUse "" Bash | sh "$TT" hook
assert_eq "Bash" "$(tail -1 "$CUR" | cut -f18)" 'tool_name is recorded'

hook_json s2 UserPromptSubmit "/goal ship the redesign" | sh "$TT" hook
assert_eq "trigger" "$(tail -1 "$CUR" | cut -f19)" 'a solo-trigger command classifies as trigger'
assert_eq "solo" "$(sh "$TT" debug-mode "$TT_ROOT/sportx" s2)" 'a trigger command sets solo for its session'
assert_eq "paired" "$(sh "$TT" debug-mode "$TT_ROOT/sportx" s1)" 'another session keeps its own mode'

hook_json s2 UserPromptSubmit "/goal ship the redesign" | sh "$TT" hook
assert_eq "machine" "$(tail -1 "$CUR" | cut -f19)" 'a replayed trigger prompt classifies as machine'

hook_json s2 UserPromptSubmit "how is it going" | sh "$TT" hook
assert_eq "human" "$(tail -1 "$CUR" | cut -f19)" 'a check-in during a solo run is a human prompt'

hook_json s2 SessionEnd "" | sh "$TT" hook
hook_json s2 UserPromptSubmit "/goal ship the redesign" | sh "$TT" hook
assert_eq "trigger" "$(tail -1 "$CUR" | cut -f19)" 'SessionEnd clears the recorded trigger'

hook_json s3 UserPromptSubmit "/deploy now" | TT_SOLO_COMMANDS=deploy sh "$TT" hook
assert_eq "trigger" "$(tail -1 "$CUR" | cut -f19)" 'the trigger list is configurable'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/lan/workspace/langerrr/timetrack && sh tests/run.sh`
Expected: FAIL — `an ordinary prompt classifies as human` reports the empty string, because column 19 does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Add these helpers to `bin/tt`, above `cmd_hook`:

```sh
# A fingerprint identifies a repeated prompt without storing what it said.
# cksum is in POSIX and present on both target platforms; the value only has
# to be stable within one machine's log.
tt_fingerprint() { # string
  printf '%s' "$1" | cksum | awk '{ printf "%08x\n", $1 }'
}

tt_solo_commands() {
  value=$(tt_config TT_SOLO_COMMANDS) || value=''
  [ -n "${value:-}" ] || value=${TT_SOLO_COMMANDS:-goal,loop,schedule}
  printf '%s' "$value"
}

tt_trigger_file() { # session
  printf '%s/trigger/%s' "$TT_HOME" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
}

# Prints CLASS<tab>FINGERPRINT for a submitted prompt.
tt_classify_prompt() { # prompt session
  prompt=$1; sid=$2
  if [ -z "$prompt" ]; then printf -- '-\t-\n'; return 0; fi
  fp=$(tt_fingerprint "$prompt")
  # The command word, without its leading slash or any plugin: prefix.
  word=$(printf '%s' "$prompt" | awk '{ print $1 }' | sed 's|^/||; s|^[^:]*:||')
  if printf '%s' "$(tt_solo_commands)" | tr ',' '\n' | grep -qx -- "$word"; then
    mkdir -p "$TT_HOME/trigger" 2>/dev/null || :
    printf '%s\n' "$fp" > "$(tt_trigger_file "$sid")" 2>/dev/null || :
    printf 'trigger\t%s\n' "$fp"
    return 0
  fi
  known=$(cat "$(tt_trigger_file "$sid")" 2>/dev/null) || known=''
  if [ -n "$known" ] && [ "$known" = "$fp" ]; then
    printf 'machine\t%s\n' "$fp"
    return 0
  fi
  printf 'human\t%s\n' "$fp"
}
```

In `cmd_hook`, after `session_source` is read, add:

```sh
  tool_name=$(tt_json_str tool_name "$input")
  [ -n "$tool_name" ] || tool_name='-'
  user_prompt=$(tt_json_str user_prompt "$input")
  [ -n "$user_prompt" ] || user_prompt=$(tt_json_str prompt "$input")
  prompt_class='-'; prompt_fp='-'
  if [ "$evt" = UserPromptSubmit ]; then
    classified=$(tt_classify_prompt "$user_prompt" "$sid")
    prompt_class=$(printf '%s' "$classified" | cut -f1)
    prompt_fp=$(printf '%s' "$classified" | cut -f2)
  fi
  [ "$evt" != SessionEnd ] || rm -f "$(tt_trigger_file "$sid")" 2>/dev/null || :
```

Extend the row `printf` to twenty columns:

```sh
  row=$(printf '%s\tbeat\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$(tt_iso "$now")" "$now" "$now" "$(tt_machine)" "$harness" "$mode" \
    "$(tt_clean "$proj")" "$(tt_clean "$sub")" "$(tt_clean "$sid")" "$(tt_clean "$evt")" \
    "$(tt_clean "$turn")" "$(tt_clean "$tool")" "$(tt_clean "$agent")" \
    "$(tt_clean "$agent_type")" "$words" "$(tt_clean "$session_source")" \
    "$(tt_clean "$tool_name")" "$prompt_class" "$prompt_fp")
```

Immediately after `tt_append_row`, write the automatic solo transition. It must be written after the beat so the mode row's timestamp does not precede the prompt that caused it:

```sh
  if [ "$prompt_class" = trigger ]; then
    tt_write_mode_row solo "$cwd" "$sid" "$now" >/dev/null 2>&1 || :
  fi
```

`tt_write_mode_row` is the existing mode-row writer used by `cmd_mode`; extract it from `cmd_mode` if it is still inline there, so both callers share it. Its signature is `tt_write_mode_row MODE PATH SESSION EPOCH ORIGIN`, where `ORIGIN` is `hand` for `tt solo`/`tt paired` and `auto` for a trigger command. It is written into column 11, which mode rows otherwise leave empty, and exists so a session that went solo on its own can be explained later. Nothing in reporting reads it.

Add this assertion to the test above:

```sh
assert_eq "auto" "$(grep '	mode	' "$CUR" | tail -1 | cut -f11)" 'an automatic transition records its origin'
```

Update the `cmd_init` config template:

```sh
  [ -f "$TT_HOME/config" ] || printf '# machine=\n# TT_ROOT=\n# TT_PRESENCE_GAP=3600\n# TT_CHECKIN_WINDOW=1200\n# TT_MAX_ACTIVE_GAP=3600\n# TT_SOLO_COMMANDS=goal,loop,schedule\n' > "$TT_HOME/config"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/lan/workspace/langerrr/timetrack && sh tests/run.sh`
Expected: PASS — every assertion in the new section reports OK, and no earlier assertion regresses.

- [ ] **Step 5: Commit**

```bash
git add bin/tt tests/run.sh
git commit -m "Record tool names and classify submitted prompts"
```

---

### Task 4: Mode resolution

**Files:**
- Create: `lib/ttreport/modes.py`
- Test: `tests/python/test_modes.py`

**Interfaces:**
- Consumes: `Row` from `ttreport.events`.
- Produces: `ModeTimeline` with `ModeTimeline.from_rows(rows: Iterable[Row]) -> ModeTimeline` and `timeline.at(stream: Tuple[str, str, str], when: int, project: str, subpath: str) -> str` returning `"paired"` or `"solo"`.

The stream key collapses to a session id when one exists, which discards the path. A path-scoped transition needs the path, so `at` takes `project` and `subpath` explicitly rather than trying to recover them from the key.

A `mode` row applies forward from its timestamp to every stream it covers: the same machine, and either the same session id or — when the mode row names no session — any stream whose project and subpath sit at or below the mode row's path. A stream with no transition reads as `paired`.

- [ ] **Step 1: Write the failing test**

```python
# tests/python/test_modes.py
import unittest
from ttreport.events import parse_line
from ttreport.modes import ModeTimeline


def mode_row(at, mode, project, subpath, session):
    return parse_line("\t".join([
        "i", "mode", str(at), str(at), "m1", "-", mode, project, subpath,
        session, "-",
    ]))


def beat(at, project, subpath, session):
    return parse_line("\t".join([
        "i", "beat", str(at), str(at), "m1", "claude", "paired", project,
        subpath, session, "UserPromptSubmit",
    ]))


class TestModeTimeline(unittest.TestCase):
    def setUp(self):
        self.row = beat(0, "sportx", ".", "s1")

    def at(self, timeline, when, row=None):
        row = row or self.row
        return timeline.at(row.stream, when, row.project, row.subpath)

    def test_default_is_paired(self):
        t = ModeTimeline.from_rows([])
        self.assertEqual(self.at(t, 100), "paired")

    def test_transition_applies_forward_only(self):
        t = ModeTimeline.from_rows([mode_row(100, "solo", "sportx", ".", "s1")])
        self.assertEqual(self.at(t, 99), "paired")
        self.assertEqual(self.at(t, 100), "solo")
        self.assertEqual(self.at(t, 5000), "solo")

    def test_later_transition_wins(self):
        t = ModeTimeline.from_rows([
            mode_row(100, "solo", "sportx", ".", "s1"),
            mode_row(200, "paired", "sportx", ".", "s1"),
        ])
        self.assertEqual(self.at(t, 150), "solo")
        self.assertEqual(self.at(t, 250), "paired")

    def test_session_scoped_transition_does_not_reach_another_session(self):
        other = beat(0, "sportx", ".", "s2")
        t = ModeTimeline.from_rows([mode_row(100, "solo", "sportx", ".", "s1")])
        self.assertEqual(self.at(t, 150, other), "paired")

    def test_pathwide_transition_reaches_every_session_below_it(self):
        nested = beat(0, "sportx", "saas-backend", "s2")
        t = ModeTimeline.from_rows([mode_row(100, "solo", "sportx", ".", "-")])
        self.assertEqual(self.at(t, 150, nested), "solo")

    def test_pathwide_transition_does_not_reach_a_sibling_project(self):
        sibling = beat(0, "tuurny", ".", "s3")
        t = ModeTimeline.from_rows([mode_row(100, "solo", "sportx", ".", "-")])
        self.assertEqual(self.at(t, 150, sibling), "paired")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/lan/workspace/langerrr/timetrack && PYTHONPATH=lib python3 -m unittest tests.python.test_modes -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'ttreport.modes'`

- [ ] **Step 3: Write minimal implementation**

```python
# lib/ttreport/modes.py
"""Which mode is in force for a stream at an instant.

A path-scoped transition reaches every session at or below that path, so
`tt solo` typed at a project root also covers a tool that later reports a
nested working directory.
"""

from typing import Iterable, List, Tuple

from .events import Row

PAIRED = "paired"
SOLO = "solo"


def _covers(row, project, subpath):
    # type: (Row, str, str) -> bool
    if row.project != project:
        return False
    if row.subpath in (".", "-", ""):
        return True
    return subpath == row.subpath or subpath.startswith(row.subpath + "/")


class ModeTimeline(object):
    def __init__(self, transitions):
        # type: (List[Row]) -> None
        self._transitions = transitions

    @classmethod
    def from_rows(cls, rows):
        # type: (Iterable[Row]) -> ModeTimeline
        transitions = [r for r in rows if r.kind == "mode"]
        transitions.sort(key=lambda r: r.start)
        return cls(transitions)

    def at(self, stream, when, project, subpath):
        # type: (Tuple[str, str, str], int, str, str) -> str
        machine, _harness, key = stream
        mode = PAIRED
        for row in self._transitions:
            if row.start > when:
                break
            if row.machine != machine:
                continue
            if row.session not in ("-", ""):
                if row.session != key:
                    continue
            elif not _covers(row, project, subpath):
                continue
            mode = row.mode if row.mode in (PAIRED, SOLO) else mode
        return mode
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/lan/workspace/langerrr/timetrack && PYTHONPATH=lib python3 -m unittest tests.python.test_modes -v`
Expected: PASS, 6 tests

- [ ] **Step 5: Commit**

```bash
git add lib/ttreport/modes.py tests/python/test_modes.py
git commit -m "Resolve which mode covers a stream"
```

---

### Task 5: Machine time

**Files:**
- Create: `lib/ttreport/machine.py`
- Test: `tests/python/test_machine.py`

**Interfaces:**
- Consumes: `Row`, `SUBAGENT_TOOLS` from `ttreport.events`; `union`, `total` from `ttreport.intervals`.
- Produces: `MachineSpans` — a `NamedTuple` with `agent: List[Tuple[str, str, Tuple[int, int]]]` and `tool: List[Tuple[str, str, Tuple[int, int]]]`, each entry `(project, subpath, span)` — and `machine_spans(rows: Iterable[Row], max_active: int) -> MachineSpans`.

Rules:
- A **tool bracket** runs from `PreToolUse` to the `PostToolUse`, `PostToolUseFailure` or `PermissionDenied` carrying the same `tool_use_id` on the same stream. Every tool bracket is a `tool` span.
- A tool bracket whose `tool_name` is in `SUBAGENT_TOOLS` is also an `agent` span: the subagent worker it opened.
- A **main worker interval** runs from `UserPromptSubmit` to the next `Stop`, `Interrupt`, `StopFailure` or `SessionEnd` on that stream. A `Stop` with no preceding `UserPromptSubmit` since the last terminal event opens its interval at the previous terminal event — this is the hook-driven continuation turn.
- A main worker interval contributes `agent` spans equal to the interval minus the union of the tool brackets inside it.
- Any bracket left open contributes `max_active` seconds from its opening event, or less if the log ends sooner.

- [ ] **Step 1: Write the failing test**

```python
# tests/python/test_machine.py
import unittest
from ttreport.events import parse_line
from ttreport.intervals import total
from ttreport.machine import machine_spans


def beat(at, event, session="s1", tool_id="-", tool_name="-", project="sportx"):
    return parse_line("\t".join([
        "i", "beat", str(at), str(at), "m1", "claude", "paired", project, ".",
        session, event, "t1", tool_id, "-", "-", "-", "-", tool_name, "-", "-",
    ]))


def spans_of(entries):
    return [span for _p, _s, span in entries]


class TestMachineSpans(unittest.TestCase):
    def test_turn_with_no_tools_is_all_agent_time(self):
        m = machine_spans([
            beat(0, "UserPromptSubmit"),
            beat(100, "Stop"),
        ], max_active=3600)
        self.assertEqual(total(spans_of(m.agent)), 100)
        self.assertEqual(total(spans_of(m.tool)), 0)

    def test_tool_time_is_subtracted_from_agent_time(self):
        m = machine_spans([
            beat(0, "UserPromptSubmit"),
            beat(10, "PreToolUse", tool_id="a", tool_name="Bash"),
            beat(30, "PostToolUse", tool_id="a", tool_name="Bash"),
            beat(100, "Stop"),
        ], max_active=3600)
        self.assertEqual(total(spans_of(m.tool)), 20)
        self.assertEqual(total(spans_of(m.agent)), 80)

    def test_overlapping_tools_sum_but_subtract_only_their_union(self):
        m = machine_spans([
            beat(0, "UserPromptSubmit"),
            beat(10, "PreToolUse", tool_id="a", tool_name="Bash"),
            beat(10, "PreToolUse", tool_id="b", tool_name="Bash"),
            beat(30, "PostToolUse", tool_id="a", tool_name="Bash"),
            beat(30, "PostToolUse", tool_id="b", tool_name="Bash"),
            beat(100, "Stop"),
        ], max_active=3600)
        self.assertEqual(total(spans_of(m.tool)), 40)
        self.assertEqual(total(spans_of(m.agent)), 80)

    def test_a_subagent_tool_also_counts_as_agent_time(self):
        # The parent subtracts the bracket; the subagent worker adds it back.
        m = machine_spans([
            beat(0, "UserPromptSubmit"),
            beat(10, "PreToolUse", tool_id="a", tool_name="Task"),
            beat(70, "PostToolUse", tool_id="a", tool_name="Task"),
            beat(100, "Stop"),
        ], max_active=3600)
        self.assertEqual(total(spans_of(m.tool)), 60)
        self.assertEqual(total(spans_of(m.agent)), 100)

    def test_parallel_subagents_each_count(self):
        rows = [beat(0, "UserPromptSubmit")]
        for name in ("a", "b", "c", "d", "e"):
            rows.append(beat(10, "PreToolUse", tool_id=name, tool_name="Task"))
            rows.append(beat(610, "PostToolUse", tool_id=name, tool_name="Task"))
        rows.append(beat(700, "Stop"))
        m = machine_spans(rows, max_active=3600)
        # Five workers of 600s each, plus the parent's own 100s outside them.
        self.assertEqual(total(spans_of(m.agent)), 5 * 600 + 100)

    def test_a_long_command_keeps_its_full_duration(self):
        m = machine_spans([
            beat(0, "UserPromptSubmit"),
            beat(10, "PreToolUse", tool_id="a", tool_name="Bash"),
            beat(1210, "PostToolUse", tool_id="a", tool_name="Bash"),
            beat(1220, "Stop"),
        ], max_active=3600)
        self.assertEqual(total(spans_of(m.tool)), 1200)

    def test_hook_driven_turn_opens_at_the_previous_terminal_event(self):
        m = machine_spans([
            beat(0, "UserPromptSubmit"),
            beat(100, "Stop"),
            beat(160, "Stop"),
        ], max_active=3600)
        self.assertEqual(total(spans_of(m.agent)), 160)

    def test_unclosed_bracket_is_capped(self):
        m = machine_spans([
            beat(0, "UserPromptSubmit"),
            beat(10, "PreToolUse", tool_id="a", tool_name="Bash"),
        ], max_active=60)
        self.assertEqual(total(spans_of(m.tool)), 60)

    def test_separate_sessions_do_not_close_each_other(self):
        m = machine_spans([
            beat(0, "UserPromptSubmit", session="s1"),
            beat(10, "UserPromptSubmit", session="s2"),
            beat(50, "Stop", session="s2"),
            beat(100, "Stop", session="s1"),
        ], max_active=3600)
        self.assertEqual(total(spans_of(m.agent)), 140)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/lan/workspace/langerrr/timetrack && PYTHONPATH=lib python3 -m unittest tests.python.test_machine -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'ttreport.machine'`

- [ ] **Step 3: Write minimal implementation**

```python
# lib/ttreport/machine.py
"""Machine time: what the agents did, split into agent and tool.

A worker is a main session or one subagent. Workers run in parallel, so
their spans sum. Tool calls inside a worker are that worker working, so
their union is subtracted from its agent time -- but the tool column sums
them, because two commands running at once occupy two commands' worth of
machine.
"""

from typing import Dict, Iterable, List, NamedTuple, Tuple

from .events import Row, SUBAGENT_TOOLS
from .intervals import Span, union

TOOL_OPEN = "PreToolUse"
TOOL_CLOSE = frozenset(["PostToolUse", "PostToolUseFailure", "PermissionDenied"])
TURN_OPEN = "UserPromptSubmit"
TURN_CLOSE = frozenset(["Stop", "Interrupt", "StopFailure", "SessionEnd"])

Entry = Tuple[str, str, Span]


class MachineSpans(NamedTuple):
    agent: List[Entry]
    tool: List[Entry]


def machine_spans(rows, max_active):
    # type: (Iterable[Row], int) -> MachineSpans
    rows = [r for r in rows if r.kind == "beat"]
    rows.sort(key=lambda r: r.start)

    agent = []  # type: List[Entry]
    tool = []  # type: List[Entry]

    open_tools = {}  # type: Dict[Tuple, Row]
    turn_open = {}  # type: Dict[Tuple, Row]
    turn_tools = {}  # type: Dict[Tuple, List[Span]]
    last_close = {}  # type: Dict[Tuple, int]

    def close_turn(stream, opened, at):
        inside = union(turn_tools.pop(stream, []))
        whole = [(opened.start, at)]
        for start, end in whole:
            cursor = start
            for tstart, tend in inside:
                if tend <= cursor or tstart >= end:
                    continue
                if tstart > cursor:
                    agent.append((opened.project, opened.subpath, (cursor, tstart)))
                cursor = max(cursor, tend)
            if end > cursor:
                agent.append((opened.project, opened.subpath, (cursor, end)))
        last_close[stream] = at

    for row in rows:
        stream = row.stream
        if row.event == TOOL_OPEN:
            open_tools[(stream, row.tool_use_id)] = row
        elif row.event in TOOL_CLOSE:
            opened = open_tools.pop((stream, row.tool_use_id), None)
            if opened is not None:
                span = (opened.start, row.start)
                tool.append((opened.project, opened.subpath, span))
                turn_tools.setdefault(stream, []).append(span)
                if opened.tool_name in SUBAGENT_TOOLS:
                    agent.append((opened.project, opened.subpath, span))
        elif row.event == TURN_OPEN:
            if stream in turn_open:
                close_turn(stream, turn_open.pop(stream), row.start)
            turn_open[stream] = row
        elif row.event in TURN_CLOSE:
            opened = turn_open.pop(stream, None)
            if opened is None:
                start = last_close.get(stream)
                if start is None or row.start - start > max_active:
                    last_close[stream] = row.start
                    continue
                opened = row._replace(start=start)
            close_turn(stream, opened, row.start)

    for (stream, _tool_id), opened in open_tools.items():
        span = (opened.start, opened.start + max_active)
        tool.append((opened.project, opened.subpath, span))
        turn_tools.setdefault(stream, []).append(span)
        if opened.tool_name in SUBAGENT_TOOLS:
            agent.append((opened.project, opened.subpath, span))

    for stream, opened in list(turn_open.items()):
        close_turn(stream, opened, opened.start + max_active)

    return MachineSpans(agent=agent, tool=tool)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/lan/workspace/langerrr/timetrack && PYTHONPATH=lib python3 -m unittest tests.python.test_machine -v`
Expected: PASS, 9 tests

- [ ] **Step 5: Commit**

```bash
git add lib/ttreport/machine.py tests/python/test_machine.py
git commit -m "Measure agent and tool time per worker"
```

---

### Task 6: Effort

**Files:**
- Create: `lib/ttreport/effort.py`
- Test: `tests/python/test_effort.py`

**Interfaces:**
- Consumes: `Row` from `ttreport.events`; `ModeTimeline`, `PAIRED`, `SOLO` from `ttreport.modes`; `union` from `ttreport.intervals`.
- Produces: `EffortSpans` — a `NamedTuple` with `paired`, `checkin` and `manual`, each `List[Tuple[str, str, Tuple[int, int]]]` of `(project, subpath, span)` — and `effort_spans(rows, timeline, presence_gap, checkin_window) -> EffortSpans`.

Rules:
- A **heartbeat** is a `beat` row with `event == "UserPromptSubmit"`, `agent_id` of `-`, and `prompt_class` not `machine`; or a `mode` row; or a `span` row.
- Heartbeats group by stream and sort by time.
- For two consecutive heartbeats in a stream where the mode at the earlier one is `paired`: credit the whole interval if it is at most `presence_gap`, otherwise credit `presence_gap // 2` ending at the later heartbeat.
- Heartbeats whose mode is `solo` cluster into episodes: consecutive heartbeats no more than `checkin_window` apart belong to one episode. An episode credits `(first - checkin_window // 2, last + checkin_window // 2)`.
- A `span` row credits `(start, end)` as manual.
- Spans are unioned **per project** by the caller, not here.

- [ ] **Step 1: Write the failing test**

```python
# tests/python/test_effort.py
import unittest
from ttreport.events import parse_line
from ttreport.intervals import total, union
from ttreport.modes import ModeTimeline
from ttreport.effort import effort_spans

GAP = 3600
WINDOW = 1200


def prompt(at, session="s1", project="sportx", cls="human", agent="-"):
    return parse_line("\t".join([
        "i", "beat", str(at), str(at), "m1", "claude", "paired", project, ".",
        session, "UserPromptSubmit", "t1", "-", agent, "-", "-", "-", "-",
        cls, "fp",
    ]))


def mode_row(at, mode, session="s1", project="sportx"):
    return parse_line("\t".join([
        "i", "mode", str(at), str(at), "m1", "-", mode, project, ".",
        session, "-",
    ]))


def span_row(start, end, project="sportx"):
    return parse_line("\t".join([
        "i", "span", str(start), str(end), "m1", "-", "manual", project, ".",
        "-", "a note",
    ]))


def spans_of(entries):
    return [s for _p, _sub, s in entries]


def run(rows):
    return effort_spans(rows, ModeTimeline.from_rows(rows), GAP, WINDOW)


class TestPairedEffort(unittest.TestCase):
    def test_gap_within_the_threshold_is_credited_whole(self):
        e = run([prompt(0), prompt(900)])
        self.assertEqual(total(spans_of(e.paired)), 900)

    def test_sparse_design_session_still_counts_in_full(self):
        # 55 minutes between prompts, under the 60-minute threshold.
        e = run([prompt(0), prompt(3300)])
        self.assertEqual(total(spans_of(e.paired)), 3300)

    def test_gap_over_the_threshold_credits_half_of_it(self):
        e = run([prompt(0), prompt(4200)])
        self.assertEqual(total(spans_of(e.paired)), GAP // 2)

    def test_a_three_hour_gap_credits_the_same_half(self):
        e = run([prompt(0), prompt(10800)])
        self.assertEqual(total(spans_of(e.paired)), GAP // 2)

    def test_half_credit_sits_immediately_before_the_later_heartbeat(self):
        e = run([prompt(0), prompt(10800)])
        self.assertEqual(spans_of(e.paired), [(10800 - GAP // 2, 10800)])

    def test_a_lone_heartbeat_credits_nothing(self):
        self.assertEqual(run([prompt(0)]).paired, [])

    def test_machine_prompts_are_not_heartbeats(self):
        e = run([prompt(0), prompt(600, cls="machine"), prompt(1200)])
        # The middle row is ignored, so one 1200s interval is credited.
        self.assertEqual(spans_of(e.paired), [(0, 1200)])

    def test_a_subagent_prompt_is_not_a_heartbeat(self):
        e = run([prompt(0), prompt(600, agent="ag1"), prompt(1200)])
        self.assertEqual(spans_of(e.paired), [(0, 1200)])

    def test_parallel_sessions_on_one_project_union_to_one_hour(self):
        rows = [prompt(0, "s1"), prompt(3600, "s1"),
                prompt(0, "s2"), prompt(3600, "s2")]
        e = run(rows)
        self.assertEqual(total(union(spans_of(e.paired))), 3600)

    def test_two_projects_at_once_are_double_booked(self):
        rows = [prompt(0, "s1", "sportx"), prompt(3600, "s1", "sportx"),
                prompt(0, "s2", "tuurny"), prompt(3600, "s2", "tuurny")]
        e = run(rows)
        by_project = {}
        for project, _sub, span in e.paired:
            by_project.setdefault(project, []).append(span)
        self.assertEqual(total(union(by_project["sportx"])), 3600)
        self.assertEqual(total(union(by_project["tuurny"])), 3600)


class TestSoloEffort(unittest.TestCase):
    # `tt solo` is itself a moment of presence, so the mode row is a heartbeat
    # and opens an episode of its own. Every expectation below therefore
    # carries one window for the mode row plus whatever the prompts add.

    def test_a_single_checkin_credits_one_window(self):
        e = run([mode_row(0, "solo"), prompt(5000)])
        self.assertEqual(total(union(spans_of(e.checkin))), 2 * WINDOW)

    def test_two_prompts_ten_minutes_apart_credit_their_span_plus_a_window(self):
        e = run([mode_row(0, "solo"), prompt(5000), prompt(5600)])
        self.assertEqual(total(union(spans_of(e.checkin))), 600 + 2 * WINDOW)

    def test_prompts_far_apart_form_separate_episodes(self):
        e = run([mode_row(0, "solo"), prompt(5000), prompt(50000)])
        self.assertEqual(total(union(spans_of(e.checkin))), 3 * WINDOW)

    def test_an_eight_hour_run_credits_the_checkin_not_the_run(self):
        e = run([mode_row(0, "solo"), prompt(28800)])
        # Two heartbeats, two episodes, two windows -- not eight hours.
        self.assertEqual(total(union(spans_of(e.checkin))), 2 * WINDOW)


class TestManualEffort(unittest.TestCase):
    def test_a_span_is_credited_as_stated(self):
        e = run([span_row(0, 5400)])
        self.assertEqual(total(spans_of(e.manual)), 5400)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/lan/workspace/langerrr/timetrack && PYTHONPATH=lib python3 -m unittest tests.python.test_effort -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'ttreport.effort'`

- [ ] **Step 3: Write minimal implementation**

```python
# lib/ttreport/effort.py
"""Effort: the user's own engagement, reconstructed from heartbeats.

A heartbeat is an event only a present human produces. In paired mode the
interval between two heartbeats is the work -- reading, thinking, typing --
and is credited whole. In solo mode the user is away by default, so
heartbeats cluster into check-in episodes and only those are credited.
"""

from typing import Dict, Iterable, List, NamedTuple, Tuple

from .events import Row
from .intervals import Span
from .modes import ModeTimeline, PAIRED, SOLO

Entry = Tuple[str, str, Span]


class EffortSpans(NamedTuple):
    paired: List[Entry]
    checkin: List[Entry]
    manual: List[Entry]


def _is_heartbeat(row):
    # type: (Row) -> bool
    if row.kind in ("mode", "span"):
        return True
    if row.kind != "beat" or row.event != "UserPromptSubmit":
        return False
    if row.agent_id not in ("-", ""):
        return False
    return row.prompt_class != "machine"


def effort_spans(rows, timeline, presence_gap, checkin_window):
    # type: (Iterable[Row], ModeTimeline, int, int) -> EffortSpans
    paired = []  # type: List[Entry]
    checkin = []  # type: List[Entry]
    manual = []  # type: List[Entry]

    by_stream = {}  # type: Dict[Tuple, List[Row]]
    for row in rows:
        if row.kind == "span":
            manual.append((row.project, row.subpath, (row.start, row.end)))
            continue
        if _is_heartbeat(row):
            by_stream.setdefault(row.stream, []).append(row)

    half_gap = presence_gap // 2
    half_window = checkin_window // 2

    for stream, beats in by_stream.items():
        beats.sort(key=lambda r: r.start)
        episode = []  # type: List[Row]

        def flush(episode):
            if not episode:
                return
            first, last = episode[0], episode[-1]
            checkin.append((first.project, first.subpath,
                            (first.start - half_window,
                             last.start + half_window)))

        for index, row in enumerate(beats):
            mode = timeline.at(stream, row.start, row.project, row.subpath)
            if mode == SOLO:
                if episode and row.start - episode[-1].start > checkin_window:
                    flush(episode)
                    episode = []
                episode.append(row)
                continue
            flush(episode)
            episode = []
            if index + 1 >= len(beats):
                continue
            nxt = beats[index + 1]
            if timeline.at(stream, nxt.start, nxt.project, nxt.subpath) == SOLO:
                continue
            elapsed = nxt.start - row.start
            if elapsed <= 0:
                continue
            if elapsed <= presence_gap:
                paired.append((row.project, row.subpath, (row.start, nxt.start)))
            else:
                paired.append((row.project, row.subpath,
                               (nxt.start - half_gap, nxt.start)))
        flush(episode)

    return EffortSpans(paired=paired, checkin=checkin, manual=manual)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/lan/workspace/langerrr/timetrack && PYTHONPATH=lib python3 -m unittest tests.python.test_effort -v`
Expected: PASS, 15 tests

- [ ] **Step 5: Commit**

```bash
git add lib/ttreport/effort.py tests/python/test_effort.py
git commit -m "Reconstruct effort from heartbeats"
```

---

### Task 7: Report aggregation and formatting

**Files:**
- Create: `lib/ttreport/report.py`
- Create: `lib/ttreport/__main__.py`
- Test: `tests/python/test_report.py`

**Interfaces:**
- Consumes: everything above.
- Produces: `Options` (a `NamedTuple` with `since: int`, `upto: int`, `byday: bool`, `detail: bool`, `boundaries: List[int]`, `presence_gap: int`, `checkin_window: int`, `max_active: int`), `build_report(rows, options) -> str`, and a `main(argv, stdin)` entry point.

Aggregation:
- Effort spans are unioned **within each bucket and category**; machine spans are summed.
- The bucket key is the project (plus `/subpath` when `detail`), or the day when `byday`.
- Column order: `PROJECT` (or `DAY`), `PAIRED`, `CHECKIN`, `MANUAL`, `EFFORT`, `AGENT`, `TOOL`.
- `EFFORT` is `PAIRED + CHECKIN + MANUAL`. A `TOTAL` row closes the table.
- Durations format as `%dh %02dm`, truncating seconds.

- [ ] **Step 1: Write the failing test**

```python
# tests/python/test_report.py
import unittest
from ttreport.events import parse_line
from ttreport.report import Options, build_report, format_duration


def prompt(at, project="sportx", session="s1"):
    return parse_line("\t".join([
        "i", "beat", str(at), str(at), "m1", "claude", "paired", project, ".",
        session, "UserPromptSubmit", "t1", "-", "-", "-", "-", "-", "-",
        "human", "fp",
    ]))


def stop(at, project="sportx", session="s1"):
    return parse_line("\t".join([
        "i", "beat", str(at), str(at), "m1", "claude", "paired", project, ".",
        session, "Stop", "t1", "-", "-", "-", "-", "-", "-", "-", "-",
    ]))


def options(**kw):
    base = dict(since=0, upto=100000, byday=False, detail=False,
                boundaries=[], presence_gap=3600, checkin_window=1200,
                max_active=3600)
    base.update(kw)
    return Options(**base)


class TestFormatDuration(unittest.TestCase):
    def test_zero(self):
        self.assertEqual(format_duration(0), "0h 00m")

    def test_truncates_seconds(self):
        self.assertEqual(format_duration(119), "0h 01m")

    def test_hours_are_not_wrapped(self):
        self.assertEqual(format_duration(90000), "25h 00m")


class TestBuildReport(unittest.TestCase):
    def test_header_names_every_column(self):
        out = build_report([], options())
        self.assertIn("PROJECT", out)
        for column in ("PAIRED", "CHECKIN", "MANUAL", "EFFORT", "AGENT", "TOOL"):
            self.assertIn(column, out)

    def test_effort_is_the_sum_of_its_three_parts(self):
        rows = [prompt(0), prompt(600), stop(650)]
        out = build_report(rows, options())
        line = [l for l in out.splitlines() if l.startswith("sportx")][0]
        # Columns are "0h 10m" pairs; rebuild them positionally.
        values = line[len("sportx"):].split()
        pairs = [" ".join(values[i:i + 2]) for i in range(0, len(values), 2)]
        self.assertEqual(pairs[0], "0h 10m")   # PAIRED
        self.assertEqual(pairs[3], "0h 10m")   # EFFORT

    def test_machine_columns_are_not_added_into_effort(self):
        rows = [prompt(0), stop(3600), prompt(3700)]
        out = build_report(rows, options())
        line = [l for l in out.splitlines() if l.startswith("sportx")][0]
        values = line[len("sportx"):].split()
        pairs = [" ".join(values[i:i + 2]) for i in range(0, len(values), 2)]
        effort, agent = pairs[3], pairs[4]
        self.assertEqual(effort, "1h 01m")
        self.assertEqual(agent, "1h 00m")

    def test_parallel_sessions_do_not_double_count_effort(self):
        rows = [prompt(0, session="s1"), prompt(3600, session="s1"),
                prompt(0, session="s2"), prompt(3600, session="s2")]
        out = build_report(rows, options())
        line = [l for l in out.splitlines() if l.startswith("sportx")][0]
        values = line[len("sportx"):].split()
        pairs = [" ".join(values[i:i + 2]) for i in range(0, len(values), 2)]
        self.assertEqual(pairs[0], "1h 00m")

    def test_two_projects_each_get_their_own_hour(self):
        rows = [prompt(0, "sportx", "s1"), prompt(3600, "sportx", "s1"),
                prompt(0, "tuurny", "s2"), prompt(3600, "tuurny", "s2")]
        out = build_report(rows, options())
        self.assertIn("sportx", out)
        self.assertIn("tuurny", out)
        totals = [l for l in out.splitlines() if l.startswith("TOTAL")][0]
        values = totals[len("TOTAL"):].split()
        pairs = [" ".join(values[i:i + 2]) for i in range(0, len(values), 2)]
        self.assertEqual(pairs[0], "2h 00m")

    def test_rows_outside_the_window_are_excluded(self):
        rows = [prompt(0), prompt(600)]
        out = build_report(rows, options(since=50000, upto=60000))
        self.assertNotIn("sportx", out)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/lan/workspace/langerrr/timetrack && PYTHONPATH=lib python3 -m unittest tests.python.test_report -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'ttreport.report'`

- [ ] **Step 3: Write minimal implementation**

```python
# lib/ttreport/report.py
"""Aggregates spans into buckets and renders the table.

Effort unions inside a bucket, because one person cannot spend the same
minute twice on one project. Machine time sums, because agents can.
"""

from typing import Dict, Iterable, List, NamedTuple, Tuple

from .effort import effort_spans
from .events import Row
from .intervals import clip, split_days, total, union
from .machine import machine_spans
from .modes import ModeTimeline

COLUMNS = ("PAIRED", "CHECKIN", "MANUAL", "EFFORT", "AGENT", "TOOL")
UNIONED = ("PAIRED", "CHECKIN", "MANUAL")


class Options(NamedTuple):
    since: int
    upto: int
    byday: bool
    detail: bool
    boundaries: List[int]
    presence_gap: int
    checkin_window: int
    max_active: int


def format_duration(seconds):
    # type: (int) -> str
    seconds = max(0, int(seconds))
    return "%dh %02dm" % (seconds // 3600, (seconds % 3600) // 60)


def _bucket(project, subpath, options):
    # type: (str, str, Options) -> str
    if options.detail and subpath not in (".", "-", ""):
        return project + "/" + subpath
    return project


def _collect(entries, options):
    # type: (Iterable, Options) -> Dict[str, List[Tuple[int, int]]]
    out = {}  # type: Dict[str, List[Tuple[int, int]]]
    for project, subpath, span in entries:
        for span in clip([span], options.since, options.upto):
            if options.byday:
                for day, piece in split_days([span], options.boundaries):
                    out.setdefault(str(day), []).append(piece)
            else:
                out.setdefault(_bucket(project, subpath, options), []).append(span)
    return out


def build_report(rows, options):
    # type: (Iterable[Row], Options) -> str
    rows = list(rows)
    timeline = ModeTimeline.from_rows(rows)
    effort = effort_spans(rows, timeline, options.presence_gap,
                          options.checkin_window)
    machine = machine_spans(rows, options.max_active)

    sources = {
        "PAIRED": effort.paired,
        "CHECKIN": effort.checkin,
        "MANUAL": effort.manual,
        "AGENT": machine.agent,
        "TOOL": machine.tool,
    }
    collected = {name: _collect(entries, options)
                 for name, entries in sources.items()}

    keys = set()
    for buckets in collected.values():
        keys.update(buckets)

    table = {}  # type: Dict[str, Dict[str, int]]
    for key in keys:
        cells = {}
        for name in ("PAIRED", "CHECKIN", "MANUAL"):
            cells[name] = total(union(collected[name].get(key, [])))
        for name in ("AGENT", "TOOL"):
            cells[name] = total(collected[name].get(key, []))
        cells["EFFORT"] = cells["PAIRED"] + cells["CHECKIN"] + cells["MANUAL"]
        if any(cells[name] for name in COLUMNS):
            table[key] = cells

    label = "DAY" if options.byday else "PROJECT"
    width = max([len(label), len("TOTAL")] + [len(k) for k in table] or [7])
    lines = ["%-*s %9s %9s %9s %9s %9s %9s"
             % (width, label, *COLUMNS)]
    grand = dict((name, 0) for name in COLUMNS)
    for key in sorted(table):
        cells = table[key]
        for name in COLUMNS:
            grand[name] += cells[name]
        lines.append("%-*s %9s %9s %9s %9s %9s %9s" % (
            width, key, *[format_duration(cells[n]) for n in COLUMNS]))
    lines.append("%-*s %9s %9s %9s %9s %9s %9s" % (
        width, "TOTAL", *[format_duration(grand[n]) for n in COLUMNS]))
    return "\n".join(lines) + "\n"
```

```python
# lib/ttreport/__main__.py
"""Entry point. Reads the timestamp-sorted TSV on stdin."""

import argparse
import sys

from .events import parse_stream
from .report import Options, build_report


def main(argv=None, stdin=None):
    parser = argparse.ArgumentParser(prog="ttreport")
    parser.add_argument("--since", type=int, required=True)
    parser.add_argument("--upto", type=int, required=True)
    parser.add_argument("--presence-gap", type=int, default=3600)
    parser.add_argument("--checkin-window", type=int, default=1200)
    parser.add_argument("--max-active", type=int, default=3600)
    parser.add_argument("--byday", action="store_true")
    parser.add_argument("--detail", action="store_true")
    parser.add_argument("--boundary", type=int, action="append", default=[])
    args = parser.parse_args(argv)

    rows = parse_stream(stdin or sys.stdin)
    options = Options(
        since=args.since, upto=args.upto, byday=args.byday,
        detail=args.detail, boundaries=args.boundary,
        presence_gap=args.presence_gap,
        checkin_window=args.checkin_window,
        max_active=args.max_active,
    )
    sys.stdout.write(build_report(rows, options))
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/lan/workspace/langerrr/timetrack && PYTHONPATH=lib python3 -m unittest discover -s tests/python -v`
Expected: PASS, all tests across every module

- [ ] **Step 5: Commit**

```bash
git add lib/ttreport/report.py lib/ttreport/__main__.py tests/python/test_report.py
git commit -m "Render the effort and machine table"
```

---

### Task 8: Wire `tt report` to Python

**Files:**
- Modify: `bin/tt` — `cmd_report` (currently `bin/tt:931-990`), and the config readers near `bin/tt:7-12`
- Modify: `tests/run.sh`
- Test: `tests/run.sh`

**Interfaces:**
- Consumes: `python3 -m ttreport` from Task 7.
- Produces: `tt report` output in the new column layout.

`tt_presence_gap`, `tt_checkin_window` and `tt_max_active_gap` read their value from `$TT_HOME/config` first, then the environment, then the default. `tt_day_boundaries` already emits `boundary` rows for `--by day`; those become `--boundary` arguments instead.

- [ ] **Step 1: Write the failing test**

```sh
# append to tests/run.sh
printf 'Task N: report wiring\n'

REPORT=$(sh "$TT" report --since 1970-01-01)
assert_contains "$REPORT" "EFFORT" 'the report names the effort column'
assert_contains "$REPORT" "AGENT" 'the report names the agent column'
assert_contains "$REPORT" "TOOL" 'the report names the tool column'
assert_status 1 'the retired estimate column is gone' -- \
  sh -c "sh \"$TT\" report --since 1970-01-01 | grep -q ESTIMATED"
assert_contains "$(sh "$TT" report --by day --since 1970-01-01)" "DAY" \
  'grouping by day names the day column'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/lan/workspace/langerrr/timetrack && sh tests/run.sh`
Expected: FAIL — `the report names the effort column` finds `PAIRED SOLO MANUAL ESTIMATED TOTAL` from the awk implementation.

- [ ] **Step 3: Write minimal implementation**

Replace the tail of `cmd_report` in `bin/tt`:

```sh
  presence_gap=$(tt_presence_gap)
  checkin_window=$(tt_checkin_window)
  max_active=$(tt_max_active_gap)
  lib=${TT_LIB:-$(tt_self)/../lib}

  tt_compact || tt_die "cannot compact $(tt_compact_file)"

  set -- --since "$since" --upto "$upto" \
         --presence-gap "$presence_gap" \
         --checkin-window "$checkin_window" \
         --max-active "$max_active"
  [ "$detail" -eq 0 ] || set -- "$@" --detail
  if [ "$byday" -eq 1 ]; then
    set -- "$@" --byday
    for boundary in $(tt_day_boundary_epochs "$since" "$upto"); do
      set -- "$@" --boundary "$boundary"
    done
  fi

  {
    cat "$TT_HOME"/events-*.tsv 2>/dev/null
    cat "$TT_HOME"/current-*.tsv 2>/dev/null
  } | tt_sort_events | PYTHONPATH="$lib" python3 -m ttreport "$@"
```

Add the three config readers beside the existing ones:

```sh
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
```

Add `tt_day_boundary_epochs`, which prints one epoch per local midnight in the window. Leave the existing `boundary`-row emitter `tt_day_boundaries` in place — `tt_compact_locked` still runs through `report.awk` until Task 9 and needs it. Task 9 deletes it.

```sh
tt_day_boundary_epochs() { # since upto
  cursor=$(tt_midnight "$1") || return 1
  while [ "$cursor" -lt "$2" ]; do
    printf '%s\n' "$cursor"
    cursor=$(tt_next_midnight "$cursor") || return 1
  done
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/lan/workspace/langerrr/timetrack && sh tests/run.sh`
Expected: PASS — the new assertions pass. Earlier assertions that check the old `PAIRED SOLO MANUAL ESTIMATED TOTAL` header will fail; update each to the new header as part of this step, and delete assertions that test reading-time estimation, which Task 10 removes entirely.

- [ ] **Step 5: Commit**

```bash
git add bin/tt tests/run.sh
git commit -m "Report through the Python implementation"
```

---

### Task 9: Compaction

**Files:**
- Create: `lib/ttreport/compact.py`
- Modify: `bin/tt` — `tt_compact_locked` (currently `bin/tt:714-790`)
- Test: `tests/python/test_compact.py`

**Interfaces:**
- Consumes: `Row` from `ttreport.events`; `effort_spans`, `machine_spans`, `ModeTimeline`.
- Produces: `compact(rows, cutoff, options) -> Tuple[List[str], List[str]]` returning `(history_lines, carry_lines)`.

Rows whose `start` is before `cutoff` roll into one `total` row per day, project, subpath and category. Rows at or after `cutoff` are carried forward verbatim. The `state` row carries only what the new reconstruction needs across the boundary: for each stream, the last heartbeat time, the open turn's opening time if any, and each open tool bracket's `tool_use_id`, `tool_name` and opening time.

A `total` row uses columns 3 and 4 for the day's start and end, column 7 for the category (`paired`, `checkin`, `manual`, `agent`, `tool`), and column 16 for the seconds.

- [ ] **Step 1: Write the failing test**

```python
# tests/python/test_compact.py
import unittest
from ttreport.events import parse_line, parse_stream
from ttreport.compact import compact
from ttreport.report import Options


def prompt(at, project="sportx", session="s1"):
    return "\t".join([
        "i", "beat", str(at), str(at), "m1", "claude", "paired", project, ".",
        session, "UserPromptSubmit", "t1", "-", "-", "-", "-", "-", "-",
        "human", "fp",
    ])


def options(**kw):
    base = dict(since=0, upto=10 ** 10, byday=True, detail=True,
                boundaries=[0, 86400, 172800], presence_gap=3600,
                checkin_window=1200, max_active=3600)
    base.update(kw)
    return Options(**base)


class TestCompact(unittest.TestCase):
    def test_rows_after_the_cutoff_are_carried_verbatim(self):
        rows = parse_stream([prompt(90000), prompt(90600)])
        history, carry = compact(rows, cutoff=86400, options=options())
        self.assertEqual(len(carry), 2)
        self.assertTrue(all("\tbeat\t" in line for line in carry))

    def test_rows_before_the_cutoff_become_total_rows(self):
        rows = parse_stream([prompt(0), prompt(600)])
        history, carry = compact(rows, cutoff=86400, options=options())
        self.assertTrue(history)
        self.assertTrue(all("\ttotal\t" in line for line in history))
        self.assertEqual(carry, [])

    def test_a_total_row_carries_its_seconds(self):
        rows = parse_stream([prompt(0), prompt(600)])
        history, _carry = compact(rows, cutoff=86400, options=options())
        paired = [l for l in history if l.split("\t")[6] == "paired"][0]
        self.assertEqual(paired.split("\t")[15], "600")

    def test_compaction_preserves_the_reported_total(self):
        rows = parse_stream([prompt(0), prompt(600), prompt(1200)])
        history, _carry = compact(rows, cutoff=86400, options=options())
        seconds = sum(int(l.split("\t")[15]) for l in history
                      if l.split("\t")[6] == "paired")
        self.assertEqual(seconds, 1200)

    def test_an_empty_log_compacts_to_nothing(self):
        history, carry = compact([], cutoff=86400, options=options())
        self.assertEqual((history, carry), ([], []))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/lan/workspace/langerrr/timetrack && PYTHONPATH=lib python3 -m unittest tests.python.test_compact -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'ttreport.compact'`

- [ ] **Step 3: Write minimal implementation**

```python
# lib/ttreport/compact.py
"""Rolls completed days into bounded totals.

A day that has closed cannot change, so its spans collapse into one total
per project, subpath and category. Rows at or after the cutoff are carried
forward untouched, because the reconstruction that covers them is not
finished yet.
"""

from typing import Dict, Iterable, List, Tuple

from .effort import effort_spans
from .events import Row
from .intervals import clip, split_days, total, union
from .machine import machine_spans
from .modes import ModeTimeline
from .report import Options


def _line(day, day_end, project, subpath, category, seconds):
    # type: (int, int, str, str, str, int) -> str
    return "\t".join([
        "-", "total", str(day), str(day_end), "-", "-", category,
        project, subpath, "-", "-", "-", "-", "-", "-", str(seconds),
        "-", "-", "-", "-",
    ])


def compact(rows, cutoff, options):
    # type: (Iterable[Row], int, Options) -> Tuple[List[str], List[str]]
    rows = list(rows)
    past = [r for r in rows if r.start < cutoff]
    carry = ["\t".join([
        r.iso, r.kind, str(r.start), str(r.end), r.machine, r.harness, r.mode,
        r.project, r.subpath, r.session, r.event, r.turn_id, r.tool_use_id,
        r.agent_id, r.agent_type, r.words, r.session_source, r.tool_name,
        r.prompt_class, r.fingerprint,
    ]) for r in rows if r.start >= cutoff]

    if not past:
        return ([], carry)

    timeline = ModeTimeline.from_rows(past)
    effort = effort_spans(past, timeline, options.presence_gap,
                          options.checkin_window)
    machine = machine_spans(past, options.max_active)

    sources = [
        ("paired", effort.paired, True),
        ("checkin", effort.checkin, True),
        ("manual", effort.manual, True),
        ("agent", machine.agent, False),
        ("tool", machine.tool, False),
    ]

    buckets = {}  # type: Dict[Tuple[int, str, str, str], List[Tuple[int, int]]]
    for category, entries, _unioned in sources:
        for project, subpath, span in entries:
            for span in clip([span], 0, cutoff):
                for day, piece in split_days([span], options.boundaries):
                    key = (day, project, subpath, category)
                    buckets.setdefault(key, []).append(piece)

    history = []
    for key in sorted(buckets):
        day, project, subpath, category = key
        spans = buckets[key]
        unioned = dict((c, u) for c, _e, u in sources)[category]
        seconds = total(union(spans)) if unioned else total(spans)
        if seconds <= 0:
            continue
        index = options.boundaries.index(day) if day in options.boundaries else -1
        day_end = (options.boundaries[index + 1]
                   if 0 <= index < len(options.boundaries) - 1
                   else day + 86400)
        history.append(_line(day, day_end, project, subpath, category, seconds))
    return (history, carry)
```

Add a CLI to `compact.py` so `bin/tt` can invoke it as a module:

```python
def main(argv=None, stdin=None):
    import argparse
    import sys

    from .events import parse_stream

    parser = argparse.ArgumentParser(prog="ttreport.compact")
    parser.add_argument("--cutoff", type=int, required=True)
    parser.add_argument("--carry", required=True,
                        help="path to write the carried-forward rows")
    parser.add_argument("--presence-gap", type=int, default=3600)
    parser.add_argument("--checkin-window", type=int, default=1200)
    parser.add_argument("--max-active", type=int, default=3600)
    parser.add_argument("--boundary", type=int, action="append", default=[])
    args = parser.parse_args(argv)

    rows = parse_stream(stdin or sys.stdin)
    options = Options(
        since=0, upto=args.cutoff, byday=True, detail=True,
        boundaries=args.boundary, presence_gap=args.presence_gap,
        checkin_window=args.checkin_window, max_active=args.max_active,
    )
    history, carry = compact(rows, args.cutoff, options)
    with open(args.carry, "w") as handle:
        for line in carry:
            handle.write(line + "\n")
    for line in history:
        sys.stdout.write(line + "\n")
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
```

In `bin/tt`, replace the body of `tt_compact_locked` so it pipes the sorted log through `python3 -m ttreport.compact` rather than `report.awk`, writing history and carry to temporary files and validating both are non-empty-or-expected before replacing the real files. Keep the existing lock, the existing temp-file-then-`mv` sequence and the existing validation; only the producer changes. Delete `tt_day_boundaries`, whose last caller goes away with `report.awk`'s compact mode; pass `--boundary` values from `tt_day_boundary_epochs` instead.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/lan/workspace/langerrr/timetrack && PYTHONPATH=lib python3 -m unittest discover -s tests/python -v && sh tests/run.sh`
Expected: PASS on both

- [ ] **Step 5: Commit**

```bash
git add lib/ttreport/compact.py bin/tt tests/python/test_compact.py
git commit -m "Compact completed days through the Python reconstruction"
```

---

### Task 10: Retire the awk implementation and the reading estimate

**Files:**
- Delete: `lib/report.awk`
- Modify: `bin/tt` — remove `tt_reading_wpm`, `tt_max_reading_time` and their config plumbing
- Modify: `tests/run.sh` — delete reading-estimate assertions
- Modify: `README.md`

**Interfaces:**
- Consumes: everything above.
- Produces: a tree with one reconstruction implementation.

`TT_READING_WPM` and `TT_MAX_READING_TIME` stop being read anywhere. `assistant_words` stays in the layout — it is written by existing rows and costs nothing to keep — but nothing consumes it.

- [ ] **Step 1: Write the failing test**

```sh
# append to tests/run.sh
printf 'Task N: the awk reconstruction is gone\n'
assert_status 1 'report.awk is deleted' -- test -f "$REPO/lib/report.awk"
assert_status 1 'no reading-wpm plumbing remains' -- \
  grep -q TT_READING_WPM "$REPO/bin/tt"
assert_status 1 'no max-reading plumbing remains' -- \
  grep -q TT_MAX_READING_TIME "$REPO/bin/tt"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/lan/workspace/langerrr/timetrack && sh tests/run.sh`
Expected: FAIL — `report.awk is deleted` fails because the file is still present.

- [ ] **Step 3: Write minimal implementation**

```bash
git rm lib/report.awk
```

In `bin/tt`, delete the `tt_reading_wpm` and `tt_max_reading_time` functions, the `TT_READING_WPM_SET` and `TT_MAX_READING_TIME_SET` variables near the top of the file, and every remaining reference to them.

Update `README.md`:
- Replace the "What it records" reconstruction paragraph with the two measures, the heartbeat rule, and the mode table from the spec.
- Replace the `ESTIMATED` column in every sample report with `EFFORT`, `AGENT` and `TOOL`.
- Replace the configuration table with `TT_PRESENCE_GAP`, `TT_CHECKIN_WINDOW`, `TT_MAX_ACTIVE_GAP`, `TT_SOLO_COMMANDS` and `TT_ROOT`.
- Add Python 3.8+ to the requirements section, noting it is needed for reporting but not for capture.
- Document automatic solo under "The three modes".

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/lan/workspace/langerrr/timetrack && PYTHONPATH=lib python3 -m unittest discover -s tests/python -v && sh tests/run.sh`
Expected: PASS on both

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Retire the awk reconstruction"
```

---

## Verification

After Task 10, confirm against real data rather than fixtures:

```bash
cd /home/lan/workspace/langerrr/timetrack
PYTHONPATH=lib python3 -m unittest discover -s tests/python -v
sh tests/run.sh
./bin/tt report today
./bin/tt report --by day --since 2026-09-02
```

Expected on `tt report today`: `EFFORT` within a few minutes of the old `PAIRED` figure for an ordinary single-session paired day, and `AGENT` far smaller than `EFFORT` — measured at roughly 90% human on 2026-09-08.

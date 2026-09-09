"""Normalize effort within each project, then sum into display buckets.

Machine time and opaque legacy durations remain additive. New effort history
retains timestamp coverage and joins live effort before normalization.
"""

import time
from typing import Dict, Iterable, List, NamedTuple

from .effort import effort_spans
from .events import Row
from .intervals import Span, clip, split_days, total
from .machine import machine_spans
from .modes import ModeTimeline
from .coverage import with_history

COLUMNS = ("PAIRED", "CHECKIN", "MANUAL", "EFFORT", "AGENT", "TOOL")
EFFORT_PRIORITY = ("PAIRED", "CHECKIN", "MANUAL")

# A compacted day's category (compact.py writes these, lowercase, into a
# total row's column 7 -- old rows normalize to the same names in events.py)
# maps onto the table column it contributes to.
CATEGORY_COLUMNS = {
    "paired": "PAIRED",
    "checkin": "CHECKIN",
    "manual": "MANUAL",
    "agent": "AGENT",
    "tool": "TOOL",
}


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
    seconds = int(seconds)
    return "%dh %02dm" % (seconds // 3600, (seconds % 3600) // 60)


def _bucket(project, subpath, options):
    # type: (str, str, Options) -> str
    if options.detail and subpath not in (".", "-", ""):
        return project + "/" + subpath
    return project


def _collect(entries, options):
    # type: (Iterable, Options) -> Dict[str, List[Span]]
    out = {}  # type: Dict[str, List[Span]]
    for project, subpath, span in entries:
        for clipped in clip([span], options.since, options.upto):
            if options.byday:
                for day, piece in split_days([clipped], options.boundaries):
                    label = time.strftime("%Y-%m-%d", time.localtime(day))
                    out.setdefault(label, []).append(piece)
            else:
                out.setdefault(_bucket(project, subpath, options), []).append(clipped)
    return out


def _total_key(row, options):
    # type: (Row, Options) -> str
    if options.byday:
        return time.strftime("%Y-%m-%d", time.localtime(row.start))
    return _bucket(row.project, row.subpath, options)


def _collect_totals(rows, options):
    # type: (Iterable[Row], Options) -> Dict[str, Dict[str, int]]
    """A compacted day contributes a pre-summed, already-disjoint total
    straight to its bucket -- it carries no spans left to union or clip."""
    out = {}  # type: Dict[str, Dict[str, int]]
    for row in rows:
        if row.kind != "total":
            continue
        if row.start >= options.upto or row.end <= options.since:
            continue
        column = CATEGORY_COLUMNS.get(row.mode)
        if column is None:
            continue
        try:
            seconds = int(row.words)
        except ValueError:
            continue
        if seconds <= 0:
            continue
        bucket = out.setdefault(_total_key(row, options), {})
        bucket[column] = bucket.get(column, 0) + seconds
    return out


def build_report(rows, options):
    # type: (Iterable[Row], Options) -> str
    rows = list(rows)
    timeline = ModeTimeline.from_rows(rows)
    effort = effort_spans(rows, timeline, options.presence_gap,
                          options.checkin_window)
    machine = machine_spans(rows, options.max_active)

    normalized = with_history(effort, rows)
    sources = {name.upper(): entries for name, entries in normalized.items()}
    sources.update(AGENT=machine.agent, TOOL=machine.tool)
    collected = {name: _collect(entries, options)
                 for name, entries in sources.items()}
    totals = _collect_totals(rows, options)

    keys = set()
    for buckets in collected.values():
        keys.update(buckets)
    keys.update(totals)

    table = {}  # type: Dict[str, Dict[str, int]]
    for key in keys:
        cells = {}
        for name in EFFORT_PRIORITY:
            cells[name] = total(collected[name].get(key, []))
        for name in ("AGENT", "TOOL"):
            cells[name] = total(collected[name].get(key, []))
        extra = totals.get(key, {})
        for name in ("PAIRED", "CHECKIN", "MANUAL", "AGENT", "TOOL"):
            cells[name] += extra.get(name, 0)
        cells["EFFORT"] = cells["PAIRED"] + cells["CHECKIN"] + cells["MANUAL"]
        if any(cells[name] for name in COLUMNS):
            table[key] = cells

    label = "DAY" if options.byday else "PROJECT"
    width = max([len(label), len("TOTAL")] + [len(k) for k in table])
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

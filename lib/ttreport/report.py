"""Aggregates spans into buckets and renders the table.

Effort unions inside a bucket, because one person cannot spend the same
minute twice on one project. Machine time sums, because agents can.

Effort's three columns arrive with overlapping coverage -- a check-in
episode's window can cover seconds a paired interval also covers -- so
before totalling, each category has whatever a higher-priority category
already covers subtracted from it, in priority order PAIRED > CHECKIN >
MANUAL. That makes the three columns disjoint, so they sum exactly to
EFFORT, and EFFORT equals the union of every effort span in the bucket.
"""

import time
from typing import Dict, Iterable, List, NamedTuple

from .effort import effort_spans
from .events import Row
from .intervals import Span, clip, split_days, subtract, total, union
from .machine import machine_spans
from .modes import ModeTimeline
from .state import floor_entries, floor_of

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
    seconds = max(0, int(seconds))
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


def _disjoint_effort(collected, key):
    # type: (Dict[str, Dict[str, List[Span]]], str) -> Dict[str, List[Span]]
    """Priority order PAIRED > CHECKIN > MANUAL: each category keeps only
    the seconds no higher-priority category already claimed."""
    claimed = []  # type: List[Span]
    disjoint = {}  # type: Dict[str, List[Span]]
    for name in EFFORT_PRIORITY:
        spans = union(collected[name].get(key, []))
        remaining = subtract(spans, claimed)
        disjoint[name] = remaining
        claimed = union(claimed + remaining)
    return disjoint


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

    # A carried heartbeat, turn or tool bracket is dated at its own real,
    # pre-cutoff timestamp so it classifies correctly against what follows
    # it -- but its pre-cutoff portion is already inside a history `total`
    # row, so whatever it contributes here is floored at the cutoff that
    # carried it.
    floor = floor_of(rows)
    sources = {
        "PAIRED": floor_entries(effort.paired, floor),
        "CHECKIN": floor_entries(effort.checkin, floor),
        "MANUAL": effort.manual,
        "AGENT": floor_entries(machine.agent, floor),
        "TOOL": floor_entries(machine.tool, floor),
    }
    collected = {name: _collect(entries, options)
                 for name, entries in sources.items()}
    totals = _collect_totals(rows, options)

    keys = set()
    for buckets in collected.values():
        keys.update(buckets)
    keys.update(totals)

    table = {}  # type: Dict[str, Dict[str, int]]
    for key in keys:
        disjoint = _disjoint_effort(collected, key)
        cells = {}
        for name in EFFORT_PRIORITY:
            cells[name] = total(disjoint[name])
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

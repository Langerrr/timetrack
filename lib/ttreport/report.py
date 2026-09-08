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
from .intervals import Span, clip, split_days, total, union
from .machine import machine_spans
from .modes import ModeTimeline

COLUMNS = ("PAIRED", "CHECKIN", "MANUAL", "EFFORT", "AGENT", "TOOL")
EFFORT_PRIORITY = ("PAIRED", "CHECKIN", "MANUAL")


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


def _subtract(spans, remove):
    # type: (List[Span], List[Span]) -> List[Span]
    """spans and remove are each already sorted and internally disjoint
    (the output of union()). Removes every second `remove` covers."""
    if not remove:
        return list(spans)
    out = []  # type: List[Span]
    for start, end in spans:
        cursor = start
        for rstart, rend in remove:
            if rend <= cursor:
                continue
            if rstart >= end:
                break
            if rstart > cursor:
                out.append((cursor, rstart))
            cursor = max(cursor, rend)
            if cursor >= end:
                break
        if cursor < end:
            out.append((cursor, end))
    return out


def _disjoint_effort(collected, key):
    # type: (Dict[str, Dict[str, List[Span]]], str) -> Dict[str, List[Span]]
    """Priority order PAIRED > CHECKIN > MANUAL: each category keeps only
    the seconds no higher-priority category already claimed."""
    claimed = []  # type: List[Span]
    disjoint = {}  # type: Dict[str, List[Span]]
    for name in EFFORT_PRIORITY:
        spans = union(collected[name].get(key, []))
        remaining = _subtract(spans, claimed)
        disjoint[name] = remaining
        claimed = union(claimed + remaining)
    return disjoint


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
        disjoint = _disjoint_effort(collected, key)
        cells = {}
        for name in EFFORT_PRIORITY:
            cells[name] = total(disjoint[name])
        for name in ("AGENT", "TOOL"):
            cells[name] = total(collected[name].get(key, []))
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

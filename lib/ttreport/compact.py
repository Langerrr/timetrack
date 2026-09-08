"""Rolls completed days into bounded totals.

A day that has closed cannot change, so its spans collapse into one total
per project, subpath and category. Rows at or after the cutoff are carried
forward untouched, because the reconstruction that covers them is not
finished yet. The one exception is a manual span that straddles the
cutoff: it is already fully known (both its ends were logged at once, not
reconstructed), so its future portion is carried forward too rather than
lost.

Effort categories are made disjoint here in the same priority order --
PAIRED > CHECKIN > MANUAL -- that build_report applies to live spans, so a
historical total sums to the EFFORT a live report over the same rows would
have shown. Machine time is never unioned: two tools running at once are
two tools' worth of TOOL time, and a subagent's own AGENT time stands
beside its parent's.
"""

from typing import Dict, Iterable, List, Tuple

from .effort import effort_spans
from .events import Row
from .intervals import Span, clip, split_days, subtract, total, union
from .machine import machine_spans
from .modes import ModeTimeline
from .report import Options

EFFORT_CATEGORIES = ("paired", "checkin", "manual")
MACHINE_CATEGORIES = ("agent", "tool")
CATEGORIES = EFFORT_CATEGORIES + MACHINE_CATEGORIES


def _line(day, day_end, project, subpath, category, seconds):
    # type: (int, int, str, str, str, int) -> str
    return "\t".join([
        "-", "total", str(day), str(day_end), "-", "-", category,
        project, subpath, "-", "-", "-", "-", "-", "-", str(seconds),
        "-", "-", "-", "-",
    ])


def _carry_line(row):
    # type: (Row) -> str
    return "\t".join([
        row.iso, row.kind, str(row.start), str(row.end), row.machine,
        row.harness, row.mode, row.project, row.subpath, row.session,
        row.event, row.turn_id, row.tool_use_id, row.agent_id,
        row.agent_type, row.words, row.session_source, row.tool_name,
        row.prompt_class, row.fingerprint,
    ])


def _day_end(day, boundaries, cutoff):
    # type: (int, List[int], int) -> int
    """A full prior day ends at its own next midnight, which always
    precedes cutoff. The still-open final day has no later boundary in the
    list yet, so it ends exactly at cutoff -- never a whole day past it."""
    later = [b for b in boundaries if b > day]
    day_end = min(later) if later else cutoff
    return min(day_end, cutoff)


def compact(rows, cutoff, options):
    # type: (Iterable[Row], int, Options) -> Tuple[List[str], List[str]]
    rows = list(rows)

    carry = []  # type: List[str]
    for row in rows:
        if row.start >= cutoff:
            carry.append(_carry_line(row))
        elif row.kind == "span" and row.end > cutoff:
            carry.append(_carry_line(row._replace(start=cutoff)))

    past = [r for r in rows if r.start < cutoff]
    if not past:
        return ([], carry)

    timeline = ModeTimeline.from_rows(past)
    effort = effort_spans(past, timeline, options.presence_gap,
                          options.checkin_window)
    machine = machine_spans(past, options.max_active)

    sources = {
        "paired": effort.paired,
        "checkin": effort.checkin,
        "manual": effort.manual,
        "agent": machine.agent,
        "tool": machine.tool,
    }

    buckets = {}  # type: Dict[Tuple[int, str, str], Dict[str, List[Span]]]
    for category, entries in sources.items():
        for project, subpath, span in entries:
            for clipped in clip([span], 0, cutoff):
                for day, piece in split_days([clipped], options.boundaries):
                    bucket = buckets.setdefault((day, project, subpath), {})
                    bucket.setdefault(category, []).append(piece)

    history = []
    for key in sorted(buckets):
        day, project, subpath = key
        by_category = buckets[key]

        claimed = []  # type: List[Span]
        seconds = {}  # type: Dict[str, int]
        for category in EFFORT_CATEGORIES:
            remaining = subtract(union(by_category.get(category, [])), claimed)
            seconds[category] = total(remaining)
            claimed = union(claimed + remaining)
        for category in MACHINE_CATEGORIES:
            seconds[category] = total(by_category.get(category, []))

        day_end = _day_end(day, options.boundaries, cutoff)
        for category in CATEGORIES:
            if seconds[category] <= 0:
                continue
            history.append(_line(day, day_end, project, subpath, category,
                                 seconds[category]))
    return (history, carry)


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

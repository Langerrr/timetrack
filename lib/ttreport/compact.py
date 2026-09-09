"""Bounded effort coverage and finalized machine totals, with pending state.

Effort history retains coalesced project/day coverage for union with other
sources and later manual additions. Machine totals contain only closed,
resolved contributions. Unresolved estimates remain replaceable in current
state, including pre-cutoff seconds which later evidence can correct.
"""

from typing import Dict, Iterable, List, Tuple

from .effort import effort_spans
from .events import Row
from .intervals import clip, split_days
from .machine import machine_spans
from .modes import ModeTimeline
from .report import Options
from .state import write_lines

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
    # Reconstruct only observations available before the cutoff. Estimates
    # are rendered from carried facts, never frozen into machine totals.
    from .coverage import with_history
    rows = list(rows)
    carry = []
    history = []
    for row in rows:
        if row.kind == 'total':
            history.append(_carry_line(row))
        elif row.start >= cutoff:
            carry.append(_carry_line(row))
        elif row.kind in ('span', 'coverage') and row.end > cutoff:
            carry.append(_carry_line(row._replace(start=cutoff)))
    past = [r for r in rows if r.start < cutoff]
    if not past:
        return history, carry
    timeline = ModeTimeline.from_rows(past)
    effort = effort_spans(past, timeline, options.presence_gap, options.checkin_window)
    machine = machine_spans(past, options.max_active)
    carry.extend(write_lines(past, cutoff, options.checkin_window, options.max_active, machine))
    for category, entries in with_history(effort, past).items():
        for project, subpath, span in entries:
            for clipped in clip([span], 0, cutoff):
                for _day, piece in split_days([clipped], options.boundaries):
                    start, end = piece
                    fields = _line(start, end, project, subpath, category, end-start).split('\t')
                    fields[1] = 'coverage'
                    history.append('\t'.join(fields))
    buckets = {}
    for category, entries in [('agent', machine.stable_agent), ('tool', machine.stable_tool)]:
        for project, subpath, span in entries:
            for clipped in clip([span], 0, cutoff):
                for day, piece in split_days([clipped], options.boundaries):
                    key = (day, project, subpath, category)
                    buckets[key] = buckets.get(key, 0) + piece[1] - piece[0]
    for (day, project, subpath, category), seconds in sorted(buckets.items()):
        if seconds:
            history.append(_line(day, _day_end(day, options.boundaries, cutoff),
                                 project, subpath, category, seconds))
    return history, carry


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

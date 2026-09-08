"""Reconstruction state carried across a compaction cutoff.

A stream still active at the cutoff -- a recent heartbeat, an open turn, an
open tool bracket -- does not simply stop existing at that instant.
Compaction emits one `state` row per still-relevant fact, each dated at its
own real, pre-cutoff timestamp, so a later, independent reconstruction (a
live report, or the next compaction) resumes it and classifies the gap to
whatever comes next exactly as an uncompacted reconstruction would have.

Every fact this carries also carries the cutoff that produced it, as a
floor. The pre-cutoff portion of any interval a carried fact takes part in
is already inside a history `total` row, so the credited result of
resuming it must never reach back before that floor -- see `floor_entries`.
"""

from typing import Dict, Iterable, List, Optional, Tuple

from .effort import _is_heartbeat, _presence_key
from .events import Row, STATE_HEARTBEAT, STATE_TOOL, STATE_TURN
from .intervals import Span, clip
from .machine import MachineSpans
from .modes import ModeTimeline, SOLO

HUGE = 1 << 62


def _line(at, floor, event, project, subpath, machine, harness, session,
         mode="-", tool_use_id="-", tool_name="-"):
    # type: (int, int, str, str, str, str, str, str, str, str, str) -> str
    return "\t".join([
        "-", "state", str(at), str(at), machine, harness, mode, project,
        subpath, session, event, "-", tool_use_id, "-", "-", str(floor),
        "-", tool_name, "-", "-",
    ])


def write_lines(past, cutoff, presence_gap, max_active, machine_result):
    # type: (List[Row], int, int, int, MachineSpans) -> List[str]
    """past is strictly what precedes the cutoff; machine_result is
    machine_spans(past, ...) -- computed once by the caller, since its
    open_turns/open_tools already answer what past alone leaves
    unresolved. A bracket or heartbeat this call's own full-row pass
    resolves (its close is somewhere in the rows being compacted, whether
    before or after the cutoff) needs no seed: it is either already inside
    a history total, or -- being at or after the cutoff itself -- already
    carried verbatim as that close's own row. Only what past alone cannot
    resolve is carried here. A bracket older than max_active is one
    machine_spans itself would already treat as abandoned rather than
    still running, so it is left uncarried the same way.

    A manual span is presence too (effort.py's own _is_heartbeat says so,
    for episode-forming purposes inside a single reconstruction pass) but
    it is not a lifecycle fact that ever needs resuming -- it already
    carries both of its own ends, via the straddling-span carry in
    compact() itself -- so it is excluded here explicitly."""
    lines = []  # type: List[str]

    timeline = ModeTimeline.from_rows(past)
    last_by_key = {}  # type: Dict[Tuple, Row]
    for row in past:
        if row.kind == "span" or not _is_heartbeat(row):
            continue
        key = _presence_key(row)
        current = last_by_key.get(key)
        if current is None or row.start > current.start:
            last_by_key[key] = row

    open_turns = dict((stream, opened)
                      for stream, opened in machine_result.open_turns.items()
                      if cutoff - opened.start <= max_active)
    open_tools = dict((k, opened)
                      for k, opened in machine_result.open_tools.items()
                      if cutoff - opened.start <= max_active)

    for last in last_by_key.values():
        if last.start >= cutoff:
            continue
        mode = timeline.at(last.stream, last.start, last.project, last.subpath)
        has_open = (last.stream in open_turns or
                    any(k[0] == last.stream for k in open_tools))
        # A trailing PAIRED heartbeat only matters for gap-crediting the
        # next one, which is worthless once the gap alone would already
        # exceed presence_gap. SOLO has no such expiry: `tt solo` stays in
        # force until something explicitly changes it, no matter the gap.
        if (mode != SOLO and cutoff - last.start > presence_gap and
                not has_open):
            continue
        lines.append(_line(last.start, cutoff, STATE_HEARTBEAT,
                           last.project, last.subpath, last.machine,
                           last.harness, last.session, mode=mode))

    for opened in open_turns.values():
        lines.append(_line(opened.start, cutoff, STATE_TURN, opened.project,
                           opened.subpath, opened.machine, opened.harness,
                           opened.session))

    for (_stream, tool_use_id), opened in open_tools.items():
        lines.append(_line(opened.start, cutoff, STATE_TOOL, opened.project,
                           opened.subpath, opened.machine, opened.harness,
                           opened.session, tool_use_id=tool_use_id,
                           tool_name=opened.tool_name))

    return lines


def floor_of(rows):
    # type: (Iterable[Row]) -> Optional[int]
    """The cutoff any state rows in `rows` were carried from -- None if
    there are none, in which case nothing needs flooring."""
    floors = []
    for row in rows:
        if row.kind != "state":
            continue
        try:
            floors.append(int(row.words))
        except ValueError:
            continue
    return max(floors) if floors else None


def floor_entries(entries, floor):
    # type: (Iterable[Tuple[str, str, Span]], Optional[int]) -> List[Tuple[str, str, Span]]
    """Clips every entry to start no earlier than `floor`. A carried fact's
    pre-floor portion is already inside a history total row -- crediting it
    again here would double count it."""
    if floor is None:
        return list(entries)
    out = []
    for project, subpath, span in entries:
        for clipped in clip([span], floor, HUGE):
            out.append((project, subpath, clipped))
    return out

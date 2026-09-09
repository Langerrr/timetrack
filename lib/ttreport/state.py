"""Minimal effort and machine facts retained until resolving evidence arrives.

There is no shared reconstruction floor: pending estimates were never posted
as immutable machine totals. Effort can add earlier coverage when the next
heartbeat arrives; canonical project union absorbs already-known seconds.
"""

from typing import List

from .effort import presence_groups, _scoped_heartbeat
from .events import Row, STATE_HEARTBEAT
from .machine import MachineSpans
from .modes import ModeTimeline, SOLO


def _line(at, floor, event, project, subpath, machine, harness, session,
         mode="-", tool_use_id="-", tool_name="-"):
    # type: (int, int, str, str, str, str, str, str, str, str, str) -> str
    return "\t".join([
        "-", "state", str(at), str(at), machine, harness, mode, project,
        subpath, session, event, "-", tool_use_id, "-", "-", str(floor),
        "-", tool_name, "-", "-",
    ])


def write_lines(past, cutoff, checkin_window, max_active, machine_result):
    # type: (List[Row], int, int, int, MachineSpans) -> List[str]
    """Use only observations before cutoff; keep openings regardless of age.

    A solo episode also carries its initial attribution so extending its
    final heartbeat after rollover cannot move its effort to another path.
    """
    # A new session may first appear after rollover, then inherit presence
    # from older overlapping terminal scopes. Their complete transition
    # sequence preserves solo boundaries between those heartbeats. Keep only
    # these mode facts, never raw hook history; this history grows with the
    # number of terminal mode commands.
    lines = ['\t'.join(str(field) for field in row)
             for row in past if _scoped_heartbeat(row)]  # type: List[str]

    from .effort import episode_location
    timeline = ModeTimeline.from_rows(past)
    last_by_key = {}
    anchors = {}
    for key, beats in presence_groups(past).items():
        for row in sorted(beats, key=lambda r: r.start):
            previous = last_by_key.get(key)
            mode = timeline.at(row.stream, row.start, row.project, row.subpath)
            if mode == SOLO:
                if (previous is None or key not in anchors or
                        row.start - previous.start > checkin_window):
                    anchors[key] = episode_location(row)
            else:
                anchors.pop(key, None)
            last_by_key[key] = row

    from .events import parse_line
    for key, last in last_by_key.items():
        if last.start >= cutoff or _scoped_heartbeat(last):
            continue
        mode = timeline.at(last.stream, last.start, last.project, last.subpath)
        carried = parse_line(_line(last.start, 0, STATE_HEARTBEAT,
                                  last.project, last.subpath, last.machine,
                                  last.harness, last.session, mode=mode))
        if key in anchors:
            project, subpath = anchors[key]
            carried = carried._replace(session_source='episode', agent_type=project,
                                       tool_name=subpath)
        lines.append('\t'.join(str(field) for field in carried))

    from .machine import state
    lines.extend('\t'.join(str(field) for field in row)
                 for row in machine_result.pending)
    for seed in machine_result.last_close.values():
        if cutoff - seed.start <= max_active:
            lines.append('\t'.join(str(field) for field in state(seed, 'continuation')))

    return lines

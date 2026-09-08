"""Effort: the user's own engagement, reconstructed from heartbeats.

A heartbeat is an event only a present human produces. In paired mode the
interval between two heartbeats is the work -- reading, thinking, typing --
and is credited whole. In solo mode the user is away by default, so
heartbeats cluster into check-in episodes and only those are credited.
"""

from typing import Dict, Iterable, List, NamedTuple, Tuple

from .events import Row
from .intervals import Span
from .modes import ModeTimeline, SOLO

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
            boundary = nxt.start
            change = timeline.next_change(stream, row.start, row.project, row.subpath)
            if change is not None and change < boundary:
                boundary = change
            if boundary <= row.start:
                continue
            elapsed = boundary - row.start
            if elapsed <= presence_gap:
                paired.append((row.project, row.subpath, (row.start, boundary)))
            else:
                paired.append((row.project, row.subpath,
                               (boundary - half_gap, boundary)))
        flush(episode)

    return EffortSpans(paired=paired, checkin=checkin, manual=manual)

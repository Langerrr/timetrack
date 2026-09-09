"""Effort: the user's own engagement, reconstructed from heartbeats.

A heartbeat is an event only a present human produces. In paired mode the
interval between two heartbeats is the work -- reading, thinking, typing --
and is credited whole. In solo mode the user is away by default, so
heartbeats cluster into check-in episodes and only those are credited.
"""

from typing import Dict, Iterable, List, NamedTuple, Tuple

from .events import Row, STATE_HEARTBEAT
from .intervals import Span
from .modes import ModeTimeline, SOLO, _applies

Entry = Tuple[str, str, Span]


class EffortSpans(NamedTuple):
    paired: List[Entry]
    checkin: List[Entry]
    manual: List[Entry]


def _is_heartbeat(row):
    # type: (Row) -> bool
    if row.kind == "mode":
        return True
    if row.kind == "state":
        return row.event == STATE_HEARTBEAT
    if row.kind != "beat" or row.event != "UserPromptSubmit":
        return False
    if row.agent_id not in ("-", ""):
        return False
    return row.prompt_class != "machine"


def _presence_key(row):
    # type: (Row) -> Tuple
    # A mode row carries no harness, so harness cannot be part of the key
    # that groups a session's heartbeats: `tt paired` and the prompt that
    # follows it are one person returning to one session.
    if row.session and row.session != "-":
        return (row.machine, row.session)
    return (row.machine, row.harness, row.project + "/" + row.subpath)


def _scoped_heartbeat(row):
    return (row.session in ('-', '') and row.harness == '-' and
            (row.kind == 'mode' or
             (row.kind == 'state' and row.event == STATE_HEARTBEAT)))


def presence_groups(rows):
    """Share terminal presence with covered sessions, using the mode scope.

    Keep the terminal's own stream too: two terminal commands are evidence
    even without a harness session. Project coverage unions their overlap.
    Project each shared heartbeat onto the session's observed location so
    subsequent nested mode changes resolve against the same scope as prompts.
    """
    groups = {}
    scopes = []
    for row in rows:
        if not _is_heartbeat(row):
            continue
        groups.setdefault(_presence_key(row), []).append(row)
        if _scoped_heartbeat(row):
            scopes.append(row)
    for key, beats in groups.items():
        observed = sorted((r for r in beats if not _scoped_heartbeat(r)),
                          key=lambda r: r.start)
        if not observed:
            continue
        for scope in scopes:
            # A carried session has already settled everything before its
            # last heartbeat. Older terminal commands remain available only
            # to newly observed sessions; replaying them here could bridge a
            # session-specific solo transition that was already compacted.
            first = observed[0]
            if (first.kind == 'state' and first.event == STATE_HEARTBEAT and
                    scope.start <= first.start):
                continue
            # The latest known location applies until a session next moves.
            target = observed[0]
            for row in observed:
                if row.start > scope.start:
                    break
                target = row
            if not _applies(scope, target.stream, target.project, target.subpath):
                continue
            project, subpath = episode_location(scope)
            beats.append(scope._replace(
                kind='state', event=STATE_HEARTBEAT, harness=target.harness,
                session=target.session, project=target.project,
                subpath=target.subpath, session_source='episode',
                agent_type=project, tool_name=subpath))
        beats.sort(key=lambda r: r.start)
    return groups


def episode_location(row):
    if row.kind == 'state' and row.session_source == 'episode':
        return row.agent_type, row.tool_name
    return row.project, row.subpath


def effort_spans(rows, timeline, presence_gap, checkin_window):
    # type: (Iterable[Row], ModeTimeline, int, int) -> EffortSpans
    paired = []  # type: List[Entry]
    checkin = []  # type: List[Entry]
    manual = []  # type: List[Entry]

    rows = list(rows)
    manual = [(row.project, row.subpath, (row.start, row.end))
              for row in rows if row.kind == "span"]
    by_presence = presence_groups(rows)

    half_gap = presence_gap // 2
    half_window = checkin_window // 2

    for _key, beats in by_presence.items():
        beats.sort(key=lambda r: r.start)
        episode = []  # type: List[Row]

        def flush(episode):
            if not episode:
                return
            first, last = episode[0], episode[-1]
            project, subpath = episode_location(first)
            checkin.append((project, subpath,
                            (first.start - half_window,
                             last.start + half_window)))

        for index, row in enumerate(beats):
            mode = timeline.at(row.stream, row.start, row.project, row.subpath)
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
            change = timeline.next_change(row.stream, row.start, row.project, row.subpath)
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

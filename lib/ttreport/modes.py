"""Which mode is in force for a stream at an instant.

A path-scoped transition reaches every session at or below that path, so
`tt solo` typed at a project root also covers a tool that later reports a
nested working directory.
"""

from typing import Iterable, List, Optional, Tuple

from .events import Row, STATE_HEARTBEAT

PAIRED = "paired"
SOLO = "solo"


def _covers(row, project, subpath):
    # type: (Row, str, str) -> bool
    if row.project != project:
        return False
    if row.subpath in (".", "-", ""):
        return True
    return subpath == row.subpath or subpath.startswith(row.subpath + "/")


def _applies(row, stream, project, subpath):
    # type: (Row, Tuple[str, str, str], str, str) -> bool
    machine, _harness, key = stream
    if row.machine != machine:
        return False
    if row.session not in ("-", ""):
        return row.session == key
    return _covers(row, project, subpath)


class ModeTimeline(object):
    def __init__(self, transitions):
        # type: (List[Row]) -> None
        self._transitions = transitions

    @classmethod
    def from_rows(cls, rows):
        # type: (Iterable[Row]) -> ModeTimeline
        # A carried heartbeat state row is itself a transition: it is dated
        # at the heartbeat's own timestamp and carries the mode that was
        # effective there, so a post-cutoff query resumes it exactly as an
        # uncompacted timeline would have.
        transitions = [r for r in rows if r.kind == "mode" or
                       (r.kind == "state" and r.event == STATE_HEARTBEAT)]
        transitions.sort(key=lambda r: r.start)
        return cls(transitions)

    def at(self, stream, when, project, subpath):
        # type: (Tuple[str, str, str], int, str, str) -> str
        mode = PAIRED
        for row in self._transitions:
            if row.start > when:
                break
            if not _applies(row, stream, project, subpath):
                continue
            mode = row.mode if row.mode in (PAIRED, SOLO) else mode
        return mode

    def next_change(self, stream, when, project, subpath):
        # type: (Tuple[str, str, str], int, str, str) -> Optional[int]
        """When this stream's mode next differs from the mode at `when`."""
        current = self.at(stream, when, project, subpath)
        mode = current
        for row in self._transitions:
            if row.start <= when:
                continue
            if not _applies(row, stream, project, subpath):
                continue
            mode = row.mode if row.mode in (PAIRED, SOLO) else mode
            if mode != current:
                return row.start
        return None

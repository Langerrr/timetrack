"""Which mode is in force for a stream at an instant.

A path-scoped transition reaches every session at or below that path, so
`tt solo` typed at a project root also covers a tool that later reports a
nested working directory.
"""

from typing import Iterable, List, Tuple

from .events import Row

PAIRED = "paired"
SOLO = "solo"


def _covers(row, project, subpath):
    # type: (Row, str, str) -> bool
    if row.project != project:
        return False
    if row.subpath in (".", "-", ""):
        return True
    return subpath == row.subpath or subpath.startswith(row.subpath + "/")


class ModeTimeline(object):
    def __init__(self, transitions):
        # type: (List[Row]) -> None
        self._transitions = transitions

    @classmethod
    def from_rows(cls, rows):
        # type: (Iterable[Row]) -> ModeTimeline
        transitions = [r for r in rows if r.kind == "mode"]
        transitions.sort(key=lambda r: r.start)
        return cls(transitions)

    def at(self, stream, when, project, subpath):
        # type: (Tuple[str, str, str], int, str, str) -> str
        machine, _harness, key = stream
        mode = PAIRED
        for row in self._transitions:
            if row.start > when:
                break
            if row.machine != machine:
                continue
            if row.session not in ("-", ""):
                if row.session != key:
                    continue
            elif not _covers(row, project, subpath):
                continue
            mode = row.mode if row.mode in (PAIRED, SOLO) else mode
        return mode

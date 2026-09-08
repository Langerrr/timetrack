"""Parses the event TSV into typed rows.

This module owns the column layout. Rows written before a column existed
are shorter than the current layout and read their missing fields as "-",
so an old log replays without conversion.
"""

from typing import Iterable, List, NamedTuple, Optional, Tuple

COLUMNS = 20
MIN_COLUMNS = 11

SUBAGENT_TOOLS = frozenset(["Task", "Agent"])


class Row(NamedTuple):
    iso: str
    kind: str
    start: int
    end: int
    machine: str
    harness: str
    mode: str
    project: str
    subpath: str
    session: str
    event: str
    turn_id: str
    tool_use_id: str
    agent_id: str
    agent_type: str
    words: str
    session_source: str
    tool_name: str
    prompt_class: str
    fingerprint: str

    @property
    def stream(self):
        # type: () -> Tuple[str, str, str]
        if self.session and self.session != "-":
            return (self.machine, self.harness, self.session)
        return (self.machine, self.harness, self.project + "/" + self.subpath)


def parse_line(line):
    # type: (str) -> Optional[Row]
    line = line.rstrip("\n")
    if not line:
        return None
    fields = line.split("\t")
    if len(fields) < MIN_COLUMNS:
        return None
    fields = fields + ["-"] * (COLUMNS - len(fields))
    try:
        start = int(fields[2])
        end = int(fields[3])
    except ValueError:
        return None
    return Row(
        iso=fields[0], kind=fields[1], start=start, end=end,
        machine=fields[4], harness=fields[5], mode=fields[6],
        project=fields[7], subpath=fields[8], session=fields[9],
        event=fields[10], turn_id=fields[11], tool_use_id=fields[12],
        agent_id=fields[13], agent_type=fields[14], words=fields[15],
        session_source=fields[16], tool_name=fields[17],
        prompt_class=fields[18], fingerprint=fields[19],
    )


def parse_stream(lines):
    # type: (Iterable[str]) -> List[Row]
    out = []
    for line in lines:
        row = parse_line(line)
        if row is not None:
            out.append(row)
    return out

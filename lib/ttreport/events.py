"""Parses the event TSV into typed rows.

This module owns the column layout. Rows written before a column existed
are shorter than the current layout and read their missing fields as "-",
so an old log replays without conversion.

A `total` row is the one exception that needs more than padding: the
retired awk compactor wrote a 12-field layout with the day's mode in
column 7 and its seconds in column 11, while the current compactor writes
the full-width layout with a category in column 7 and seconds in column
16. An old row is normalized into the current layout's positions here, so
every other module only ever sees one `total` shape.
"""

from typing import Iterable, List, NamedTuple, Optional, Tuple

COLUMNS = 20
MIN_COLUMNS = 11
OLD_TOTAL_COLUMNS = 12

SUBAGENT_TOOLS = frozenset(["Task", "Agent"])

# `solo` maps to `agent` because, under the retired model, it meant the
# agent ran while the user was elsewhere -- machine time, not the user's
# own effort. A duration-only row cannot be split between AGENT and TOOL,
# so it all lands on AGENT.
_OLD_TOTAL_CATEGORY = {"paired": "paired", "manual": "manual", "solo": "agent"}

# A `state` row's `event` column says which fact it carries across a
# compaction cutoff: the last heartbeat (its `mode` column is the mode
# effective at that heartbeat), an open turn, or an open tool bracket.
STATE_HEARTBEAT = "heartbeat"
STATE_TURN = "turn"
STATE_TOOL = "tool"


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
    if fields[1] == 'coverage':
        if len(fields) != COLUMNS or fields[6] not in ('paired', 'checkin', 'manual'):
            return None
        try:
            start, end, seconds = int(fields[2]), int(fields[3]), int(fields[15])
        except ValueError:
            return None
        if start < 0 or end <= start or seconds != end - start or not fields[7] or not fields[8]:
            return None
    if fields[1] == "total" and len(fields) == OLD_TOTAL_COLUMNS:
        category = _OLD_TOTAL_CATEGORY.get(fields[6])
        if category is None:
            return None
        fields = [
            fields[0], "total", fields[2], fields[3], fields[4], "-",
            category, fields[7], fields[8], "-", "-", "-", "-", "-", "-",
            fields[10], "-", "-", "-", "-",
        ]
    elif fields[1] == "state" and len(fields) != COLUMNS:
        # The retired awk compactor's state row encoded a different
        # reconstruction entirely (reading estimates, pending-stop
        # tracking) at widths that are never exactly COLUMNS wide. There is
        # no coherent mapping from that model to this one, unlike `total`,
        # so it is dropped rather than misread as a carried heartbeat or
        # bracket.
        return None
    else:
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

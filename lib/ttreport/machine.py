"""Machine time: what the agents did, split into agent and tool.

A worker is a main session or one subagent. Workers run in parallel, so
their spans sum. Tool calls inside a worker are that worker working, so
their union is subtracted from its agent time -- but the tool column sums
them, because two commands running at once occupy two commands' worth of
machine.
"""

from typing import Dict, Iterable, List, NamedTuple, Tuple

from .events import Row, SUBAGENT_TOOLS
from .intervals import Span, union

TOOL_OPEN = "PreToolUse"
TOOL_CLOSE = frozenset(["PostToolUse", "PostToolUseFailure", "PermissionDenied"])
TURN_OPEN = "UserPromptSubmit"
TURN_CLOSE = frozenset(["Stop", "Interrupt", "StopFailure", "SessionEnd"])

Entry = Tuple[str, str, Span]


class MachineSpans(NamedTuple):
    agent: List[Entry]
    tool: List[Entry]


def machine_spans(rows, max_active):
    # type: (Iterable[Row], int) -> MachineSpans
    rows = [r for r in rows if r.kind == "beat"]
    rows.sort(key=lambda r: r.start)

    agent = []  # type: List[Entry]
    tool = []  # type: List[Entry]

    open_tools = {}  # type: Dict[Tuple, Row]
    turn_open = {}  # type: Dict[Tuple, Row]
    turn_tools = {}  # type: Dict[Tuple, List[Span]]
    last_close = {}  # type: Dict[Tuple, int]

    def close_turn(stream, opened, at):
        inside = union(turn_tools.pop(stream, []))
        whole = [(opened.start, at)]
        for start, end in whole:
            cursor = start
            for tstart, tend in inside:
                if tend <= cursor or tstart >= end:
                    continue
                if tstart > cursor:
                    agent.append((opened.project, opened.subpath, (cursor, tstart)))
                cursor = max(cursor, tend)
            if end > cursor:
                agent.append((opened.project, opened.subpath, (cursor, end)))
        last_close[stream] = at

    for row in rows:
        stream = row.stream
        if row.event == TOOL_OPEN:
            open_tools[(stream, row.tool_use_id)] = row
        elif row.event in TOOL_CLOSE:
            opened = open_tools.pop((stream, row.tool_use_id), None)
            if opened is not None:
                span = (opened.start, row.start)
                tool.append((opened.project, opened.subpath, span))
                turn_tools.setdefault(stream, []).append(span)
                if opened.tool_name in SUBAGENT_TOOLS:
                    agent.append((opened.project, opened.subpath, span))
        elif row.event == TURN_OPEN:
            if stream in turn_open:
                close_turn(stream, turn_open.pop(stream), row.start)
            turn_open[stream] = row
        elif row.event in TURN_CLOSE:
            opened = turn_open.pop(stream, None)
            if opened is None:
                start = last_close.get(stream)
                if start is None or row.start - start > max_active:
                    last_close[stream] = row.start
                    continue
                opened = row._replace(start=start)
            close_turn(stream, opened, row.start)

    for (stream, _tool_id), opened in open_tools.items():
        span = (opened.start, opened.start + max_active)
        tool.append((opened.project, opened.subpath, span))
        turn_tools.setdefault(stream, []).append(span)
        if opened.tool_name in SUBAGENT_TOOLS:
            agent.append((opened.project, opened.subpath, span))

    for stream, opened in list(turn_open.items()):
        close_turn(stream, opened, opened.start + max_active)

    return MachineSpans(agent=agent, tool=tool)

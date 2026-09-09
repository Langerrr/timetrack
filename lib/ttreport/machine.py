"""Machine time and the compact frontier of unresolved worker lifecycles.

Closed tool durations are additive. Agent time subtracts the union of that
worker's tools. Estimates stay provisional until closure; compactors emit
only stable contributions and carry the facts needed to replace estimates.
"""
from typing import Dict, List, NamedTuple, Tuple
from .events import Row, SUBAGENT_TOOLS
from .intervals import subtract, union

TOOL_OPEN = 'PreToolUse'
TOOL_CLOSE = frozenset(['PostToolUse', 'PostToolUseFailure', 'PermissionDenied'])
TURN_OPEN = 'UserPromptSubmit'
TURN_CLOSE = frozenset(['Stop', 'Interrupt', 'StopFailure', 'SessionEnd'])
Entry = Tuple[str, str, Tuple[int, int]]


class MachineSpans(NamedTuple):
    agent: List[Entry]
    tool: List[Entry]
    open_turns: Dict[Tuple, Row]
    open_tools: Dict[Tuple, Row]
    stable_agent: List[Entry]
    stable_tool: List[Entry]
    pending: List[Row]
    last_close: Dict[Tuple, Row]


def worker(row):
    return (row.stream, row.agent_id if row.agent_id not in ('', '-') else '-')


def tool_worker(row):
    owner = worker(row)
    if row.session_source == 'unassociated':
        return (owner[0], ('unassociated', owner[1]))
    return owner


def state(row, event, end=None):
    return row._replace(iso='-', kind='state', event=event,
                        end=row.start if end is None else end, words='0',
                        prompt_class='-', fingerprint='-')


def machine_spans(rows, max_active):
    rows = sorted((r for r in rows if r.kind == 'beat' or
                   (r.kind == 'state' and r.event != 'heartbeat')), key=lambda r: r.start)
    open_tools, open_turns, last_close = {}, {}, {}
    tools, turns = [], []  # (worker, opening, end, stable, already credited)

    def close_tool(key, at, stable=True):
        opened = open_tools.pop(key)
        tools.append((tool_worker(opened), opened, at, stable, False))
        if opened.tool_name in SUBAGENT_TOOLS and opened.harness != 'codex':
            child = opened.agent_type
            if child in ('', '-'):
                child = '@%s:%s' % (opened.tool_use_id, opened.start)
            turns.append(((opened.stream, child), opened._replace(agent_id=child), at, stable))

    def close_turn(key, at):
        opened = open_turns.pop(key)
        turns.append((key, opened, at, True))

    for row in rows:
        owner = worker(row)
        key = (owner, row.tool_use_id)
        if row.kind == 'state':
            if row.event == 'tool':
                open_tools[key] = row
            elif row.event == 'turn':
                open_turns[owner] = row
            elif row.event == 'closed-turn':
                turns.append((owner, row, row.end, True))
            elif row.event == 'tool-coverage':
                tools.append((tool_worker(row), row, row.end, True, True))
            elif row.event == 'continuation':
                last_close[owner] = row
            continue
        if row.harness == 'codex' and row.agent_id not in ('', '-'):
            # Codex spawn calls return before the child finishes. Its explicit
            # lifecycle shares the parent session and carries the child id,
            # as do the child's own tool hooks.
            if row.event == 'SubagentStart':
                if owner in open_turns:
                    close_turn(owner, row.start)
                open_turns[owner] = row
                continue
            if row.event == 'SubagentStop':
                if owner in open_turns:
                    close_turn(owner, row.start)
                continue
        if row.event == 'SessionStart':
            if row.harness == 'codex' and row.session_source == 'compact':
                continue
            for tool_key in list(open_tools):
                if tool_key[0][0] == row.stream:
                    opened = open_tools[tool_key]
                    close_tool(tool_key, min(row.start, opened.start + max_active))
            for turn_key in list(open_turns):
                if turn_key[0] == row.stream:
                    opened = open_turns[turn_key]
                    close_turn(turn_key, min(row.start, opened.start + max_active))
            for turn_key in list(last_close):
                if turn_key[0] == row.stream:
                    del last_close[turn_key]
            continue
        if row.event == TOOL_OPEN:
            associated = owner[1] == '-' or row.harness == 'codex'
            if owner[1] != '-' and row.harness != 'codex':
                # An observed child belongs to the sole eligible active spawn.
                # Multiple candidates are ambiguous: leave them unassociated.
                candidates = [k for k, opened in open_tools.items()
                              if opened.stream == row.stream and opened.tool_name in SUBAGENT_TOOLS
                              and opened.agent_type in ('-', '', owner[1])]
                bound = [k for k in candidates if open_tools[k].agent_type == owner[1]]
                if len(bound or candidates) == 1:
                    associated = True
                    spawn_key = (bound or candidates)[0]
                    open_tools[spawn_key] = open_tools[spawn_key]._replace(agent_type=owner[1])
            open_tools[key] = row._replace(
                agent_type='-', session_source='-' if associated else 'unassociated')
        elif row.event in TOOL_CLOSE:
            if key in open_tools:
                close_tool(key, row.start)
        elif row.event == TURN_OPEN:
            if owner[1] != '-':
                continue  # spawned worker's elapsed bracket owns its lifetime
            if owner in open_turns:
                close_turn(owner, row.start)
            open_turns[owner] = row
        elif row.event in TURN_CLOSE:
            if owner in open_turns:
                close_turn(owner, row.start)
            elif row.event != 'SessionEnd':
                seed = last_close.get(owner)
                if seed is not None and row.start - seed.start <= max_active:
                    turns.append((owner, row._replace(start=seed.start), row.start, True))
            if row.event == 'SessionEnd':
                # Shutdown may follow a completed turn after a long idle gap.
                # It closes work still open, but is not a hook continuation.
                last_close.pop(owner, None)
            else:
                last_close[owner] = row

    pending = [state(row, 'tool') for row in open_tools.values()]
    saved_open_tools = dict(open_tools)
    for key, opened in list(open_tools.items()):
        close_tool(key, opened.start + max_active, stable=False)
    pending.extend(state(row, 'turn') for row in open_turns.values())
    for owner, opened in open_turns.items():
        turns.append((owner, opened, opened.start + max_active, False))

    agent, tool, stable_agent, stable_tool = [], [], [], []
    coverage = {}
    for owner, opened, end, stable, credited in tools:
        span = (opened.start, end)
        coverage.setdefault(owner, []).append(span)
        if not credited:
            entry = (opened.project, opened.subpath, span)
            tool.append(entry)
            if stable:
                stable_tool.append(entry)

    pending_windows = {}
    for owner, opened, end, stable in turns:
        pieces = subtract([(opened.start, end)], union(coverage.get(owner, [])))
        entries = [(opened.project, opened.subpath, span) for span in pieces]
        agent.extend(entries)
        unresolved = any(tool_worker(r) == owner and r.start < end
                         for k, r in saved_open_tools.items())
        if stable and not unresolved:
            stable_agent.extend(entries)
        else:
            # An open turn may later close far beyond its current estimate.
            pending_windows.setdefault(owner, []).append((opened.start, end if stable else 1 << 62))
            if stable:
                pending.append(state(opened, 'closed-turn', end))

    # Retain only coalesced, already-credited tool coverage which can still
    # affect a pending turn (or a future hook continuation from its Stop).
    for owner, seed in last_close.items():
        pending_windows.setdefault(owner, []).append((seed.start, seed.start + max_active))
    from .intervals import clip
    for owner, windows in pending_windows.items():
        spans = []
        sample = None
        for tool_owner, opened, end, stable, _credited in tools:
            if tool_owner == owner and stable:
                sample = opened
                for lo, hi in windows:
                    spans.extend(clip([(opened.start, end)], lo, hi))
        if sample is not None:
            for start, end in union(spans):
                pending.append(state(sample._replace(start=start), 'tool-coverage', end))
    # Adjacent pending turns carry their union, not one row per terminal
    # event. A worker cannot have overlapping main turns; attribution stays
    # in the key so this compression preserves detail rows too.
    closed = {}
    others = []
    for row in pending:
        if row.event == 'closed-turn':
            key = (worker(row), row.project, row.subpath)
            sample, spans = closed.setdefault(key, (row, []))
            spans.append((row.start, row.end))
        else:
            others.append(row)
    for sample, spans in closed.values():
        for start, end in union(spans):
            others.append(sample._replace(start=start, end=end))
    pending = others
    return MachineSpans(agent, tool, dict(open_turns), saved_open_tools,
                        stable_agent, stable_tool, pending, last_close)

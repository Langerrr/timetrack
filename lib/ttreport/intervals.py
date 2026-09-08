"""Interval algebra. No domain knowledge lives here.

Effort unions its spans because one person cannot be in two places.
Machine time sums its spans because agents genuinely run in parallel.
Both operations are here so the domain modules choose between them
explicitly rather than by accident.
"""

import bisect
from typing import Iterable, List, Sequence, Tuple

Span = Tuple[int, int]


def union(spans):
    # type: (Iterable[Span]) -> List[Span]
    ordered = sorted((s for s in spans if s[1] > s[0]))
    merged = []  # type: List[Span]
    for start, end in ordered:
        if merged and start <= merged[-1][1]:
            if end > merged[-1][1]:
                merged[-1] = (merged[-1][0], end)
        else:
            merged.append((start, end))
    return merged


def total(spans):
    # type: (Iterable[Span]) -> int
    return sum(end - start for start, end in spans if end > start)


def subtract(spans, remove):
    # type: (Sequence[Span], Sequence[Span]) -> List[Span]
    """spans and remove are each already sorted and internally disjoint
    (each the output of union()). Removes every second `remove` covers."""
    if not remove:
        return list(spans)
    out = []  # type: List[Span]
    for start, end in spans:
        cursor = start
        for rstart, rend in remove:
            if rend <= cursor:
                continue
            if rstart >= end:
                break
            if rstart > cursor:
                out.append((cursor, rstart))
            cursor = max(cursor, rend)
            if cursor >= end:
                break
        if cursor < end:
            out.append((cursor, end))
    return out


def clip(spans, since, upto):
    # type: (Iterable[Span], int, int) -> List[Span]
    out = []
    for start, end in spans:
        start = max(start, since)
        end = min(end, upto)
        if end > start:
            out.append((start, end))
    return out


def split_days(spans, boundaries):
    # type: (Iterable[Span], Sequence[int]) -> List[Tuple[int, Span]]
    out = []
    ordered = sorted(boundaries)
    if not ordered:
        return []
    for start, end in spans:
        cursor = start
        while cursor < end:
            index = bisect.bisect_right(ordered, cursor) - 1
            if index < 0:
                # Before the first boundary: advance cursor to it.
                cursor = ordered[0]
                if cursor >= end:
                    # Span ends before reaching the first boundary.
                    break
                continue
            day = ordered[index]
            nxt = ordered[index + 1] if index + 1 < len(ordered) else end
            finish = min(end, nxt)
            if finish <= cursor:
                break
            out.append((day, (cursor, finish)))
            cursor = finish
    return out

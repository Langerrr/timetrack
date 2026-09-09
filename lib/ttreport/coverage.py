"""Canonical project effort, independent of source and display grouping."""
import posixpath
from collections import Counter

PRIORITY = ('paired', 'checkin', 'manual')


def normalize(sources):
    """Allocate each second to category priority, then the smallest subpath.

    The sweep emits coalesced disjoint runs, so splitting them at local day
    boundaries gives at most one run per second of that day and project.
    """
    projects = {}
    for category in PRIORITY:
        for project, subpath, (start, end) in sources.get(category, []):
            if end <= start:
                continue
            subpath = posixpath.normpath(subpath) if subpath not in ('', '-') else '.'
            claimant = (PRIORITY.index(category), subpath)
            changes = projects.setdefault(project, {})
            changes.setdefault(start, []).append((claimant, 1))
            changes.setdefault(end, []).append((claimant, -1))
    out = {category: [] for category in PRIORITY}
    for project, changes in projects.items():
        active = Counter()
        previous = None
        runs = []
        for at in sorted(changes):
            if previous is not None and at > previous and active:
                rank, subpath = min(active)
                if runs and runs[-1][:2] == (rank, subpath) and runs[-1][3] == previous:
                    runs[-1] = (rank, subpath, runs[-1][2], at)
                else:
                    runs.append((rank, subpath, previous, at))
            for claimant, delta in changes[at]:
                active[claimant] += delta
                if active[claimant] == 0:
                    del active[claimant]
            previous = at
        for rank, subpath, start, end in runs:
            out[PRIORITY[rank]].append((project, subpath, (start, end)))
    return out


def with_history(effort, rows):
    sources = {name: list(getattr(effort, name)) for name in PRIORITY}
    for row in rows:
        if row.kind == 'coverage' and row.mode in sources:
            sources[row.mode].append((row.project, row.subpath, (row.start, row.end)))
    return normalize(sources)

"""Integration invariants: project effort and replaceable rollover state."""
import unittest
from unittest.mock import patch
from ttreport.events import parse_stream
from ttreport.compact import compact
from ttreport.report import build_report
from test_compact import beat, prompt_row, span_row, options

C = 86400


def cells(rows, byday=False, detail=False):
    with patch('ttreport.report.format_duration', side_effect=str):
        text = build_report(rows, options(byday=byday, detail=detail))
    return tuple(map(int, text.splitlines()[-1].split()[1:]))


def rollover(rows, at=C):
    history, carry = compact(rows, at, options())
    return parse_stream(history + carry)


class AccountingRepairTests(unittest.TestCase):
    def check_views(self, rows, expected):
        for day in (False, True):
            for detail in (False, True):
                self.assertEqual(cells(rows, day, detail), expected, (day, detail))

    def check_rollovers(self, rows, expected):
        self.check_views(rows, expected)
        once = rollover(rows)
        self.check_views(once, expected)
        self.check_views(rollover(once), expected)
        past, future = [r for r in rows if r.start < C], [r for r in rows if r.start >= C]
        carried = rollover(past)
        self.check_views(carried + future, expected)
        self.check_views(rollover(carried + future, 2*C), expected)

    def test_r1_subpaths_share_project_union(self):
        rows = [prompt_row(t, session=s)._replace(subpath=p)
                for s, p in [('a', 'one'), ('b', 'two')] for t in (100, 3700)]
        self.check_rollovers(rows, (3600, 0, 0, 3600, 14400, 0))

    def test_r1_historical_manual_additions_union(self):
        rows = rollover([span_row(1000, 4600)]) + rollover([span_row(1000, 4600)])
        self.check_views(rows, (0, 0, 3600, 3600, 0, 0))
        self.check_views(rollover(rows), (0, 0, 3600, 3600, 0, 0))

    def test_r2_incremental_heartbeat(self):
        self.check_rollovers([prompt_row(C-100), prompt_row(C+100)],
                             (200, 0, 0, 200, 3800, 0))

    def test_r2_stale_heartbeat_and_matched_turn(self):
        self.check_rollovers([prompt_row(C-7200), prompt_row(C+600)],
                             (1800, 0, 0, 1800, 11400, 0))
        self.check_rollovers([prompt_row(C-7200), beat(C+600, 'Stop')],
                             (0, 0, 0, 0, 7800, 0))

    def test_r2_long_tool_survives_multiple_rollovers(self):
        early = [prompt_row(C-7300), beat(C-7200, 'PreToolUse', tool_id='x', tool_name='Bash')]
        late = [beat(2*C+600, 'PostToolUse', tool_id='x', tool_name='Bash'), beat(2*C+700, 'Stop')]
        expected = (0, 0, 0, 0, 200, C+7800)
        self.check_views(early+late, expected)
        carried = rollover(rollover(early), 2*C)
        self.assertTrue(all(r.kind == 'state' for r in carried))
        self.check_views(carried+late, expected)
        self.check_views(rollover(carried+late, 3*C), expected)

    def test_r3_day_sums_projects(self):
        rows = [prompt_row(t, project=p, session=p) for p in ('alpha', 'beta') for t in (100, 3700)]
        self.check_rollovers(rows, (7200, 0, 0, 7200, 14400, 0))

    def test_r4_different_machine_frontiers(self):
        m1 = rollover([prompt_row(C-100), beat(C+100, 'Stop')])
        m2 = [prompt_row(t, project='other')._replace(machine='m2') for t in (1000, 1600)]
        self.check_views(m1+m2, (600, 0, 0, 600, 4400, 0))

    def test_r5_stop_continuation(self):
        self.check_rollovers([prompt_row(C-200), beat(C-100, 'Stop'), beat(C+100, 'Stop')],
                             (0, 0, 0, 0, 300, 0))

    def test_r6_reset_versus_codex_compaction(self):
        for harness, source, expected in [('claude', 'startup', (0,0,0,0,10,90)),
                                          ('codex', 'compact', (0,0,0,0,110,190))]:
            rows = [prompt_row(C-200), beat(C-190, 'PreToolUse', tool_id='x', tool_name='Bash'),
                    beat(C-100, 'SessionStart')._replace(session_source=source),
                    beat(C, 'PostToolUse', tool_id='x', tool_name='Bash'), beat(C+100, 'Stop')]
            rows = [r._replace(harness=harness) for r in rows]
            self.check_rollovers(rows, expected)
            self.check_views(rollover(rows[:2])+rows[2:], expected)

    def test_r7_child_subtracts_own_tools(self):
        rows = [prompt_row(C-100), beat(C-90, 'PreToolUse', tool_id='spawn', tool_name='Task'),
                beat(C-80, 'PreToolUse', tool_id='bash', tool_name='Bash')._replace(agent_id='child'),
                beat(C-20, 'PostToolUse', tool_id='bash', tool_name='Bash')._replace(agent_id='child'),
                beat(C+10, 'PostToolUse', tool_id='spawn', tool_name='Task'), beat(C+20, 'Stop')]
        self.check_rollovers(rows, (0, 0, 0, 0, 60, 160))

    def test_r1_coverage_is_canonical_and_bounded(self):
        rows = [span_row(1000, 4600)._replace(subpath=p) for p in ('z', 'a') for _ in range(100)]
        history, _ = compact(rows, C, options())
        coverage = [r for r in parse_stream(history) if r.kind == 'coverage']
        self.assertEqual([(r.start, r.end, r.subpath) for r in coverage], [(1000, 4600, 'a')])

    def test_r2_closed_tools_survive_while_turn_is_unresolved(self):
        early = [prompt_row(C-300)]
        for t in range(C-250, C-150, 10):
            early += [beat(t, 'PreToolUse', tool_id=str(t), tool_name='Bash'),
                      beat(t+10, 'PostToolUse', tool_id=str(t), tool_name='Bash')]
        late = [beat(2*C+100, 'Stop')]
        pending = rollover(rollover(early), 2*C)
        self.assertEqual(len([r for r in pending if r.event == 'tool-coverage']), 1)
        self.check_views(pending+late, (0,0,0,0,C+300,100))
        self.check_views(rollover(pending+late, 3*C), (0,0,0,0,C+300,100))

    def test_r2_solo_episode_keeps_its_initial_attribution(self):
        from test_compact import mode_row
        rows = [mode_row(C-500, 'solo')._replace(subpath='z'),
                prompt_row(C-100)._replace(subpath='a'), prompt_row(C+100)._replace(subpath='b')]
        raw = build_report(rows, options(detail=True, byday=False))
        self.assertEqual(build_report(rollover(rows[:2])+rows[2:], options(detail=True, byday=False)), raw)

    def test_r7_ambiguous_children_are_not_assigned_arbitrarily(self):
        rows = [prompt_row(C-100),
                beat(C-90, 'PreToolUse', tool_id='a', tool_name='Task'),
                beat(C-90, 'PreToolUse', tool_id='b', tool_name='Task'),
                beat(C-80, 'PreToolUse', tool_id='bash', tool_name='Bash')._replace(agent_id='child'),
                beat(C-20, 'PostToolUse', tool_id='bash', tool_name='Bash')._replace(agent_id='child'),
                beat(C+10, 'PostToolUse', tool_id='a', tool_name='Task'),
                beat(C+10, 'PostToolUse', tool_id='b', tool_name='Task'), beat(C+20, 'Stop')]
        self.check_rollovers(rows, (0,0,0,0,220,260))

    def test_r2_pending_closed_turns_have_bounded_coverage(self):
        rows = [prompt_row(C-1000), beat(C-999, 'PreToolUse', tool_id='long', tool_name='Bash')]
        rows += [beat(t, 'Stop') for t in range(C-998, C-100)]
        pending = rollover(rows)
        self.assertLessEqual(len([r for r in pending if r.event == 'closed-turn']), 1)
        closed = [beat(C+10, 'PostToolUse', tool_id='long', tool_name='Bash')]
        self.check_views(pending+closed, (0,0,0,0,1,1009))

    def test_r7_later_binding_does_not_claim_earlier_ambiguous_tools(self):
        early = [prompt_row(C-100),
                 beat(C-90, 'PreToolUse', tool_id='a', tool_name='Task'),
                 beat(C-90, 'PreToolUse', tool_id='b', tool_name='Task'),
                 beat(C-80, 'PreToolUse', tool_id='x', tool_name='Bash')._replace(agent_id='child')]
        late = [beat(C+10, 'PostToolUse', tool_id='a', tool_name='Task'),
                beat(C+20, 'PreToolUse', tool_id='y', tool_name='Bash')._replace(agent_id='child'),
                beat(C+30, 'PostToolUse', tool_id='y', tool_name='Bash')._replace(agent_id='child'),
                beat(C+40, 'PostToolUse', tool_id='x', tool_name='Bash')._replace(agent_id='child'),
                beat(C+50, 'PostToolUse', tool_id='b', tool_name='Task'), beat(C+60, 'Stop')]
        # Parent 20 + first child 100 + second child (140 - its observed 10).
        self.check_rollovers(early+late, (0,0,0,0,250,370))

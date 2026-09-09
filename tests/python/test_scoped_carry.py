"""Overlapping terminal scopes must survive a later session's first heartbeat."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from ttreport.report import build_report
from test_compact import mode_row, prompt_row, options
from test_accounting_repairs import C, cells, rollover


def cases():
    for reverse in (False, True):
        first, second = ('api', 'api/nested') if reverse else ('api/nested', 'api')
        yield 'effort-' + str(reverse), [
            mode_row(C-4900, 'paired', session='-')._replace(subpath=first),
            mode_row(C-4400, 'solo', session='-')._replace(subpath=second),
            mode_row(C-900, 'solo', session='-')._replace(subpath=second),
            prompt_row(C)._replace(subpath='api/nested')]
        first, second = ('api/nested', 'api') if reverse else ('api', 'api/nested')
        yield 'category-' + str(reverse), [
            mode_row(C-2100, 'paired', session='-')._replace(subpath=first),
            mode_row(C-800, 'solo', session='-')._replace(subpath=second),
            mode_row(C-500, 'paired', session='-')._replace(subpath=second),
            prompt_row(C+100)._replace(subpath='api/nested')]


def exact_report(rows, byday, detail):
    with patch('ttreport.report.format_duration', side_effect=str):
        return build_report(rows, options(byday=byday, detail=detail))


class ScopedCarryTests(unittest.TestCase):
    def test_overlapping_scope_boundaries_preserve_every_report_column(self):
        for label, rows in cases():
            if label == 'effort-False':
                self.assertEqual(cells(rows), (500, 2800, 0, 3300, 3600, 0))
            if label == 'category-False':
                self.assertEqual(cells(rows), (1900, 300, 0, 2200, 3600, 0))
            for byday in (False, True):
                for detail in (False, True):
                    with self.subTest(case=label, byday=byday, detail=detail):
                        expected = exact_report(rows, byday, detail)
                        early, late = rows[:-1], rows[-1:]
                        for carried in (rollover(early), rollover(rollover(early)),
                                        rollover(rollover(early), 2*C)):
                            # Only the original terminal transitions survive;
                            # rollover must not multiply them or retain beats.
                            self.assertEqual([r for r in carried if r.kind == 'mode'], early)
                            self.assertFalse(any(r.kind == 'beat' for r in carried))
                            actual = carried + late
                            self.assertEqual(exact_report(actual, byday, detail), expected)
                            self.assertEqual(exact_report(rollover(actual, 3*C), byday, detail), expected)

    def test_carried_session_does_not_replay_older_terminal_heartbeats(self):
        early = [mode_row(C-1000, 'paired', session='-'),
                 prompt_row(C-900), mode_row(C-800, 'solo'),
                 prompt_row(C-700), mode_row(C-500, 'paired'), prompt_row(C-100)]
        late = [prompt_row(C+100)]
        for byday in (False, True):
            for detail in (False, True):
                with self.subTest(byday=byday, detail=detail):
                    expected = exact_report(early + late, byday, detail)
                    carried = rollover(early)
                    self.assertEqual(exact_report(carried + late, byday, detail), expected)
                    self.assertEqual(exact_report(rollover(carried, 2*C) + late,
                                                  byday, detail), expected)

    def test_actual_cli_rollover_before_first_session_preserves_all_views(self):
        repo = Path(__file__).resolve().parents[2]
        for label, rows in cases():
            for byday in (False, True):
                for detail in (False, True):
                    with self.subTest(case=label, byday=byday, detail=detail):
                        with tempfile.TemporaryDirectory() as directory:
                            root = Path(directory)
                            def run(home, at):
                                env = dict(os.environ, TT_HOME=str(home), TT_LIB=str(repo/'lib'),
                                           TT_NOW=str(at), TZ='UTC', TT_PRESENCE_GAP='3600',
                                           TT_CHECKIN_WINDOW='1200', TT_MAX_ACTIVE_GAP='3600')
                                args = ['sh', str(repo/'bin/tt'), 'report', '--since', '1970-01-01',
                                        '--until', '1970-01-04']
                                if byday:
                                    args += ['--by', 'day']
                                if detail:
                                    args += ['--detail']
                                return subprocess.run(args, env=env, text=True, capture_output=True,
                                                      check=True).stdout
                            def home(name, initial):
                                target = root/name
                                target.mkdir()
                                (target/'config').write_text('machine=m1\n')
                                (target/'current-m1.tsv').write_text(''.join(
                                    '\t'.join(map(str, row))+'\n' for row in initial))
                                return target
                            raw = home('raw', rows)
                            expected = run(raw, C-100)  # Read all rows before rollover is due.
                            incremental = home('incremental', rows[:-1])
                            run(incremental, C+50)
                            self.assertIn('\tcompact\t', (incremental/'events-m1.tsv').read_text())
                            with (incremental/'current-m1.tsv').open('a') as output:
                                output.write('\t'.join(map(str, rows[-1]))+'\n')
                            self.assertEqual(run(incremental, C+200), expected)
                            self.assertEqual(run(incremental, 2*C+200), expected)
                            self.assertEqual(run(incremental, 2*C+200), expected)

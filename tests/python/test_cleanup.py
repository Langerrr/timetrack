"""Path-scoped human presence survives rollover without changing workers."""
import unittest
from ttreport.effort import effort_spans
from ttreport.intervals import total, union
from ttreport.modes import ModeTimeline
from test_compact import mode_row, prompt_row, options
from test_accounting_repairs import cells, rollover, C


def paired(rows):
    result = effort_spans(rows, ModeTimeline.from_rows(rows), 3600, 1200)
    return total(union([span for _, _, span in result.paired]))


class ScopedPresenceTests(unittest.TestCase):
    def test_terminal_return_credits_only_time_after_return(self):
        rows = [mode_row(0, 'solo', session='-'), prompt_row(1000),
                mode_row(1100, 'paired', session='-'), prompt_row(2000)]
        self.assertEqual(paired(rows), 900)
        self.assertEqual(cells(rows)[:4], (900, 1100, 0, 2000))

    def test_multiple_nested_sessions_and_scope_exclusions(self):
        rows = [mode_row(0, 'solo', session='-')._replace(subpath='api'),
                mode_row(1100, 'paired', session='-')._replace(subpath='api')]
        for session, path, machine, project in [
                ('a', 'api', 'm1', 'sportx'),
                ('b', 'api/nested', 'm1', 'sportx'),
                ('c', 'api-old', 'm1', 'sportx'),
                ('d', 'api', 'm2', 'sportx'),
                ('e', 'api', 'm1', 'other')]:
            rows += [prompt_row(t, project=project, session=session)._replace(
                subpath=path, machine=machine) for t in (1000, 2000)]
        result = effort_spans(rows, ModeTimeline.from_rows(rows), 3600, 1200)
        self.assertIn(('sportx', 'api/nested', (1100, 2000)), result.paired)
        self.assertNotIn(('sportx', 'api/nested', (1000, 1100)), result.paired)
        for key in [('sportx', 'api-old'), ('other', 'api')]:
            self.assertIn((*key, (1000, 2000)), result.paired)
        self.assertEqual(cells(rows)[4:], cells([r for r in rows if r.kind != 'mode'])[4:])

    def test_incremental_return_after_earlier_solo_transition(self):
        rows = [prompt_row(C-2000), mode_row(C-1900, 'solo', session='-'),
                prompt_row(C-500), mode_row(C-100, 'paired', session='-'),
                prompt_row(C+800)]
        self.assertEqual(paired(rows), 1000)
        expected = cells(rows)
        for byday in (False, True):
            for detail in (False, True):
                from ttreport.report import build_report
                raw = build_report(rows, options(byday=byday, detail=detail))
                carried = rollover(rows[:-1]) + rows[-1:]
                self.assertEqual(build_report(carried, options(byday=byday, detail=detail)), raw)
                self.assertEqual(cells(rollover(carried, 2*C)), expected)
        self.assertEqual(cells(rollover(rollover(rows))), expected)

    def test_nested_sessions_share_return_through_incremental_rollover(self):
        rows = [mode_row(C-2000, 'solo', session='-')._replace(subpath='api')]
        rows += [prompt_row(C-500, session=s)._replace(subpath=p)
                 for s, p in [('a', 'api'), ('b', 'api/nested')]]
        rows += [mode_row(C-100, 'paired', session='-')._replace(subpath='api')]
        future = [prompt_row(C+800, session=s)._replace(subpath=p)
                  for s, p in [('a', 'api'), ('b', 'api/nested')]]
        from ttreport.report import build_report
        for byday in (False, True):
            for detail in (False, True):
                opts = options(byday=byday, detail=detail)
                expected = build_report(rows + future, opts)
                carried = rollover(rows) + future
                self.assertEqual(build_report(carried, opts), expected)
                self.assertEqual(build_report(rollover(carried, 2*C), opts), expected)
        self.assertEqual(cells(rows + future)[0], 900)

    def test_terminal_heartbeat_reaches_a_session_first_seen_after_rollover(self):
        rows = [mode_row(C-100, 'solo', session='-')]
        future = [prompt_row(C+100)._replace(subpath='nested')]
        from ttreport.report import build_report
        for detail in (False, True):
            opts = options(detail=detail)
            expected = build_report(rows + future, opts)
            self.assertEqual(build_report(rollover(rows) + future, opts), expected)
            self.assertEqual(build_report(rollover(rollover(rows) + future, 2*C), opts), expected)


class ModeDiagnosticTests(unittest.TestCase):
    def test_stale_lock_reports_recovery_and_invalid_path_is_distinct(self):
        import os
        from pathlib import Path
        import subprocess
        import tempfile
        repo = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / 'modes.lock').mkdir()
            commands = home / 'commands'
            commands.mkdir()
            sleep = commands / 'sleep'
            sleep.write_text('#!/bin/sh\nexit 0\n')
            sleep.chmod(0o755)
            env = dict(os.environ, TT_HOME=directory,
                       PATH=str(commands) + os.pathsep + os.environ['PATH'])
            def invoke(path):
                return subprocess.run(['sh', str(repo / 'bin/tt'), 'solo', path,
                                       '--all-sessions'], env=env, text=True,
                                      capture_output=True, timeout=10)
            locked = invoke(directory)
            self.assertEqual(locked.returncode, 1)
            self.assertIn(str(home / 'modes.lock'), locked.stderr)
            self.assertIn('if no other tt is running, remove it', locked.stderr)
            invalid = invoke(directory + '/bad\tpath')
            self.assertEqual(invalid.returncode, 1)
            self.assertIn('tab', invalid.stderr)
            self.assertNotIn('remove it', invalid.stderr)
            (home / 'modes.lock').rmdir()
            # A failed cache writer must remain distinct from lock timeout.
            awk = commands / 'awk'
            awk.write_text('#!/bin/sh\nexit 1\n')
            awk.chmod(0o755)
            unwritable = invoke(directory)
            self.assertEqual(unwritable.returncode, 1)
            self.assertIn('cannot write ' + str(home / 'modes'), unwritable.stderr)
            self.assertNotIn('remove it', unwritable.stderr)

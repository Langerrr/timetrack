"""Codex lifecycle semantics and its actual manifest command path."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_machine import beat, spans_of
from ttreport.events import parse_stream
from ttreport.machine import machine_spans
from ttreport.intervals import total
from test_accounting_repairs import rollover, cells, C

REPO = Path(__file__).resolve().parents[2]


def codex(at, event):
    return beat(at, event)._replace(harness='codex', mode='-')


class TestCodexLifecycle(unittest.TestCase):
    def test_asynchronous_child_uses_lifecycle_and_subtracts_its_own_tools(self):
        rows = [codex(C-100, 'UserPromptSubmit'),
                codex(C-90, 'PreToolUse')._replace(tool_use_id='spawn', tool_name='collaborationspawn_agent'),
                codex(C-89, 'PostToolUse')._replace(tool_use_id='spawn', tool_name='collaborationspawn_agent'),
                codex(C-80, 'SubagentStart')._replace(agent_id='child'),
                codex(C-50, 'PreToolUse')._replace(agent_id='child', tool_use_id='tool', tool_name='Bash'),
                codex(C+20, 'PostToolUse')._replace(agent_id='child', tool_use_id='tool', tool_name='Bash'),
                codex(C+50, 'SubagentStop')._replace(agent_id='child'),
                codex(C+100, 'Stop'), codex(C+200, 'SessionEnd')]
        # Parent 200-1; child 130-70; tool brackets 1+70.
        expected = (0, 0, 0, 0, 259, 71)
        carried = rollover(rows[:5]) + rows[5:]
        for observed in (rows, carried, rollover(carried, 2*C),
                         rollover(rollover(rows))):
            for byday in (False, True):
                for detail in (False, True):
                    self.assertEqual(cells(observed, byday, detail), expected)

    def test_codex_spawn_bracket_does_not_add_a_second_child_worker(self):
        rows = [codex(1000, 'PreToolUse')._replace(tool_use_id='spawn', tool_name='Agent'),
                codex(1010, 'SubagentStart')._replace(agent_id='child'),
                codex(1020, 'PostToolUse')._replace(tool_use_id='spawn', tool_name='Agent'),
                codex(1100, 'SubagentStop')._replace(agent_id='child')]
        measured = machine_spans(rows, 3600)
        self.assertEqual(total(spans_of(measured.agent)), 90)
        self.assertEqual(total(spans_of(measured.tool)), 20)

    def test_session_end_does_not_bill_idle_time_after_stop(self):
        rows = [codex(C-100, 'UserPromptSubmit'), codex(C-50, 'Stop'),
                codex(C+100, 'SessionEnd')]
        for observed in (rows, rollover(rows[:2]) + rows[2:]):
            # Completed agent seconds may live in total rows after rollover.
            stable = sum(int(r.words) for r in observed
                         if r.kind == 'total' and r.mode == 'agent')
            measured = machine_spans(observed, 3600)
            self.assertEqual(stable + total(spans_of(measured.agent)), 50)
            self.assertEqual(total(spans_of(measured.tool)), 0)

    def test_session_end_closes_an_open_turn_without_seeding_a_continuation(self):
        rows = [codex(0, 'UserPromptSubmit'), codex(50, 'SessionEnd'),
                codex(200, 'Stop')]
        self.assertEqual(total(spans_of(machine_spans(rows, 3600).agent)), 50)

    def test_session_end_after_interrupt_does_not_extend_agent_time(self):
        rows = [codex(0, 'UserPromptSubmit'), codex(50, 'Interrupt'),
                codex(200, 'SessionEnd')]
        self.assertEqual(total(spans_of(machine_spans(rows, 3600).agent)), 50)

    def test_stop_hook_continuation_is_still_counted(self):
        rows = [codex(0, 'UserPromptSubmit'), codex(50, 'Stop'),
                codex(100, 'Stop'), codex(200, 'SessionEnd')]
        self.assertEqual(total(spans_of(machine_spans(rows, 3600).agent)), 100)


class TestCodexManifest(unittest.TestCase):
    def test_all_nine_event_commands_capture_codex_fields_quietly(self):
        manifest = json.loads((REPO / '.codex-plugin/plugin.json').read_text())
        hooks = json.loads((REPO / manifest['hooks']).read_text())['hooks']
        self.assertEqual(set(hooks), {'SessionStart', 'UserPromptSubmit',
            'PreToolUse', 'PostToolUse', 'Stop', 'Interrupt', 'SessionEnd',
            'SubagentStart', 'SubagentStop'})
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            cwd = root / 'workspace' / 'project'
            cwd.mkdir(parents=True)
            env = os.environ.copy()
            for key in list(env):
                if key.startswith(('TT_', 'PLUGIN_', 'CLAUDE_')):
                    env.pop(key, None)
            env.update(TT_HOME=str(root/'time'), TT_ROOT=str(root/'workspace'),
                       TT_NOW='1788883200', PLUGIN_ROOT=str(REPO),
                       CLAUDE_PLUGIN_ROOT=str(REPO), TZ='UTC')
            for event, groups in hooks.items():
                payload = dict(cwd=str(cwd), session_id='parent-session',
                               hook_event_name=event, turn_id='turn-1')
                if event == 'SessionStart': payload['source'] = 'compact'
                if event == 'UserPromptSubmit': payload['prompt'] = 'human question'
                if event in ('PreToolUse', 'PostToolUse'):
                    payload.update(tool_use_id='tool-1', tool_name='Bash',
                                   tool_input={'command':'true','cwd':'/wrong/nested/path'})
                if event in ('SubagentStart', 'SubagentStop'):
                    payload.update(agent_id='child-1', agent_type='worker')
                result = subprocess.run(groups[0]['hooks'][0]['command'],
                    shell=True, input=json.dumps(payload), text=True, env=env,
                    capture_output=True, check=True, cwd=cwd)
                self.assertEqual((result.stdout, result.stderr), ('', ''))
            rows = list(parse_stream(next((root/'time').glob('current-*.tsv')).read_text().splitlines()))
            self.assertEqual(len(rows), 9)
            for row in rows:
                self.assertEqual((row.harness, row.mode, row.project, row.subpath,
                                  row.session), ('codex','-','project','.','parent-session'))
                self.assertEqual(len(row), 20)
                if row.event in ('SubagentStart','SubagentStop'):
                    self.assertEqual((row.agent_id,row.agent_type),('child-1','worker'))
                if row.event in ('PreToolUse','PostToolUse'):
                    self.assertEqual((row.tool_use_id,row.tool_name,row.prompt_class,
                                      row.fingerprint), ('tool-1','Bash','-','-'))

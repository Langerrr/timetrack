# tests/python/test_machine.py
import unittest
from ttreport.events import parse_line
from ttreport.intervals import total
from ttreport.machine import machine_spans


def beat(at, event, session="s1", tool_id="-", tool_name="-", project="sportx"):
    return parse_line("\t".join([
        "i", "beat", str(at), str(at), "m1", "claude", "paired", project, ".",
        session, event, "t1", tool_id, "-", "-", "-", "-", tool_name, "-", "-",
    ]))


def spans_of(entries):
    return [span for _p, _s, span in entries]


class TestMachineSpans(unittest.TestCase):
    def test_turn_with_no_tools_is_all_agent_time(self):
        m = machine_spans([
            beat(0, "UserPromptSubmit"),
            beat(100, "Stop"),
        ], max_active=3600)
        self.assertEqual(total(spans_of(m.agent)), 100)
        self.assertEqual(total(spans_of(m.tool)), 0)

    def test_tool_time_is_subtracted_from_agent_time(self):
        m = machine_spans([
            beat(0, "UserPromptSubmit"),
            beat(10, "PreToolUse", tool_id="a", tool_name="Bash"),
            beat(30, "PostToolUse", tool_id="a", tool_name="Bash"),
            beat(100, "Stop"),
        ], max_active=3600)
        self.assertEqual(total(spans_of(m.tool)), 20)
        self.assertEqual(total(spans_of(m.agent)), 80)

    def test_overlapping_tools_sum_but_subtract_only_their_union(self):
        m = machine_spans([
            beat(0, "UserPromptSubmit"),
            beat(10, "PreToolUse", tool_id="a", tool_name="Bash"),
            beat(10, "PreToolUse", tool_id="b", tool_name="Bash"),
            beat(30, "PostToolUse", tool_id="a", tool_name="Bash"),
            beat(30, "PostToolUse", tool_id="b", tool_name="Bash"),
            beat(100, "Stop"),
        ], max_active=3600)
        self.assertEqual(total(spans_of(m.tool)), 40)
        self.assertEqual(total(spans_of(m.agent)), 80)

    def test_a_subagent_tool_also_counts_as_agent_time(self):
        # The parent subtracts the bracket; the subagent worker adds it back.
        m = machine_spans([
            beat(0, "UserPromptSubmit"),
            beat(10, "PreToolUse", tool_id="a", tool_name="Task"),
            beat(70, "PostToolUse", tool_id="a", tool_name="Task"),
            beat(100, "Stop"),
        ], max_active=3600)
        self.assertEqual(total(spans_of(m.tool)), 60)
        self.assertEqual(total(spans_of(m.agent)), 100)

    def test_parallel_subagents_each_count(self):
        rows = [beat(0, "UserPromptSubmit")]
        for name in ("a", "b", "c", "d", "e"):
            rows.append(beat(10, "PreToolUse", tool_id=name, tool_name="Task"))
            rows.append(beat(610, "PostToolUse", tool_id=name, tool_name="Task"))
        rows.append(beat(700, "Stop"))
        m = machine_spans(rows, max_active=3600)
        # Five workers of 600s each, plus the parent's own 100s outside them.
        self.assertEqual(total(spans_of(m.agent)), 5 * 600 + 100)

    def test_a_long_command_keeps_its_full_duration(self):
        m = machine_spans([
            beat(0, "UserPromptSubmit"),
            beat(10, "PreToolUse", tool_id="a", tool_name="Bash"),
            beat(1210, "PostToolUse", tool_id="a", tool_name="Bash"),
            beat(1220, "Stop"),
        ], max_active=3600)
        self.assertEqual(total(spans_of(m.tool)), 1200)

    def test_hook_driven_turn_opens_at_the_previous_terminal_event(self):
        m = machine_spans([
            beat(0, "UserPromptSubmit"),
            beat(100, "Stop"),
            beat(160, "Stop"),
        ], max_active=3600)
        self.assertEqual(total(spans_of(m.agent)), 160)

    def test_unclosed_bracket_is_capped(self):
        m = machine_spans([
            beat(0, "UserPromptSubmit"),
            beat(10, "PreToolUse", tool_id="a", tool_name="Bash"),
        ], max_active=60)
        self.assertEqual(total(spans_of(m.tool)), 60)

    def test_separate_sessions_do_not_close_each_other(self):
        m = machine_spans([
            beat(0, "UserPromptSubmit", session="s1"),
            beat(10, "UserPromptSubmit", session="s2"),
            beat(50, "Stop", session="s2"),
            beat(100, "Stop", session="s1"),
        ], max_active=3600)
        self.assertEqual(total(spans_of(m.agent)), 140)


if __name__ == "__main__":
    unittest.main()

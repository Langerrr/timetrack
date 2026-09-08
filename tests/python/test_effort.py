import unittest
from ttreport.events import parse_line
from ttreport.intervals import total, union
from ttreport.modes import ModeTimeline
from ttreport.effort import effort_spans

GAP = 3600
WINDOW = 1200


def prompt(at, session="s1", project="sportx", cls="human", agent="-"):
    return parse_line("\t".join([
        "i", "beat", str(at), str(at), "m1", "claude", "paired", project, ".",
        session, "UserPromptSubmit", "t1", "-", agent, "-", "-", "-", "-",
        cls, "fp",
    ]))


def mode_row(at, mode, session="s1", project="sportx"):
    return parse_line("\t".join([
        "i", "mode", str(at), str(at), "m1", "-", mode, project, ".",
        session, "-",
    ]))


def span_row(start, end, project="sportx"):
    return parse_line("\t".join([
        "i", "span", str(start), str(end), "m1", "-", "manual", project, ".",
        "-", "a note",
    ]))


def spans_of(entries):
    return [s for _p, _sub, s in entries]


def run(rows):
    return effort_spans(rows, ModeTimeline.from_rows(rows), GAP, WINDOW)


class TestPairedEffort(unittest.TestCase):
    def test_gap_within_the_threshold_is_credited_whole(self):
        e = run([prompt(0), prompt(900)])
        self.assertEqual(total(spans_of(e.paired)), 900)

    def test_sparse_design_session_still_counts_in_full(self):
        # 55 minutes between prompts, under the 60-minute threshold.
        e = run([prompt(0), prompt(3300)])
        self.assertEqual(total(spans_of(e.paired)), 3300)

    def test_gap_over_the_threshold_credits_half_of_it(self):
        e = run([prompt(0), prompt(4200)])
        self.assertEqual(total(spans_of(e.paired)), GAP // 2)

    def test_a_three_hour_gap_credits_the_same_half(self):
        e = run([prompt(0), prompt(10800)])
        self.assertEqual(total(spans_of(e.paired)), GAP // 2)

    def test_half_credit_sits_immediately_before_the_later_heartbeat(self):
        e = run([prompt(0), prompt(10800)])
        self.assertEqual(spans_of(e.paired), [(10800 - GAP // 2, 10800)])

    def test_a_lone_heartbeat_credits_nothing(self):
        self.assertEqual(run([prompt(0)]).paired, [])

    def test_machine_prompts_are_not_heartbeats(self):
        e = run([prompt(0), prompt(600, cls="machine"), prompt(1200)])
        # The middle row is ignored, so one 1200s interval is credited.
        self.assertEqual(spans_of(e.paired), [(0, 1200)])

    def test_a_subagent_prompt_is_not_a_heartbeat(self):
        e = run([prompt(0), prompt(600, agent="ag1"), prompt(1200)])
        self.assertEqual(spans_of(e.paired), [(0, 1200)])

    def test_parallel_sessions_on_one_project_union_to_one_hour(self):
        rows = [prompt(0, "s1"), prompt(3600, "s1"),
                prompt(0, "s2"), prompt(3600, "s2")]
        e = run(rows)
        self.assertEqual(total(union(spans_of(e.paired))), 3600)

    def test_two_projects_at_once_are_double_booked(self):
        rows = [prompt(0, "s1", "sportx"), prompt(3600, "s1", "sportx"),
                prompt(0, "s2", "tuurny"), prompt(3600, "s2", "tuurny")]
        e = run(rows)
        by_project = {}
        for project, _sub, span in e.paired:
            by_project.setdefault(project, []).append(span)
        self.assertEqual(total(union(by_project["sportx"])), 3600)
        self.assertEqual(total(union(by_project["tuurny"])), 3600)


class TestSoloEffort(unittest.TestCase):
    # `tt solo` is itself a moment of presence, so the mode row is a heartbeat
    # and opens an episode of its own. Every expectation below therefore
    # carries one window for the mode row plus whatever the prompts add.

    def test_a_single_checkin_credits_one_window(self):
        e = run([mode_row(0, "solo"), prompt(5000)])
        self.assertEqual(total(union(spans_of(e.checkin))), 2 * WINDOW)

    def test_two_prompts_ten_minutes_apart_credit_their_span_plus_a_window(self):
        e = run([mode_row(0, "solo"), prompt(5000), prompt(5600)])
        self.assertEqual(total(union(spans_of(e.checkin))), 600 + 2 * WINDOW)

    def test_prompts_far_apart_form_separate_episodes(self):
        e = run([mode_row(0, "solo"), prompt(5000), prompt(50000)])
        self.assertEqual(total(union(spans_of(e.checkin))), 3 * WINDOW)

    def test_an_eight_hour_run_credits_the_checkin_not_the_run(self):
        e = run([mode_row(0, "solo"), prompt(28800)])
        # Two heartbeats, two episodes, two windows -- not eight hours.
        self.assertEqual(total(union(spans_of(e.checkin))), 2 * WINDOW)


class TestManualEffort(unittest.TestCase):
    def test_a_span_is_credited_as_stated(self):
        e = run([span_row(0, 5400)])
        self.assertEqual(total(spans_of(e.manual)), 5400)


if __name__ == "__main__":
    unittest.main()

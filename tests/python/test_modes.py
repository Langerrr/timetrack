import unittest
from ttreport.events import parse_line
from ttreport.modes import ModeTimeline


def mode_row(at, mode, project, subpath, session):
    return parse_line("\t".join([
        "i", "mode", str(at), str(at), "m1", "-", mode, project, subpath,
        session, "-",
    ]))


def beat(at, project, subpath, session):
    return parse_line("\t".join([
        "i", "beat", str(at), str(at), "m1", "claude", "paired", project,
        subpath, session, "UserPromptSubmit",
    ]))


class TestModeTimeline(unittest.TestCase):
    def setUp(self):
        self.row = beat(0, "sportx", ".", "s1")

    def at(self, timeline, when, row=None):
        row = row or self.row
        return timeline.at(row.stream, when, row.project, row.subpath)

    def test_default_is_paired(self):
        t = ModeTimeline.from_rows([])
        self.assertEqual(self.at(t, 100), "paired")

    def test_transition_applies_forward_only(self):
        t = ModeTimeline.from_rows([mode_row(100, "solo", "sportx", ".", "s1")])
        self.assertEqual(self.at(t, 99), "paired")
        self.assertEqual(self.at(t, 100), "solo")
        self.assertEqual(self.at(t, 5000), "solo")

    def test_later_transition_wins(self):
        t = ModeTimeline.from_rows([
            mode_row(100, "solo", "sportx", ".", "s1"),
            mode_row(200, "paired", "sportx", ".", "s1"),
        ])
        self.assertEqual(self.at(t, 150), "solo")
        self.assertEqual(self.at(t, 250), "paired")

    def test_session_scoped_transition_does_not_reach_another_session(self):
        other = beat(0, "sportx", ".", "s2")
        t = ModeTimeline.from_rows([mode_row(100, "solo", "sportx", ".", "s1")])
        self.assertEqual(self.at(t, 150, other), "paired")

    def test_pathwide_transition_reaches_every_session_below_it(self):
        nested = beat(0, "sportx", "saas-backend", "s2")
        t = ModeTimeline.from_rows([mode_row(100, "solo", "sportx", ".", "-")])
        self.assertEqual(self.at(t, 150, nested), "solo")

    def test_pathwide_transition_does_not_reach_a_sibling_project(self):
        sibling = beat(0, "tuurny", ".", "s3")
        t = ModeTimeline.from_rows([mode_row(100, "solo", "sportx", ".", "-")])
        self.assertEqual(self.at(t, 150, sibling), "paired")

    def test_a_scoped_transition_does_not_leak_into_a_prefix_sibling(self):
        sibling = beat(0, "sportx", "saas-backend-old", "s4")
        t = ModeTimeline.from_rows([
            mode_row(100, "solo", "sportx", "saas-backend", "-")])
        self.assertEqual(self.at(t, 150, sibling), "paired")

    def test_a_scoped_transition_reaches_its_own_subtree(self):
        nested = beat(0, "sportx", "saas-backend/api", "s5")
        t = ModeTimeline.from_rows([
            mode_row(100, "solo", "sportx", "saas-backend", "-")])
        self.assertEqual(self.at(t, 150, nested), "solo")


if __name__ == "__main__":
    unittest.main()

import unittest
from ttreport.events import parse_line, parse_stream
from ttreport.compact import compact
from ttreport.report import Options, build_report


def prompt(at, project="sportx", session="s1"):
    return "\t".join([
        "i", "beat", str(at), str(at), "m1", "claude", "paired", project, ".",
        session, "UserPromptSubmit", "t1", "-", "-", "-", "-", "-", "-",
        "human", "fp",
    ])


def options(**kw):
    base = dict(since=0, upto=10 ** 10, byday=True, detail=True,
                boundaries=[0, 86400, 172800], presence_gap=3600,
                checkin_window=1200, max_active=3600)
    base.update(kw)
    return Options(**base)


class TestCompact(unittest.TestCase):
    def test_rows_after_the_cutoff_are_carried_verbatim(self):
        rows = parse_stream([prompt(90000), prompt(90600)])
        history, carry = compact(rows, cutoff=86400, options=options())
        self.assertEqual(len(carry), 2)
        self.assertTrue(all("\tbeat\t" in line for line in carry))

    def test_rows_before_the_cutoff_become_total_rows(self):
        rows = parse_stream([prompt(0), prompt(600)])
        history, carry = compact(rows, cutoff=86400, options=options())
        self.assertTrue(history)
        self.assertTrue(all(line.split("\t")[1] in ("total", "coverage") for line in history))
        self.assertEqual({r.event for r in parse_stream(carry)}, {"heartbeat", "turn"})

    def test_a_total_row_carries_its_seconds(self):
        rows = parse_stream([prompt(0), prompt(600)])
        history, _carry = compact(rows, cutoff=86400, options=options())
        paired = [l for l in history if l.split("\t")[6] == "paired"][0]
        self.assertEqual(paired.split("\t")[15], "600")

    def test_compaction_preserves_the_reported_total(self):
        rows = parse_stream([prompt(0), prompt(600), prompt(1200)])
        history, _carry = compact(rows, cutoff=86400, options=options())
        seconds = sum(int(l.split("\t")[15]) for l in history
                      if l.split("\t")[6] == "paired")
        self.assertEqual(seconds, 1200)

    def test_an_empty_log_compacts_to_nothing(self):
        history, carry = compact([], cutoff=86400, options=options())
        self.assertEqual((history, carry), ([], []))


# --- Helpers shared by the tests below, matching the conventions already
# established in test_effort.py, test_machine.py and test_report.py. ---

def mode_row(at, mode, session="s1", project="sportx"):
    return parse_line("\t".join([
        "i", "mode", str(at), str(at), "m1", "-", mode, project, ".",
        session, "-",
    ]))


def beat(at, event, session="s1", tool_id="-", tool_name="-",
         project="sportx", subpath="."):
    return parse_line("\t".join([
        "i", "beat", str(at), str(at), "m1", "claude", "paired", project,
        subpath, session, event, "t1", tool_id, "-", "-", "-", "-",
        tool_name, "-", "-",
    ]))


def span_row(start, end, project="tuurny", subpath="."):
    return parse_line("\t".join([
        "i", "span", str(start), str(end), "m1", "-", "manual", project,
        subpath, "-", "a note",
    ]))


def prompt_row(at, project="sportx", session="s1"):
    return parse_line(prompt(at, project=project, session=session))


class TestCompactDisjointEffort(unittest.TestCase):
    # Mirrors test_report.py's test_overlapping_categories_are_counted_once:
    # a check-in episode's window can cover seconds a paired interval also
    # covers. The brief's own bucket accumulation unions each category on
    # its own and never subtracts a higher-priority category from a lower
    # one, so it would double count this overlap in a historical total.
    def test_overlap_between_paired_and_checkin_is_not_double_counted(self):
        rows = [
            mode_row(0, "solo"),
            prompt_row(1000),
            mode_row(1100, "paired"),
            prompt_row(1200), prompt_row(1500),
        ]
        history, _carry = compact(rows, cutoff=86400, options=options())
        by_category = {}
        for line in history:
            fields = line.split("\t")
            by_category[fields[6]] = by_category.get(fields[6], 0) + int(fields[15])
        # Ground truth, independent of compact(): PAIRED's raw union is
        # (1100, 1500) = 400s; CHECKIN's raw union is (-600, 1600) = 2200s,
        # clipped to (0, 1600) = 1600s by compact()'s own clip(0, cutoff).
        # Subtracting PAIRED's claim leaves (0, 1100) + (1500, 1600) = 1200s.
        # Unsubtracted (the brief's own bucket accumulation), CHECKIN would
        # instead union to the full clipped 1600s -- so 1600 is the value
        # that would show up here if the priority subtraction were missing.
        self.assertEqual(by_category.get("paired", 0), 400)
        self.assertEqual(by_category.get("checkin", 0), 1200)
        self.assertNotIn("manual", by_category)


class TestCompactDayEnd(unittest.TestCase):
    def test_the_final_partial_day_ends_at_the_cutoff_not_a_day_later(self):
        # Only one boundary (today's midnight) precedes the cutoff, so the
        # brief's `.index()`-based day_end falls through to `day + 86400` --
        # a full day past the actual, partial end of today.
        rows = parse_stream([prompt(0), prompt(600)])
        history, _carry = compact(
            rows, cutoff=1000, options=options(boundaries=[0]))
        self.assertTrue(history)
        for line in history:
            fields = line.split("\t")
            self.assertEqual(fields[3], "1000" if fields[1] == "total" else "600")

    def test_a_full_prior_day_ends_at_the_next_boundary(self):
        rows = parse_stream([prompt(0), prompt(600)])
        history, _carry = compact(
            rows, cutoff=172800, options=options(boundaries=[0, 86400, 172800]))
        self.assertTrue(history)
        for line in history:
            fields = line.split("\t")
            self.assertEqual(fields[2], "0")
            self.assertEqual(fields[3], "86400" if fields[1] == "total" else "600")


class TestCompactMachineTime(unittest.TestCase):
    def test_agent_and_tool_categories_reach_history(self):
        rows = [
            beat(0, "UserPromptSubmit", session="s2", subpath="backend"),
            beat(10, "PreToolUse", session="s2", tool_id="a",
                 tool_name="Bash", subpath="backend"),
            beat(30, "PostToolUse", session="s2", tool_id="a",
                 tool_name="Bash", subpath="backend"),
            beat(100, "Stop", session="s2", subpath="backend"),
        ]
        history, _carry = compact(rows, cutoff=86400, options=options())
        by_category = {}
        for line in history:
            fields = line.split("\t")
            by_category[fields[6]] = by_category.get(fields[6], 0) + int(fields[15])
        self.assertEqual(by_category.get("tool", 0), 20)
        self.assertEqual(by_category.get("agent", 0), 80)


class TestCompactStraddlingManualSpan(unittest.TestCase):
    def test_a_span_crossing_the_cutoff_splits_between_history_and_carry(self):
        rows = [span_row(86000, 87200, project="tuurny", subpath="docs")]
        history, carry = compact(rows, cutoff=86400, options=options())

        manual = [l for l in history if l.split("\t")[6] == "manual"]
        self.assertEqual(len(manual), 1)
        self.assertEqual(manual[0].split("\t")[15], "400")

        self.assertEqual(len(carry), 1)
        carried = carry[0].split("\t")
        self.assertEqual(carried[1], "span")
        self.assertEqual(carried[2], "86400")
        self.assertEqual(carried[3], "87200")

    def test_a_span_entirely_before_the_cutoff_is_not_carried(self):
        rows = [span_row(3000, 4000)]
        history, carry = compact(rows, cutoff=86400, options=options())
        self.assertEqual(carry, [])
        manual = [l for l in history if l.split("\t")[6] == "manual"]
        self.assertEqual(manual[0].split("\t")[15], "1000")


def _report_options(**kw):
    base = dict(since=0, upto=10 ** 10, byday=False, detail=True,
                boundaries=[], presence_gap=3600, checkin_window=1200,
                max_active=3600)
    base.update(kw)
    return Options(**base)


class TestCompactionRoundTrips(unittest.TestCase):
    # "That property is the whole point of this task": a log containing
    # detail rows must report the same totals after compaction as before.
    def test_a_mixed_log_reports_identically_after_compaction(self):
        rows = [
            # Scenario A: overlapping paired/checkin (session s1, sportx).
            mode_row(0, "solo"),
            prompt_row(1000),
            mode_row(1100, "paired"),
            prompt_row(1200), prompt_row(1500),
            # Scenario B: machine time (session s2, sportx/backend).
            beat(2000, "UserPromptSubmit", session="s2", subpath="backend"),
            beat(2010, "PreToolUse", session="s2", tool_id="a",
                 tool_name="Bash", subpath="backend"),
            beat(2030, "PostToolUse", session="s2", tool_id="a",
                 tool_name="Bash", subpath="backend"),
            beat(2100, "Stop", session="s2", subpath="backend"),
            # Scenario C: a manual span entirely before the cutoff.
            span_row(3000, 4000, project="tuurny", subpath="."),
            # Scenario D: a manual span straddling the cutoff.
            span_row(86000, 87200, project="tuurny", subpath="docs"),
        ]
        cutoff = 86400
        report_opts = _report_options()
        before = build_report(rows, report_opts)

        history, carry = compact(
            rows, cutoff=cutoff, options=options(boundaries=[0, 86400]))
        after_rows = parse_stream(history + carry)
        after = build_report(after_rows, report_opts)

        self.assertEqual(before, after)

    def test_two_heartbeats_still_report_after_compaction(self):
        # The regression this task exists to fix: a report reaching past
        # today used to lose every compacted day's history entirely --
        # two valid heartbeats would report as 0h 00m once compaction had
        # consumed them.
        rows = [prompt_row(100), prompt_row(700)]
        cutoff = 86400
        byday_opts = dict(since=0, upto=200000, byday=True, detail=False,
                          boundaries=[0, 86400], presence_gap=3600,
                          checkin_window=1200, max_active=3600)

        import time
        label = time.strftime("%Y-%m-%d", time.localtime(0))

        def paired_cell(report):
            line = [l for l in report.splitlines() if l.startswith(label)][0]
            return " ".join(line[len(label):].split()[0:2])

        before = build_report(rows, Options(**byday_opts))
        self.assertNotEqual(paired_cell(before), "0h 00m")

        history, carry = compact(rows, cutoff=cutoff,
                                 options=Options(**byday_opts))
        after_rows = parse_stream(history + carry)
        after = build_report(after_rows, Options(**byday_opts))

        self.assertEqual(before, after)
        self.assertNotEqual(paired_cell(after), "0h 00m")


class TestCompactionAcrossActiveState(unittest.TestCase):
    # A cutoff placed the way bin/tt places it -- a local day boundary --
    # can still fall inside a turn, a tool bracket, or right at a mode
    # transition, because compaction runs whenever the next `tt` invocation
    # happens to land, not at the instant something closes. Each case here
    # builds the report from the raw rows, compacts at the boundary, rebuilds
    # the report from history-plus-carry (exactly what cmd_report feeds
    # ttreport: events-*.tsv and current-*.tsv together), and compares the
    # two column by column.
    CUTOFF = 86400
    COMPACT_OPTIONS = options(boundaries=[0, 86400])

    def round_trip(self, rows, report_opts=None):
        report_opts = report_opts or _report_options()
        before = build_report(rows, report_opts)
        history, carry = compact(rows, cutoff=self.CUTOFF,
                                 options=self.COMPACT_OPTIONS)
        after = build_report(parse_stream(history + carry), report_opts)
        return before, after

    def test_an_open_turn_spanning_the_cutoff_keeps_its_agent_time(self):
        # UserPromptSubmit before the cutoff, Stop after it.
        rows = [
            beat(86300, "UserPromptSubmit"),
            beat(86500, "Stop"),
        ]
        before, after = self.round_trip(rows)
        self.assertEqual(before, after)

    def test_a_tool_bracket_spanning_the_cutoff_keeps_agent_and_tool_time(self):
        # PreToolUse before the cutoff, PostToolUse after it.
        rows = [
            beat(86000, "UserPromptSubmit"),
            beat(86300, "PreToolUse", tool_id="a", tool_name="Bash"),
            beat(86500, "PostToolUse", tool_id="a", tool_name="Bash"),
            beat(86700, "Stop"),
        ]
        before, after = self.round_trip(rows)
        self.assertEqual(before, after)

    def test_a_solo_transition_before_the_cutoff_is_not_reclassified_paired(self):
        # A mode row switches to solo well before the cutoff; the heartbeats
        # that follow it land after the cutoff. If the transition is lost,
        # ModeTimeline defaults back to paired for the carried heartbeats.
        rows = [
            mode_row(80000, "solo"),
            prompt_row(86500),
            prompt_row(87000),
        ]
        before, after = self.round_trip(rows)
        self.assertEqual(before, after)

    def test_a_paired_heartbeat_gap_straddling_the_cutoff_is_unchanged(self):
        rows = [prompt_row(86300), prompt_row(86500)]
        before, after = self.round_trip(rows)
        self.assertEqual(before, after)


if __name__ == "__main__":
    unittest.main()

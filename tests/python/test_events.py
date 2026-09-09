import unittest
from ttreport.events import Row, parse_line, parse_stream


def row(*fields):
    return "\t".join(fields)


class TestParseLine(unittest.TestCase):
    def test_full_row_parses_every_column(self):
        line = row(
            "2026-09-08T11:35:07-0400", "beat", "1788000000", "1788000000",
            "m1", "claude", "paired", "sportx", ".", "sess1",
            "UserPromptSubmit", "t1", "-", "-", "-", "-", "-",
            "-", "human", "ab12cd34",
        )
        r = parse_line(line)
        self.assertEqual(r.kind, "beat")
        self.assertEqual(r.start, 1788000000)
        self.assertEqual(r.event, "UserPromptSubmit")
        self.assertEqual(r.prompt_class, "human")
        self.assertEqual(r.fingerprint, "ab12cd34")

    def test_legacy_17_column_row_defaults_new_columns(self):
        line = row(
            "2026-09-08T11:35:07-0400", "beat", "1788000000", "1788000000",
            "m1", "claude", "paired", "sportx", ".", "sess1",
            "PreToolUse", "t1", "tool9", "-", "-", "-", "-",
        )
        r = parse_line(line)
        self.assertEqual(r.tool_use_id, "tool9")
        self.assertEqual(r.tool_name, "-")
        self.assertEqual(r.prompt_class, "-")
        self.assertEqual(r.fingerprint, "-")

    def test_extra_columns_are_ignored_without_shifting_known_fields(self):
        fields = ['i', 'beat', '1', '1', 'm1', 'claude', '-', 'sportx', '.',
                  's1', 'UserPromptSubmit', '-', '-', '-', '-', '-', '-', '-',
                  'human', 'fingerprint']
        expected = parse_line(row(*fields))
        self.assertEqual(parse_line(row(*(fields + ['future', 'extension']))), expected)

    def test_empty_session_uses_the_same_fallback_as_a_dash(self):
        fields = ['i', 'beat', '1', '1', 'm1', 'claude', '-', 'sportx', 'api',
                  '', 'Stop']
        self.assertEqual(parse_line(row(*fields)).stream,
                         ('m1', 'claude', 'sportx/api'))

    def test_row_with_unparsable_timestamp_is_dropped(self):
        line = row("bad", "beat", "not-a-number", "0", "m1", "claude",
                   "paired", "sportx", ".", "s", "Stop")
        self.assertIsNone(parse_line(line))

    def test_blank_and_short_lines_are_dropped(self):
        self.assertIsNone(parse_line(""))
        self.assertIsNone(parse_line("only\tthree\tfields"))

    def test_stream_prefers_session_id(self):
        r = parse_line(row(
            "i", "beat", "1", "1", "m1", "claude", "paired", "sportx",
            "sub", "sess1", "Stop"))
        self.assertEqual(r.stream, ("m1", "claude", "sess1"))

    def test_stream_falls_back_to_path_without_session(self):
        r = parse_line(row(
            "i", "beat", "1", "1", "m1", "claude", "paired", "sportx",
            "sub", "-", "Stop"))
        self.assertEqual(r.stream, ("m1", "claude", "sportx/sub"))

    def test_parse_stream_skips_bad_rows_and_keeps_order(self):
        good = row("i", "beat", "5", "5", "m", "c", "paired", "p", ".",
                   "s", "Stop")
        rows = parse_stream([good, "", "junk", good])
        self.assertEqual(len(rows), 2)
        self.assertEqual([r.start for r in rows], [5, 5])


class TestOldTotalRow(unittest.TestCase):
    # The retired awk compactor's 12-field layout:
    # iso, total, start, end, machine, -, MODE, project, subpath, -,
    # SECONDS, estimated
    def old_total(self, mode, seconds="600", estimated="0", project="sportx",
                 subpath="."):
        return row("2026-09-01T00:00:00-0400", "total", "0", "86400", "m1",
                   "-", mode, project, subpath, "-", seconds, estimated)

    def test_old_paired_row_keeps_its_category_and_seconds(self):
        r = parse_line(self.old_total("paired"))
        self.assertEqual(r.kind, "total")
        self.assertEqual(r.mode, "paired")
        self.assertEqual(r.words, "600")
        self.assertEqual(r.start, 0)
        self.assertEqual(r.end, 86400)
        self.assertEqual(r.project, "sportx")
        self.assertEqual(r.subpath, ".")

    def test_old_manual_row_keeps_its_category(self):
        r = parse_line(self.old_total("manual"))
        self.assertEqual(r.mode, "manual")

    def test_old_solo_row_maps_to_agent(self):
        # Under the retired model, solo meant the agent ran while the user
        # was elsewhere -- machine time, not the user's own effort.
        r = parse_line(self.old_total("solo"))
        self.assertEqual(r.mode, "agent")

    def test_an_unrecognized_old_mode_is_dropped_not_crashed(self):
        self.assertIsNone(parse_line(self.old_total("bogus")))

    def test_new_format_total_row_is_read_directly(self):
        line = row("-", "total", "0", "86400", "-", "-", "checkin",
                   "sportx", ".", "-", "-", "-", "-", "-", "-", "900",
                   "-", "-", "-", "-")
        r = parse_line(line)
        self.assertEqual(r.mode, "checkin")
        self.assertEqual(r.words, "900")


class TestLegacyRowsDoNotCrash(unittest.TestCase):
    def test_an_old_state_row_is_dropped_not_crashed(self):
        # 18 fields: the retired awk compactor's width, never exactly the
        # current 20-column layout. There is no coherent mapping from its
        # reading-estimate model to a carried heartbeat or bracket, so it is
        # dropped -- same outcome as any other malformed row, and distinct
        # from a genuine new-format state row (tested in test_compact.py).
        line = row("i", "state", "100", "100", "m1", "claude", "paired",
                   "sportx", ".", "s1", "UserPromptSubmit", "t1", "-", "0",
                   "-", "-", "-", "-")
        self.assertIsNone(parse_line(line))

    def test_a_new_format_state_row_parses(self):
        line = row("-", "state", "100", "100", "m1", "claude", "paired",
                   "sportx", ".", "s1", "heartbeat", "-", "-", "-", "-",
                   "86400", "-", "-", "-", "-")
        r = parse_line(line)
        self.assertIsNotNone(r)
        self.assertEqual(r.kind, "state")
        self.assertEqual(r.event, "heartbeat")

    def test_a_compact_marker_row_parses_without_raising(self):
        line = row("2026-09-01", "compact", "86400", "86400", "m1", "-",
                   "-", "-", "-", "-", "-")
        r = parse_line(line)
        self.assertIsNotNone(r)
        self.assertEqual(r.kind, "compact")


if __name__ == "__main__":
    unittest.main()


class CoverageValidationTests(unittest.TestCase):
    def test_coverage_requires_explicit_interval_and_matching_duration(self):
        fields = ['-', 'coverage', '100', '160', '-', '-', 'paired', 'p', '.',
                  '-', '-', '-', '-', '-', '-', '60', '-', '-', '-', '-']
        self.assertIsNotNone(parse_line('\t'.join(fields)))
        fields[15] = '120'
        self.assertIsNone(parse_line('\t'.join(fields)))
        self.assertIsNone(parse_line('\t'.join(fields[:11])))

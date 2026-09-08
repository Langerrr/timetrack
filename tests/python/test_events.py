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


if __name__ == "__main__":
    unittest.main()

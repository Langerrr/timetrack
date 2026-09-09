import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
TT = REPO / "bin" / "tt"


class TestReportCLI(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        root = Path(self.tempdir.name)
        self.home = root / "home"
        self.project_root = root / "workspace"
        self.home.mkdir()
        self.project_root.mkdir()
        self.env = os.environ.copy()
        self.env.update({
            "TT_HOME": str(self.home),
            "TT_ROOT": str(self.project_root),
            "TT_LIB": str(REPO / "lib"),
            "TZ": "UTC",
        })
        self.machine = self.run_tt("debug-machine").stdout.strip()
        self.current = self.home / ("current-%s.tsv" % self.machine)

    def tearDown(self):
        self.tempdir.cleanup()

    def run_tt(self, *args, **environment):
        env = self.env.copy()
        env.update({key: str(value) for key, value in environment.items()})
        return subprocess.run(
            ["sh", str(TT)] + list(args),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )

    def write_rows(self, *rows):
        self.current.write_text("\n".join(rows) + "\n", encoding="utf-8")

    def mode(self, at, mode="paired", project="sportx", subpath=".",
             session="s1"):
        return "i\tmode\t%d\t%d\t%s\t-\t%s\t%s\t%s\t%s\t-" % (
            at, at, self.machine, mode, project, subpath, session,
        )

    def span(self, start, end, project="tuurny", subpath="."):
        return "i\tspan\t%d\t%d\t%s\t-\tmanual\t%s\t%s\t-\tcall" % (
            start, end, self.machine, project, subpath,
        )

    @staticmethod
    def durations(output, row="sportx"):
        line = next(line for line in output.splitlines()
                    if line.startswith(row))
        values = line[len(row):].split()
        return [" ".join(values[index:index + 2])
                for index in range(0, len(values), 2)]

    def report(self, *args, **environment):
        defaults = ("--since", "2000-01-01", "--until", "2100-01-01")
        return self.run_tt("report", *(args or defaults), **environment).stdout

    def test_report_sorts_rows_before_reconstruction(self):
        self.write_rows(
            self.mode(1900000120),
            self.mode(1900000000),
            self.mode(1900000060),
        )
        output = self.report(TT_NOW=1900100000)
        self.assertEqual(self.durations(output)[0], "0h 02m")

    def test_equal_timestamp_rows_keep_append_order(self):
        self.write_rows(
            self.mode(1900000000, "solo"),
            self.mode(1900000000, "paired"),
            self.mode(1900000060, "paired"),
        )
        output = self.report(TT_NOW=1900100000)
        durations = self.durations(output)
        self.assertEqual(durations[0], "0h 01m")
        self.assertEqual(durations[1], "0h 00m")

    def test_manual_span_reaches_the_report(self):
        self.write_rows(self.span(1900000000, 1900003600))
        output = self.report(TT_NOW=1900000100)
        self.assertEqual(self.durations(output, "tuurny")[2], "1h 00m")

    def test_detail_includes_the_subpath(self):
        self.write_rows(
            self.mode(1900000000, subpath="saas-backend"),
            self.mode(1900000060, subpath="saas-backend"),
        )
        output = self.report(
            "--since", "2000-01-01", "--until", "2100-01-01", "--detail",
            TT_NOW=1900100000,
        )
        self.assertIn("sportx/saas-backend", output)

    def test_empty_log_exits_successfully(self):
        completed = self.run_tt("report", TT_NOW=1900100000)
        self.assertEqual(completed.returncode, 0)


if __name__ == "__main__":
    unittest.main()

"""Entry point. Reads the timestamp-sorted TSV on stdin."""

import argparse
import sys

from .events import parse_stream
from .report import Options, build_report


def main(argv=None, stdin=None):
    parser = argparse.ArgumentParser(prog="ttreport")
    parser.add_argument("--since", type=int, required=True)
    parser.add_argument("--upto", type=int, required=True)
    parser.add_argument("--presence-gap", type=int, default=3600)
    parser.add_argument("--checkin-window", type=int, default=1200)
    parser.add_argument("--max-active", type=int, default=3600)
    parser.add_argument("--byday", action="store_true")
    parser.add_argument("--detail", action="store_true")
    parser.add_argument("--boundary", type=int, action="append", default=[])
    args = parser.parse_args(argv)

    rows = parse_stream(stdin or sys.stdin)
    options = Options(
        since=args.since, upto=args.upto, byday=args.byday,
        detail=args.detail, boundaries=args.boundary,
        presence_gap=args.presence_gap,
        checkin_window=args.checkin_window,
        max_active=args.max_active,
    )
    sys.stdout.write(build_report(rows, options))
    return 0


if __name__ == "__main__":
    sys.exit(main())

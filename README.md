# timetrack

Track personal effort and agent activity across projects, machines, Claude Code,
and Codex. Once installed, hooks record activity automatically. Use `tt` or ask
an agent to log manual time, change your presence mode, or show a report.

## What the numbers mean

| Column | Measures |
|---|---|
| `PAIRED` | Time between human check-ins while working alongside an agent |
| `CHECKIN` | Brief engagement during unattended runs |
| `MANUAL` | Time entered with `tt add` |
| `EFFORT` | `PAIRED` + `CHECKIN` + `MANUAL`, with overlaps removed within each project |
| `AGENT` | Worker elapsed time, excluding that worker's tool intervals |
| `TOOL` | Sum of tool-call durations |

Effort overlaps count once within a project, even across sessions and machines.
Different projects remain additive. Machine time is separate from effort and
can exceed wall-clock time when workers or tools run concurrently.

By default, paired gaps up to one hour count in full; longer gaps credit
30 minutes. Solo check-ins within 20 minutes form an episode, credited as its
span plus 20 minutes. Tool events and automatic continuations do not establish
human presence.

## Install

Requires POSIX shell utilities and **Python 3.8+** for reporting and compaction,
including rollover triggered by hooks. `ssh` and `rsync` are optional for remote
setup and log retrieval.

Clone the public repository, which includes its own plugin marketplace:

```sh
git clone https://github.com/Langerrr/timetrack.git ~/timetrack-plugin
```

**Claude Code** — run inside an interactive session:

```text
/plugin marketplace add ~/timetrack-plugin
/plugin install timetrack@timetrack
```

**Codex**:

```sh
codex plugin marketplace add ~/timetrack-plugin
codex plugin add timetrack@timetrack
```

Restart the harness after installation. In Codex, open `/hooks` and review and
trust the plugin's hook definitions; untrusted hooks do not run.

To use `tt` directly in your shell, link it into a directory on your `PATH`:

```sh
mkdir -p ~/.local/bin
ln -sf ~/timetrack-plugin/bin/tt ~/.local/bin/tt
# Ensure ~/.local/bin is on your PATH.
tt init
```

The hooks and bundled agent skill work without the symlink. Projects are the
first directory below `~/workspace` by default; set `TT_ROOT` in
`~/.timetrack/config` if your projects live elsewhere.

### Upgrading to 0.6.0

Update your source clone, then update or reinstall the plugin using the same
marketplace name as before. Harnesses run cached copies; pulling the source
alone does not refresh an installed plugin. Restart the harness and review the
changed hooks in Codex through `/hooks`.

Version 0.6.0 separates effort from machine time, preserves effort coverage
through compaction, and moves hook capture into `bin/tt-hook`. Existing `tt hook`
configurations still work. Install Python 3.8+ on every logging machine and back
up both `events-*.tsv` and `current-*.tsv` before the first run. Existing logs
migrate automatically; legacy duration-only totals remain additive because
their original timestamps cannot be recovered to remove historical overlaps.

## Everyday use

```sh
tt report                         # today, grouped by project
tt report week --detail            # break projects down by subdirectory
tt report month --by day
tt report --since 2026-09-01 --until 2026-09-08

tt add sportx 90m "architecture review"
tt add sportx 1.5h "pairing" --at '2026-09-08 10:00'

tt solo                           # leaving an unattended run
tt paired                         # back at the keyboard
tt sessions                       # explicitly set presence modes
```

Reports also accept `yesterday`. Date bounds include the entire local day.
`tt add` accepts minutes, hours, or combinations such as `2h30m`; without
`--at`, the span ends now. Quote multiword notes.

`solo` and `paired` apply forward from the command, never retroactively. Inside
a harness shell they use its session ID when available. Otherwise they cover
sessions at or below the selected path, which defaults to the current directory.
Use `--session ID` to narrow the scope or `--all-sessions` to apply path-wide.
The default mode is paired.

Prompts received as literal `/goal`, `/loop`, or `/schedule` commands select
solo automatically. **Native Codex goals need an explicit `tt solo`:** Codex
0.153.4 supplies no goal-start marker in its hook payload. Human check-ins do
not end an automatic solo run; `tt paired` or `SessionEnd` does.

You can also ask an agent: “log two hours on sportx for the architecture
review”, “I'm heading out, let it run”, or “how much time on sportx this week”.
Run `tt help` or `tt report --help` for the full command reference.

## Configuration and storage

`~/.timetrack/config` uses `key=value`; environment variables override it:

```text
machine=laptop
TT_ROOT=/home/you/workspace
TT_PRESENCE_GAP=3600
TT_CHECKIN_WINDOW=1200
TT_MAX_ACTIVE_GAP=3600
TT_SOLO_COMMANDS=goal,loop,schedule
```

The three intervals are seconds. `TT_MAX_ACTIVE_GAP` caps estimates for worker
or tool activity whose closing event is missing. Reconstruction settings affect
current detail and pending state, not finalized history. Set `TT_HOME` to move
the log directory.

Each machine writes two TAB-separated files:

- `events-<machine>.tsv`: compact effort coverage and finalized machine totals,
  suitable for a **private** Git repository.
- `current-<machine>.tsv`: current detail and unresolved activity carried across
  rollover; gitignored along with the live `modes` cache.

Rollover preserves effort overlap information and pending activity while
removing completed raw detail. Old duration-only totals remain readable.
Project attribution comes from each event's working directory: the first path
component below `TT_ROOT` is the project, and the remainder is its subpath.
The root itself is `~root`; paths outside it are `~outside`.

## Other machines

```sh
tt install-remote macmini    # clone the public tool over SSH and initialize it
tt sync pull macmini         # retrieve both log files through rsync
```

Remote setup prints the plugin registration commands to run on that host.
It clones into `~/timetrack-plugin` and sets the machine name to the host name
you supplied. An existing clone is updated with a fast-forward pull. The host
needs GitHub access, Python 3.8+, and plugin registration and hook trust as above.
No GitHub credentials are transferred.

`sync pull` replaces that host's local log files. Keep machine names unique,
and commit only compact history to your private log repository. The tool does
not push logs. Remote commands have been tested with stand-in SSH, rsync, and
Git commands; real-host deployment and the existing-clone update path remain
unverified.

## Troubleshooting

- **No activity:** check the plugin is enabled, restart the harness, and review
  Codex hook trust through `/hooks`. Run `tt init` if the log directory is absent.
- **Source edits have no effect:** refresh the installed plugin's cached copy.
- **Unexpected project:** check `TT_ROOT` and the harness working directory.
- **Empty or zero report:** inspect `current-*.tsv`. A single beat does not
  establish a paired interval, and displayed durations round down to minutes.

## Development

Capture uses `bin/tt-hook`; `bin/tt` provides the CLI. Both share
`lib/tt-common.sh`. Reporting and compaction use the standard-library Python
package in `lib/ttreport`. For manual hook setup, run
`tt hooks-snippet claude` or `tt hooks-snippet codex`.

Run tests sequentially from the repository root, or give parallel shell runs
separate `TMPDIR` directories:

```sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=lib python3 -m unittest discover -s tests/python
sh tests/run.sh
dash tests/run.sh  # where available
```

Version 0.6.0 passed 156 Python tests and 214 assertions under each shell.
Detailed documentation:

- [Accounting design](docs/superpowers/specs/2026-09-08-effort-and-machine-time-design.md)
- [Implementation and verification](docs/superpowers/reports/2026-09-08-completion.md)
- [Codex runtime review and integration limits](docs/superpowers/reports/2026-09-08-codex-hooks-review.md)

## Licence

MIT.

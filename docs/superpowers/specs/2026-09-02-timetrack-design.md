# timetrack — design

Date: 2026-09-02

## Purpose

Record how much time goes into each project under `~/workspace`, across several
machines and several agent harnesses, keeping three kinds of time apart: time
worked alongside an agent, time an agent worked alone, and time spent away from
any agent at all.

## Constraints

- Runtime is POSIX `sh`, `awk`, `sed` and `date`. Nothing else is assumed present.
- Runs on Ubuntu under WSL2 and on macOS.
- Serves Claude Code and Codex today, and any harness with a hook mechanism later.
- No graphical interface. Output is aligned plain text.

## Data model

### Events

One append-only TSV per machine. Every row is one event, of one of two kinds:

- `beat` — emitted by a harness hook. `start` equals `end`.
- `span` — a manual entry. `start` and `end` bound a stated duration.

Columns, in order:

| # | Column | Meaning |
|---|--------|---------|
| 1 | `iso_start` | Local time, formatted at capture |
| 2 | `kind` | `beat` or `span` |
| 3 | `start` | Epoch seconds |
| 4 | `end` | Epoch seconds |
| 5 | `machine` | Machine identity |
| 6 | `harness` | `claude`, `codex`, … or `-` for spans |
| 7 | `mode` | `paired`, `solo` or `manual` |
| 8 | `project` | Top-level directory under the workspace root |
| 9 | `subpath` | Remainder of the session directory |
| 10 | `session` | Harness session id, or `-` |
| 11 | `note` | Free text, or `-` |

Each row carries epoch seconds and a preformatted local timestamp written at
capture time. Reporting therefore compares and sums integers, and behaves
identically on both operating systems.

### Attribution

`project` and `subpath` both derive from the agent's session working directory —
the directory the agent was started in, delivered as `cwd` on hook stdin. An
agent started in one repository and reading a sibling repository books its time
to where it started.

- Session directory under `TT_ROOT` (default `~/workspace`): `project` is the
  first path segment, `subpath` is the remainder, or `.` at the project root.
- Session directory at `TT_ROOT` itself: `project` is `~root` and `subpath` is `.`.
- Session directory anywhere else: `project` is `~outside` and `subpath` is the
  absolute path.

### Mode

`paired` and `solo` are set by hand and apply to agent time. `manual` belongs to
spans, and marks time that involved no agent.

Mode is held per session directory, in `~/.timetrack/modes`: one
`mode<TAB>absolute-path` line per directory, matched on the exact path and
rewritten whole when a mode is set. A directory with no line reads as `paired`.

    tt solo [path]      # path defaults to $PWD, resolved absolute
    tt paired [path]
    tt sessions         # recently active session directories and their modes

Two agents started in different directories hold independent modes, so a solo
run in one repository and paired work in another record correctly at the same
time. Two agents started in the same directory share one mode.

Each beat is stamped with the mode in force at that instant, so a mode changed
mid-run splits the run at the moment of the change.

### Reconstructing intervals

Beats group by machine and session, sorted by start. Two consecutive beats less
than `TT_IDLE_GAP` apart (default 900 seconds) contribute their difference,
credited to the mode on the earlier beat. A longer gap contributes nothing and
opens a new block.

Beats rather than start/stop pairs mean a killed terminal or a crashed harness
costs the tail of one block and leaves no unterminated interval behind.

Spans contribute `end - start`.

## Storage

    ~/.timetrack/
      config              # machine=, TT_ROOT=, TT_IDLE_GAP=
      events-<machine>.tsv
      modes               # mode<TAB>absolute-path per session directory

A private git repository. Each machine appends only to its own file, so pulls
and pushes touch disjoint paths.

Machine identity comes from `machine=` in `config`, falling back to the short
hostname. Setting it explicitly keeps a renamed machine writing to the same file.

## Command surface

    tt hook                        # read hook JSON on stdin, append one beat
    tt add <project> <duration> [note] [--at 'YYYY-MM-DD HH:MM']
    tt solo|paired [path]
    tt sessions
    tt report [today|week|month] [--since D] [--until D] [--by project|day] [--detail]
    tt sync pull <host>
    tt install-remote <host>
    tt hooks-snippet [claude|codex]

Durations parse as `90m`, `1.5h` or `2h30m`. `tt add` without `--at` ends the
span at the current time. `tt add` prints the row it wrote.

`tt report` covers today unless given a period.

`tt report` prints one row per project with paired, solo, manual and total
columns. `--detail` breaks projects out by subpath.

## Hook capture

Hooks fire on `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`
and `Stop`. Each calls `tt hook`, which reads `session_id` and `cwd` from stdin
with POSIX `sed`, falls back to `$PWD` when the field is absent, appends one
line and exits.

Installing the plugin wires these hooks. `tt hooks-snippet` prints the equivalent
configuration for a machine set up by hand.

## Packaging

A plugin repository, `Langerrr/timetrack`, cloned to
`~/workspace/langerrr/timetrack` and listed in the `langerrr` marketplace
manifest beside `zforge` and `distributed-architect`.

    timetrack/
      .claude-plugin/plugin.json
      .codex-plugin/plugin.json
      bin/tt
      hooks/hooks.json
      skills/timetrack/SKILL.md
      README.md

Dual manifests serve Claude Code and Codex from one source tree, following the
layout `zforge` already uses. Installing the plugin wires the hooks. `bin/tt` is
symlinked to `~/workspace/bin/tt` so the tool is usable straight from a shell.

The event log lives outside this repository. The tool is generic and shareable;
the log is personal, and separating them leaves the plugin repository's
visibility a free choice.

## Skill

`skills/timetrack/SKILL.md`, loaded by both harnesses, covering four jobs:

**Logging past work.** From "two hours on sportx yesterday afternoon for the
architecture review", resolve `sportx` against the directories under `TT_ROOT`,
convert the relative time to a concrete `--at` argument using the current
timestamp, run `tt add`, and show the row that was written.

**Setting mode.** "I'm heading out, let it run" runs `tt solo`; the agent's own
working directory is the session directory the hook sees, so the key matches.

**Reporting.** Run `tt report` for the period asked about and read the table back.

**Correcting.** The log is plain TSV with a documented schema, so a wrong manual
entry is a one-line edit. `span` rows may be edited. `beat` rows are captured
evidence and stay as written.

Guardrails: log only a duration the user stated or confirmed, treat time coming
up in conversation as conversation, and always echo the written row.

## The mac-mini

The mac-mini runs no git and holds no credentials. Both directions cross
Tailscale SSH, initiated from a trusted machine.

`tt install-remote macmini` rsyncs the plugin directory across and registers it
as a local marketplace there, the mechanism the `zforge-local` entry already
uses.

`tt sync pull macmini` copies `events-macmini.tsv` to the trusted machine, which
commits and pushes it. One machine owns one file, so the pull is a whole-file
overwrite and repeats harmlessly. An offline mac-mini fails the pull and keeps
its data until the next one.

## Out of scope

A live stopwatch, editing beats, CSV export, a background daemon, idle
detection, and anything resembling billing or invoicing.

## Open item

Codex's `[hooks]` TOML key shape, and whether it exposes a plugin-root variable
equivalent to `${CLAUDE_PLUGIN_ROOT}`. Verify against codex-cli 0.152.1 before
wiring. Where no variable exists, the Codex hook entry carries an absolute path.

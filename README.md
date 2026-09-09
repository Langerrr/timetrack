# timetrack

`tt` records how much time goes into each project under a configurable project
root (`~/workspace` by default), across several machines and several agent
harnesses. It runs as a plugin: once
installed, hooks in Claude Code and Codex fire on their own and the log fills
itself. Nothing to start, nothing to stop.

Capture uses POSIX shell and `awk`; reporting and compaction use Python. Each
machine uses one compact history file and one current-day detail file.

## What it records

Every event lands in one row. There are three kinds:

- **`beat`** — written by a harness hook, at the instant it fired. A beat is a
  point in time, not an interval.
- **`span`** — written by `tt add`, bounding a duration you stated.
- **`mode`** — written by `tt solo` or `tt paired`, timestamping an explicit
  human-presence transition.

Reports calculate two separate measures. **Effort** is your engagement and is
bounded by one human timeline within a project. Concurrent sessions for one
project union, while attention shared across different projects is credited to
each project. **Machine time** is summed over main sessions and subagents. It is
split into `AGENT` time (worker elapsed time less overlapping tool intervals)
and `TOOL` time (the sum of tool-call brackets), so it can exceed wall-clock
time. Machine time is never added to effort.

Effort comes from human heartbeats: a human `UserPromptSubmit`, a `tt paired` or
`tt solo` command, or a `tt add` span. `SessionStart`, tool events, subagent
events, and machine-generated continuations are not human heartbeats. During an
automatic solo run, a replay of the prompt that started the run is recognized
by its fingerprint and excluded; a different prompt is a human check-in.

Machine time comes from lifecycle brackets. Main sessions run from
`UserPromptSubmit` to `Stop`; tool calls run from `PreToolUse` to `PostToolUse`;
and the bracket of a subagent-spawning tool measures the child worker. An
unclosed bracket contributes at most `TT_MAX_ACTIVE_GAP` (3600 seconds by
default). A non-compaction `SessionStart` closes open work for that session.

### The three modes

| Mode | Effort credited |
|---|---|
| `paired` | The interval between consecutive heartbeats, or half of `TT_PRESENCE_GAP` when it runs longer |
| `solo` | Each check-in episode: its span plus `TT_CHECKIN_WINDOW` |
| `manual` | The stated span of a `tt add` entry |

`paired` and `solo` control how human heartbeats become effort and can be **set
by hand**:

```sh
tt solo      # heading out, leaving a long run going
tt paired    # back at the keyboard
tt solo --session abc123  # narrow the transition to one session
tt solo --all-sessions    # override in-session detection
```

Inside a harness shell (`! tt solo`), the current session id is used when the
harness exports one. In an ordinary external terminal, mode applies to every
session whose current directory is the selected path or below it. This means
`tt solo` at a project root also covers tools that later report a nested working
directory. `--session ID` narrows the subtree explicitly; `--all-sessions`
forces path-wide scope. A scope with no explicit mode reads as `paired`; when
several scopes match, the most recent explicit transition wins.

Mode applies **forward, from the moment you set it**, and remains sticky until
the matching `tt paired` or `tt solo` command. Setting `solo` after a two-hour
unattended run does not reclassify that run. In paired mode, the interval
between heartbeats is the work: reading, thinking, and composing. A gap longer
than `TT_PRESENCE_GAP` credits half that configured gap, bounding a mislabeled
absence. In solo mode, heartbeats no more than `TT_CHECKIN_WINDOW` apart form an
episode; the episode span plus one check-in window is credited.

### Automatic solo

Prompts invoking a command in `TT_SOLO_COMMANDS` automatically write a solo
transition for that session. The default list is `goal,loop,schedule`. Automatic
solo ends at an explicit `tt paired` or at `SessionEnd`; human check-ins during
the run earn their check-in windows without ending solo mode.

`manual` is not something you set. Every `tt add` row is `manual`, because a span
you typed in is by definition time no hook was watching.

## Install on a trusted machine

### Claude Code

```
/plugin marketplace add ~/workspace/langerrr
/plugin install timetrack@langerrr
```

Or from a clone of this repository, which carries its own marketplace manifest.
The repository is public, so the clone needs no credentials:

```sh
git clone https://github.com/Langerrr/timetrack.git ~/timetrack-plugin
```

```
/plugin marketplace add ~/timetrack-plugin
/plugin install timetrack@timetrack
```

Either way the hooks run from the next session. There is no trust step.

### Codex

**Codex silently skips a plugin's hooks until you grant hook trust in its
interactive TUI.** There is no error, no warning and no log line — `tt` simply
appears dead, and an empty log is the only symptom. This is the most likely
reason an install looks like it failed.

So install, and then start one **interactive** Codex session and accept the
trust decision it asks for:

```sh
codex plugin marketplace add ~/workspace/langerrr
codex plugin add timetrack@langerrr
codex          # interactive; accept the hook trust decision when prompted
```

Codex requires the marketplace in the plugin name. `codex plugin add timetrack`
is refused with `plugin requires --marketplace unless passed as
<plugin>@<marketplace>`.

Codex calls this *persisted* hook trust in its own `codex exec --help`, so the
expectation is that you grant it once rather than every session — though the
silent-skip behaviour is what was observed here, not the granting. That same
help text carries a `--dangerously-bypass-hook-trust` flag for vetted automation;
it is not the normal path and should not be how you install this.

Updating this plugin changes the hook definition and its trust hash. After
installing a new version, review and trust the current hooks again through
`/hooks` in an interactive Codex session.

### Put `tt` on your PATH

The hooks and bundled agent skill find `tt` through the plugin root, so both
automatic tracking and natural-language requests work without this. You need a
link only to type `tt report`, `tt add` or `tt solo` directly in your own shell.

```sh
ln -sf ~/workspace/langerrr/timetrack/bin/tt ~/workspace/bin/tt
```

Use any directory already on your `PATH`; `~/workspace/bin` is not on it by
default. `tt` resolves its own location through symlinks, so the link can live
anywhere.

Claude Code also adds an installed plugin's `bin/` to `PATH` inside its own
sessions, so an agent can call `tt` with no symlink at all.

### Create the log

```sh
tt init
```

That writes `~/.timetrack/` with a `config`, `events-<machine>.tsv` for compact
daily coverage and machine totals, `current-<machine>.tsv` for today's detail, and a `modes` file. It
also creates or extends `.gitignore` so current detail and lock directories are
not committed. To keep the compact history across machines, make the directory
a git repository with a **private** remote:

```sh
git -C ~/.timetrack init -b main
git -C ~/.timetrack remote add origin git@github.com:you/timetrack-log.git
git -C ~/.timetrack add -A
git -C ~/.timetrack commit -m "Start the time log"
```

`modes` and `current-*.tsv` are gitignored because they are live per-machine
state. Lock directories exist only for the length of a write or rollover.

Each machine writes only files carrying its own machine name, so pulls and
pushes between machines touch disjoint paths and do not conflict.

## Install on an edge machine

An edge machine — a mac-mini running long jobs, a box you do not fully trust —
should hold no credentials of yours. Because the tool repository is public, it
can fetch the tool itself over an anonymous `git clone`, and that is what
`install-remote` automates over SSH:

```sh
tt install-remote macmini
```

It **transfers no files**. Over SSH it makes the host clone
`https://github.com/Langerrr/timetrack.git` into `~/timetrack-plugin`, writes
`machine=macmini` into the host's `~/.timetrack/config` so its files end in
`-macmini.tsv`, and runs `tt init` there. The only fact that travels from your
machine is the name you log the host under.

It then prints the registration commands, which you run **on the host**, in each
harness you use there. The clone carries its own marketplace manifest, so it
registers as the marketplace `timetrack` holding the plugin `timetrack`. Under
Codex, remember the trust step.

Because the host clones the published repository, push anything you want it to
have before running this.

When `~/timetrack-plugin/.git` already exists it fast-forwards that clone instead
of making a new one, so re-running is meant to be how you update a host.

**How far this has been taken.** The remote commands have only ever been driven
against a stand-in `ssh`, `rsync` and `git`; no real host and no GitHub request
at any point. Within that, the first-run clone path is the one that was
rehearsed. The update path — `git pull --ff-only` against an existing clone — is
implemented but has never been executed, because the stand-in `git` creates no
`.git` directory and so the branch was never taken. Treat a re-run as expected
behaviour rather than verified behaviour: after one, check on the host that the
code actually moved.

Whenever new code does reach `~/timetrack-plugin`, uninstall and reinstall the
plugin on the host to pick it up. Both harnesses install a plugin by **copying**
it into their own cache — that part was observed here — and `plugin update` does
nothing unless the version in `plugin.json` changed.

Bring its log back to a trusted machine, which is where committing and pushing
happen:

```sh
tt sync pull macmini
```

It runs `rsync -a` for both `events-macmini.tsv` and
`current-macmini.tsv`, replacing each in full, so a repeated pull should change
nothing. Only the compact file belongs in Git. Nothing is ever pushed from the
host — there is no code in `tt` that pushes. Like `install-remote`, this has only
been exercised against a stand-in `rsync`.

**Known limitation:** a host that cannot reach GitHub has no route in.
`install-remote` provisions by cloning; an air-gapped or network-restricted
machine is not served, and nothing is built for that case.

## Command surface

`tt help` prints this list.

**Record**

```
tt add PROJECT DURATION [NOTE] [--at 'YYYY-MM-DD HH:MM']
tt solo [PATH] [--session ID|--all-sessions]
tt paired [PATH] [--session ID|--all-sessions]
```

`add` records time away from any agent. Duration is `90m`, `1.5h`, `2h30m` or a
bare number of minutes. `--at` sets the start, and the duration runs forward
from it. A note longer than one word must be quoted.

`solo` and `paired` explicitly mark whether agent activity in the `PATH` subtree
is running without you or alongside you. `PATH` defaults to the current
directory, and `paired` is the default state. An in-session shell id narrows the
command automatically when available. `--session ID` selects one explicitly;
`--all-sessions` applies to every matching session.

**Read**

```
tt root
tt report [today|yesterday|week|month] [--since D] [--until D] [--by project|day] [--detail]
tt sessions
```

`root` prints the effective configured project root. `report` covers today
unless given a period. `yesterday` covers the complete previous local day;
`week` and `month` are week-to-date and month-to-date. `D` is `YYYY-MM-DD`, and
an `--until` date includes that entire local day. `--by` accepts `project` or
`day`, while `--detail` breaks projects out by sub-directory. Run
`tt report --help` or `tt help report` for the complete report reference.
`sessions` lists every path/session scope whose mode has been set, and its mode.

**Other machines**

```
tt sync pull HOST        fetch HOST's log into this machine's repo
tt install-remote HOST   clone this tool onto HOST over SSH and name it
```

**Setup**

```
tt init                          create ~/.timetrack
tt hooks-snippet [claude|codex]  print hook config for a hand-set-up machine
```

`tt-hook` is what the hooks call; you never run it by hand. `tt hook` forwards
to it for existing hand-set-up configurations.

### Logging time by hand

```sh
$ tt add sportx 25m "pairing on the report" --at '2026-09-02 16:00'
2026-09-02T16:00:00-0400	span	1788379200	1788380700	DESKTOP-G7ULRNT	-	manual	sportx	.	-	pairing on the report
```

Durations parse as `90m`, `1.5h`, `2h30m`, or a bare number read as minutes.
`--at` is the **start** of the block and the duration runs forward from it;
without `--at` the span ends now. The note is a single argument — quote it, or
only its last word is kept. `tt add` prints the row it wrote.

### Reporting

```sh
$ tt report yesterday
PROJECT      PAIRED   CHECKIN   MANUAL    EFFORT     AGENT      TOOL
sportx       1h 12m    0h 00m    0h 00m    1h 12m    0h 48m    0h 09m
TOTAL        1h 12m    0h 00m    0h 00m    1h 12m    0h 48m    0h 09m

$ tt report today
PROJECT      PAIRED   CHECKIN   MANUAL    EFFORT     AGENT      TOOL
sportx       0h 10m    0h 20m    3h 30m    4h 00m    2h 40m    0h 35m
stratos      0h 00m    0h 00m    0h 45m    0h 45m    1h 15m    0h 12m
TOTAL        0h 10m    0h 20m    4h 15m    4h 45m    3h 55m    0h 47m

$ tt report --by day
DAY          PAIRED   CHECKIN   MANUAL    EFFORT     AGENT      TOOL
2026-09-02   0h 10m    0h 20m    4h 15m    4h 45m    3h 55m    0h 47m
TOTAL        0h 10m    0h 20m    4h 15m    4h 45m    3h 55m    0h 47m
```

With no period, `tt report` covers today. `--detail` breaks each project out by
sub-directory. `--since` and `--until` take `YYYY-MM-DD`. `EFFORT` is the sum of
`PAIRED`, `CHECKIN`, and `MANUAL`. `AGENT` and `TOOL` use agent-hours and stand
apart from that total.

Effort is unioned within each project, then summed across projects in every
view. When several subpaths claim the same second in the winning category
(`PAIRED` before `CHECKIN` before `MANUAL`), the lexicographically smallest
normalized subpath receives it. Detail rows show these allocated shares and
sum to project effort; changing grouping never changes the portfolio total.

```sh
$ tt sessions
solo    all          /home/lan/workspace/sportx
paired  abc123       /home/lan/workspace/stratos
```

`all` means every session below that path; another value is the explicitly
targeted session id. Empty output means nothing has been set and everything is
reading as `paired`.

### Asking an agent instead

The plugin ships a `timetrack` skill, so in either harness you can say "log two
hours on sportx for the architecture review", "I'm heading out, let it run", or
"how much time on sportx this week", and the agent runs the right command.

## The log format

Each machine has two TAB-separated files:

- `events-<machine>.tsv` is the compact history intended for Git. Completed
  local days retain canonical `coverage` runs for effort and additive `total`
  rows for finalized machine time. Existing duration-only totals remain readable.
- `current-<machine>.tsv` contains detailed `beat`, `mode`, and `span` rows for the
  current local day, plus carried state and session-less mode transitions from
  earlier days. It is gitignored.

On the first hook, manual entry, or report after midnight, `tt` reconstructs the
completed day, merges it into the compact file, and removes those detailed rows.
Internal `state` rows retain each observed session's last heartbeat and unresolved
lifecycle openings until later evidence resolves them, even across several rollovers.
Session-less `mode` transitions are retained separately: a session first observed
after rollover can inherit older terminal presence, including solo boundaries
on overlapping parent and nested paths. This transition history grows with mode
commands; raw hook history is still discarded. Already-carried sessions resume
from their own heartbeat instead of replaying older terminal presence.
Machine estimates remain provisional in this state, so a later matching close
can replace a capped estimate with the full duration. Closed tool coverage
needed to subtract from pending agent work is coalesced, as are pending closed
turns; raw hook history is discarded. A recent Stop remains as a bounded
continuation seed and ordinary SessionStart clears lifecycle state. An
old single-file `events-<machine>.tsv` is migrated automatically the first time
the updated tool writes or reports. Before replacing either file, rollover
validates both its source rows and generated rows; unexpected content stops the
operation with the original files intact.

Current detail keeps the original eleven columns:

```
iso_start  kind  start  end  machine  harness  mode  project  subpath  session  note
```

| # | Column | Meaning |
|---|---|---|
| 1 | `iso_start` | Local time, formatted when the row was written |
| 2 | `kind` | `beat`, `mode`, or `span` in current detail |
| 3 | `start` | Epoch seconds |
| 4 | `end` | Epoch seconds; equal to `start` on a beat |
| 5 | `machine` | `machine=` from config, else the short hostname |
| 6 | `harness` | `claude`, `codex`, or `-` on a mode/span |
| 7 | `mode` | `paired` or `solo` on transitions, `manual` on spans, `-` on beats |
| 8 | `project` | Top-level directory under `TT_ROOT` |
| 9 | `subpath` | Remainder of the event's working directory, or `.` |
| 10 | `session` | Harness session id, or `-` for an all-session scope |
| 11 | `note` | On a `span`, your free-text note (`-` if none). On a `beat`, the hook event name. `mode` uses `-`. |

Beat column 7 stays `-`; reports resolve modes from explicit and automatic
transition rows. Older beats with a mode stamp still parse normally.

New beat rows append lifecycle and classification fields:

| # | Column | Meaning |
|---|---|---|
| 12 | `turn_id` | Turn identifier — Codex `turn_id`, Claude Code `prompt_id` — or `-` |
| 13 | `tool_use_id` | Tool-call identifier, or `-` |
| 14 | `agent_id` | Subagent identifier, or `-` |
| 15 | `agent_type` | Subagent type or profile, or `-` |
| 16 | `assistant_words` | Word count of the final message on `Stop`, or `-` |
| 17 | `session_source` | `SessionStart` source such as `startup`, `resume`, `clear`, or `compact`; otherwise `-` |
| 18 | `tool_name` | Tool name used to recognize subagent-spawning brackets, or `-` |
| 19 | `prompt_class` | `human`, `trigger`, or `machine` for a prompt, or `-` |
| 20 | `fingerprint` | Short prompt fingerprint used to recognize a machine continuation, or `-` |

Column 11 carries different things by kind, and that is deliberate: a span's note
is what you said about it, a beat's note is which hook produced it
(`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, and
the other documented lifecycle events). Manual spans and old beats may remain
eleven columns while migration runs. Raw assistant-message text is never
persisted.

New compact `coverage` rows use all 20 columns. Columns 3 and 4 are the exact
start and exclusive end of an effort run; column 7 is `paired`, `checkin`, or
`manual`; columns 8 and 9 give project and allocated subpath; column 16 is
`end - start`. Other fields are `-`. Runs are disjoint and coalesced within
project and local day, so their count is bounded by the integer seconds in
that day, independent of event count. They are unioned with other machines'
coverage and later `tt add` entries before reporting or the next compaction.

Compact `total` rows retain the day's bounds in columns 3 and 4, category in
column 7, and seconds in column 16. New totals contain finalized `agent` or
`tool` durations. Older effort totals remain an opaque additive baseline:
timestamp coverage discarded by the old format cannot be recovered.

Internal 20-column `state` rows preserve machine, harness, session and worker
identity. Column 11 is `heartbeat`, `turn`, `tool`, `continuation`, `closed-turn`,
or `tool-coverage`. The first four carry an instant in columns 3 and 4; the
latter two carry a coalesced interval. Column 16 is reserved as zero.
A tool state retains tool id/name in columns 13/18 and its owning worker in
column 14; a spawning tool's column 15 records its associated child id. A solo
heartbeat uses column 17=`episode` and columns 15/18 for its episode's original
project/subpath. An unassociated child tool uses column 17=`unassociated`; a later association
does not retroactively claim it. These internal meanings do not change captured
beat columns.
The first `compact` row records the current local-day marker for the fast path.

Observed child tools are subtracted only from their owning worker. When a
child has exactly one eligible active spawning bracket in its session, that
bracket owns the child. Ambiguous or missing associations leave the child's
tools in TOOL without subtracting them from an arbitrary spawned worker.

Captured rows hold epoch seconds and a preformatted local timestamp, so
reporting compares and sums integers and behaves identically on Linux and macOS.

### Attribution

`project` and `subpath` come from `cwd` on each hook event. A real harness session
remains one activity timeline when that value changes; the subpath attributes
sequential pieces for `--detail` instead of creating concurrent copies.

- Under `TT_ROOT`: `project` is the first path segment, `subpath` the rest (or `.`).
- At `TT_ROOT` itself: `project` is `~root`, `subpath` is `.`.
- Anywhere else: `project` is `~outside` and `subpath` is the absolute path.

### Fixing a mistake

For today, edit or delete the relevant `span` in `current-<machine>.tsv`. After a
day has been compacted, correct its matching `coverage` interval (and duration),
or the seconds of an opaque legacy `total` row, in
`events-<machine>.tsv`. Beat detail is temporary implementation data and is
discarded automatically after the day closes.

## Configuration

`~/.timetrack/config` is flat `key=value`. Anything already in the environment
wins over it.

Settings that affect interval reconstruction are applied when a day is
compacted. Changing them later affects current detail and pending state, not finalized history
already stored for completed days.

```
machine=DESKTOP-G7ULRNT
TT_ROOT=/home/lan/workspace
TT_PRESENCE_GAP=3600
TT_CHECKIN_WINDOW=1200
TT_MAX_ACTIVE_GAP=3600
TT_SOLO_COMMANDS=goal,loop,schedule
```

Setting `machine=` explicitly keeps a renamed machine writing to the same pair
of files. `tt sync pull HOST` looks for both `events-HOST.tsv` and
`current-HOST.tsv`, so a host's `machine=` must match the name you pull it by.

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `TT_HOME` | `~/.timetrack` | Where the log, config and modes live |
| `TT_ROOT` | `~/workspace` | The root that project names are taken under |
| `TT_PRESENCE_GAP` | `3600` | Longest gap between heartbeats counted as continuous paired work |
| `TT_CHECKIN_WINDOW` | `1200` | Window added to a solo check-in episode and the gap separating episodes |
| `TT_MAX_ACTIVE_GAP` | `3600` | Ceiling on an agent bracket whose ending was not recorded; `0` removes it |
| `TT_SOLO_COMMANDS` | `goal,loop,schedule` | Commands that automatically declare a session-scoped solo run |
| `TT_SESSION_ID` | harness id or `-` | Override the implicit session scope of `solo`/`paired` |
| `TT_NOW` | — | Override "now" as epoch seconds; used by the tests |
| `TT_LIB` | `<tt>/../lib` | Where the `ttreport` Python package is found |
| `TT_RSYNC` | `rsync` | The rsync `tt sync pull` invokes |
| `TT_SSH` | `ssh` | The ssh `tt install-remote` invokes |

## Which plugin-root variable each harness exports

Claude Code runs the command from `hooks/hooks.json`; Codex selects
`hooks/codex-hooks.json` from its manifest. Each file names the events that
harness fires, and both include everything that opens or closes tracked
activity: Claude Code adds `PostToolUseFailure`, `PermissionDenied` and
`StopFailure`, which are the endings `PostToolUse` and `Stop` do not cover, and
Codex adds `Interrupt`. Both commands resolve `tt-hook` through the plugin root. Claude Code uses the compatibility fallback, while the
Codex-specific file uses `$PLUGIN_ROOT` directly:

```sh
sh -c 'exec "${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}/bin/tt-hook"'
sh -c 'exec "$PLUGIN_ROOT/bin/tt-hook"'
```

The available variables differ by harness:

| Variable | Claude Code | Codex |
|---|---|---|
| `CLAUDE_PLUGIN_ROOT` | set | set |
| `CLAUDE_PLUGIN_DATA` | set | set |
| `PLUGIN_ROOT` | not set | set |
| `PLUGIN_DATA` | not set | set |
| `CLAUDECODE` | `1` | not set |

Codex exports the `CLAUDE_*` pair alongside its own, so `CLAUDE_PLUGIN_ROOT`
alone cannot tell the two apart. `PLUGIN_ROOT` is set only by Codex, which is why
`tt` tests it **first** when stamping column 6, falling back to
`CLAUDE_PLUGIN_ROOT` or `CLAUDECODE` for Claude Code. Reading them the other way
round attributes every Codex beat to `claude`.

`CODEX_HOME` is deliberately not consulted: it is configuration a user may export
from a login shell, and a hook inherits the login environment, so keying on it
would attribute every Claude Code beat to `codex`.

If you would rather wire the hooks by hand than install the plugin,
`tt hooks-snippet claude` and `tt hooks-snippet codex` print exactly what to add.

## Nothing is being recorded

1. **On Codex, grant hook trust.** Start an interactive session and accept the
   trust decision. Untrusted hooks are skipped in silence.
2. **Check the plugin is enabled** — `claude plugin list` or `codex plugin list`.
3. **Restart the harness.** Hooks are read at session start.
4. **Look for the log** — `ls ~/.timetrack/`. No file at all means `tt init` was
   never run.
5. **Check today's detail directly** — `tail ~/.timetrack/current-*.tsv`. Rows
   present but an empty report means there is no interval supported by human
   heartbeats or agent lifecycle brackets. Older totals are in `events-*.tsv`.
6. **Project reads `~outside`?** The agent was started outside `TT_ROOT`. Set
   `TT_ROOT=` in `~/.timetrack/config`.
7. **Report reads `0h 00m`?** That is real: a short session produces beats only
   seconds apart, and the table rounds down to the minute.
8. **Edited the source and nothing changed?** The harness runs its own copy from
   its plugin cache. Uninstall and reinstall to refresh it.

## Requirements

Capture needs `sh`, `awk`, `sed`, `sort`, `tr`, `date`, `hostname`, `mkdir`,
`mv`, `rm`, `cat`, `cut`, `head`, `dirname`, and `readlink`. These are POSIX
base utilities present on Ubuntu, WSL2, and macOS; both BSD and GNU `date` are
handled. Reporting and compaction also require Python 3.8 or newer.

`rsync` and `ssh` are needed only by `tt sync pull` and `tt install-remote`.

## The two repositories

| | |
|---|---|
| **Tool** | <https://github.com/Langerrr/timetrack> — **public** |
| **Log** | your own **private** repository, cloned to `~/.timetrack` |

The split is deliberate: the tool is shareable, the log is personal. It is also
what makes the edge-machine route work — a public tool can be cloned anonymously
by a machine you have given no credentials.

## Tests

```sh
sh tests/run.sh
```

## Licence

MIT.

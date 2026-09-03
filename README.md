# timetrack

`tt` records how much time goes into each project under a configurable project
root (`~/workspace` by default), across several machines and several agent
harnesses. It runs as a plugin: once
installed, hooks in Claude Code and Codex fire on their own and the log fills
itself. Nothing to start, nothing to stop.

Everything is POSIX shell and `awk`. Each machine uses one compact history file
and one current-day detail file.

## What it records

Every event lands in one row. There are two kinds:

- **`beat`** — written by a harness hook, at the instant it fired. A beat is a
  point in time, not an interval.
- **`span`** — written by `tt add`, bounding a duration you stated.

Reports rebuild intervals from beats. Complete turns, tool calls and subagent
runs are known-active intervals even when they exceed `TT_IDLE_GAP`. For legacy
or incomplete lifecycle data, two consecutive beats from the same machine,
harness, session and directory contribute their difference only when they are
no more than `TT_IDLE_GAP` apart (900 seconds by default). A final unmatched
start never extends to report time, so a killed terminal or crashed harness
leaves nothing dangling.

Not every ending gets recorded — Claude Code fires no hook when you interrupt —
so a single gap inside an open turn or tool call counts at most
`TT_MAX_ACTIVE_GAP` (3600 seconds by default). A prompt carrying a new turn id
closes the turn before it. A `SessionStart` also closes everything open when a
session starts, resumes, or clears; Codex's mid-turn `source=compact`
continuation preserves the current turn.

### The three modes

| Mode | Means |
|---|---|
| `paired` | You were working alongside the agent. |
| `solo` | The agent was running while you were elsewhere. |
| `manual` | Time that involved no agent at all. |

`paired` and `solo` apply to agent time and can be **set by hand**:

```sh
tt solo      # heading out, leaving a long run going
tt paired    # back at the keyboard
```

Mode is held **per session directory** — the directory an agent was started in —
so a solo run in one repository and paired work in another record correctly at
the same time. Two agents started in the same directory share one mode. A
directory with no mode set reads as `paired`.

Mode applies **forward, from the moment you set it**. It does not reach back over
beats already written. Setting `solo` after a two-hour unattended run does not
reclassify that run; each beat carries the mode that was in force when it fired.

Submitting a new prompt after a solo run automatically returns that directory to
`paired` at the prompt timestamp. Codex has no hook for scrolling, focusing the
composer or beginning to type, so timetrack cannot directly observe when reading
started. Instead, when a solo `Stop` contains a final assistant message, it
stores only that message's word count. On the next prompt it estimates reading
time at 120 words per minute, bounded by both the real Stop-to-prompt gap and ten
minutes. The rest of the solo gap stays uncounted. Reports show this estimate as
a disclosed subset of paired time.

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
daily totals, `current-<machine>.tsv` for today's detail, and a `modes` file. It
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
tt solo [PATH]
tt paired [PATH]
```

`add` records time away from any agent. Duration is `90m`, `1.5h`, `2h30m` or a
bare number of minutes. `--at` sets the start, and the duration runs forward
from it. A note longer than one word must be quoted.

`solo` and `paired` say whether the agent started in `PATH` is working without
you or alongside you. `PATH` defaults to the current directory, and `paired` is
the default state.

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
`sessions` lists every session directory whose mode has been set, and its mode.

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

`tt hook` is what the hooks call; you never run it by hand.

### Logging time by hand

```sh
$ tt add sportx 25m "pairing on the report awk" --at '2026-09-02 16:00'
2026-09-02T16:00:00-0400	span	1788379200	1788380700	DESKTOP-G7ULRNT	-	manual	sportx	.	-	pairing on the report awk
```

Durations parse as `90m`, `1.5h`, `2h30m`, or a bare number read as minutes.
`--at` is the **start** of the block and the duration runs forward from it;
without `--at` the span ends now. The note is a single argument — quote it, or
only its last word is kept. `tt add` prints the row it wrote.

### Reporting

```sh
$ tt report yesterday
PROJECT     PAIRED      SOLO    MANUAL ESTIMATED     TOTAL
sportx      1h 12m    0h 00m    0h 00m    0h 00m    1h 12m
TOTAL       1h 12m    0h 00m    0h 00m    0h 00m    1h 12m

$ tt report today
PROJECT     PAIRED      SOLO    MANUAL ESTIMATED     TOTAL
sportx      0h 10m    0h 00m    3h 30m    0h 03m    3h 40m
stratos     0h 00m    0h 00m    0h 45m    0h 00m    0h 45m
TOTAL       0h 10m    0h 00m    4h 15m    0h 03m    4h 25m

$ tt report --by day
DAY            PAIRED      SOLO    MANUAL ESTIMATED     TOTAL
2026-09-02     0h 10m    0h 00m    4h 15m    0h 03m    4h 25m
TOTAL          0h 10m    0h 00m    4h 15m    0h 03m    4h 25m
```

With no period, `tt report` covers today. `--detail` breaks each project out by
sub-directory. `--since` and `--until` take `YYYY-MM-DD`. `ESTIMATED` is already
included in `PAIRED` and `TOTAL`; it is shown separately to disclose how much of
the paired total came from solo-output reading estimates.

```sh
$ tt sessions
solo    /home/lan/workspace/sportx
paired  /home/lan/workspace/stratos
```

`tt sessions` lists only directories whose mode was set explicitly. Empty output
means nothing has been set and everything is reading as `paired`.

### Asking an agent instead

The plugin ships a `timetrack` skill, so in either harness you can say "log two
hours on sportx for the architecture review", "I'm heading out, let it run", or
"how much time on sportx this week", and the agent runs the right command.

## The log format

Each machine has two TAB-separated files:

- `events-<machine>.tsv` is the compact history intended for Git. Completed
  local days occupy a few `total` rows per project and mode.
- `current-<machine>.tsv` contains detailed `beat` and `span` rows for the
  current local day. It is gitignored.

On the first hook, manual entry, or report after midnight, `tt` reconstructs the
completed day, merges it into the compact file, and removes those detailed rows.
A small internal `state` row may remain when an interval crosses midnight. An
old single-file `events-<machine>.tsv` is migrated automatically the first time
the updated tool writes or reports.

Current detail keeps the original eleven columns:

```
iso_start  kind  start  end  machine  harness  mode  project  subpath  session  note
```

| # | Column | Meaning |
|---|---|---|
| 1 | `iso_start` | Local time, formatted when the row was written |
| 2 | `kind` | `beat` or `span` in current detail |
| 3 | `start` | Epoch seconds |
| 4 | `end` | Epoch seconds; equal to `start` on a beat |
| 5 | `machine` | `machine=` from config, else the short hostname |
| 6 | `harness` | `claude`, `codex`, or `-` on a span |
| 7 | `mode` | `paired`, `solo` or `manual` |
| 8 | `project` | Top-level directory under `TT_ROOT` |
| 9 | `subpath` | Remainder of the session directory, or `.` |
| 10 | `session` | Harness session id, or `-` |
| 11 | `note` | On a `span`, your free-text note (`-` if none). On a `beat`, the hook event name. |

New beat rows append six lifecycle fields:

| # | Column | Meaning |
|---|---|---|
| 12 | `turn_id` | Turn identifier — Codex `turn_id`, Claude Code `prompt_id` — or `-` |
| 13 | `tool_use_id` | Tool-call identifier, or `-` |
| 14 | `agent_id` | Subagent identifier, or `-` |
| 15 | `agent_type` | Subagent type or profile, or `-` |
| 16 | `assistant_words` | Word count of the final message on `Stop`, or `-` |
| 17 | `session_source` | `SessionStart` source such as `startup`, `resume`, `clear`, or `compact`; otherwise `-` |

Column 11 carries different things by kind, and that is deliberate: a span's note
is what you said about it, a beat's note is which hook produced it
(`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, and
the other documented lifecycle events). Manual spans and old beats may remain
eleven columns while migration runs. Raw assistant-message text is never
persisted.

Compact `total` rows reuse the stable project and mode columns. Column 3 is the
local day's first epoch, column 4 is the next local-day boundary, column 11 is
the number of seconds for that mode, and column 12 is the estimated-reading
subset of a paired total. The first `compact` row stores the current local-day
marker used for a constant-time rollover check.

Every row holds both epoch seconds and a preformatted local timestamp, so
reporting compares and sums integers and behaves identically on Linux and macOS.

### Attribution

`project` and `subpath` both come from the agent's **session directory** — where
the agent was started, delivered as `cwd` on hook stdin. An agent started in one
repository and reading a sibling attributes its time to where it started.

- Under `TT_ROOT`: `project` is the first path segment, `subpath` the rest (or `.`).
- At `TT_ROOT` itself: `project` is `~root`, `subpath` is `.`.
- Anywhere else: `project` is `~outside` and `subpath` is the absolute path.

### Fixing a mistake

For today, edit or delete the relevant `span` in `current-<machine>.tsv`. After a
day has been compacted, correct the seconds in its matching `total` row in
`events-<machine>.tsv`. Beat detail is temporary implementation data and is
discarded automatically after the day closes.

## Configuration

`~/.timetrack/config` is flat `key=value`. Anything already in the environment
wins over it.

Settings that affect interval reconstruction are applied when a day is
compacted. Changing them later affects current and future detail, not totals
already stored for completed days.

```
machine=DESKTOP-G7ULRNT
TT_ROOT=/home/lan/workspace
TT_IDLE_GAP=900
TT_MAX_ACTIVE_GAP=3600
TT_READING_WPM=120
TT_MAX_READING_TIME=600
```

Setting `machine=` explicitly keeps a renamed machine writing to the same pair
of files. `tt sync pull HOST` looks for both `events-HOST.tsv` and
`current-HOST.tsv`, so a host's `machine=` must match the name you pull it by.

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `TT_HOME` | `~/.timetrack` | Where the log, config and modes live |
| `TT_ROOT` | `~/workspace` | The root that project names are taken under |
| `TT_IDLE_GAP` | `900` | Seconds between beats that still count as continuous |
| `TT_MAX_ACTIVE_GAP` | `3600` | Ceiling on one gap inside an open turn or tool call; `0` removes it |
| `TT_READING_WPM` | `120` | Personal reading-speed assumption for solo-output estimates; `0` switches the estimate off |
| `TT_MAX_READING_TIME` | `600` | Maximum seconds added by one solo-output reading estimate |
| `TT_NOW` | — | Override "now" as epoch seconds; used by the tests |
| `TT_LIB` | `<tt>/../lib` | Where `report.awk` is found |
| `TT_RSYNC` | `rsync` | The rsync `tt sync pull` invokes |
| `TT_SSH` | `ssh` | The ssh `tt install-remote` invokes |

## Which plugin-root variable each harness exports

Claude Code runs the command from `hooks/hooks.json`; Codex selects
`hooks/codex-hooks.json` from its manifest. Each file names the events that
harness fires, and both include everything that opens or closes tracked
activity: Claude Code adds `PostToolUseFailure`, `PermissionDenied` and
`StopFailure`, which are the endings `PostToolUse` and `Stop` do not cover, and
Codex adds `Interrupt`. Both commands resolve `tt` through the plugin root. Claude Code uses the compatibility fallback, while the
Codex-specific file uses `$PLUGIN_ROOT` directly:

```sh
sh -c 'exec "${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}/bin/tt" hook'
sh -c 'exec "$PLUGIN_ROOT/bin/tt" hook'
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
   present but an empty report means there is neither a complete lifecycle
   interval nor a legacy pair within `TT_IDLE_GAP`. Older totals are in
   `events-*.tsv`.
6. **Project reads `~outside`?** The agent was started outside `TT_ROOT`. Set
   `TT_ROOT=` in `~/.timetrack/config`.
7. **Report reads `0h 00m`?** That is real: a short session produces beats only
   seconds apart, and the table rounds down to the minute.
8. **Edited the source and nothing changed?** The harness runs its own copy from
   its plugin cache. Uninstall and reinstall to refresh it.

## Requirements

`sh`, `awk`, `sed`, `sort`, `tr`, `date`, `hostname`, `mkdir`, `mv`, `rm`,
`cat`, `cut`, `head`, `dirname`, `readlink`. All are POSIX base utilities and
present on Ubuntu, WSL2 and macOS. Both BSD and GNU `date` are handled.

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

# timetrack

`tt` records how much time goes into each project under `~/workspace`, across
several machines and several agent harnesses. It runs as a plugin: once
installed, hooks in Claude Code and Codex fire on their own and the log fills
itself. Nothing to start, nothing to stop.

Everything is POSIX shell and `awk`. One append-only TSV per machine.

## What it records

Every event lands in one row. There are two kinds:

- **`beat`** — written by a harness hook, at the instant it fired. A beat is a
  point in time, not an interval.
- **`span`** — written by `tt add`, bounding a duration you stated.

Reports rebuild intervals from beats: two consecutive beats from the same
machine, session and directory that are less than `TT_IDLE_GAP` apart (900
seconds by default) contribute their difference. A longer gap contributes
nothing and starts a new block. Because a beat is complete the moment it is
written, a killed terminal or a crashed harness costs the tail of one block and
leaves nothing dangling.

### The three modes

| Mode | Means |
|---|---|
| `paired` | You were working alongside the agent. |
| `solo` | The agent was running while you were elsewhere. |
| `manual` | Time that involved no agent at all. |

`paired` and `solo` apply to agent time and are **set by hand**:

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

### Put `tt` on your PATH

The hooks find `tt` through the plugin root, so tracking works without this. You
need it to run `tt report`, `tt add` and `tt solo` yourself.

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

That writes `~/.timetrack/` with a `config`, an empty `events-<machine>.tsv` and
a `mode/` directory. To keep the log across machines, make it a git repository
with a **private** remote:

```sh
git -C ~/.timetrack init -b main
printf 'mode/\n' > ~/.timetrack/.gitignore
git -C ~/.timetrack remote add origin git@github.com:you/timetrack-log.git
git -C ~/.timetrack add -A
git -C ~/.timetrack commit -m "Start the time log"
```

`mode/` is gitignored on purpose: it is live per-machine state, not history.

Each machine appends only to its own `events-<machine>.tsv`, so pulls and pushes
between machines touch disjoint files and never conflict.

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
`machine=macmini` into the host's `~/.timetrack/config` so its log is named
`events-macmini.tsv`, and runs `tt init` there. The only fact that travels from
your machine is the name you log the host under.

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
behaviour rather than proven behaviour: after one, check on the host that the
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

It runs `rsync -a`, which replaces `~/.timetrack/events-macmini.tsv` in full, so
a repeated pull should change nothing. Nothing is ever pushed from the host —
there is no code in `tt` that pushes. Like `install-remote`, this has only been
exercised against a stand-in `rsync`.

**Known limitation:** a host that cannot reach GitHub has no route in.
`install-remote` provisions by cloning; an air-gapped or network-restricted
machine is not served, and nothing is built for that case.

## Command surface

```
tt init                          create ~/.timetrack
tt hook                          append one beat from hook JSON on stdin
tt add PROJECT DURATION [NOTE] [--at 'YYYY-MM-DD HH:MM']
tt solo [PATH]                   mark the session started in PATH as solo
tt paired [PATH]                 mark it as paired
tt sessions                      list known session directories and modes
tt report [today|week|month] [--since D] [--until D] [--by project|day] [--detail]
tt sync pull HOST                fetch HOST's log into this machine's repo
tt install-remote HOST           clone this tool onto HOST over SSH and name it
tt hooks-snippet [claude|codex]  print hook configuration
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
$ tt report today
PROJECT     PAIRED      SOLO    MANUAL     TOTAL
sportx      0h 00m    0h 00m    3h 30m    3h 30m
stratos     0h 00m    0h 00m    0h 45m    0h 45m
TOTAL       0h 00m    0h 00m    4h 15m    4h 15m

$ tt report --by day
DAY            PAIRED      SOLO    MANUAL     TOTAL
2026-09-02     0h 00m    0h 00m    4h 15m    4h 15m
TOTAL          0h 00m    0h 00m    4h 15m    4h 15m
```

With no period, `tt report` covers today. `--detail` breaks each project out by
sub-directory. `--since` and `--until` take `YYYY-MM-DD`.

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

`~/.timetrack/events-<machine>.tsv`, one event per line, eleven TAB-separated
columns:

```
iso_start  kind  start  end  machine  harness  mode  project  subpath  session  note
```

| # | Column | Meaning |
|---|---|---|
| 1 | `iso_start` | Local time, formatted when the row was written |
| 2 | `kind` | `beat` or `span` |
| 3 | `start` | Epoch seconds |
| 4 | `end` | Epoch seconds; equal to `start` on a beat |
| 5 | `machine` | `machine=` from config, else the short hostname |
| 6 | `harness` | `claude`, `codex`, or `-` on a span |
| 7 | `mode` | `paired`, `solo` or `manual` |
| 8 | `project` | Top-level directory under `TT_ROOT` |
| 9 | `subpath` | Remainder of the session directory, or `.` |
| 10 | `session` | Harness session id, or `-` |
| 11 | `note` | On a `span`, your free-text note (`-` if none). On a `beat`, the hook event name. |

Column 11 carries different things by kind, and that is deliberate: a span's note
is what you said about it, a beat's note is which hook produced it
(`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`).

Every row holds both epoch seconds and a preformatted local timestamp, so
reporting compares and sums integers and behaves identically on Linux and macOS.

### Attribution

`project` and `subpath` both come from the agent's **session directory** — where
the agent was started, delivered as `cwd` on hook stdin. An agent started in one
repository and reading a sibling books its time to where it started.

- Under `TT_ROOT`: `project` is the first path segment, `subpath` the rest (or `.`).
- At `TT_ROOT` itself: `project` is `~root`, `subpath` is `.`.
- Anywhere else: `project` is `~outside` and `subpath` is the absolute path.

### Fixing a mistake

Rows with kind `span` are yours; edit or delete them. Rows with kind `beat` are
captured evidence — leave them as written.

## Configuration

`~/.timetrack/config` is flat `key=value`. Anything already in the environment
wins over it.

```
machine=DESKTOP-G7ULRNT
TT_ROOT=/home/lan/workspace
TT_IDLE_GAP=900
```

Setting `machine=` explicitly keeps a renamed machine writing to the same log
file. `tt sync pull HOST` looks for `events-HOST.tsv`, so a host's `machine=`
must match the name you pull it by.

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `TT_HOME` | `~/.timetrack` | Where the log, config and modes live |
| `TT_ROOT` | `~/workspace` | The root that project names are taken under |
| `TT_IDLE_GAP` | `900` | Seconds between beats that still count as continuous |
| `TT_NOW` | — | Override "now" as epoch seconds; used by the tests |
| `TT_LIB` | `<tt>/../lib` | Where `report.awk` is found |
| `TT_RSYNC` | `rsync` | The rsync `tt sync pull` invokes |
| `TT_SSH` | `ssh` | The ssh `tt install-remote` invokes |

## Which plugin-root variable each harness exports

Both harnesses run the same hook command from `hooks/hooks.json`:

```sh
sh -c 'exec "${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}/bin/tt" hook'
```

That one line works for both because of how they differ:

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
round books every Codex beat as `claude`.

`CODEX_HOME` is deliberately not consulted: it is configuration a user may export
from a login shell, and a hook inherits the login environment, so keying on it
would book every Claude Code beat as `codex`.

If you would rather wire the hooks by hand than install the plugin,
`tt hooks-snippet claude` and `tt hooks-snippet codex` print exactly what to add.

## Nothing is being recorded

1. **On Codex, grant hook trust.** Start an interactive session and accept the
   trust decision. Untrusted hooks are skipped in silence.
2. **Check the plugin is enabled** — `claude plugin list` or `codex plugin list`.
3. **Restart the harness.** Hooks are read at session start.
4. **Look for the log** — `ls ~/.timetrack/`. No file at all means `tt init` was
   never run.
5. **Check the log directly** — `tail ~/.timetrack/events-*.tsv`. Rows present but
   an empty report means the beats fall outside the reporting window, or every
   pair of them is more than `TT_IDLE_GAP` apart.
6. **Project reads `~outside`?** The agent was started outside `TT_ROOT`. Set
   `TT_ROOT=` in `~/.timetrack/config`.
7. **Report reads `0h 00m`?** That is real: a short session produces beats only
   seconds apart, and the table rounds down to the minute.
8. **Edited the source and nothing changed?** The harness runs its own copy from
   its plugin cache. Uninstall and reinstall to refresh it.

## Requirements

`sh`, `awk`, `sed`, `tr`, `date`, `hostname`, `mkdir`, `cat`, `cut`, `head`,
`dirname`, `readlink`. All are POSIX base utilities and present on Ubuntu, WSL2
and macOS. Both BSD and GNU `date` are handled.

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

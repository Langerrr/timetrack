# Task 2 report: standalone hook entry point

`bin/tt-hook` now owns JSON stdin capture and always returns zero. `bin/tt`
keeps its public `hook` command as an `exec` forwarder for older hook settings.
Both manifests and generated snippets invoke `tt-hook`; the Codex `SessionEnd`
timeout remains `3`.

## RED → GREEN

After adding the direct-entrypoint tests, `TMPDIR=<unique> sh tests/run.sh`
failed because `bin/tt-hook` did not exist (45 cascading failures). After the
move, the following all passed:

```sh
PYTHONPATH=lib python3 -m unittest discover -s tests/python  # 134 tests
TMPDIR=<unique> sh tests/run.sh                              # 212 assertions
TMPDIR=<unique> dash tests/run.sh                            # 212 assertions
```

The eight added assertions cover the entry point, executable bit, 20-column
row, contained unwritable-home failure, `tt hook` forwarding, generated Claude
snippet, and both manifests. All 204 baseline assertion names remain present.
Both final shell runs observed 20/20 concurrent hook beats. Task 1 previously
recorded one 19/20 observation before its successful repeat; this task did not
weaken or retry that assertion.

## Move checks

```sh
diff -u <(git show 50926aa:bin/tt | sed -n '95,158p') <(sed -n '26,89p' bin/tt-hook)
diff -u <(git show 50926aa:bin/tt | sed -n '208,318p') <(sed -n '91,201p' bin/tt-hook)
wc -l bin/tt bin/tt-hook lib/tt-common.sh
```

The two diffs produced no output: hook-only bodies are byte-identical. Line
counts are `511`, `204`, and `670`, respectively. `git diff --check` passed.

## Bootstrap follow-up

Review found that the hook loader omitted the `TT_MAX_ACTIVE_GAP_SET` marker
and `TT_MAX_ACTIVE_GAP` default required by `tt_max_active_gap` under `set -u`.
The hook's unconditional success wrapper had hidden the resulting rollover
failure. The loader now copies those two lines from `bin/tt` before sourcing
the shared library.

`TestReportCLI.test_standalone_hook_rollover_honors_config_then_environment_max_gap`
first failed before the fix with an empty compact history despite exit zero.
Afterward it passed, asserting the compact marker and that a config value of
`6000` retains a continuation while environment `TT_MAX_ACTIVE_GAP=120`
overrides it and does not retain one.

```sh
PYTHONPATH=lib python3 -m unittest \
  tests.python.test_cli.TestReportCLI.test_standalone_hook_rollover_honors_config_then_environment_max_gap
# Ran 1 test ... OK
PYTHONPATH=lib python3 -m unittest discover -s tests/python
# Ran 135 tests ... OK
```

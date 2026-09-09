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

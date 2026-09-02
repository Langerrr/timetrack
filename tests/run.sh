#!/bin/sh
# Runs every test in a throwaway TT_HOME. Usage: sh tests/run.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
TT="$REPO/bin/tt"
. "$HERE/lib.sh"

SANDBOX=${TMPDIR:-/tmp}/tt-test-$$
mkdir -p "$SANDBOX/home" "$SANDBOX/root/sportx/saas-backend" "$SANDBOX/root/tuurny"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

TT_HOME="$SANDBOX/home"
TT_ROOT="$SANDBOX/root"
export TT_HOME TT_ROOT

printf 'Task 1: skeleton\n'
assert_status 2 'unknown subcommand exits 2' -- sh "$TT" nonsense
assert_eq "$TT_HOME" "$(sh "$TT" debug-home)" 'TT_HOME override honoured'
assert_eq "1900000000" "$(TT_NOW=1900000000 sh "$TT" debug-now)" 'TT_NOW override honoured'
assert_eq "testbox" "$(printf 'machine=testbox\n' > "$TT_HOME/config"; sh "$TT" debug-machine)" 'machine from config'
rm -f "$TT_HOME/config"

printf 'Task 2: attribution and mode\n'
assert_eq "sportx	." "$(sh "$TT" debug-attribute "$TT_ROOT/sportx")" 'project root gives subpath .'
assert_eq "sportx	saas-backend" "$(sh "$TT" debug-attribute "$TT_ROOT/sportx/saas-backend")" 'nested gives subpath'
assert_eq "~outside	/etc" "$(sh "$TT" debug-attribute /etc)" 'outside root books to ~outside'
assert_eq "sportx	." "$(sh "$TT" debug-attribute "$TT_ROOT/sportx/")" 'trailing slash tolerated'
assert_eq "~root	." "$(sh "$TT" debug-attribute "$TT_ROOT")" 'the workspace root itself books to ~root'

assert_eq "paired" "$(sh "$TT" debug-mode "$TT_ROOT/sportx")" 'default mode is paired'
sh "$TT" solo "$TT_ROOT/sportx" >/dev/null
assert_eq "solo" "$(sh "$TT" debug-mode "$TT_ROOT/sportx")" 'solo is recorded'
assert_eq "paired" "$(sh "$TT" debug-mode "$TT_ROOT/tuurny")" 'sibling directory is unaffected'
sh "$TT" paired "$TT_ROOT/sportx" >/dev/null
assert_eq "paired" "$(sh "$TT" debug-mode "$TT_ROOT/sportx")" 'paired is recorded'

sh "$TT" solo "$TT_ROOT/sportx/saas-backend" >/dev/null
assert_contains "$(sh "$TT" sessions)" "solo" 'sessions lists the mode'
assert_contains "$(sh "$TT" sessions)" "$TT_ROOT/sportx/saas-backend" 'sessions lists the true path'

finish

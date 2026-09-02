# Minimal POSIX assertion helpers. Sourced by tests/run.sh.
TESTS_RUN=0
TESTS_FAILED=0

assert_eq() { # expected actual label
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$1" = "$2" ]; then
    printf '  ok   %s\n' "$3"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$3" "$1" "$2"
  fi
}

assert_status() { # expected_status label -- command...
  expected=$1; label=$2; shift 3
  TESTS_RUN=$((TESTS_RUN + 1))
  "$@" >/dev/null 2>&1
  actual=$?
  if [ "$expected" = "$actual" ]; then
    printf '  ok   %s\n' "$label"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL %s\n       expected status: %s\n       actual status:   %s\n' "$label" "$expected" "$actual"
  fi
}

assert_contains() { # haystack needle label
  TESTS_RUN=$((TESTS_RUN + 1))
  case "$1" in
    *"$2"*) printf '  ok   %s\n' "$3" ;;
    *) TESTS_FAILED=$((TESTS_FAILED + 1))
       printf '  FAIL %s\n       [%s] does not contain [%s]\n' "$3" "$1" "$2" ;;
  esac
}

assert_not_contains() { # haystack needle label
  TESTS_RUN=$((TESTS_RUN + 1))
  case "$1" in
    *"$2"*) TESTS_FAILED=$((TESTS_FAILED + 1))
       printf '  FAIL %s\n       [%s] contains [%s]\n' "$3" "$1" "$2" ;;
    *) printf '  ok   %s\n' "$3" ;;
  esac
}

finish() {
  printf '\n%s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ] || exit 1
}

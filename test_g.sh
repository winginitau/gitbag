#!/usr/bin/env bash
# Safe, comprehensive tests for ./g (git wrapper)
#
# Safety properties:
# 1) Refuses to run if current directory is inside an existing Git repository.
# 2) Refuses to run if current directory contains anything except allowed files (g and test scripts).
# 3) Creates a fresh temporary sandbox and runs *all* tests there.
# 4) Refuses to use any non-local (non-file) origin URL.

set -euo pipefail

G_PATH="${G_PATH:-./g}"    # path to g executable
KEEP_TMP="${KEEP_TMP:-0}"  # 1 keeps sandbox

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
note() { echo "---- $*"; }

# -----------------------------
# SAFETY CHECKS (current directory)
# -----------------------------
note "Safety checks (current directory)"

# 1) must not be inside any git repo
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "Refusing to run inside a Git repository. Run from a non-repo directory."
fi

# 2) current directory may contain only: g and test scripts
script_base="$(basename "$0")"
allowed=(
  "$script_base"
  "g"
  "test_g"
  "test_g.sh"
  "test_g_safe.sh"
  "test_g_safe"
)

is_allowed() {
  local f="$1"
  for a in "${allowed[@]}"; do
    [[ "$f" == "$a" ]] && return 0
  done
  return 1
}

shopt -s dotglob nullglob
entries=( * )
shopt -u dotglob nullglob

if [[ ${#entries[@]} -gt 0 ]]; then
  bad=()
  for e in "${entries[@]}"; do
    if ! is_allowed "$e"; then
      bad+=("$e")
    fi
  done

  if [[ ${#bad[@]} -gt 0 ]]; then
    printf "Directory contains disallowed entries:\n" >&2
    for e in "${bad[@]}"; do printf "  - %s\n" "$e" >&2; done
    fail "Refusing to run unless current directory contains only: ${allowed[*]}"
  fi
fi

# 3) g must be executable
[[ -x "$G_PATH" ]] || fail "g not found/executable at: $G_PATH"

# -----------------------------
# Create sandbox and run tests there
# -----------------------------
SANDBOX="$(mktemp -d)"
BIN="$SANDBOX/bin"
ORIGIN_BARE="$SANDBOX/origin.git"
WORK="$SANDBOX/work"
WT_OTHER="$SANDBOX/worktree-other"

cleanup() {
  if [[ "$KEEP_TMP" == "1" ]]; then
    note "KEEP_TMP=1, leaving sandbox at: $SANDBOX"
  else
    rm -rf "$SANDBOX"
  fi
}
trap cleanup EXIT

note "Created sandbox: $SANDBOX"

mkdir -p "$BIN"
cp -a "$G_PATH" "$BIN/g"
chmod +x "$BIN/g"

# ensure WORK does not exist and is empty when created
mkdir -p "$WORK"
shopt -s dotglob nullglob
work_entries=( "$WORK"/* )
shopt -u dotglob nullglob
[[ ${#work_entries[@]} -eq 0 ]] || fail "Internal error: sandbox work dir is not empty."
rm -rf "$WORK" # will be created by clone

# -----------------------------
# Tiny test framework
# -----------------------------
RUN_OUT=""
RUN_RC=0

run_cmd() {
  # Captures stdout+stderr into RUN_OUT and exit code into RUN_RC.
  # Safe under `set -e` (it disables errexit around the call).
  set +e
  RUN_OUT="$("$@" 2>&1)"
  RUN_RC=$?
  set -e
}

assert_rc_eq() {
  local got="$1" want="$2" msg="$3"
  [[ "$got" == "$want" ]] || fail "$msg (rc=$got, want=$want)"
}

assert_rc_ne0() {
  local got="$1" msg="$2"
  [[ "$got" -ne 0 ]] || fail "$msg (rc=$got, want non-zero)"
}

assert_contains() {
  local hay="$1" needle="$2" msg="$3"
  grep -Fq "$needle" <<<"$hay" || fail "$msg (missing: $needle)"
}

fetch_all() { (cd "$WORK" && git fetch --prune >/dev/null 2>&1 || true); }

# -----------------------------
# Setup isolated origin + clone
# -----------------------------
note "Creating bare origin (local file-based)"
git init --bare "$ORIGIN_BARE" >/dev/null

note "Cloning work repo"
git clone "$ORIGIN_BARE" "$WORK" >/dev/null

# Additional safety: ensure origin URL is local file path
origin_url="$(git -C "$WORK" remote get-url origin)"
case "$origin_url" in
  /*|file://* ) : ;;
  * ) fail "Refusing to run with non-local origin URL: $origin_url" ;;
esac

# Seed initial commit on main
note "Seeding initial commit on main"
(
  cd "$WORK"
  git switch -c main >/dev/null
  git config user.name "g-test"
  git config user.email "g-test@example.invalid"
  echo "seed" > README.md
  git add README.md
  git commit -m "seed" >/dev/null
  git push -u origin main >/dev/null
)

# -----------------------------
# TESTS
# -----------------------------

note "TEST 1: g (no args) => healthy + usage"
run_cmd bash -lc "cd '$WORK' && '$BIN/g'"
assert_rc_eq "$RUN_RC" 0 "g (no args) should exit 0"
assert_contains "$RUN_OUT" "git is healthy" "should print health ok"
assert_contains "$RUN_OUT" "Usage:" "should print usage"
pass "TEST 1"

note "TEST 2: g c on clean repo => nothing staged to commit"
(cd "$WORK" && test -z "$(git status --porcelain)")
run_cmd bash -lc "cd '$WORK' && '$BIN/g' c"
assert_rc_eq "$RUN_RC" 0 "g c should exit 0"
assert_contains "$RUN_OUT" "git is healthy" "should print health ok"
assert_contains "$RUN_OUT" "Nothing staged to commit." "clean repo should not commit"
pass "TEST 2"

note "TEST 3: g c commits and pushes changes"
(
  cd "$WORK"
  echo "change1" >> README.md
  echo "temp" > temp.txt
  git reset --mixed >/dev/null 2>&1 || true
)
run_cmd bash -lc "cd '$WORK' && '$BIN/g' c"
assert_rc_eq "$RUN_RC" 0 "g c should exit 0"
assert_contains "$RUN_OUT" "auto:" "should auto-commit"
fetch_all
(
  cd "$WORK"
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "g c should push: HEAD != origin/main"
)
pass "TEST 3"

note "TEST 4: g b creates+pushes new branch (allow-empty initial commit)"
(cd "$WORK" && git reset --hard HEAD >/dev/null && git clean -fd >/dev/null)
run_cmd bash -lc "cd '$WORK' && '$BIN/g' b feature_b"
assert_rc_eq "$RUN_RC" 0 "g b should exit 0"
fetch_all
(
  cd "$WORK"
  [[ "$(git rev-parse --abbrev-ref HEAD)" == "feature_b" ]] || fail "should be on feature_b after g b"
  [[ "$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}')" == "origin/feature_b" ]] || fail "feature_b should track origin/feature_b"
)
pass "TEST 4"

# Return to main and delete local feature_b to avoid later blockers; keep remote branch.
(cd "$WORK" && git switch main >/dev/null && git branch -D feature_b >/dev/null)

note "TEST 5: blocker A (other branch missing upstream) blocks g b"
(
  cd "$WORK"
  git switch main >/dev/null
  git branch other_no_upstream >/dev/null
)
run_cmd bash -lc "cd '$WORK' && '$BIN/g' b should_fail_A"
assert_rc_ne0 "$RUN_RC" "g b should have failed due to blocker A"
assert_contains "$RUN_OUT" "Blocking issues detected" "should report blockers"
assert_contains "$RUN_OUT" "no upstream set" "should mention no upstream"
pass "TEST 5"
(cd "$WORK" && git branch -D other_no_upstream >/dev/null)

note "TEST 6: blocker B (other branch not merged into main) blocks g b"
(
  cd "$WORK"
  git switch -c other_not_merged >/dev/null
  echo "x" > other.txt
  git add other.txt
  git commit -m "other commit" >/dev/null
  git push -u origin other_not_merged >/dev/null
  git switch main >/dev/null
)
run_cmd bash -lc "cd '$WORK' && '$BIN/g' b should_fail_B"
assert_rc_ne0 "$RUN_RC" "g b should have failed due to blocker B"
assert_contains "$RUN_OUT" "commits not merged into main" "should mention not merged"
pass "TEST 6"
(cd "$WORK" && git branch -D other_not_merged >/dev/null)

note "TEST 7: blocker C (dirty other worktree) blocks g b"
(
  cd "$WORK"
  git worktree add "$WT_OTHER" -b wt_dirty >/dev/null
)
(
  cd "$WT_OTHER"
  echo "dirty" > dirty.txt
)
run_cmd bash -lc "cd '$WORK' && '$BIN/g' b should_fail_C"
assert_rc_ne0 "$RUN_RC" "g b should have failed due to blocker C"
assert_contains "$RUN_OUT" "C) Other worktrees are dirty:" "should mention dirty worktrees"
pass "TEST 7"
(
  cd "$WT_OTHER"
  git reset --hard HEAD >/dev/null
  git clean -fd >/dev/null
)
(cd "$WORK" && git worktree remove "$WT_OTHER" >/dev/null)
(cd "$WORK" && git branch -D wt_dirty >/dev/null 2>&1 || true)

note "TEST 8: g m from feature branch commits/pushes, merges --no-ff into main, pushes main"
(
  cd "$WORK"
  git switch main >/dev/null
  git switch -c feature_merge >/dev/null
  echo "merge_me" >> README.md
)
run_cmd bash -lc "cd '$WORK' && '$BIN/g' m"
assert_rc_eq "$RUN_RC" 0 "g m should exit 0"
assert_contains "$RUN_OUT" "Merging 'feature_merge' into main (no-ff)" "should merge no-ff"
fetch_all
(
  cd "$WORK"
  [[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || fail "after g m, should be on main"
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "after g m, main should be pushed"
  git log -1 --pretty=%B | grep -q "Merge" || fail "expected merge commit message on main"
)
pass "TEST 8"

note "TEST 9: g m on main with nothing outstanding => message and exit 0"
run_cmd bash -lc "cd '$WORK' && git switch main >/dev/null && '$BIN/g' m"
assert_rc_eq "$RUN_RC" 0 "g m on main (nothing to merge) should exit 0"
assert_contains "$RUN_OUT" "On main: nothing to merge" "should state nothing to merge"
pass "TEST 9"

note "TEST 10: g m on main with exactly one outstanding branch => prompt and merge on y"
(
  cd "$WORK"
  git switch -c feature_prompt >/dev/null
  echo "prompt_merge" > prompt.txt
  git add prompt.txt
  git commit -m "prompt branch commit" >/dev/null
  git push -u origin feature_prompt >/dev/null
  git switch main >/dev/null
)
run_cmd bash -lc "cd '$WORK' && printf 'y\n' | '$BIN/g' m"
assert_rc_eq "$RUN_RC" 0 "g m prompt merge should exit 0"
assert_contains "$RUN_OUT" "Merge branch 'feature_prompt' into main and push main?" "should prompt"
fetch_all
(
  cd "$WORK"
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main should be pushed after prompted merge"
  git log --oneline --max-count=100 | grep -q "prompt branch commit" || fail "feature_prompt commit should be in main"
)
pass "TEST 10"

note "ALL TESTS PASSED (sandbox: $SANDBOX)"

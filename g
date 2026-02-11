#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Config (env overrides)
# -----------------------------
G_REMOTE="${G_REMOTE:-origin}"
G_MAIN_BRANCH="${G_MAIN_BRANCH:-main}"
G_FETCH="${G_FETCH:-0}"              # 1 => git fetch --prune before branch/upstream checks
G_STRICT_FSCK="${G_STRICT_FSCK:-1}"  # 1 => fail on fsck issues (excluding dangling); 0 => skip fsck entirely
G_VERSION="0.2.0"

# -----------------------------
# Helpers
# -----------------------------
die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "$*"; }

in_repo()        { git rev-parse --is-inside-work-tree >/dev/null 2>&1; }
repo_root()      { git rev-parse --show-toplevel; }
current_branch() { git rev-parse --abbrev-ref HEAD; }

has_upstream_for_current() {
  git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1
}

require_remote() {
  git remote get-url "$G_REMOTE" >/dev/null 2>&1 || die "Remote '$G_REMOTE' is not configured."
}

worktree_porcelain() {
  git worktree list --porcelain 2>/dev/null || true
}

is_dirty_tree() {
  [[ -n "$(git status --porcelain --untracked-files=all)" ]]
}

ensure_clean_working_tree() {
  if is_dirty_tree; then
    git status --porcelain --untracked-files=all
    die "Working tree is not clean. Commit/stash/discard changes first."
  fi
}

ensure_identity_if_commit_needed() {
  # Only enforce if a commit is actually required
  local name email
  name="$(git config user.name || true)"
  email="$(git config user.email || true)"
  [[ -n "${name}" && -n "${email}" ]] || die "Git identity not set (user.name/user.email). Set them before committing."
}

# -----------------------------
# Health checks (every invocation)
# -----------------------------
health_check() {
  in_repo || die "Not inside a git work tree."

  local gd
  gd="$(git rev-parse --git-dir)"

  [[ -e "$gd/index.lock" ]] && die "index.lock exists ($gd/index.lock). Another git process may be running or it crashed."
  [[ -e "$gd/MERGE_HEAD" ]] && die "Merge in progress (MERGE_HEAD exists). Resolve/abort before using g."
  [[ -d "$gd/rebase-apply" || -d "$gd/rebase-merge" ]] && die "Rebase in progress. Resolve/abort before using g."
  [[ -e "$gd/CHERRY_PICK_HEAD" ]] && die "Cherry-pick in progress. Resolve/abort before using g."
  [[ -e "$gd/REVERT_HEAD" ]] && die "Revert in progress. Resolve/abort before using g."

  if [[ "$G_STRICT_FSCK" == "1" ]]; then
    local out rc filtered
    set +e
    out="$(git fsck --full 2>&1)"
    rc=$?
    set -e

    # Ignore benign dangling objects only
    filtered="$(printf "%s\n" "$out" | grep -Ev '^(dangling (blob|tree|commit|tag) )' || true)"

    if [[ $rc -ne 0 ]]; then
      echo "$out" >&2
      die "git fsck --full reported problems (non-zero exit)."
    fi

    if [[ -n "${filtered// }" ]]; then
      echo "$filtered" >&2
      die "git fsck --full reported issues (excluding dangling objects)."
    fi
  fi

  info "git is healthy"
}

# -----------------------------
# Cross-branch / worktree checks (A/B/C)
# -----------------------------
check_other_branch_activity() {
  # Blocks if any of:
  # A) other branches ahead of upstream OR no upstream
  # B) other branches have commits not merged into main
  # C) other worktrees dirty
  #
  # exclude_branch: a branch name to exclude from A/B checks (typically current or candidate)
  local exclude_branch="${1:-}"

  if [[ "$G_FETCH" == "1" ]]; then
    git fetch --prune "$G_REMOTE" >/dev/null 2>&1 || true
  fi

  local br

  # --- A) ahead-of-upstream / no upstream
  local a_issues=()
  while IFS= read -r br; do
    [[ -z "$br" ]] && continue
    [[ "$br" == "HEAD" ]] && continue
    [[ "$br" == "$exclude_branch" ]] && continue

    if ! git rev-parse --verify -q "${br}@{u}" >/dev/null; then
      a_issues+=("$br (no upstream set)")
      continue
    fi

    local counts behind ahead
    counts="$(git rev-list --left-right --count "${br}@{u}...${br}" 2>/dev/null || printf "0\t0")"
    behind=0; ahead=0
    IFS=$'\t ' read -r behind ahead <<<"$counts" || true
    behind="${behind:-0}"
    ahead="${ahead:-0}"

    if [[ "$ahead" =~ ^[0-9]+$ ]] && [[ "$ahead" -gt 0 ]]; then
      a_issues+=("$br (ahead of upstream by $ahead)")
    fi
  done < <(git for-each-ref --format='%(refname:short)' refs/heads)

  # --- B) commits not merged into main
  local b_issues=()
  while IFS= read -r br; do
    [[ -z "$br" ]] && continue
    [[ "$br" == "$G_MAIN_BRANCH" ]] && continue
    [[ "$br" == "$exclude_branch" ]] && continue

    local cnt
    cnt="$(git rev-list --count "${G_MAIN_BRANCH}..${br}" 2>/dev/null || echo "0")"
    if [[ "$cnt" =~ ^[0-9]+$ ]] && [[ "$cnt" -gt 0 ]]; then
      b_issues+=("$br ($cnt commits not merged into ${G_MAIN_BRANCH})")
    fi
  done < <(git for-each-ref --format='%(refname:short)' refs/heads)

  # --- C) other worktrees dirty
  local c_issues=()
  local root line wt_path=""
  root="$(repo_root)"

  while IFS= read -r line; do
    case "$line" in
      worktree\ *|path\ *)
        wt_path="${line#* }"
        ;;
      "")
        wt_path=""
        ;;
    esac

    if [[ -n "$wt_path" ]]; then
      # Skip current worktree
      if [[ "$(cd "$wt_path" 2>/dev/null && pwd -P || true)" == "$(cd "$root" && pwd -P)" ]]; then
        continue
      fi

      # Skip missing/unreadable worktree dirs
      [[ -d "$wt_path" ]] || continue

      if [[ -n "$(git -C "$wt_path" status --porcelain --untracked-files=all 2>/dev/null || true)" ]]; then
        local wt_branch
        wt_branch="$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")"
        c_issues+=("$wt_path (branch: $wt_branch)")
      fi
    fi
  done < <(worktree_porcelain)

  if ((${#a_issues[@]})) || ((${#b_issues[@]})) || ((${#c_issues[@]})); then
    echo "Blocking issues detected (must be none of A/B/C):" >&2
    if ((${#a_issues[@]})); then
      echo "  A) Other branches ahead of upstream / no upstream:" >&2
      for x in "${a_issues[@]}"; do echo "     - $x" >&2; done
    fi
    if ((${#b_issues[@]})); then
      echo "  B) Other branches not merged into ${G_MAIN_BRANCH}:" >&2
      for x in "${b_issues[@]}"; do echo "     - $x" >&2; done
    fi
    if ((${#c_issues[@]})); then
      echo "  C) Other worktrees are dirty:" >&2
      for x in "${c_issues[@]}"; do echo "     - $x" >&2; done
    fi
    exit 1
  fi
}

find_single_outstanding_branch_not_merged_into_main() {
  local br
  local candidates=()

  while IFS= read -r br; do
    [[ -z "$br" ]] && continue
    [[ "$br" == "$G_MAIN_BRANCH" ]] && continue
    local cnt
    cnt="$(git rev-list --count "${G_MAIN_BRANCH}..${br}" 2>/dev/null || echo "0")"
    if [[ "$cnt" =~ ^[0-9]+$ ]] && [[ "$cnt" -gt 0 ]]; then
      candidates+=("$br")
    fi
  done < <(git for-each-ref --format='%(refname:short)' refs/heads)

  [[ "${#candidates[@]}" -eq 1 ]] || return 1
  echo "${candidates[0]}"
}

auto_commit_message() {
  local br
  br="$(current_branch)"
  echo "auto: ${br} $(date '+%Y-%m-%d %H:%M')"
}

ensure_upstream_then_push() {
  local br
  br="$(current_branch)"
  if has_upstream_for_current; then
    git push "$G_REMOTE"
  else
    git push -u "$G_REMOTE" "$br"
  fi
}

do_commit_all_and_push() {
  require_remote
  git add -A :/

  if git diff --cached --quiet; then
    info "Nothing staged to commit."
  else
    ensure_identity_if_commit_needed
    git commit -m "$(auto_commit_message)"
  fi

  ensure_upstream_then_push
}

ensure_main_up_to_date() {
  # Avoid merging onto stale main.
  git fetch "$G_REMOTE" >/dev/null 2>&1 || true
  if git show-ref --verify --quiet "refs/remotes/${G_REMOTE}/${G_MAIN_BRANCH}"; then
    local behind
    behind="$(git rev-list --count "${G_MAIN_BRANCH}..${G_REMOTE}/${G_MAIN_BRANCH}" 2>/dev/null || echo 0)"
    if [[ "$behind" =~ ^[0-9]+$ ]] && [[ "$behind" -gt 0 ]]; then
      die "Local ${G_MAIN_BRANCH} is behind ${G_REMOTE}/${G_MAIN_BRANCH} by $behind commits. Run: git switch ${G_MAIN_BRANCH} && git pull --ff-only"
    fi
  fi
}

merge_branch_into_main_no_ff() {
  local feature_branch="$1"
  git show-ref --verify --quiet "refs/heads/${G_MAIN_BRANCH}" || die "Local ${G_MAIN_BRANCH} branch not found."

  info "Switching to ${G_MAIN_BRANCH}"
  git switch "$G_MAIN_BRANCH"

  ensure_main_up_to_date

  info "Merging '$feature_branch' into ${G_MAIN_BRANCH} (no-ff)"
  if ! git merge --no-ff "$feature_branch"; then
    die "Merge failed. Resolve conflicts, then commit the merge (or abort with: git merge --abort)."
  fi

  info "Pushing ${G_MAIN_BRANCH}"
  require_remote
  git push "$G_REMOTE"
}

usage() {
  cat <<EOF
g $G_VERSION - agent-safe git wrapper

Usage:
  g                     Run health checks and show this help
  g c                   Add all (incl deletes), auto-commit with dated message, push current branch
  g b <branch>           Create+switch to new branch, set upstream, create initial commit (allow-empty), push
                        Only if none of A/B/C issues exist on any other branch/worktree
  g m                   Merge workflow:
                        - If current branch != ${G_MAIN_BRANCH}:
                            ensure no A/B/C issues elsewhere,
                            commit+push current branch,
                            merge into ${G_MAIN_BRANCH} (--no-ff),
                            push ${G_MAIN_BRANCH}
                        - If current branch == ${G_MAIN_BRANCH}:
                            if exactly one local branch has commits not merged into ${G_MAIN_BRANCH}, prompt to merge it.

Options:
  --help, -h            Show help
  --version             Show version

Env:
  G_REMOTE=$G_REMOTE
  G_MAIN_BRANCH=$G_MAIN_BRANCH
  G_FETCH=$G_FETCH          (1 => fetch --prune before A/B checks)
  G_STRICT_FSCK=$G_STRICT_FSCK  (0 => skip fsck)

Blocking issues A/B/C:
  A) Other branches are ahead of upstream OR have no upstream set
  B) Other branches have commits not merged into ${G_MAIN_BRANCH}
  C) Other worktrees are dirty
EOF
}

# -----------------------------
# Main
# -----------------------------
health_check

if [[ "${#}" -eq 0 ]]; then
  usage
  exit 0
fi

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --version) echo "$G_VERSION"; exit 0 ;;
esac

cmd="${1:-}"; shift || true

case "$cmd" in
  c)
    do_commit_all_and_push
    ;;

  b)
    [[ "${#}" -eq 1 ]] || die "Branch name required. Usage: g b <branch>"
    new_branch="$1"

    ensure_clean_working_tree
    check_other_branch_activity "$(current_branch)"

    git switch -c "$new_branch"
    ensure_identity_if_commit_needed
    git commit --allow-empty -m "$(auto_commit_message) branch start"

    require_remote
    git push -u "$G_REMOTE" "$new_branch"
    ;;

  m)
    cur="$(current_branch)"
    if [[ "$cur" != "$G_MAIN_BRANCH" ]]; then
      check_other_branch_activity "$cur"
      do_commit_all_and_push
      merge_branch_into_main_no_ff "$cur"
    else
      candidate="$(find_single_outstanding_branch_not_merged_into_main || true)"
      if [[ -z "${candidate:-}" ]]; then
        info "On ${G_MAIN_BRANCH}: nothing to merge (no branches have commits not merged into ${G_MAIN_BRANCH})."
        exit 0
      fi

      # Block A/C on all *other* branches/worktrees; allow B for the candidate itself.
      check_other_branch_activity "$candidate"

      # Prompt reliably even when stdin is piped
      printf "Merge branch '%s' into %s and push %s? [y/N] " "$candidate" "$G_MAIN_BRANCH" "$G_MAIN_BRANCH" >&2
      IFS= read -r ans || ans=""
      if [[ "$ans" =~ ^[Yy]$ ]]; then
        merge_branch_into_main_no_ff "$candidate"
      else
        info "Aborted."
        exit 0
      fi
    fi
    ;;

  *)
    usage
    exit 1
    ;;
esac

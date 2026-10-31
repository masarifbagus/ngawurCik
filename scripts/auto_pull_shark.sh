#!/usr/bin/env bash
#
# auto_pull_shark.sh
# Automates creating + squash-merging sequential pull requests using GitHub CLI.
#
# Usage:
#   ./scripts/auto_pull_shark.sh            # runs 1..128
#   ./scripts/auto_pull_shark.sh 42         # resume from index 42 to 128
#   ./scripts/auto_pull_shark.sh 1 16       # runs 1..16
#
set -euo pipefail

START="${1:-1}"
TOTAL="${2:-128}"
GRIND_FILE=".shark_grind.txt"
SLEEP_SECONDS=1

log()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

trap 'printf "\033[1;31m[ABORTED]\033[0m Script stopped at line %s (index: %s). Resume with: %s %s %s\n" "$LINENO" "${i:-?}" "$0" "${i:-$START}" "$TOTAL" >&2' ERR

# ---------------------------------------------------------------------------
# 1. Initial validation
# ---------------------------------------------------------------------------
command -v git >/dev/null || fail "git is not installed."
command -v gh  >/dev/null || fail "GitHub CLI (gh) is not installed. Install: brew install gh"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "Not inside a git repository."
cd "$(git rev-parse --show-toplevel)"

git remote get-url origin >/dev/null 2>&1 || fail "Remote 'origin' is not configured."

if [[ -n "$(git status --porcelain)" ]]; then
  fail "Working tree is not clean. Commit or stash your changes first."
fi
ok "Git working tree is clean."

gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated. Run: gh auth login"
ok "GitHub CLI is authenticated."

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)"
[[ -n "$DEFAULT_BRANCH" ]] || fail "Could not determine default branch."
ok "Repository: $REPO | Default branch: $DEFAULT_BRANCH"

# Branch protection check (404 = not protected; 403 = feature unavailable on plan -> treat as unprotected)
set +e
PROTECTION_OUTPUT="$(gh api "repos/$REPO/branches/$DEFAULT_BRANCH/protection" 2>&1)"
PROTECTION_STATUS=$?
set -e
if [[ $PROTECTION_STATUS -eq 0 ]]; then
  REQUIRED_REVIEWS="$(gh api "repos/$REPO/branches/$DEFAULT_BRANCH/protection" \
    -q '.required_pull_request_reviews.required_approving_review_count // 0' 2>/dev/null || echo 0)"
  REQUIRED_CHECKS="$(gh api "repos/$REPO/branches/$DEFAULT_BRANCH/protection" \
    -q '(.required_status_checks.contexts // []) | length' 2>/dev/null || echo 0)"
  if [[ "$REQUIRED_REVIEWS" != "0" || "$REQUIRED_CHECKS" != "0" ]]; then
    fail "Branch '$DEFAULT_BRANCH' is protected (required reviews: $REQUIRED_REVIEWS, required checks: $REQUIRED_CHECKS). PRs cannot be merged immediately."
  fi
  log "Branch protection exists but does not require reviews/status checks. Continuing."
elif grep -q "Branch not protected" <<<"$PROTECTION_OUTPUT" || grep -q "HTTP 404" <<<"$PROTECTION_OUTPUT"; then
  ok "No branch protection on '$DEFAULT_BRANCH'."
elif grep -q "HTTP 403" <<<"$PROTECTION_OUTPUT"; then
  log "Branch protection API unavailable (HTTP 403). Assuming unprotected."
else
  fail "Failed to check branch protection: $PROTECTION_OUTPUT"
fi

# Check repo allows squash merge
SQUASH_ALLOWED="$(gh api "repos/$REPO" -q .allow_squash_merge)"
[[ "$SQUASH_ALLOWED" == "true" ]] || fail "Squash merge is disabled in repository settings."

git checkout "$DEFAULT_BRANCH" >/dev/null 2>&1
git pull --ff-only origin "$DEFAULT_BRANCH"

# ---------------------------------------------------------------------------
# 2. Main loop
# ---------------------------------------------------------------------------
log "Starting Pull Shark grind: $START -> $TOTAL"

for (( i=START; i<=TOTAL; i++ )); do
  BRANCH="pull-shark-$i"

  # Clean up leftovers from a previously interrupted run
  git branch -D "$BRANCH" >/dev/null 2>&1 || true

  git checkout -b "$BRANCH" >/dev/null 2>&1
  echo "Shark grind #$i - $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$GRIND_FILE"
  git add "$GRIND_FILE"
  git commit -q -m "chore(shark): grind $i"
  git push -q -u origin "$BRANCH"

  gh pr create \
    --base "$DEFAULT_BRANCH" \
    --head "$BRANCH" \
    --title "Shark grind #$i" \
    --body "Automated grind" >/dev/null

  gh pr merge "$BRANCH" --squash --delete-branch >/dev/null

  # gh may already switch back & delete the local branch; make it idempotent
  git checkout "$DEFAULT_BRANCH" >/dev/null 2>&1
  git pull -q --ff-only origin "$DEFAULT_BRANCH"
  git branch -D "$BRANCH" >/dev/null 2>&1 || true

  printf '\033[1;32m[%d/%d] Completed\033[0m\n' "$i" "$TOTAL"
  sleep "$SLEEP_SECONDS"
done

ok "All done! $((TOTAL - START + 1)) pull requests merged into '$DEFAULT_BRANCH'."


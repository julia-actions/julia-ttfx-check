#!/usr/bin/env bash
# Check out the base and head commits side by side under $RUNNER_TEMP, at paths of equal
# length, and write their locations and labels to $GITHUB_OUTPUT.
set -euo pipefail

work="${RUNNER_TEMP:-/tmp}/julia-ttfx-check"
rm -rf "$work"
# A check that ran earlier in the job left its worktrees registered.
git worktree prune
mkdir -p "$work/src"

head=$(git rev-parse HEAD)
base="${INPUT_BASE:-}"
if [[ -z "$base" ]]; then
    if [[ -n "${PR_BASE:-}" ]]; then
        # On a pull request, actions/checkout checks out the merge commit, whose first
        # parent is the base branch, so the comparison is exactly what merging would change.
        base="$PR_BASE"
    elif [[ -n "${PUSH_BEFORE:-}" && ! "$PUSH_BEFORE" =~ ^0+$ ]]; then
        base="$PUSH_BEFORE"
    else
        base="HEAD^"
    fi
fi

# A shallow checkout lacks the base commit; fetch it on its own.
if [[ "$base" == "HEAD^" ]] && ! git rev-parse -q --verify "HEAD^" >/dev/null; then
    git fetch --no-tags --deepen=1 origin
elif ! git cat-file -e "$base^{commit}" 2>/dev/null; then
    git fetch --no-tags --depth=1 origin "$base" || git fetch --no-tags origin "$base"
fi
base=$(git rev-parse "$base^{commit}")

git worktree add --detach "$work/src/base" "$base" >/dev/null
git worktree add --detach "$work/src/head" "$head" >/dev/null

short() { echo "\`${1:0:7}\`"; }
if [[ -n "${PR_NUMBER:-}" ]]; then
    head_label="#$PR_NUMBER ($(short "$head"))"
else
    head_label=$(short "$head")
fi

mkdir -p "$work/report"
[[ -n "${PR_NUMBER:-}" ]] && echo "$PR_NUMBER" > "$work/report/pr_number"

pkg_path="${INPUT_PATH:-.}"
{
    echo "work=$work"
    echo "out=$work/report"
    echo "base_dir=$work/src/base/$pkg_path"
    echo "head_dir=$work/src/head/$pkg_path"
    echo "base_label=$(short "$base")"
    echo "head_label=$head_label"
} >> "$GITHUB_OUTPUT"

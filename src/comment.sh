#!/usr/bin/env bash
# Create or update the pull request comment of a check from its report directory.
#
# TTFX_REPORT_DIR holds report.md (whose first line is the check's marker), verdict and
# pr_number; TTFX_COMMENT is the mode; TTFX_REPOSITORY is owner/repo; GH_TOKEN the token.
#
# A comment is created only when the mode asks for this verdict. Once a check has a
# comment it is updated on every run, so it never describes an older commit.
set -euo pipefail

dir="$TTFX_REPORT_DIR"
mode="${TTFX_COMMENT:-changes}"
repo="$TTFX_REPOSITORY"
report="$dir/report.md"
[[ -f "$report" && -f "$dir/verdict" && -f "$dir/pr_number" ]] || { echo "No report to comment with"; exit 0; }
verdict=$(cat "$dir/verdict")
pr=$(cat "$dir/pr_number")
[[ "$pr" =~ ^[0-9]+$ ]] || { echo "::warning::Not a pull request number: $pr"; exit 0; }
marker=$(head -n 1 "$report")
[[ "$marker" =~ ^\<\!--\ julia-ttfx-check:[A-Za-z0-9._-]+\ --\>$ ]] || { echo "::error::The report does not start with a check marker"; exit 1; }

# The report of a pull request from a fork is untrusted when this runs from workflow_run:
# only comment on the pull request whose head is the commit that was measured.
if [[ -n "${TTFX_HEAD_SHA:-}" ]]; then
    pr_head=$(gh api "repos/$repo/pulls/$pr" --jq .head.sha)
    [[ "$pr_head" == "$TTFX_HEAD_SHA" ]] || { echo "::error::#$pr is at $pr_head, not the measured $TTFX_HEAD_SHA"; exit 1; }
fi

case "$mode" in
    always) want=1 ;;
    changes) [[ "$verdict" != same ]] && want=1 || want=0 ;;
    regressions) [[ "$verdict" == regression || "$verdict" == mixed ]] && want=1 || want=0 ;;
    improvements) [[ "$verdict" == improvement || "$verdict" == mixed ]] && want=1 || want=0 ;;
    never) exit 0 ;;
    *) echo "::error::Unknown comment mode \`$mode\`"; exit 1 ;;
esac

existing=$(gh api --paginate "repos/$repo/issues/$pr/comments" \
    --jq ".[] | select(.body | startswith(\"$marker\")) | .id" | tail -n 1) || {
    echo "::warning::Could not read the comments of #$pr. For pull requests from forks, post the comment from a workflow_run workflow with the comment action."
    exit 0
}

body=$(jq -Rs '{body: .}' < "$report")
if [[ -n "$existing" ]]; then
    gh api -X PATCH "repos/$repo/issues/comments/$existing" --input - <<< "$body" > /dev/null && {
        echo "Updated comment $existing"; exit 0; }
elif [[ "$want" == 1 ]]; then
    gh api -X POST "repos/$repo/issues/$pr/comments" --input - <<< "$body" > /dev/null && {
        echo "Commented on #$pr"; exit 0; }
else
    echo "Verdict \`$verdict\` does not call for a comment in mode \`$mode\`"
    exit 0
fi
echo "::warning::Could not comment on #$pr (the token may lack permission, as on pull requests from forks). Post the comment from a workflow_run workflow with the comment action."

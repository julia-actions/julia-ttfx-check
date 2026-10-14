#!/usr/bin/env bash
# Tests for src/checkouts.sh and src/comment.sh. Needs git and jq; `gh` is replaced by a
# fake that answers from files and logs the requests.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
src="$here/../src"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0

check() {  # check DESCRIPTION COMMAND...
    local desc=$1; shift
    if "$@"; then echo "ok   $desc"; else echo "FAIL $desc"; failures=$((failures + 1)); fi
}
output() { grep "^$1=" "$GITHUB_OUTPUT" | tail -n 1 | cut -d= -f2-; }

# --- checkouts.sh -------------------------------------------------------------

origin="$tmp/origin"
git init -q -b main "$origin"
git -C "$origin" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
first=$(git -C "$origin" rev-parse HEAD)
git -C "$origin" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
second=$(git -C "$origin" rev-parse HEAD)
git -C "$origin" -c user.name=t -c user.email=t@t commit -q --allow-empty -m three
third=$(git -C "$origin" rev-parse HEAD)

run_checkouts() {  # in a fresh shallow clone, with the given environment
    rm -rf "$tmp/clone" "$tmp/runner"
    git clone -q --depth=1 "file://$origin" "$tmp/clone"
    mkdir -p "$tmp/runner"
    export GITHUB_OUTPUT="$tmp/outputs" RUNNER_TEMP="$tmp/runner"
    : > "$GITHUB_OUTPUT"
    (cd "$tmp/clone" && env "$@" bash "$src/checkouts.sh" 2>/dev/null)
}
at() { git -C "$1" rev-parse HEAD; }

run_checkouts INPUT_BASE= PR_BASE= PR_NUMBER= PUSH_BEFORE=
check "no base given: the previous commit" test "$(at "$(output base_dir)")" == "$second"
check "head is HEAD" test "$(at "$(output head_dir)")" == "$third"
check "label of a push" test "$(output head_label)" == "\`${third:0:7}\`"
check "no pr_number file outside a pull request" test ! -e "$(output out)/pr_number"

run_checkouts INPUT_BASE= PR_BASE="$first" PR_NUMBER=42 PUSH_BEFORE=
check "pull request: its base commit, fetched into a shallow clone" test "$(at "$(output base_dir)")" == "$first"
check "pull request label" test "$(output head_label)" == "#42 (\`${third:0:7}\`)"
check "pr_number file" test "$(cat "$(output out)/pr_number")" == 42

run_checkouts INPUT_BASE= PR_BASE= PR_NUMBER= PUSH_BEFORE=0000000000000000000000000000000000000000
check "a new branch's push falls back to the previous commit" test "$(at "$(output base_dir)")" == "$second"

run_checkouts INPUT_BASE="$first" PR_BASE="$second" PR_NUMBER=1 PUSH_BEFORE=
check "the base input wins" test "$(at "$(output base_dir)")" == "$first"

(cd "$tmp/clone" && env INPUT_BASE="$first" bash "$src/checkouts.sh" 2>/dev/null)
check "a second check in the same job" test "$(at "$(output base_dir)")" == "$first"

run_checkouts INPUT_BASE= PR_BASE= PR_NUMBER= PUSH_BEFORE= INPUT_PATH=sub/Pkg
check "path input" test "$(output head_dir)" == "$tmp/runner/julia-ttfx-check/src/head/sub/Pkg"
b=$(output base_dir); h=$(output head_dir)
check "paths of equal length" test "${#b}" == "${#h}"

# --- comment.sh ---------------------------------------------------------------

bin="$tmp/bin"
mkdir -p "$bin"
cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
# A fake gh: the existing comment id comes from $FAKE_EXISTING, the pull request's head
# from $FAKE_HEAD; writes are logged with their body.
echo "$*" >> "$FAKE_LOG"
case "$*" in
    *"/comments --jq"*) [[ -n "${FAKE_EXISTING:-}" ]] && echo "$FAKE_EXISTING"; exit 0 ;;
    *"/pulls/"*"--jq .head.sha"*) echo "$FAKE_HEAD"; exit 0 ;;
    *"-X PATCH"*|*"-X POST"*) cat >> "$FAKE_LOG"; echo >> "$FAKE_LOG"; exit "${FAKE_WRITE_STATUS:-0}" ;;
esac
exit 1
EOF
chmod +x "$bin/gh"

report_dir="$tmp/report"
mkdir -p "$report_dir"
echo 7 > "$report_dir/pr_number"

run_comment() {  # run_comment MODE VERDICT [ENV...]; prints what the fake gh was asked to write
    local mode=$1 verdict=$2; shift 2
    echo "$verdict" > "$report_dir/verdict"
    export FAKE_LOG="$tmp/gh.log"
    : > "$FAKE_LOG"
    env PATH="$bin:$PATH" TTFX_REPORT_DIR="$report_dir" TTFX_COMMENT="$mode" TTFX_REPOSITORY=o/r \
        FAKE_EXISTING= FAKE_HEAD= TTFX_HEAD_SHA= "$@" bash "$src/comment.sh" > "$tmp/comment.out" 2>&1
    echo $? > "$tmp/comment.status"
    grep -E -- '-X (POST|PATCH)' "$FAKE_LOG" | sed -E 's/^api -X ([A-Z]+) repos\/o\/r\/issues\/(comments\/)?([0-9]+).*/\1 \3/'
}

printf '<!-- julia-ttfx-check:default -->\n### TTFX: report\n' > "$report_dir/report.md"
check "changes, a regression: new comment" test "$(run_comment changes regression)" == "POST 7"
check "changes, no change, no comment yet: nothing" test -z "$(run_comment changes same)"
check "changes, no change, a comment already: updated" test "$(run_comment changes same FAKE_EXISTING=99)" == "PATCH 99"
check "always, no change: new comment" test "$(run_comment always same)" == "POST 7"
check "regressions, an improvement: nothing" test -z "$(run_comment regressions improvement)"
check "regressions, mixed: new comment" test "$(run_comment regressions mixed)" == "POST 7"
check "improvements, an improvement: new comment" test "$(run_comment improvements improvement)" == "POST 7"
check "improvements, a regression, a comment already: updated" test "$(run_comment improvements regression FAKE_EXISTING=5)" == "PATCH 5"
check "never: nothing" test -z "$(run_comment never regression FAKE_EXISTING=5)"
run_comment changes regression > /dev/null
check "the body is the report" grep -q '"body": *"<!-- julia-ttfx-check:default -->' "$tmp/gh.log"
check "the head matches: comment" test "$(run_comment changes regression TTFX_HEAD_SHA=abc FAKE_HEAD=abc)" == "POST 7"
check "the head does not match: nothing" test -z "$(run_comment changes regression TTFX_HEAD_SHA=abc FAKE_HEAD=def)"
check "the head does not match: an error" test "$(cat "$tmp/comment.status")" != 0
run_comment changes regression FAKE_WRITE_STATUS=1 > /dev/null
check "a refused write warns and does not fail" grep -q '::warning::' "$tmp/comment.out"
check "a refused write does not fail" test "$(cat "$tmp/comment.status")" == 0
run_comment sometimes regression > /dev/null
check "an unknown mode fails" test "$(cat "$tmp/comment.status")" != 0

printf 'no marker\n' > "$report_dir/report.md"
check "a report without a marker: nothing" test -z "$(run_comment always regression)"
printf '<!-- julia-ttfx-check:a" -->\n' > "$report_dir/report.md"
check "a malformed marker: nothing" test -z "$(run_comment always regression)"
printf '<!-- julia-ttfx-check:default -->\n' > "$report_dir/report.md"
echo "7; rm -rf /" > "$report_dir/pr_number"
check "a malformed pull request number: nothing" test -z "$(run_comment always regression)"

echo
[[ $failures == 0 ]] && echo "all passed" || { echo "$failures failed"; exit 1; }

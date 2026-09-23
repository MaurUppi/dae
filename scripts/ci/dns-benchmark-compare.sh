#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[dns-bench] %s\n' "$*"
}

die() {
  printf '[dns-bench] ERROR: %s\n' "$*" >&2
  exit 1
}

ERROR_TAIL_LINES=80

# print_error_tail writes the last ERROR_TAIL_LINES of "$1" to stderr.
# A missing file is ignored; the caller dies with its own message.
print_error_tail() {
  local file="$1"
  tail -n "$ERROR_TAIL_LINES" "$file" >&2 || true
}

if ! command -v git >/dev/null 2>&1; then
  die "git is required"
fi
if ! command -v go >/dev/null 2>&1; then
  die "go is required"
fi
if ! command -v benchstat >/dev/null 2>&1; then
  die "benchstat is required (go install golang.org/x/perf/cmd/benchstat@latest)"
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

BASE_REF="${1:-${BASE_REF:-origin/main}}"
HEAD_REF="${2:-${HEAD_REF:-HEAD}}"
BASE_COMMIT_STRATEGY="${BASE_COMMIT_STRATEGY:-merge-base}"
BENCH_PACKAGE="${BENCH_PACKAGE:-./control}"
BENCH_FILTER="${BENCH_FILTER:-^BenchmarkDnsCache_}"
BENCH_COUNT="${BENCH_COUNT:-3}"
BENCH_TIME="${BENCH_TIME:-200ms}"
ARTIFACT_DIR="${ARTIFACT_DIR:-bench-artifacts}"
BENCH_OVERLAY_DIR="${BENCH_OVERLAY_DIR:-}"
BENCH_EXCLUDE_TEST_FILES="${BENCH_EXCLUDE_TEST_FILES:-}"
KEEP_WORKTREES="${KEEP_WORKTREES:-0}"
WORKTREE_ROOT="${WORKTREE_ROOT:-$(mktemp -d -t dae-dns-bench-XXXXXX)}"

BASE_WT="$WORKTREE_ROOT/base"
HEAD_WT="$WORKTREE_ROOT/head"

mkdir -p "$ARTIFACT_DIR"
ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd)"
# A marker left by an earlier run is not evidence for this run.
rm -f "$ARTIFACT_DIR/skipped_base_incompatible"

cleanup() {
  if [[ "$KEEP_WORKTREES" == "1" ]]; then
    log "keeping worktrees at $WORKTREE_ROOT"
    return
  fi
  git worktree remove "$BASE_WT" --force >/dev/null 2>&1 || true
  git worktree remove "$HEAD_WT" --force >/dev/null 2>&1 || true
  rm -rf "$WORKTREE_ROOT"
}
trap cleanup EXIT

resolve_ref() {
  local ref="$1"
  if git rev-parse --verify "${ref}^{commit}" >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$ref" == origin/* ]]; then
    local branch="${ref#origin/}"
    log "fetching missing ref $ref from origin/$branch"
    git fetch --no-tags origin "$branch" >/dev/null 2>&1 || true
  else
    log "fetching missing ref $ref from origin"
    git fetch --no-tags origin "$ref" >/dev/null 2>&1 || true
  fi
  git rev-parse --verify "${ref}^{commit}" >/dev/null 2>&1
}

resolve_ref "$BASE_REF" || die "cannot resolve base ref: $BASE_REF"
resolve_ref "$HEAD_REF" || die "cannot resolve head ref: $HEAD_REF"

case "$BASE_COMMIT_STRATEGY" in
  merge-base)
    BASE_COMMIT="$(git merge-base "$BASE_REF" "$HEAD_REF")"
    ;;
  exact)
    BASE_COMMIT="$(git rev-parse "$BASE_REF")"
    ;;
  *)
    die "unsupported BASE_COMMIT_STRATEGY: $BASE_COMMIT_STRATEGY (expected merge-base|exact)"
    ;;
esac
HEAD_COMMIT="$(git rev-parse "$HEAD_REF")"

log "base ref: $BASE_REF ($BASE_COMMIT)"
log "head ref: $HEAD_REF ($HEAD_COMMIT)"

git worktree add --detach "$BASE_WT" "$BASE_COMMIT" >/dev/null
git worktree add --detach "$HEAD_WT" "$HEAD_COMMIT" >/dev/null

prepare_tree() {
  local wt="$1"
  (
    cd "$wt"
    git submodule update --init --recursive >/dev/null 2>&1 || true
    export GOWORK=off
    export GOFLAGS="${GOFLAGS:-} -buildvcs=false"
    export BPF_CLANG="${BPF_CLANG:-clang}"
    export BPF_STRIP_FLAG="${BPF_STRIP_FLAG:--no-strip}"
    export BPF_CFLAGS="${BPF_CFLAGS:--O2 -Wall -Werror -DMAX_MATCH_SET_LEN=1024}"
    export BPF_TARGET="${BPF_TARGET:-bpfel}"
    if [[ "$BENCH_PACKAGE" == "./control"* || "$BENCH_PACKAGE" == "control"* ]]; then
      go generate ./control/control.go >/dev/null
    fi
  )
}

apply_overlay() {
  local wt="$1"
  if [[ -z "$BENCH_OVERLAY_DIR" ]]; then
    return 0
  fi
  local overlay_abs="$BENCH_OVERLAY_DIR"
  if [[ ! -d "$overlay_abs" ]]; then
    die "overlay dir does not exist: $overlay_abs"
  fi
  while IFS= read -r src; do
    local rel="${src#$overlay_abs/}"
    local dst="$wt/$rel"
    mkdir -p "$(dirname "$dst")"
    # Strip "//go:build ignore" tag added to prevent go test ./... from picking
    # up the overlay file in its source directory where package types are absent.
    grep -v '^//go:build ignore$' "$src" > "$dst"
  done < <(find "$overlay_abs" -type f | sort)
}

exclude_test_files() {
  local wt="$1"
  if [[ -z "$BENCH_EXCLUDE_TEST_FILES" ]]; then
    return 0
  fi
  IFS=',' read -r -a patterns <<<"$BENCH_EXCLUDE_TEST_FILES"
  (
    cd "$wt"
    shopt -s nullglob
    : > .bench_excluded_files
    for raw in "${patterns[@]}"; do
      pat="$(echo "$raw" | xargs)"
      [[ -z "$pat" ]] && continue
      for f in $pat; do
        [[ -f "$f" ]] || continue
        mv "$f" "${f}.bench_disabled"
        echo "$f" >> .bench_excluded_files
      done
    done
  )
}

# list_benchmarks writes matching benchmark names, one per line, to $out.
# When $3 is non-empty, go test -list stderr is copied there.
#
# Called as `list_benchmarks ... || status=$?`, which disables errexit for
# this function and its subshell. Every step checks its own status.
#
# Contract:
#   return 0
#     go test -list succeeded. $out may be empty when BENCH_FILTER matches
#     nothing (grep exit 1). grep exit 2 or higher is an internal error.
#   return <status>
#     Only `go test -list` failed, with that command's own status. Callers
#     may treat a returned non-zero status as "the package did not compile".
#   die (exit 1, not returned)
#     Any other failure: entering the worktree, mktemp, cp, awk|sort, or
#     writing $out. Internal errors are fatal for both base and head, so a
#     caller cannot report them as a base-incompatible skip.
# The worktree step is `cd "$wt" || exit 1`, so go test cannot run in the
# wrong directory. That subshell status is 1, the same code go test uses, so
# the subshell records a flag and the function dies instead of returning it.
list_benchmarks() {
  local wt="$1"
  local out="$2"
  local err_file="${3:-}"
  local raw err_tmp status all_tmp grep_status cd_failed
  cd_failed="$WORKTREE_ROOT/list-benchmarks-cd-failed"
  rm -f "$cd_failed" || die "list_benchmarks: cannot clear worktree flag"
  raw="$(mktemp "$WORKTREE_ROOT/bench-list.XXXXXX")" || die "list_benchmarks: mktemp failed"
  err_tmp="$(mktemp "$WORKTREE_ROOT/bench-list-err.XXXXXX")" || die "list_benchmarks: mktemp failed"
  status=0
  (
    cd "$wt" || {
      touch "$cd_failed" || exit 1
      exit 1
    }
    export GOWORK=off
    go test "$BENCH_PACKAGE" -run '^$' -list '^Benchmark'
  ) >"$raw" 2>"$err_tmp" || status=$?
  if [[ -n "$err_file" ]]; then
    cp "$err_tmp" "$err_file" || die "list_benchmarks: cannot write $err_file"
  fi
  rm -f "$err_tmp" || die "list_benchmarks: cannot remove $err_tmp"
  if [[ -f "$cd_failed" ]]; then
    die "list_benchmarks: cannot enter worktree $wt"
  fi
  if [[ "$status" -ne 0 ]]; then
    rm -f "$raw" || die "list_benchmarks: cannot remove $raw"
    return "$status"
  fi
  all_tmp="$(mktemp "$WORKTREE_ROOT/bench-list-names.XXXXXX")" || die "list_benchmarks: mktemp failed"
  # pipefail is on: awk or sort failing makes the pipeline fail.
  awk '/^Benchmark/ {print $1}' "$raw" | sort -u >"$all_tmp" \
    || die "list_benchmarks: failed to collect benchmark names from $wt"
  rm -f "$raw" || die "list_benchmarks: cannot remove $raw"
  if [[ -n "$BENCH_FILTER" ]]; then
    grep_status=0
    grep -E "$BENCH_FILTER" "$all_tmp" >"$out" || grep_status=$?
    if [[ "$grep_status" -gt 1 ]]; then
      die "list_benchmarks: filter failed for $out (grep status $grep_status)"
    fi
  else
    cp "$all_tmp" "$out" || die "list_benchmarks: cannot write $out"
  fi
  rm -f "$all_tmp" || die "list_benchmarks: cannot remove $all_tmp"
}

run_benchmarks() {
  local wt="$1"
  local names_file="$2"
  local output_file="$3"
  if [[ ! -s "$names_file" ]]; then
    : >"$output_file"
    return 0
  fi
  local regex
  regex="$(paste -sd'|' "$names_file")"
  (
    cd "$wt"
    export GOWORK=off
    export GOFLAGS="${GOFLAGS:-} -buildvcs=false"
    go test "$BENCH_PACKAGE" \
      -run '^$' \
      -bench "^(${regex})$" \
      -benchmem \
      -count "$BENCH_COUNT" \
      -benchtime "$BENCH_TIME" \
      | tee "$output_file"
  )
}

prepare_tree "$BASE_WT"
prepare_tree "$HEAD_WT"
apply_overlay "$BASE_WT"
apply_overlay "$HEAD_WT"
exclude_test_files "$BASE_WT"
exclude_test_files "$HEAD_WT"

BASE_LIST="$ARTIFACT_DIR/base_benchmarks.txt"
HEAD_LIST="$ARTIFACT_DIR/head_benchmarks.txt"
COMMON_LIST="$ARTIFACT_DIR/common_benchmarks.txt"
HEAD_ONLY_LIST="$ARTIFACT_DIR/head_only_benchmarks.txt"
BASE_COMMON_OUT="$ARTIFACT_DIR/base_common.txt"
HEAD_COMMON_OUT="$ARTIFACT_DIR/head_common.txt"
HEAD_ONLY_OUT="$ARTIFACT_DIR/head_only.txt"
BENCHSTAT_OUT="$ARTIFACT_DIR/benchstat_common.txt"
REPORT_MD="$ARTIFACT_DIR/report.md"

base_list_status=0
list_benchmarks "$BASE_WT" "$BASE_LIST" "$ARTIFACT_DIR/base_list_error.txt" || base_list_status=$?
head_list_status=0
list_benchmarks "$HEAD_WT" "$HEAD_LIST" "$ARTIFACT_DIR/head_list_error.txt" || head_list_status=$?
if [[ "$head_list_status" -ne 0 ]]; then
  printf '[dns-bench] head list error (tail):\n' >&2
  print_error_tail "$ARTIFACT_DIR/head_list_error.txt"
  die "head cannot compile the benchmark set for $BENCH_PACKAGE (see $ARTIFACT_DIR/head_list_error.txt)"
fi

if [[ "$base_list_status" -ne 0 ]]; then
  printf '::warning::BENCH_PACKAGE=%s base cannot compile the benchmark set\n' "$BENCH_PACKAGE"
  printf '[dns-bench] base list error (tail):\n' >&2
  print_error_tail "$ARTIFACT_DIR/base_list_error.txt"
  cp "$HEAD_LIST" "$HEAD_ONLY_LIST"
  : >"$COMMON_LIST"
  run_benchmarks "$HEAD_WT" "$HEAD_ONLY_LIST" "$HEAD_ONLY_OUT"
  {
    echo "## DNS Benchmark Compare"
    echo
    echo "- Status: skipped (base incompatible)"
    echo "- Base: \`$BASE_REF\` (\`$BASE_COMMIT\`)"
    echo "- Head: \`$HEAD_REF\` (\`$HEAD_COMMIT\`)"
    echo "- Package: \`$BENCH_PACKAGE\`"
    echo "- Benchmark filter: \`$BENCH_FILTER\`"
    echo
    echo "### Base list error (tail)"
    echo
    echo '```text'
    tail -n "$ERROR_TAIL_LINES" "$ARTIFACT_DIR/base_list_error.txt" || true
    echo '```'
    echo
    echo "### Head-only benchmarks"
    echo
    echo '```text'
    cat "$HEAD_ONLY_OUT"
    echo '```'
  } >"$REPORT_MD"
  : >"$ARTIFACT_DIR/skipped_base_incompatible"
  log "base cannot compile $BENCH_PACKAGE; comparison skipped"
  exit 0
fi

comm -12 "$BASE_LIST" "$HEAD_LIST" >"$COMMON_LIST" || true
comm -13 "$BASE_LIST" "$HEAD_LIST" >"$HEAD_ONLY_LIST" || true

run_benchmarks "$BASE_WT" "$COMMON_LIST" "$BASE_COMMON_OUT"
run_benchmarks "$HEAD_WT" "$COMMON_LIST" "$HEAD_COMMON_OUT"
run_benchmarks "$HEAD_WT" "$HEAD_ONLY_LIST" "$HEAD_ONLY_OUT"

if [[ -s "$COMMON_LIST" ]]; then
  benchstat "$BASE_COMMON_OUT" "$HEAD_COMMON_OUT" | tee "$BENCHSTAT_OUT"
else
  : >"$BENCHSTAT_OUT"
fi

{
  echo "## DNS Benchmark Compare"
  echo
  echo "- Base: \`$BASE_REF\` (\`$BASE_COMMIT\`)"
  echo "- Head: \`$HEAD_REF\` (\`$HEAD_COMMIT\`)"
  echo "- Package: \`$BENCH_PACKAGE\`"
  echo "- Benchmark filter: \`$BENCH_FILTER\`"
  echo "- Common benchmarks: $(wc -l <"$COMMON_LIST" | xargs)"
  echo "- Head-only benchmarks: $(wc -l <"$HEAD_ONLY_LIST" | xargs)"
  echo
  if [[ -s "$BENCHSTAT_OUT" ]]; then
    echo "### benchstat"
    echo
    echo '```text'
    cat "$BENCHSTAT_OUT"
    echo '```'
  else
    echo "No common benchmarks matched."
  fi
  if [[ -s "$HEAD_ONLY_OUT" ]]; then
    echo
    echo "### Head-only benchmarks"
    echo
    echo '```text'
    cat "$HEAD_ONLY_OUT"
    echo '```'
  fi
} >"$REPORT_MD"

log "report generated at $REPORT_MD"

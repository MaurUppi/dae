#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[dns-bench] %s\n' "$*"
}

die() {
  printf '[dns-bench] ERROR: %s\n' "$*" >&2
  exit 1
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
BENCH_PACKAGE="${BENCH_PACKAGE:-./control}"
BENCH_FILTER="${BENCH_FILTER:-^Benchmark(AsyncCache|SingleflightOverhead|HighQpsScenario|RealisticDnsQuery|DnsController_Singleflight|PipelinedConn_Concurrent|PipelinedConn_Sequential)$}"
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

BASE_COMMIT="$(git merge-base "$BASE_REF" "$HEAD_REF")"
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
    cp "$src" "$dst"
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

list_benchmarks() {
  local wt="$1"
  local out="$2"
  local all_tmp="$out.all"
  (
    cd "$wt"
    export GOWORK=off
    go test "$BENCH_PACKAGE" -run '^$' -list '^Benchmark' \
      | awk '/^Benchmark/ {print $1}' \
      | sort -u >"$all_tmp"
  )
  if [[ -n "$BENCH_FILTER" ]]; then
    grep -E "$BENCH_FILTER" "$all_tmp" >"$out" || true
  else
    cp "$all_tmp" "$out"
  fi
  rm -f "$all_tmp"
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

list_benchmarks "$BASE_WT" "$BASE_LIST"
list_benchmarks "$HEAD_WT" "$HEAD_LIST"

comm -12 "$BASE_LIST" "$HEAD_LIST" >"$COMMON_LIST" || true
comm -13 "$BASE_LIST" "$HEAD_LIST" >"$HEAD_ONLY_LIST" || true

BASE_COMMON_OUT="$ARTIFACT_DIR/base_common.txt"
HEAD_COMMON_OUT="$ARTIFACT_DIR/head_common.txt"
HEAD_ONLY_OUT="$ARTIFACT_DIR/head_only.txt"
BENCHSTAT_OUT="$ARTIFACT_DIR/benchstat_common.txt"

run_benchmarks "$BASE_WT" "$COMMON_LIST" "$BASE_COMMON_OUT"
run_benchmarks "$HEAD_WT" "$COMMON_LIST" "$HEAD_COMMON_OUT"
run_benchmarks "$HEAD_WT" "$HEAD_ONLY_LIST" "$HEAD_ONLY_OUT"

if [[ -s "$COMMON_LIST" ]]; then
  benchstat "$BASE_COMMON_OUT" "$HEAD_COMMON_OUT" | tee "$BENCHSTAT_OUT"
else
  printf 'No common benchmarks matched filter: %s\n' "$BENCH_FILTER" >"$BENCHSTAT_OUT"
fi

REPORT_MD="$ARTIFACT_DIR/report.md"
{
  echo "## DNS Benchmark Compare"
  echo
  echo "- Base ref: \`$BASE_REF\`"
  echo "- Base commit (merge-base): \`$BASE_COMMIT\`"
  echo "- Head ref: \`$HEAD_REF\`"
  echo "- Head commit: \`$HEAD_COMMIT\`"
  echo "- Package: \`$BENCH_PACKAGE\`"
  echo "- Benchmark filter: \`$BENCH_FILTER\`"
  echo "- Benchmark count: \`$BENCH_COUNT\`"
  echo "- Benchmark time: \`$BENCH_TIME\`"
  if [[ -n "$BENCH_OVERLAY_DIR" ]]; then
    echo "- Overlay dir: \`$BENCH_OVERLAY_DIR\`"
  fi
  if [[ -n "$BENCH_EXCLUDE_TEST_FILES" ]]; then
    echo "- Excluded test files: \`$BENCH_EXCLUDE_TEST_FILES\`"
  fi
  echo
  echo "### Common Benchmarks"
  echo
  echo "- Count: $(wc -l <"$COMMON_LIST" | tr -d '[:space:]')"
  if [[ -s "$COMMON_LIST" ]]; then
    echo
    echo '```text'
    cat "$BENCHSTAT_OUT"
    echo '```'
  else
    echo "- None"
  fi
  echo
  echo "### Head-Only Benchmarks"
  echo
  echo "- Count: $(wc -l <"$HEAD_ONLY_LIST" | tr -d '[:space:]')"
  if [[ -s "$HEAD_ONLY_LIST" ]]; then
    while IFS= read -r b; do
      echo "- \`$b\`"
    done <"$HEAD_ONLY_LIST"
  else
    echo "- None"
  fi
  echo
  echo "### Output Files"
  echo
  echo "- \`$BENCHSTAT_OUT\`"
  echo "- \`$BASE_COMMON_OUT\`"
  echo "- \`$HEAD_COMMON_OUT\`"
  echo "- \`$HEAD_ONLY_OUT\`"
} >"$REPORT_MD"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat "$REPORT_MD" >>"$GITHUB_STEP_SUMMARY"
fi

log "report generated at $REPORT_MD"

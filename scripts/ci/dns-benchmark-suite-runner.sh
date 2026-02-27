#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[dns-suite-runner] %s\n' "$*"
}

die() {
  printf '[dns-suite-runner] ERROR: %s\n' "$*" >&2
  exit 1
}

if ! command -v git >/dev/null 2>&1; then
  die "git is required"
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

if [[ ! -f scripts/ci/dns-benchmark-suites.sh ]]; then
  die "missing scripts/ci/dns-benchmark-suites.sh"
fi
source scripts/ci/dns-benchmark-suites.sh

BASE_REF="${1:-${BASE_REF:-origin/main}}"
HEAD_REF="${2:-${HEAD_REF:-HEAD}}"
ARTIFACT_ROOT="${ARTIFACT_DIR:-bench-artifacts}"
PROFILE="${DNS_BENCH_PROFILE:-quick}"
SUITES_CSV="${DNS_BENCH_SUITES:-}"
BENCH_COUNT="${BENCH_COUNT:-3}"
BENCH_TIME="${BENCH_TIME:-200ms}"
BASE_COMMIT_STRATEGY="${BASE_COMMIT_STRATEGY:-merge-base}"
COMPARE_SCRIPT="${DNS_BENCH_COMPARE_SCRIPT:-scripts/ci/dns-benchmark-compare.sh}"
SKIP_GROUP_PREPARE="${DNS_BENCH_SKIP_PREPARE:-0}"

mkdir -p "$ARTIFACT_ROOT"
ARTIFACT_ROOT="$(cd "$ARTIFACT_ROOT" && pwd)"

if [[ ! -x "$COMPARE_SCRIPT" ]]; then
  chmod +x "$COMPARE_SCRIPT"
fi

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

prepare_tree() {
  local wt="$1"
  local pkg="$2"
  (
    cd "$wt"
    git submodule update --init --recursive >/dev/null 2>&1 || true
    export GOWORK=off
    export GOFLAGS="${GOFLAGS:-} -buildvcs=false"
    export BPF_CLANG="${BPF_CLANG:-clang}"
    export BPF_STRIP_FLAG="${BPF_STRIP_FLAG:--no-strip}"
    export BPF_CFLAGS="${BPF_CFLAGS:--O2 -Wall -Werror -DMAX_MATCH_SET_LEN=1024}"
    export BPF_TARGET="${BPF_TARGET:-bpfel}"
    if [[ "$pkg" == "./control"* || "$pkg" == "control"* ]]; then
      go generate ./control/control.go >/dev/null
    fi
  )
}

apply_overlay() {
  local wt="$1"
  local overlay_abs="$2"
  if [[ -z "$overlay_abs" ]]; then
    return 0
  fi
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
  local excludes_csv="$2"
  if [[ -z "$excludes_csv" ]]; then
    return 0
  fi
  IFS=',' read -r -a patterns <<<"$excludes_csv"
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

declare -a suites=()
if [[ -n "$SUITES_CSV" ]]; then
  IFS=',' read -r -a raw_suites <<<"$SUITES_CSV"
  for raw in "${raw_suites[@]}"; do
    suite="$(echo "$raw" | xargs)"
    [[ -z "$suite" ]] && continue
    suites+=("$suite")
  done
else
  suites_string="$(dns_bench_profile_suites "$PROFILE")" || die "unknown DNS_BENCH_PROFILE: $PROFILE"
  read -r -a suites <<<"$suites_string"
fi

[[ ${#suites[@]} -gt 0 ]] || die "no benchmark suites selected"

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

declare -A suite_pkg=()
declare -A suite_filter=()
declare -A suite_exclude=()
declare -A suite_overlay=()
declare -A suite_group_key=()
declare -A seen_group_key=()
declare -a group_keys=()

for suite in "${suites[@]}"; do
  pkg="$(dns_bench_suite_package "$suite")" || die "unknown suite package mapping: $suite"
  filter="$(dns_bench_suite_filter "$suite")" || die "unknown suite filter mapping: $suite"
  exclude="$(dns_bench_suite_exclude "$suite")" || die "unknown suite exclude mapping: $suite"
  overlay_rel="$(dns_bench_suite_overlay "$suite")" || die "unknown suite overlay mapping: $suite"
  overlay=""
  if [[ -n "$overlay_rel" ]]; then
    overlay="$REPO_ROOT/$overlay_rel"
  fi

  key="$pkg|$exclude|$overlay"
  suite_pkg["$suite"]="$pkg"
  suite_filter["$suite"]="$filter"
  suite_exclude["$suite"]="$exclude"
  suite_overlay["$suite"]="$overlay"
  suite_group_key["$suite"]="$key"

  if [[ -z "${seen_group_key[$key]:-}" ]]; then
    seen_group_key["$key"]=1
    group_keys+=("$key")
  fi
done

declare -A group_base_wt=()
declare -A group_head_wt=()
declare -a group_roots=()

cleanup_group_worktrees() {
  for key in "${group_keys[@]}"; do
    base_wt="${group_base_wt[$key]:-}"
    head_wt="${group_head_wt[$key]:-}"
    if [[ -n "$base_wt" ]]; then
      git worktree remove "$base_wt" --force >/dev/null 2>&1 || true
    fi
    if [[ -n "$head_wt" ]]; then
      git worktree remove "$head_wt" --force >/dev/null 2>&1 || true
    fi
  done
  for root in "${group_roots[@]}"; do
    rm -rf "$root" >/dev/null 2>&1 || true
  done
}
trap cleanup_group_worktrees EXIT

for key in "${group_keys[@]}"; do
  IFS='|' read -r pkg exclude overlay <<<"$key"

  group_root="$(mktemp -d -t dae-dns-suite-XXXXXX)"
  base_wt="$group_root/base"
  head_wt="$group_root/head"
  group_roots+=("$group_root")

  log "preparing suite-group key=$key"
  git worktree add --detach "$base_wt" "$BASE_COMMIT" >/dev/null
  git worktree add --detach "$head_wt" "$HEAD_COMMIT" >/dev/null

  if [[ "$SKIP_GROUP_PREPARE" == "1" ]]; then
    log "skip group prepare for key=$key (DNS_BENCH_SKIP_PREPARE=1)"
  else
    prepare_tree "$base_wt" "$pkg"
    prepare_tree "$head_wt" "$pkg"
    apply_overlay "$base_wt" "$overlay"
    apply_overlay "$head_wt" "$overlay"
    exclude_test_files "$base_wt" "$exclude"
    exclude_test_files "$head_wt" "$exclude"
  fi

  group_base_wt["$key"]="$base_wt"
  group_head_wt["$key"]="$head_wt"
done

overall=0
for suite in "${suites[@]}"; do
  pkg="${suite_pkg[$suite]}"
  filter="${suite_filter[$suite]}"
  exclude="${suite_exclude[$suite]}"
  overlay="${suite_overlay[$suite]}"
  key="${suite_group_key[$suite]}"

  base_wt="${group_base_wt[$key]}"
  head_wt="${group_head_wt[$key]}"

  suite_dir="$ARTIFACT_ROOT/$suite"
  mkdir -p "$suite_dir"

  log "running suite=$suite package=$pkg"
  set +e
  BENCH_PACKAGE="$pkg" \
  BENCH_FILTER="$filter" \
  BENCH_OVERLAY_DIR="$overlay" \
  BENCH_EXCLUDE_TEST_FILES="$exclude" \
  BASE_WT="$base_wt" \
  HEAD_WT="$head_wt" \
  ARTIFACT_DIR="$suite_dir" \
  BENCH_COUNT="$BENCH_COUNT" \
  BENCH_TIME="$BENCH_TIME" \
  BASE_COMMIT_STRATEGY="$BASE_COMMIT_STRATEGY" \
  "$COMPARE_SCRIPT" "$BASE_REF" "$HEAD_REF" \
    2>&1 | tee "$suite_dir/run.log"
  status=${PIPESTATUS[0]}
  set -e

  if [[ $status -ne 0 && ! -f "$suite_dir/report.md" ]]; then
    {
      echo "## DNS Benchmark Compare ($suite)"
      echo
      echo "- Status: failed"
      echo "- Exit code: \`$status\`"
      echo "- Base ref: \`$BASE_REF\`"
      echo "- Head ref: \`$HEAD_REF\`"
      echo "- Base strategy: \`$BASE_COMMIT_STRATEGY\`"
      echo "- Package: \`$pkg\`"
      echo
      echo "### Failure Log (tail)"
      echo
      echo '```text'
      tail -n 200 "$suite_dir/run.log" || true
      echo '```'
    } >"$suite_dir/report.md"
  fi

  echo "$status" >"$suite_dir/status.txt"
  if [[ $status -ne 0 ]]; then
    overall=1
  fi
done

REPORT_MD="$ARTIFACT_ROOT/report.md"
{
  echo "## DNS Benchmark Compare"
  echo
  echo "- Base ref: \`$BASE_REF\`"
  echo "- Head ref: \`$HEAD_REF\`"
  echo "- Base strategy: \`$BASE_COMMIT_STRATEGY\`"
  if [[ -n "$SUITES_CSV" ]]; then
    echo "- Suite selection: \`$SUITES_CSV\`"
  else
    echo "- Suite profile: \`$PROFILE\`"
  fi
  echo "- Benchmark count: \`$BENCH_COUNT\`"
  echo "- Benchmark time: \`$BENCH_TIME\`"
  echo
  echo "### Suite Status"
  echo
  for suite in "${suites[@]}"; do
    status="$(cat "$ARTIFACT_ROOT/$suite/status.txt" 2>/dev/null || echo 1)"
    echo "- $suite: $([[ "$status" == "0" ]] && echo 'success' || echo 'failed')"
  done
  for suite in "${suites[@]}"; do
    echo
    echo "### $suite"
    echo
    if [[ -f "$ARTIFACT_ROOT/$suite/report.md" ]]; then
      cat "$ARTIFACT_ROOT/$suite/report.md"
    else
      echo "_No report generated_"
    fi
  done
} >"$REPORT_MD"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat "$REPORT_MD" >>"$GITHUB_STEP_SUMMARY"
fi

log "aggregated report generated at $REPORT_MD"
exit "$overall"

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

mkdir -p "$ARTIFACT_ROOT"
ARTIFACT_ROOT="$(cd "$ARTIFACT_ROOT" && pwd)"

if [[ ! -x scripts/ci/dns-benchmark-compare.sh ]]; then
  chmod +x scripts/ci/dns-benchmark-compare.sh
fi

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

overall=0
for suite in "${suites[@]}"; do
  pkg="$(dns_bench_suite_package "$suite")" || die "unknown suite package mapping: $suite"
  filter="$(dns_bench_suite_filter "$suite")" || die "unknown suite filter mapping: $suite"
  exclude="$(dns_bench_suite_exclude "$suite")" || die "unknown suite exclude mapping: $suite"
  overlay_rel="$(dns_bench_suite_overlay "$suite")" || die "unknown suite overlay mapping: $suite"
  overlay=""
  if [[ -n "$overlay_rel" ]]; then
    overlay="$REPO_ROOT/$overlay_rel"
  fi

  suite_dir="$ARTIFACT_ROOT/$suite"
  mkdir -p "$suite_dir"

  log "running suite=$suite package=$pkg"
  set +e
  BENCH_PACKAGE="$pkg" \
  BENCH_FILTER="$filter" \
  BENCH_OVERLAY_DIR="$overlay" \
  BENCH_EXCLUDE_TEST_FILES="$exclude" \
  ARTIFACT_DIR="$suite_dir" \
  BENCH_COUNT="$BENCH_COUNT" \
  BENCH_TIME="$BENCH_TIME" \
  BASE_COMMIT_STRATEGY="$BASE_COMMIT_STRATEGY" \
  ./scripts/ci/dns-benchmark-compare.sh "$BASE_REF" "$HEAD_REF" \
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

#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"
source scripts/ci/dns-benchmark-suites.sh

TMP_DIR="$(mktemp -d)"
LOG_FILE="$TMP_DIR/compare-calls.log"
ARTIFACT_DIR="$TMP_DIR/artifacts"
mkdir -p "$ARTIFACT_DIR"

ORIGINAL_COMPARE="scripts/ci/dns-benchmark-compare.sh"
BACKUP_COMPARE="$TMP_DIR/dns-benchmark-compare.sh.bak"
cp "$ORIGINAL_COMPARE" "$BACKUP_COMPARE"

restore() {
  cp "$BACKUP_COMPARE" "$ORIGINAL_COMPARE"
}
trap restore EXIT

cat >"$ORIGINAL_COMPARE" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
suite="$(basename "${ARTIFACT_DIR:-unknown}")"
{
  printf 'suite=%s ' "$suite"
  printf 'pkg=%s ' "${BENCH_PACKAGE:-}"
  printf 'overlay=%s ' "${BENCH_OVERLAY_DIR:-}"
  printf 'exclude=%s ' "${BENCH_EXCLUDE_TEST_FILES:-}"
  printf 'base_wt=%s ' "${BASE_WT:-}"
  printf 'head_wt=%s\n' "${HEAD_WT:-}"
} >> "${DNS_BENCH_TEST_LOG:?}"
mkdir -p "${ARTIFACT_DIR:?}"
echo "stub report for $suite" > "${ARTIFACT_DIR}/report.md"
exit 0
STUB
chmod +x "$ORIGINAL_COMPARE"

DNS_BENCH_TEST_LOG="$LOG_FILE" \
DNS_BENCH_PROFILE="dns-module" \
DNS_BENCH_SKIP_PREPARE=1 \
BENCH_COUNT=1 \
BENCH_TIME=10ms \
ARTIFACT_DIR="$ARTIFACT_DIR" \
./scripts/ci/dns-benchmark-suite-runner.sh HEAD HEAD >/dev/null

line_count="$(wc -l <"$LOG_FILE" | tr -d '[:space:]')"
read -r -a expected_suites <<<"$(dns_bench_profile_suites dns-module)"
expected_count="${#expected_suites[@]}"
if [[ "$line_count" -ne "$expected_count" ]]; then
  echo "expected $expected_count suite invocations, got $line_count" >&2
  exit 1
fi

for suite in "${expected_suites[@]}"; do
  if ! grep -q -E "suite=${suite} " "$LOG_FILE"; then
    echo "missing suite call: $suite" >&2
    exit 1
  fi
done

control_lines="$(grep -E 'suite=control_' "$LOG_FILE" || true)"
component_line="$(grep -E 'suite=component_upstream_hotpath ' "$LOG_FILE" || true)"

[[ -n "$control_lines" ]] || { echo "missing control suite calls"; exit 1; }
[[ -n "$component_line" ]] || { echo "missing component suite call"; exit 1; }

control_pairs="$(awk '{
  base=""; head="";
  for(i=1;i<=NF;i++){
    if($i ~ /^base_wt=/){base=substr($i,9)}
    if($i ~ /^head_wt=/){head=substr($i,9)}
  }
  print base "|" head
}' <<<"$control_lines" | sort -u)"
control_pair_count="$(wc -l <<<"$control_pairs" | tr -d '[:space:]')"
if [[ "$control_pair_count" -ne 1 ]]; then
  echo "expected one shared worktree pair for all control suites, got:"
  echo "$control_pairs"
  exit 1
fi

control_pair="$(head -n1 <<<"$control_pairs")"
control_base="${control_pair%%|*}"
control_head="${control_pair##*|}"
if [[ -z "$control_base" || -z "$control_head" ]]; then
  echo "expected non-empty BASE_WT/HEAD_WT for control suites"
  exit 1
fi

component_pair="$(awk '{
  base=""; head="";
  for(i=1;i<=NF;i++){
    if($i ~ /^base_wt=/){base=substr($i,9)}
    if($i ~ /^head_wt=/){head=substr($i,9)}
  }
  print base "|" head
}' <<<"$component_line")"
component_base="${component_pair%%|*}"
component_head="${component_pair##*|}"
if [[ -z "$component_base" || -z "$component_head" ]]; then
  echo "expected non-empty BASE_WT/HEAD_WT for component suite"
  exit 1
fi
if [[ "$component_pair" == "$control_pair" ]]; then
  echo "expected component suite to use a different worktree pair than control suites"
  exit 1
fi

echo "PASS: suite grouping and shared worktree wiring are correct"

#!/usr/bin/env bash
set -euo pipefail

WF=".github/workflows/dns-benchmark-compare.yml"

if [[ ! -f "$WF" ]]; then
  echo "workflow file not found: $WF" >&2
  exit 1
fi

if grep -q 'source "\$META_FILE"' "$WF"; then
  echo "workflow must not source meta file directly" >&2
  exit 1
fi

run_script_only="$(awk '
  /- name: Run Benchmark Compare/ {in_step=1}
  in_step && /run: \|/ {in_run=1; next}
  in_step && /- name: Upload Benchmark Artifacts/ {exit}
  in_run {print}
' "$WF")"

if grep -q '\${{ github\.' <<<"$run_script_only"; then
  echo "Run Benchmark Compare step must not interpolate github context directly in run script" >&2
  exit 1
fi

for key in GH_EVENT_NAME GH_BASE_REF GH_SHA INPUT_BASE_REF INPUT_HEAD_REF INPUT_BASE_STRATEGY INPUT_SUITE_PROFILE INPUT_SUITE_LIST INPUT_BENCH_COUNT INPUT_BENCH_TIME; do
  if ! grep -q "^[[:space:]]\\{10,\\}$key:" "$WF"; then
    echo "missing env key in Run Benchmark Compare step: $key" >&2
    exit 1
  fi
done

if ! grep -Fq '|~)' "$WF"; then
  echo "delta regex must include ~ for not-significant benchstat results" >&2
  exit 1
fi

if ! grep -q '\[\[ "\$delta_v" == "~" \]\] && delta_v="~ (not significant)"' "$WF"; then
  echo "workflow must normalize ~ to ~ (not significant)" >&2
  exit 1
fi

echo "PASS: workflow safety and delta parsing guards satisfied"

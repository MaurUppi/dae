# DNS Benchmark Framework

This framework compares DNS-related benchmarks between a base ref and a head ref.

## Goals

- Cover key DNS module behavior with grouped benchmark suites.
- Allow repeatable baseline comparisons for any DNS-related commit/PR.
- Keep CI non-blocking while still publishing actionable perf reports.

## Suite Profiles

- `quick`
  - `control_core_flow`
  - `component_upstream_hotpath`
- `dns-module` (default in PR CI)
  - `control_core_flow`
  - `control_singleflight_scale`
  - `control_cache_hotpath`
  - `control_cache_structures`
  - `component_upstream_hotpath`

Suite definitions live in `scripts/ci/dns-benchmark-suites.sh`.

## Base Strategies

- `merge-base` (default): compare `merge-base(base_ref, head_ref)` vs `head_ref`.
- `exact`: compare `base_ref` commit directly vs `head_ref`.

Use `exact` when you want strict "commit A vs commit B" comparisons.

## Local Usage

```bash
chmod +x scripts/ci/dns-benchmark-compare.sh scripts/ci/dns-benchmark-suite-runner.sh

# Profile-based run
DNS_BENCH_PROFILE=dns-module \
BASE_COMMIT_STRATEGY=merge-base \
ARTIFACT_DIR=bench-artifacts \
./scripts/ci/dns-benchmark-suite-runner.sh origin/main HEAD

# Explicit suite list and exact baseline
DNS_BENCH_SUITES=component_upstream_hotpath,control_singleflight_scale \
BASE_COMMIT_STRATEGY=exact \
ARTIFACT_DIR=bench-artifacts \
./scripts/ci/dns-benchmark-suite-runner.sh 5268be5 594f449
```

## GitHub Actions

Workflow: `.github/workflows/dns-benchmark-compare.yml`

- Pull requests: runs `dns-module` profile against `origin/<base>` and PR head.
- Manual dispatch: supports `base_ref`, `head_ref`, `base_strategy`, `suite_profile`, `suite_list`, `bench_count`, and `bench_time`.

All runs publish:

- Aggregated report: `bench-artifacts/report.md`
- Per-suite reports and raw benchmark outputs
- PR comment with the latest report

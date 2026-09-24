#!/usr/bin/env bash
#
#  SPDX-License-Identifier: AGPL-3.0-only
#  Copyright (c) 2022-2026, daeuniverse Organization <dae@v2raya.org>
#
# Hermetic checks for dns-benchmark-compare.sh:
#   (a) base cannot compile the overlay → exit 0, skip marker, head-only report
#   (b) head cannot compile the overlay → non-zero, no skip marker
#   (c) both compile → exit 0, no skip marker, common benchmarks run
#   (d) internal failure inside list_benchmarks → non-zero, no skip marker
#   suite runner labels (a) as "skipped (base incompatible)"
#   suite runner labels a stale marker plus a failing status as "failed"
set -euo pipefail

DAE_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
ROOT="$(mktemp -d -t dns-bench-test-XXXXXX)"
STUB="$(mktemp -d -t dns-bench-stub-XXXXXX)"

cleanup() {
  rm -rf "$ROOT" "$STUB"
}
trap cleanup EXIT

cat >"$STUB/benchstat" <<'EOF'
#!/bin/sh
echo "benchstat stub"
cat "$@"
EOF
chmod +x "$STUB/benchstat"
export PATH="$STUB:$PATH"
export GOWORK=off

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

git_init() {
  local repo="$1"
  git init -q -b main "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name test
}

write_module() {
  local repo="$1"
  cat >"$repo/go.mod" <<'EOF'
module example.com/dnsbenchfixture

go 1.22
EOF
  mkdir -p "$repo/control"
  cat >"$repo/control/control.go" <<'EOF'
package control
EOF
}

write_fill() {
  local repo="$1"
  cat >"$repo/control/cache.go" <<'EOF'
package control

func FillIntoWithTTL() (int, error) { return 1, nil }
EOF
}

write_duplicate_bench() {
  local repo="$1"
  cat >"$repo/control/cache_test.go" <<'EOF'
package control

import "testing"

func BenchmarkDnsCache_FillIntoWithTTL(b *testing.B) {
	for i := 0; i < b.N; i++ {
		_, _ = FillIntoWithTTL()
	}
}
EOF
}

write_overlay() {
  local repo="$1"
  local body="$2"
  mkdir -p "$repo/scripts/ci/benchmarks/control"
  cat >"$repo/scripts/ci/benchmarks/control/hot_test.go" <<EOF
//go:build ignore

package control

import "testing"

$body
EOF
}

commit_all() {
  local repo="$1"
  local msg="$2"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$msg"
}

install_scripts() {
  local repo="$1"
  mkdir -p "$repo/scripts/ci"
  cp "$DAE_ROOT/scripts/ci/dns-benchmark-compare.sh" "$repo/scripts/ci/"
  cp "$DAE_ROOT/scripts/ci/dns-benchmark-suite-runner.sh" "$repo/scripts/ci/"
  cp "$DAE_ROOT/scripts/ci/dns-benchmark-suites.sh" "$repo/scripts/ci/"
  chmod +x "$repo/scripts/ci/dns-benchmark-compare.sh" "$repo/scripts/ci/dns-benchmark-suite-runner.sh"
}

run_compare() {
  local repo="$1"
  local art="$2"
  local log="$3"
  mkdir -p "$art"
  set +e
  (
    cd "$repo"
    BASE_COMMIT_STRATEGY=exact \
    BENCH_PACKAGE=./control \
    BENCH_FILTER='^BenchmarkDnsCache_FillIntoWithTTL$' \
    BENCH_OVERLAY_DIR="$repo/scripts/ci/benchmarks" \
    BENCH_COUNT=1 \
    BENCH_TIME=1x \
    ARTIFACT_DIR="$art" \
      ./scripts/ci/dns-benchmark-compare.sh base HEAD
  ) >"$log" 2>&1
  local rc=$?
  set -e
  printf '%s' "$rc"
}

# (a) base already defines the overlay benchmark; head does not.
repo_a="$ROOT/a"
git_init "$repo_a"
write_module "$repo_a"
write_fill "$repo_a"
write_duplicate_bench "$repo_a"
write_overlay "$repo_a" 'func BenchmarkDnsCache_FillIntoWithTTL(b *testing.B) {
	for i := 0; i < b.N; i++ {
		_, _ = FillIntoWithTTL()
	}
}'
commit_all "$repo_a" base
git -C "$repo_a" branch base
rm -f "$repo_a/control/cache_test.go"
commit_all "$repo_a" head
install_scripts "$repo_a"

art_a="$ROOT/art-a"
log_a="$ROOT/a.log"
rc_a="$(run_compare "$repo_a" "$art_a" "$log_a")"
if [[ "$rc_a" -ne 0 ]]; then
  printf 'case (a) log:\n' >&2
  cat "$log_a" >&2 || true
  fail "case (a) exit $rc_a, want 0"
fi
[[ -f "$art_a/skipped_base_incompatible" ]] || fail "case (a) missing skip marker"
[[ -s "$art_a/base_list_error.txt" ]] || fail "case (a) missing base list error"
grep -q 'skipped (base incompatible)' "$art_a/report.md" || fail "case (a) report missing skip status"
grep -q 'BenchmarkDnsCache_FillIntoWithTTL' "$art_a/report.md" || fail "case (a) report missing head-only benchmark"
grep -q '::warning::' "$log_a" || fail "case (a) missing GitHub warning"
grep -q 'BENCH_PACKAGE=./control' "$log_a" || fail "case (a) warning does not name the package"
grep -q 'redeclared' "$log_a" || fail "case (a) log missing base compiler error"

set +e
(
  cd "$repo_a"
  DNS_BENCH_SUITES=control_dns_cache \
  BASE_COMMIT_STRATEGY=exact \
  BENCH_COUNT=1 \
  BENCH_TIME=1x \
  ARTIFACT_DIR="$ROOT/suite-a" \
    ./scripts/ci/dns-benchmark-suite-runner.sh base HEAD
) >"$ROOT/suite-a.log" 2>&1
rc_suite=$?
set -e
if [[ "$rc_suite" -ne 0 ]]; then
  cat "$ROOT/suite-a.log" >&2 || true
  fail "suite runner exit $rc_suite, want 0"
fi
grep -q 'control_dns_cache: skipped (base incompatible)' "$ROOT/suite-a/report.md" \
  || fail "suite status was not skipped (base incompatible)"

# (b) head cannot compile the overlay; base can.
repo_b="$ROOT/b"
git_init "$repo_b"
write_module "$repo_b"
write_fill "$repo_b"
write_overlay "$repo_b" 'func BenchmarkDnsCache_FillIntoWithTTL(b *testing.B) {
	for i := 0; i < b.N; i++ {
		_, _ = FillIntoWithTTL()
	}
}'
commit_all "$repo_b" base
git -C "$repo_b" branch base
rm -f "$repo_b/control/cache.go"
printf 'package control\n' >"$repo_b/control/cache.go"
commit_all "$repo_b" head
install_scripts "$repo_b"
art_b="$ROOT/art-b"
log_b="$ROOT/b.log"
rc_b="$(run_compare "$repo_b" "$art_b" "$log_b")"
if [[ "$rc_b" -eq 0 ]]; then
  printf 'case (b) log:\n' >&2
  cat "$log_b" >&2 || true
  fail "case (b) exit 0, want non-zero"
fi
grep -q 'undefined' "$log_b" || fail "case (b) log missing head compiler error"
[[ ! -e "$art_b/skipped_base_incompatible" ]] || fail "case (b) unexpected skip marker"

# (c) both sides compile the overlay.
repo_c="$ROOT/c"
git_init "$repo_c"
write_module "$repo_c"
write_fill "$repo_c"
write_overlay "$repo_c" 'func BenchmarkDnsCache_FillIntoWithTTL(b *testing.B) {
	for i := 0; i < b.N; i++ {
		_, _ = FillIntoWithTTL()
	}
}'
commit_all "$repo_c" base
git -C "$repo_c" branch base
git -C "$repo_c" commit -q --allow-empty -m head
install_scripts "$repo_c"
art_c="$ROOT/art-c"
log_c="$ROOT/c.log"
rc_c="$(run_compare "$repo_c" "$art_c" "$log_c")"
if [[ "$rc_c" -ne 0 ]]; then
  printf 'case (c) log:\n' >&2
  cat "$log_c" >&2 || true
  fail "case (c) exit $rc_c, want 0"
fi
[[ ! -e "$art_c/skipped_base_incompatible" ]] || fail "case (c) unexpected skip marker"
grep -q 'skipped (base incompatible)' "$art_c/report.md" && fail "case (c) report says skipped"
grep -q 'BenchmarkDnsCache_FillIntoWithTTL' "$art_c/base_common.txt" || fail "case (c) base did not run the common benchmark"
grep -q 'BenchmarkDnsCache_FillIntoWithTTL' "$art_c/head_common.txt" || fail "case (c) head did not run the common benchmark"

# (d) awk failure inside list_benchmarks is an internal error, not a base skip.
awk_stub="$ROOT/awk-stub"
mkdir -p "$awk_stub"
cat >"$awk_stub/awk" <<'EOF'
#!/bin/sh
echo "awk stub: forced failure" >&2
exit 1
EOF
chmod +x "$awk_stub/awk"
art_d="$ROOT/art-d"
log_d="$ROOT/d.log"
mkdir -p "$art_d"
: >"$art_d/skipped_base_incompatible"
set +e
(
  cd "$repo_c"
  PATH="$awk_stub:$PATH" \
  BASE_COMMIT_STRATEGY=exact \
  BENCH_PACKAGE=./control \
  BENCH_FILTER='^BenchmarkDnsCache_FillIntoWithTTL$' \
  BENCH_OVERLAY_DIR="$repo_c/scripts/ci/benchmarks" \
  BENCH_COUNT=1 \
  BENCH_TIME=1x \
  ARTIFACT_DIR="$art_d" \
    ./scripts/ci/dns-benchmark-compare.sh base HEAD
) >"$log_d" 2>&1
rc_d=$?
set -e
if [[ "$rc_d" -eq 0 ]]; then
  printf 'case (d) log:\n' >&2
  cat "$log_d" >&2 || true
  fail "case (d) exit 0, want non-zero"
fi
[[ ! -e "$art_d/skipped_base_incompatible" ]] || fail "case (d) skip marker written on internal failure"
if grep -q '::warning::' "$log_d"; then
  fail "case (d) treated internal failure as base incompatible"
fi
grep -q 'list_benchmarks:' "$log_d" || fail "case (d) log missing internal error"

# Stale skip marker must not hide a failing suite status.
cat >"$repo_c/scripts/ci/dns-benchmark-compare.sh" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$repo_c/scripts/ci/dns-benchmark-compare.sh"
mkdir -p "$ROOT/suite-stale/control_dns_cache"
: >"$ROOT/suite-stale/control_dns_cache/skipped_base_incompatible"
set +e
(
  cd "$repo_c"
  DNS_BENCH_SUITES=control_dns_cache \
  BASE_COMMIT_STRATEGY=exact \
  BENCH_COUNT=1 \
  BENCH_TIME=1x \
  ARTIFACT_DIR="$ROOT/suite-stale" \
    ./scripts/ci/dns-benchmark-suite-runner.sh base HEAD
) >"$ROOT/suite-stale.log" 2>&1
rc_stale=$?
set -e
if [[ "$rc_stale" -eq 0 ]]; then
  cat "$ROOT/suite-stale.log" >&2 || true
  fail "stale-marker suite exit 0, want non-zero"
fi
grep -q 'control_dns_cache: failed' "$ROOT/suite-stale/report.md" \
  || fail "stale marker plus failing status was not reported as failed"
if grep -q 'skipped (base incompatible)' "$ROOT/suite-stale/report.md"; then
  fail "stale marker reported as skipped"
fi

printf 'ok\n'

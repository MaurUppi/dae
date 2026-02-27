#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

TMP_DIR="$(mktemp -d)"
ARTIFACT_DIR="$TMP_DIR/artifacts"
mkdir -p "$ARTIFACT_DIR"

REAL_GIT="$(command -v git)"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/git" <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${EXPECT_NO_WORKTREE_ADD:-0}" == "1" && "${1:-}" == "worktree" && "${2:-}" == "add" ]]; then
  echo "unexpected git worktree add while reusing BASE_WT/HEAD_WT" >&2
  exit 99
fi
exec "$REAL_GIT_PATH" "$@"
WRAP
chmod +x "$FAKE_BIN/git"

cat >"$FAKE_BIN/benchstat" <<'BSTAT'
#!/usr/bin/env bash
set -euo pipefail
cat <<'OUT'
goos: linux
goarch: amd64
pkg: stub
              │ base │ head │
              │ sec/op │
BenchmarkStub   1.00n   1.00n   ~
OUT
BSTAT
chmod +x "$FAKE_BIN/benchstat"

export REAL_GIT_PATH="$REAL_GIT"
export PATH="$FAKE_BIN:$PATH"
export EXPECT_NO_WORKTREE_ADD=1

set +e
BASE_WT="$REPO_ROOT" \
HEAD_WT="$REPO_ROOT" \
BENCH_PACKAGE="./component/dns" \
BENCH_FILTER="^$" \
BENCH_COUNT=1 \
BENCH_TIME=50ms \
ARTIFACT_DIR="$ARTIFACT_DIR" \
./scripts/ci/dns-benchmark-compare.sh HEAD HEAD >/dev/null 2>&1
status=$?
set -e

if [[ "$status" -ne 0 ]]; then
  echo "expected compare script to reuse provided worktrees without git worktree add, got status=$status" >&2
  exit 1
fi

echo "PASS: compare script reused provided worktrees"

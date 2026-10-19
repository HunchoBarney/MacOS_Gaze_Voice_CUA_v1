#!/usr/bin/env bash
# Unattended bench suite: env snapshot -> corpus run -> report.
#   BENCH_SET=local-safe|test-user|all   (default local-safe)
#   BENCH_STUB=1                         (stub MCP backend, no app needed)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
mkdir -p bench/results
export BENCH_SET="${BENCH_SET:-local-safe}"
export BENCH_OUT="bench/results/results-$(date -u +%Y%m%d).jsonl"
caffeinate -is bash -c '
  set -euo pipefail
  bash bench/env-snapshot.sh
  python3 bench/run.py --set "$BENCH_SET" --out "$BENCH_OUT"
  python3 bench/report.py "$BENCH_OUT"
'
echo "results:  $BENCH_OUT"
echo "baseline: bench/results/baseline.json"
echo "report:   bench/results/baseline-report.md"
ls -t bench/results/env-*.json 2>/dev/null | head -1 | sed 's/^/env:      /' || true

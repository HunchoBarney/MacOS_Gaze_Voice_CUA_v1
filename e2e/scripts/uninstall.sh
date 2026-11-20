#!/usr/bin/env bash
# Removes everything make e2e-install and make e2e put on this Mac. The
# runner's Accessibility and Screen Recording grants are the owner's to
# switch off in System Settings; this prints where.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
rm -rf "$here/node_modules" "$here/vendor" "$here/.e2e" "$here/pnpm-lock.yaml"
rm -rf "$HOME/Library/Caches/e2e/agent-desktop"
rmdir "$HOME/Library/Caches/e2e" 2>/dev/null || true
echo "removed e2e/node_modules, e2e/vendor, e2e/.e2e and the agent-desktop download"
echo "to revoke the runner's grants: System Settings → Privacy & Security → Accessibility and"
echo "Screen & System Audio Recording, then switch off the app you ran make e2e from"

#!/usr/bin/env bash
set -euo pipefail
REPO_URL="https://github.com/tuturuning/FGFW.git"
TARGET_DIR="${1:-/opt/fgfw}"
command -v git >/dev/null 2>&1 || { echo 'git is required'; exit 1; }
rm -rf "$TARGET_DIR"
git clone "$REPO_URL" "$TARGET_DIR"
echo "Cloned to $TARGET_DIR"
echo "Next: cd $TARGET_DIR && ./deploy/install.sh menu"

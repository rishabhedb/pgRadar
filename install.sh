#!/bin/sh
set -e

# ─────────────────────────────────────────────────────────────
#  PGRadar — Installer
#  Downloads the pgRadar binary from GitHub and makes it runnable
# ─────────────────────────────────────────────────────────────

# Repository Configuration
OWNER="rishabhedb"
REPO="pgRadar"
BINARY="pgRadar"

# Resolve install path to current working directory (absolute)
INSTALL_PATH=$(pwd)

echo ""
echo "  📡 PGRadar Installer"
echo "  ─────────────────────────────────────────────"
echo "  Repository : https://github.com/$OWNER/$REPO"
echo "  Binary     : $BINARY"
echo "  Install to : $INSTALL_PATH"
echo "  ─────────────────────────────────────────────"
echo ""

# 1. Download the binary
echo "  Downloading $BINARY..."
curl -sSfL "https://raw.githubusercontent.com/$OWNER/$REPO/main/$BINARY" \
     -o "$INSTALL_PATH/$BINARY"

# 2. Make it executable
chmod +x "$INSTALL_PATH/$BINARY"

echo ""
echo "  ✔  Installation successful!"
echo ""
echo "  Usage:"
echo "    sh $INSTALL_PATH/$BINARY /path/to/lasso/bundles/"
echo ""
echo "  Example (folder in current directory):"
echo "    sh $INSTALL_PATH/$BINARY 6234"
echo ""

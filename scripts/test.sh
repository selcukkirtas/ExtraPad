#!/bin/bash
# Runs the test suite.
#
# The scratch path is forced outside the project for the same reason the app
# bundle is: if the repo sits in iCloud Drive, the file provider stamps
# com.apple.FinderInfo onto the test bundle while codesign is sealing it, and
# the run fails with "resource fork, Finder information, or similar detritus
# not allowed" - which says nothing about the real cause.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec swift test --package-path "$ROOT" \
     --scratch-path "$HOME/Library/Caches/ExtraPad-build" "$@"

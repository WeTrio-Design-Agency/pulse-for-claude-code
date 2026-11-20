#!/bin/zsh
# Build from source and install (needs the Command Line Tools). Safe to run again.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
zsh scripts/install-prebuilt.sh build

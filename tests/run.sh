#!/bin/bash
# Runs the statusline and Swift logic tests.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
./tests/test-statusline.sh
swiftc -o build/tests/usage-tests Shared/Usage.swift Shared/L10n.swift tests/main.swift
build/tests/usage-tests

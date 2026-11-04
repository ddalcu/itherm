#!/bin/sh
# Runs the terminal parser's self-test: scripts/parser-tests.swift against the emulator in itherm.swift.
# Both go into one file, so the tests can reach Term's private members (private means same file in Swift).
set -e
cd "$(dirname "$0")/.."
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
awk '/^\/\/ MARK: - Monitor/ { exit } { print }' itherm.swift > "$dir/test.swift"
cat scripts/parser-tests.swift >> "$dir/test.swift"
swiftc -O "$dir/test.swift" -o "$dir/test"
exec "$dir/test"

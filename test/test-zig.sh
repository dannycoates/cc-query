#!/bin/bash
# Run cc-query tests with the Zig implementation
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC_QUERY="$SCRIPT_DIR/../zig/zig-out/bin/ccq" exec "$SCRIPT_DIR/test.sh"

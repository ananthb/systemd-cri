#!/usr/bin/env bash
# Update CRI proto files from kubernetes/cri-api
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# CRI API source
CRI_API_REPO="https://raw.githubusercontent.com/kubernetes/cri-api"
CRI_API_BRANCH="${CRI_API_BRANCH:-master}"
PROTO_PATH="pkg/apis/runtime/v1/api.proto"

# Output directories
PROTO_DIR="$PROJECT_ROOT/proto"
GENERATED_DIR="$PROJECT_ROOT/src/cri/proto"

echo "=== Updating CRI Proto Files ==="
echo "Source: $CRI_API_REPO/$CRI_API_BRANCH/$PROTO_PATH"
echo ""

# Create directories
mkdir -p "$PROTO_DIR" "$GENERATED_DIR"

# Fetch the latest proto file
echo "Fetching api.proto from kubernetes/cri-api ($CRI_API_BRANCH)..."
curl -sSL "$CRI_API_REPO/$CRI_API_BRANCH/$PROTO_PATH" -o "$PROTO_DIR/api.proto"

# Check if the file was downloaded successfully
if [[ ! -s "$PROTO_DIR/api.proto" ]]; then
    echo "ERROR: Failed to download api.proto"
    exit 1
fi

# Show version info from proto
echo ""
echo "Proto file info:"
grep -E "^(syntax|package|option go_package)" "$PROTO_DIR/api.proto" | head -5

# Generate C files using protoc-c
echo ""
echo "Generating C bindings with protoc-c..."
protoc-c \
    --proto_path="$PROTO_DIR" \
    --c_out="$GENERATED_DIR" \
    "$PROTO_DIR/api.proto"

# Verify generated files
if [[ -f "$GENERATED_DIR/api.pb-c.c" ]] && [[ -f "$GENERATED_DIR/api.pb-c.h" ]]; then
    echo ""
    echo "Generated files:"
    ls -la "$GENERATED_DIR/api.pb-c.c" "$GENERATED_DIR/api.pb-c.h"

    echo ""
    echo "Line counts:"
    wc -l "$GENERATED_DIR/api.pb-c.c" "$GENERATED_DIR/api.pb-c.h"
else
    echo "ERROR: Failed to generate C files"
    exit 1
fi

echo ""
echo "=== Proto update complete ==="
echo ""
echo "Don't forget to:"
echo "  1. Review the changes: git diff src/cri/proto/"
echo "  2. Test the build: nix build"
echo "  3. Run tests: nix flake check"
echo "  4. Commit if everything works"

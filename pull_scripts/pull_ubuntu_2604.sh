#!/usr/bin/env bash -x
# Acquire pinned Docker Official Ubuntu 26.04 for linux/amd64.
# Store as an OCI image layout, without a local registry or daemon.
set -Eeuo pipefail
umask 022

readonly REPOSITORY="docker.io/library/ubuntu"
readonly TAG="26.04"

readonly INDEX_DIGEST="sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c"
readonly AMD64_DIGEST="sha256:157dc3d6e4a3e4f2c68d12df9df9ed6e808b59af6d4c3757b432b4f519916725"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OCI_ROOT="${OCI_ROOT:-${SCRIPT_DIR}/oci}"

PARENT="${OCI_ROOT}/ubuntu/26.04"
TARGET="${PARENT}/amd64"
PROVENANCE="${PARENT}/amd64.source.txt"
OCI_TAG="26.04-amd64"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

for cmd in skopeo python3 sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 ||
        die "Required command not found: $cmd"
done

mkdir -p "$PARENT"

# Inspect the registry index by its mutable tag, then verify its
# bytes against the reviewed immutable digest.
tmp=$(mktemp -d "${PARENT}/.amd64.tmp.XXXXXX")

cleanup() {
    rm -rf -- "$tmp"
}
trap cleanup EXIT

printf 'Inspecting registry tag: %s:%s\n' "$REPOSITORY" "$TAG"

skopeo inspect --raw \
    "docker://${REPOSITORY}:${TAG}" \
    > "${tmp}/registry-index.json"

actual_index="sha256:$(sha256sum "${tmp}/registry-index.json" | awk '{print $1}')"

[[ "$actual_index" == "$INDEX_DIGEST" ]] ||
    die "Registry index differs from reviewed pin.
Expected: $INDEX_DIGEST
Actual:   $actual_index"

# Verify that the pinned amd64 child manifest is actually referenced
# by the verified multi-platform index.
python3 - "${tmp}/registry-index.json" "$AMD64_DIGEST" <<'PY'
import json
import sys

path, expected = sys.argv[1:]

with open(path, encoding="utf-8") as f:
    index = json.load(f)

matches = [
    item["digest"]
    for item in index.get("manifests", [])
    if item.get("platform", {}).get("os") == "linux"
    and item.get("platform", {}).get("architecture") == "amd64"
]

if matches.count(expected) != 1:
    print("Expected exactly one matching linux/amd64 descriptor.",
          file=sys.stderr)
    print("Expected:", expected, file=sys.stderr)
    print("Found:", matches, file=sys.stderr)
    sys.exit(1)
PY

# Validate an existing installation rather than blindly overwriting it.
if [[ -e "$TARGET" || -e "$PROVENANCE" ]]; then
    [[ -d "$TARGET" && -f "$PROVENANCE" ]] ||
        die "Incomplete existing destination; inspect before replacing."

    grep -Fxq "index=${INDEX_DIGEST}" "$PROVENANCE" ||
        die "Existing provenance has a different index digest."

    grep -Fxq "amd64=${AMD64_DIGEST}" "$PROVENANCE" ||
        die "Existing provenance has a different amd64 digest."

    platform=$(
        skopeo inspect \
            --format '{{.Os}}/{{.Architecture}}' \
            "oci:${TARGET}:${OCI_TAG}"
    ) || die "Existing OCI layout cannot be inspected."

    [[ "$platform" == "linux/amd64" ]] ||
        die "Unexpected existing platform: $platform"

    echo "Existing pinned OCI layout is present and readable:"
    echo "  $TARGET"
    exit 0
fi

echo "Copying pinned amd64 child manifest..."

mkdir -p "${tmp}/layout"

# Copy the exact child manifest, not a mutable tag or an
# architecture-selected interpretation of a mutable index.
skopeo copy \
    "docker://${REPOSITORY}@${AMD64_DIGEST}" \
    "oci:${tmp}/layout:${OCI_TAG}"

platform=$(
    skopeo inspect \
        --format '{{.Os}}/{{.Architecture}}' \
        "oci:${tmp}/layout:${OCI_TAG}"
)

[[ "$platform" == "linux/amd64" ]] ||
    die "Imported image has unexpected platform: $platform"

cat > "${tmp}/provenance" <<EOF
repository=${REPOSITORY}
tag=${TAG}
index=${INDEX_DIGEST}
amd64=${AMD64_DIGEST}
platform=linux/amd64
oci_tag=${OCI_TAG}
reviewed=2026-11-09
EOF

# Publish only after successful copy and inspection.
mv "${tmp}/layout" "$TARGET"
mv "${tmp}/provenance" "$PROVENANCE"

echo
echo "OCI image acquired:"
echo "  Layout:     $TARGET"
echo "  Platform:   $platform"
echo "  Index:      $INDEX_DIGEST"
echo "  Child:      $AMD64_DIGEST"
echo "  Provenance: $PROVENANCE"

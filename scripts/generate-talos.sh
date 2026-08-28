#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

source "$ROOT/cluster.env"

required_vars=(
  CLUSTER_NAME
  TALOS_VERSION
  KUBERNETES_VERSION
  CONTROL_PLANE_ENDPOINT
)

for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "error: $var is not set in cluster.env" >&2
    exit 1
  fi
done

required_commands=(
  talosctl
  curl
  jq
)

for command in "${required_commands[@]}"; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "error: missing command: $command" >&2
    exit 1
  fi
done

SCHEMATIC_FILE="talos/image-factory/schematic.yaml"
SCHEMATIC_ID_FILE="talos/image-factory/schematic-id"
GENERATED_DIR="talos/generated"

required_files=(
  "talos/secrets.yaml"
  "$SCHEMATIC_FILE"
  "talos/patches/common.yaml"
  "talos/patches/storage-longhorn.yaml"
  "talos/patches/talos-01.yaml"
  "talos/patches/talos-02.yaml"
  "talos/patches/talos-03.yaml"
)

for file in "${required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "error: missing file: $file" >&2
    exit 1
  fi
done

echo "Resolving Image Factory schematic..."

SCHEMATIC_ID="$(
  curl -fsSL \
    -X POST \
    --data-binary "@$SCHEMATIC_FILE" \
    https://factory.talos.dev/schematics |
    jq -r '.id'
)"

if [[ ! "$SCHEMATIC_ID" =~ ^[0-9a-f]{64}$ ]]; then
  echo "error: invalid schematic ID: $SCHEMATIC_ID" >&2
  exit 1
fi

INSTALL_IMAGE="factory.talos.dev/metal-installer-secureboot/${SCHEMATIC_ID}:${TALOS_VERSION}"

echo "Talos version:      $TALOS_VERSION"
echo "Kubernetes version: $KUBERNETES_VERSION"
echo "Schematic:          $SCHEMATIC_ID"
echo "Installer:          $INSTALL_IMAGE"
echo

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

for node in 01 02 03; do
  echo "Rendering talos-${node}..."

  talosctl gen config \
    "$CLUSTER_NAME" \
    "$CONTROL_PLANE_ENDPOINT" \
    --with-secrets talos/secrets.yaml \
    --talos-version "$TALOS_VERSION" \
    --kubernetes-version "$KUBERNETES_VERSION" \
    --install-disk /dev/nvme0n1 \
    --install-image "$INSTALL_IMAGE" \
    --config-patch @talos/patches/common.yaml \
    --config-patch @talos/patches/storage-longhorn.yaml \
    --config-patch-control-plane "@talos/patches/talos-${node}.yaml" \
    --output-types controlplane \
    --output "$tmp_dir/talos-${node}.yaml" \
    --with-docs=false \
    --with-examples=false
done

mkdir -p "$GENERATED_DIR"

for node in 01 02 03; do
  install \
    -m 600 \
    "$tmp_dir/talos-${node}.yaml" \
    "$GENERATED_DIR/talos-${node}.yaml"
done

printf '%s\n' "$SCHEMATIC_ID" > "$SCHEMATIC_ID_FILE"

echo
echo "Rendered:"
echo "  $GENERATED_DIR/talos-01.yaml"
echo "  $GENERATED_DIR/talos-02.yaml"
echo "  $GENERATED_DIR/talos-03.yaml"

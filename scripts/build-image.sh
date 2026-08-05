#!/usr/bin/env bash
# build-image.sh — build (and optionally push) the pi-kube container image.
#
# Builds one of the Dockerfile.pi targets (slim | full | custom) and, when
# PUSH=1, pushes it to a registry. Defaults assume a ghcr.io destination
# (ghcr.io/<owner>/pi-kube) since that is where the image will be published.
#
# The tag is derived from the chart's appVersion (charts/pi/Chart.yaml) by
# default; a git short-sha suffix is appended for non-release builds.
#
# Examples:
#   # slim, local build only (no push)
#   scripts/build-image.sh
#
#   # full variant, multi-arch, push to ghcr.io/<owner>/pi-kube:0.83.0-full
#   VARIANT=full PLATFORMS=linux/amd64,linux/arm64 PUSH=1 scripts/build-image.sh
#
#   # custom variant with extra apt packages
#   VARIANT=custom PACKAGES="terraform helm kubectl" TAG=0.83.0-custom \
#     PUSH=1 scripts/build-image.sh
#
#   # point at your own registry
#   REGISTRY=docker.io IMAGE_NAME=myorg/pi-kube PUSH=1 scripts/build-image.sh
#
# Env vars (all optional):
#   REGISTRY   registry host            (default: ghcr.io)
#   OWNER      image owner/namespace    (default: derived from git remote)
#   IMAGE_NAME full image name w/o tag  (default: <OWNER>/pi-kube)
#   TAG        image tag                (default: <appVersion>[-sha][-variant])
#   VARIANT    slim | full | custom     (default: slim)
#   PI_VERSION pi npm package version    (default: chart appVersion)
#   PACKAGES   extra apt pkgs (custom)  (default: "")
#   PLATFORMS  buildx platforms          (default: "" = host arch only)
#   PUSH       0|1 push after build     (default: 0)
#   DOCKERFILE path to Dockerfile        (default: charts/pi/docker/Dockerfile.pi)
#   CONTEXT    build context dir        (default: charts/pi)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

REGISTRY="${REGISTRY:-ghcr.io}"
DOCKERFILE="${DOCKERFILE:-charts/pi/docker/Dockerfile.pi}"
CONTEXT="${CONTEXT:-charts/pi}"
VARIANT="${VARIANT:-slim}"
PACKAGES="${PACKAGES:-}"
PLATFORMS="${PLATFORMS:-}"
PUSH="${PUSH:-0}"

if [[ ! -f "$DOCKERFILE" ]]; then
  echo "error: Dockerfile not found at $DOCKERFILE" >&2
  exit 1
fi

# --- Derive appVersion from Chart.yaml (single source of truth for the tag) ---
APP_VERSION="$(grep -E '^appVersion:' charts/pi/Chart.yaml | sed -E 's/.*"(.*)".*/\1/')"
if [[ -z "$APP_VERSION" ]]; then
  echo "error: could not read appVersion from charts/pi/Chart.yaml" >&2
  exit 1
fi

# --- Derive OWNER from the git remote (ghcr convention = repo owner) ---
if [[ -z "${OWNER:-}" ]]; then
  REMOTE_URL="$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null || true)"
  # matches:  https://github.com/<owner>/<repo>.git  or  git@github.com:<owner>/<repo>.git
  OWNER="$(printf '%s' "$REMOTE_URL" \
    | sed -E 's#(https?://|git@)github.com[:/]##; s#\.git$##; s#/.*$##')"
  OWNER="${OWNER:-dr34dl10n}"
fi

if [[ -z "${IMAGE_NAME:-}" ]]; then
  IMAGE_NAME="${REGISTRY}/${OWNER}/pi-kube"
fi

# --- Build the tag ---
if [[ -z "${TAG:-}" ]]; then
  TAG="$APP_VERSION"
  if [[ "$VARIANT" == "full" ]]; then
    TAG="${TAG}-full"
  elif [[ "$VARIANT" == "custom" ]]; then
    TAG="${TAG}-custom"
  fi
  # Append short sha on non-tagged commits (releases are tagged -> no suffix).
  if ! git -C "$REPO_ROOT" describe --tags --exact-match HEAD >/dev/null 2>&1; then
    SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
    TAG="${TAG}-${SHA}"
  fi
fi

IMAGE_REF="${IMAGE_NAME}:${TAG}"

echo "==> building $IMAGE_REF"
echo "    variant=$VARIANT  push=$PUSH  platforms=${PLATFORMS:-host}"

BUILD_ARGS=(
  --file "$DOCKERFILE"
  --target "$VARIANT"
)
BUILD_ARGS+=(--build-arg "PI_VERSION=$APP_VERSION")
[[ -n "$PACKAGES" ]] && BUILD_ARGS+=(--build-arg "PACKAGES=$PACKAGES")

# --- Choose builder: buildx for multi-arch/push, plain build otherwise ---
if [[ -n "$PLATFORMS" || "$PUSH" == "1" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker (with buildx) is required for push/multi-arch" >&2
    exit 1
  fi
  BUILDER="pi-kube-buildx"
  docker buildx create --name "$BUILDER" --use >/dev/null 2>&1 || docker buildx use "$BUILDER"
  BUILD_ARGS+=(--builder "$BUILDER")
  [[ -n "$PLATFORMS" ]] && BUILD_ARGS+=(--platform "$PLATFORMS")
  if [[ "$PUSH" == "1" ]]; then
    BUILD_ARGS+=(--push)
  else
    BUILD_ARGS+=(--load)   # load into local docker (single-platform only)
  fi
  docker buildx build "${BUILD_ARGS[@]}" --tag "$IMAGE_REF" "$CONTEXT"
else
  if command -v docker >/dev/null 2>&1; then
    docker build "${BUILD_ARGS[@]}" --tag "$IMAGE_REF" "$CONTEXT"
  elif command -v podman >/dev/null 2>&1; then
    podman build "${BUILD_ARGS[@]}" --tag "$IMAGE_REF" "$CONTEXT"
  else
    echo "error: neither docker nor podman found" >&2
    exit 1
  fi
fi

echo "==> done: $IMAGE_REF"
if [[ "$PUSH" != "1" ]]; then
  echo "    (not pushed. set PUSH=1 to push to $IMAGE_NAME)"
fi
#!/usr/bin/env bash
# scripts/deploy.sh — one-shot, idempotent deploy of the pi-kube Helm chart.
#
# Creates the Secrets the chart needs (SSH authorized_keys, WireGuard wg0.conf)
# and runs `helm install`/`helm upgrade` for the chosen exposure mode.
#
# Usage:
#   scripts/deploy.sh <mode> [options]
#     mode: none | loadbalancer | wireguard
#
#   --ssh-key PATH       pubkey for authorized_keys (required for loadbalancer/wireguard)
#   --wg-conf PATH       WireGuard client .conf (required for wireguard)
#   --release NAME       helm release name (default: pi)
#   --namespace NS       namespace (default: pi-kube)
#   --image-tag TAG      override image.tag (default: <appVersion>-<git short sha>,
#                        matching the tags the release workflow publishes on push)
#   --pull-secret NAME   existing imagePullSecret name (private ghcr)
#   --values FILE        values file (default: examples/my-values.yaml)
#   --upgrade            helm upgrade instead of install
#   -h, --help
#
# Examples:
#   scripts/deploy.sh wireguard --ssh-key ~/.ssh/pi_key.pub --wg-conf pi-client.conf
#   scripts/deploy.sh loadbalancer --ssh-key ~/.ssh/pi_key.pub
#   scripts/deploy.sh none
#   scripts/deploy.sh wireguard --ssh-key ~/.ssh/pi_key.pub --wg-conf pi-client.conf \
#       --pull-secret ghcr-pull --upgrade

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_DIR="$REPO_DIR/charts/pi"
DEFAULT_VALUES="$REPO_DIR/examples/my-values.yaml"

usage() {
  sed -n '3,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

mode=""
ssh_key=""
wg_conf=""
release="pi"
namespace="pi-kube"
image_tag=""
pull_secret=""
values="$DEFAULT_VALUES"
do_upgrade=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    none|loadbalancer|wireguard) mode="$1"; shift ;;
    --ssh-key) ssh_key="${2:?--ssh-key needs a PATH}"; shift 2 ;;
    --wg-conf) wg_conf="${2:?--wg-conf needs a PATH}"; shift 2 ;;
    --release) release="${2:?--release needs a NAME}"; shift 2 ;;
    --namespace) namespace="${2:?--namespace needs a NS}"; shift 2 ;;
    --image-tag) image_tag="${2:?--image-tag needs a TAG}"; shift 2 ;;
    --pull-secret) pull_secret="${2:?--pull-secret needs a NAME}"; shift 2 ;;
    --values) values="${2:?--values needs a FILE}"; shift 2 ;;
    --upgrade) do_upgrade=1; shift ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

[ -n "$mode" ] || { echo "Error: mode is required (none|loadbalancer|wireguard)" >&2; usage 1; }

# --- Validate required args per mode --------------------------------------
case "$mode" in
  wireguard)
    [ -n "$ssh_key" ] || { echo "Error: --ssh-key is required for wireguard" >&2; exit 1; }
    [ -n "$wg_conf" ] || { echo "Error: --wg-conf is required for wireguard" >&2; exit 1; }
    [ -f "$wg_conf" ] || { echo "Error: wg-conf not found: $wg_conf" >&2; exit 1; }
    ;;
  loadbalancer)
    [ -n "$ssh_key" ] || { echo "Error: --ssh-key is required for loadbalancer" >&2; exit 1; }
    ;;
esac
if [ -n "$ssh_key" ]; then [ -f "$ssh_key" ] || { echo "Error: ssh-key not found: $ssh_key" >&2; exit 1; }; fi
[ -f "$values" ] || { echo "Error: values file not found: $values" >&2; exit 1; }
[ -d "$CHART_DIR" ] || { echo "Error: chart not found: $CHART_DIR" >&2; exit 1; }

command -v helm >/dev/null || { echo "Error: helm not found in PATH" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "Error: kubectl not found in PATH" >&2; exit 1; }

# --- Namespace (idempotent) -----------------------------------------------
echo "==> Namespace $namespace"
kubectl get namespace "$namespace" >/dev/null 2>&1 \
  || kubectl create namespace "$namespace"

# --- SSH authorized_keys secret ------------------------------------------
ssh_secret="pi-ssh-keys"
if [ -n "$ssh_key" ]; then
  echo "==> Secret $ssh_secret (from $ssh_key)"
  kubectl -n "$namespace" create secret generic "$ssh_secret" \
    --from-file=authorized_keys="$ssh_key" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi

# --- WireGuard wg0.conf secret --------------------------------------------
wg_secret="${release}-wg"
if [ "$mode" = "wireguard" ]; then
  echo "==> Secret $wg_secret (from $wg_conf)"
  kubectl -n "$namespace" create secret generic "$wg_secret" \
    --from-file=wg0.conf="$wg_conf" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi

# --- Build helm args ------------------------------------------------------
helm_args=(
  "$release" "$CHART_DIR"
  --namespace "$namespace"
  --values "$values"
  --set "ingress.exposure=$mode"
  --set "ingress.ssh.enabled=true"
  --set "ingress.ssh.authorizedKeysSecret=$ssh_secret"
)
[ "$mode" = "wireguard" ] && helm_args+=(--set "ingress.wireguard.configSecret=$wg_secret")
# Default image tag: <chart appVersion>-<git short sha>, matching the tags the
# release workflow publishes on every push to main (:<ver>-<sha>). Override
# with --image-tag for an explicit tag (e.g. a -full variant or a release tag).
if [ -z "$image_tag" ]; then
  appver=$(grep -E '^appVersion:' "$CHART_DIR/Chart.yaml" | sed -E 's/^appVersion:[[:space:]]*"?([^"]+)"?/\1/')
  sha=$(git -C "$REPO_DIR" rev-parse --short HEAD)
  image_tag="${appver}-${sha}"
fi
echo "==> image.tag=$image_tag"
helm_args+=(--set "image.tag=$image_tag")
[ -n "$pull_secret" ] && helm_args+=(--set "global.imagePullSecrets[0].name=$pull_secret")

action="install"
if [ "$do_upgrade" = 1 ]; then
  action="upgrade"
elif helm status "$release" -n "$namespace" >/dev/null 2>&1; then
  echo "==> Release '$release' already exists — switching to 'helm upgrade'"
  action="upgrade"
fi

echo "==> helm $action ($mode)"
helm "$action" "${helm_args[@]}"

# --- Wait + show how to connect -------------------------------------------
if [ "$mode" = "none" ]; then
  echo
  echo "Done. No ingress. Attach with:"
  echo "  kubectl -n $namespace exec -it deploy/$release -- pi"
  exit 0
fi

echo "==> Waiting for rollout (180s)…"
kubectl -n "$namespace" rollout status "deploy/$release" --timeout=180s || {
  echo "Rollout did not complete in time. Check:"
  echo "  kubectl -n $namespace describe pod -l app.kubernetes.io/instance=$release"
  exit 1
}

echo
case "$mode" in
  loadbalancer)
    echo "Done. SSH is exposed on a LoadBalancer Service:"
    echo "  kubectl -n $namespace get svc ${release}-ssh"
    echo "  ssh -p 2222 pi@<EXTERNAL-IP>   # lands in tmux -> Pi"
    ;;
  wireguard)
    echo "Done. The pod dials out to your WireGuard server (zero cluster ports)."
    echo "SSH in over the tunnel:"
    echo "  ssh -p 2222 pi@<pod-tunnel-ip>   # the Address from your wg0.conf"
    echo "You land in a tmux session running Pi."
    ;;
esac
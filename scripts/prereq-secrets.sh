#!/usr/bin/env bash
# scripts/prereq-secrets.sh — create the K8s Secrets pi-kube needs, then print
# the `helm install` command to run yourself.
#
# Stage files under ./prereq/ (gitignored), then run:
#   scripts/prereq-secrets.sh
#
#   prereq/ssh_key.pub   required for wireguard & loadbalancer (key: authorized_keys)
#   prereq/wg.conf       required for wireguard            (key: wg0.conf)
#   prereq/auth.json     optional, pre-seeds ~/.pi/agent/auth.json (read-only, blocks /login)
#   prereq/my-values.yaml  your values (cp examples/my-values.yaml); exposure is read from it
#
# Options:
#   --namespace NS    namespace (default: pi-kube)
#   --release NAME    helm release name (default: pi) — only used in the printed command
#   -h, --help
#
# What it does: create namespace + secrets (idempotent), then print `helm install`.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREREQ="$REPO_DIR/prereq"
EXAMPLE_VALUES="$REPO_DIR/examples/my-values.yaml"

namespace="pi-kube"
release="pi"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '3,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --namespace) namespace="${2:?--namespace needs a NS}"; shift 2 ;;
    --release) release="${2:?--release needs a NAME}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

command -v kubectl >/dev/null || { echo "Error: kubectl not found in PATH" >&2; exit 1; }

values="$PREREQ/my-values.yaml"
[ -f "$values" ] || {
  echo "Error: $values not found. Copy and edit it first:" >&2
  echo "  cp $EXAMPLE_VALUES $values" >&2
  exit 1
}

# Read ingress.exposure from the values file (default wireguard if unset).
exposure=$(awk '/^ingress:/{f=1; next} f && /^[^[:space:]#]/{f=0} f && /^[[:space:]]*exposure:/{sub(/^[[:space:]]*exposure:[[:space:]]*/,""); sub(/[[:space:]]*#.*$/,""); print; exit}' "$values")
exposure="${exposure:-wireguard}"

# --- Validate required files per exposure ---------------------------------
ssh_key="$PREREQ/ssh_key.pub"
wg_conf="$PREREQ/wg.conf"
auth_json="$PREREQ/auth.json"

require() { [ -f "$1" ] || { echo "Error: $2 not found: $1" >&2; exit 1; }; }
case "$exposure" in
  wireguard)    require "$ssh_key"  "ssh_key.pub is required for wireguard"; require "$wg_conf" "wg.conf is required for wireguard" ;;
  loadbalancer) require "$ssh_key"  "ssh_key.pub is required for loadbalancer" ;;
  none)         ;;
  *) echo "Error: unknown exposure '$exposure' in $values (none|loadbalancer|wireguard)" >&2; exit 1 ;;
esac

# --- Namespace (idempotent) -----------------------------------------------
echo "==> Namespace $namespace"
kubectl get namespace "$namespace" >/dev/null 2>&1 \
  || kubectl create namespace "$namespace"

# --- Secrets (idempotent) -------------------------------------------------
make_secret() {  # name key file
  echo "==> Secret $1 (from $3, key=$2)"
  kubectl -n "$namespace" create secret generic "$1" \
    --from-file="$2=$3" >/dev/null
}

[ -f "$ssh_key" ]   && make_secret pi-ssh-keys authorized_keys "$ssh_key"
[ -f "$wg_conf" ]   && make_secret pi-wg       wg0.conf        "$wg_conf"
[ -f "$auth_json" ] && make_secret pi-auth     auth.json       "$auth_json"

# --- Print the helm install command --------------------------------------
echo
echo "Prereqs ready. Run:"
echo "  helm install $release ./charts/pi -n $namespace -f $values"
[ -f "$auth_json" ] && echo "    --set credentials.authJsonSecret=pi-auth"
echo
echo "Then wait for rollout:"
echo "  kubectl -n $namespace rollout status deploy/$release --timeout=180s"
case "$exposure" in
  loadbalancer) echo "  kubectl -n $namespace get svc ${release}-ssh    # ssh -p 2222 pi@<EXTERNAL-IP>" ;;
  wireguard)    echo "  ssh -p 2222 pi@<pod-tunnel-ip>                  # the Address from your wg.conf" ;;
  none)         echo "  kubectl -n $namespace exec -it deploy/$release -- pi" ;;
esac

# SETUP.md — Installing the pi-kube chart

What you run, not why (design rationale is in `charts/pi/README.md`).

The container image is published by CI (`.github/workflows/release.yml`):

- on `v*` tags → `ghcr.io/dr34dl10n/pi-kube:<appVersion>` (+ `:latest`, `:-full`)
- on pushes to `main` → snapshot `ghcr.io/dr34dl10n/pi-kube:<appVersion>-<sha7>` (+ `-full`)

`charts/pi/values.yaml` defaults to `ghcr.io/dr34dl10n/pi-kube:0.83.0`, so a
tagged release works out of the box. Override `image.tag` to test a `main`
snapshot (see §2).

---

## TL;DR — provide these before `helm install`

| # | Requirement | Why | How |
|---|-------------|-----|-----|
| 1 | A **StorageClass** | Chart creates 4 PVCs | `kubectl get storageclass` ≥1, else install a provisioner (§3) |
| 2 | The **`pi` image**, reachable by the cluster | Pod image pull | Published on ghcr — make the package **public**, or add a pull Secret (§2) |
| 3 | An **SSH public key** (only if exposure != none) | SSH access path | `kubectl create secret … --from-file=authorized_keys` (§0a) |
| 4 | A **provider login** — *optional* at install | Pi boots to the TUI; `/login` on first connect | nothing at install; or `--set credentials.*` (§0b) |
| 5 | An **exposure choice** | Pod is isolated by default | `ingress.exposure`: `none`(default)/`wireguard`(recommended)/… (§4) |

If #1–3 (or #5) are missing, `helm install` "succeeds" but the pod sits in
`Pending`/`ImagePullBackOff`/`CrashLoopBackOff`. #4 is optional at install.

---

## 0. Secrets (prepare before install)

```bash
export NS=pi-kube
kubectl create namespace "$NS"
```

### 0a. SSH authorized keys (required for any SSH exposure)

Secret key `authorized_keys` → mounted at `/home/pi/.ssh/authorized_keys`.
Referenced by `ingress.ssh.authorizedKeysSecret`. Host keys are generated and
persisted on the `ssh-host-keys` PVC (stable identity across restarts).

```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/pi_key
kubectl -n "$NS" create secret generic pi-ssh-keys \
  --from-file=authorized_keys=$HOME/.ssh/pi_key.pub
```
Multiple users: concatenate several `*.pub` into one, or edit the Secret.

### 0b. Provider auth (OPTIONAL — recommended: `/login` in the TUI)

**Recommended:** leave `credentials.*` empty. Pi boots to the TUI; on first
connect run `pi` then `/login`. `auth.json` is written to
`~/.pi/agent/auth.json` on the **home PVC** → persists across restarts.

> ⚠️ Do **not** set `credentials.authJsonSecret`/`authJson` if you want `/login`:
> those mount a read-only Secret at that path, blocking Pi from writing its login.
> Use them only to pre-seed an existing `auth.json` (survives PVC loss).

**Headless / unattended** — inject a key (pick one):
```bash
# inline — chart builds the Secret:
--set credentials.anthropicApiKey=sk-ant-...   # or openaiApiKey/geminiApiKey/...

# existing Secret:
kubectl -n "$NS" create secret generic pi-creds --from-literal=ANTHROPIC_API_KEY=sk-ant-...
--set credentials.existingSecret=pi-creds

# pre-seed auth.json (read-only, blocks /login):
kubectl -n "$NS" create secret generic pi-auth --from-file=auth.json=/path/to/auth.json
--set credentials.authJsonSecret=pi-auth
```

### 0c. Exposure secret (depends on `ingress.exposure`)

| `exposure` | Secret keys | field |
|---|---|---|
| `none` (default) | — | `kubectl exec -it deploy/pi -c pi -- bash -lc pi` |
| `wireguard` (recommended) | `wg0.conf` (a standard WG client config) | `ingress.wireguard.configSecret` |
| `tailscale` | `authKey` | `ingress.tailscale.authKeySecret` |
| `cloudflare` | `token` | `ingress.cloudflare.tunnelTokenSecret` |
| `loadbalancer` | — | (no Secret) |

```bash
# WireGuard: the .conf your WG server generates when you add a peer.
# (Have only the raw values? See examples/wg-client.conf.template.)
kubectl -n "$NS" create secret generic pi-wg \
  --from-file=wg0.conf=pi-client.conf
```

> `scripts/prereq-secrets.sh` turns the staged files under `prereq/` (SSH pubkey,
> WG conf, optional auth.json) into the §0a/§0c Secrets and prints the exact
> `helm install` command. See §1.3.

---

## 1. Quick install from the published image

The `ghcr.io/dr34dl10n/pi-kube` package is **private by default**. Two paths:

### Path A — make the package public (simplest for a test)
GitHub → your profile/orga → **Packages** → `pi-kube` → **Package settings** →
*Danger Zone* → Change visibility → **Public**. No pull Secret needed; skip to §1.2.

### Path B — keep it private + imagePullSecret
The chart wires `global.imagePullSecrets` onto the ServiceAccount, Deployment
and Job. Create a pull Secret (PAT with `read:packages`):

```bash
kubectl -n "$NS" create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=dr34dl10n \
  --docker-password=<PAT_read:packages> \
  --docker-email=<your-email>
```

### 1.2 First test — `exposure: none` (validate the image boots)

Recommended first step: drop ingress entirely, reach the pod via `kubectl exec`.
This isolates "does the image/Pi boot" from any tunnel/SSH misconfig.

```bash
helm install pi ./charts/pi -n "$NS" -f examples/my-values.yaml \
  --set ingress.exposure=none \
  --set ingress.ssh.enabled=false \
  --set global.imagePullSecrets[0].name=ghcr-pull   # ← Path B only; omit if Path A
```

Verify (§5). Once the pod is `2/2 Running` and `pi` shows the TUI, add ingress.

### 1.3 Then — with WireGuard (recommended real access)

Stage your files under `prereq/` and let the helper build the Secrets for you,
then run the `helm install` it prints:
```bash
mkdir prereq
cp examples/my-values.yaml prereq/my-values.yaml
cp ~/.ssh/pi_key.pub     prereq/ssh_key.pub
cp pi-client.conf        prereq/wg.conf
# Path B (private ghcr): edit prereq/my-values.yaml to add imagePullSecrets
scripts/prereq-secrets.sh
# → creates pi-ssh-keys + pi-wg, prints: helm install pi ./charts/pi -n pi-kube -f prereq/my-values.yaml
# re-deploy after edits: helm upgrade pi ./charts/pi -n $NS -f prereq/my-values.yaml
```

Or the manual equivalent (Secrets from §0a/§0c):
```bash
helm upgrade pi ./charts/pi -n "$NS" -f examples/my-values.yaml \
  --set ingress.exposure=wireguard \
  --set ingress.ssh.enabled=true \
  --set ingress.ssh.authorizedKeysSecret=pi-ssh-keys \
  --set ingress.wireguard.configSecret=pi-wg \
  --set global.imagePullSecrets[0].name=ghcr-pull   # ← Path B only; omit if Path A
```

The WG sidecar (`ghcr.io/linuxserver/wireguard`, client mode) reads `wg0.conf`
from `/config/wg_confs` and dials out to your WG server — zero cluster ports.
See `charts/pi/README.md` §Ingress for `tailscale`/`cloudflare`/`loadbalancer`.

---

## 2. The container image

Published by CI on `v*` tags (`:<appVersion>`, `:latest`, `:-full`) and on `main`
(`:<appVersion>-<sha7>` snapshot). `values.yaml` defaults to `0.83.0`.

```bash
# release (from a v* tag) — the chart default:
--set image.tag="0.83.0"
# latest main snapshot (check the Actions "Resolve tags" step for the exact sha):
--set image.tag="0.83.0-<sha7>"
# batteries-included variant (fd, fzf, …):
--set image.tag="0.83.0-full"
```

> `:latest` is only pushed on `v*` tags — never trust it to track `main`.
>
> Building your own image (custom packages / private registry / offline cluster)
> is covered in `research/deploy-notes.md`.

---

## 3. Cluster prerequisites

```bash
kubectl get nodes         # 1.20+
kubectl get storageclass  # MUST return ≥1
```

**No StorageClass** → the 4 PVCs stay `Pending`, pod never schedules.
Install a provisioner (Rancher local-path, longhorn, …) and leave
`persistence.*.storageClassName: ""` (cluster default).

> Running on a bare-metal cluster with no StorageClass (static hostPath PVs) is
> covered in `research/deploy-notes.md`.

---

## 4. Exposure (how you reach the pod)

| Mode | Needs | Reach via |
|---|---|---|
| `none` (default) | — | `kubectl exec -it deploy/pi -c pi -- bash -lc pi` — zero ingress |
| `wireguard` (recommended) | Secret + a WG server you run | `ssh -p 2222 pi@<tunnel-ip>` — zero cluster ports exposed |
| `loadbalancer` | `type: LoadBalancer` + firewall | `ssh -p 2222 pi@<EXTERNAL-IP>` |
| `tailscale` | Secret `authKey` | `ssh -p 2222 pi@<tailnet-ip>` |
| `cloudflare` | Secret `token` | sshd over a Cloudflare tunnel |

> If your cluster is **already** behind a VPN/WireGuard at the node level, use
> `loadbalancer`: no pod-side sidecar, SSH on the LB/NodePort, reachable from
> inside the existing tunnel (see `examples/my-values.yaml`).

**LB without a provisioner:** `pi-ssh` gets `EXTERNAL-IP <pending>` but still
allocates a **NodePort** — reach it on any node: `ssh -p <NodePort> pi@<node-ip>`.
Don't `port-forward` (background forwards survive rollouts, leave stale binds).

**WireGuard:** needs `NET_ADMIN` + `/dev/net/tun`; on Pod Security `restricted`
clusters it may be blocked → fall back to `tailscale` or `none`.

---

## 5. Verify

```bash
kubectl -n pi-kube rollout status deploy/pi --timeout=180s
kubectl -n pi-kube get pod -l app.kubernetes.io/instance=pi
```

If `exposure: none`:
```bash
kubectl -n pi-kube exec -it deploy/pi -c pi -- bash -lc pi
# in the TUI: /login  (writes auth.json to the home PVC, persists)
```

If SSH/WireGuard is up:
```bash
NODEPORT=$(kubectl -n pi-kube get svc pi-ssh -o jsonpath='{.spec.ports[0].nodePort}')
ssh -p $NODEPORT -i ~/.ssh/pi_key -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -t pi@<node-ip>
```
Success: pod `2/2 Running` (containers `pi` + sshd sidecar); `pi` shows the TUI
with model + prompt visible.

---

## 6. Cleanup

```bash
helm uninstall pi -n pi-kube
kubectl delete ns pi-kube --wait=false
```
`helm uninstall` does NOT delete PVCs (reclaim `Retain`). Back up `/workspace`
before uninstall — there are no backups in v1.
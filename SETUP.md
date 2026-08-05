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
| 1 | A **StorageClass** (or static PVs) | Chart creates 4 PVCs | `kubectl get storageclass` ≥1, else install a provisioner (§3) |
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
| `wireguard` (recommended) | `privatekey, peer_pubkey, endpoint, allowedips` | `ingress.wireguard.configSecret` |
| `tailscale` | `authKey` | `ingress.tailscale.authKeySecret` |
| `cloudflare` | `token` | `ingress.cloudflare.tunnelTokenSecret` |
| `loadbalancer` | — | (no Secret) |

```bash
# WireGuard example (you run a WG server, UDP 51820):
kubectl -n "$NS" create secret generic pi-wg \
  --from-literal=privatekey="<pod private key>" \
  --from-literal=peer_pubkey="<your server public key>" \
  --from-literal=endpoint="203.0.113.10:51820" \
  --from-literal=allowedips="10.10.0.0/24"
```

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

```bash
helm upgrade pi ./charts/pi -n "$NS" -f examples/my-values.yaml \
  --set ingress.exposure=wireguard \
  --set ingress.ssh.enabled=true \
  --set ingress.ssh.authorizedKeysSecret=pi-ssh-keys \
  --set ingress.wireguard.configSecret=pi-wg \
  --set global.imagePullSecrets[0].name=ghcr-pull   # ← Path B only
```

`examples/my-values.yaml` already carries the wireguard defaults; the `--set`
flags above just make the command self-contained. See `charts/pi/README.md`
§Ingress for `tailscale`/`cloudflare`/`loadbalancer`.

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

**Build your own** (custom packages / private registry):
```bash
# slim (default) / full / custom packages — always pass --target explicitly:
docker build --target slim -t <registry>/pi-kube:0.83.0-slim -f charts/pi/docker/Dockerfile.pi .
docker build --target full  -t <registry>/pi-kube:0.83.0-full -f charts/pi/docker/Dockerfile.pi .
docker build --build-arg PACKAGES="terraform helm kubectl" --target slim \
             -t <registry>/pi-kube:0.83.0-custom -f charts/pi/docker/Dockerfile.pi .
# multi-arch: add --platform linux/amd64,linux/arm64
```
> Without `--target`, the last stage (`full`) is built — mismatches a `-slim` tag.
Then `--set image.repository=<registry>/pi-kube --set image.tag=…` and add
`global.imagePullSecrets` if the registry is private.

**Offline / no-registry cluster** (advanced): kaniko in-cluster build → in-cluster
`registry:2` → DaemonSet pre-loading each node's containerd with
`ctr … pull --plain-http` + `ctr images tag` to the DNS ref in `image.repository`,
and `image.pullPolicy: IfNotPresent`. ⚠️ **Bump the tag** to bust `IfNotPresent`
cache after a rebuild (same tag can serve stale layers). See `scripts/build-image.sh`.

---

## 3. Cluster prerequisites

```bash
kubectl get nodes         # 1.20+ ; tested on v1.35
kubectl get storageclass  # MUST return ≥1, or see below
```

**No StorageClass** → the 4 PVCs stay `Pending`, pod never schedules.
Install a provisioner (Rancher local-path, longhorn, …) and leave
`persistence.*.storageClassName: ""` (cluster default). This is the happy path.

**Workaround — static hostPath PVs:** pre-create dirs owned `1000:1000` on one
node (the chart runs as `pi:1000`; `fsGroup` does **not** chown hostPath), then
static PVs with `claimRef` pre-bound to the chart's PVC names
(`<release>-home/workspace/local-tools/ssh-host-keys`, `storageClassName: ""`),
and pin the pod with `--set nodeSelector.kubernetes\.io/hostname=<node>`.
Gotcha: mount the host dir at a non-`/tmp` path or you create `/tmp/tmp/<dir>`.

---

## 4. Exposure (how you reach the pod)

| Mode | Needs | Reach via |
|---|---|---|
| `none` (default) | — | `kubectl exec -it deploy/pi -c pi -- bash -lc pi` — zero ingress |
| `wireguard` (recommended) | Secret + a WG server you run | `ssh -p 2222 pi@<tunnel-ip>` — zero cluster ports exposed |
| `loadbalancer` | `type: LoadBalancer` + firewall | `ssh -p 2222 pi@<EXTERNAL-IP>` |
| `tailscale` | Secret `authKey` | `ssh -p 2222 pi@<tailnet-ip>` |
| `cloudflare` | Secret `token` | sshd over a Cloudflare tunnel |

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
ssh -p $NODEPORT -i ~/.ssh/pi_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -t pi@<node-ip>
```
Success: pod `2/2 Running` (containers `pi` + sshd sidecar); `pi` shows the TUI
with model + prompt visible.

---

## 6. Gotchas

- **No StorageClass → PVCs Pending.** Provisioner, or static PVs (§3).
- **Private ghcr → ImagePullBackOff.** Make the package public (Path A) or add
  `global.imagePullSecrets` (Path B, §1).
- **hostPath ownership:** `fsGroup` won't chown hostPath — pre-create `1000:1000`.
- **`LoadBalancer` w/o provisioner** still exposes a NodePort — use it, don't `port-forward`.
- **Bump the image tag** to bust `IfNotPresent` cache after a rebuild.
- **sshd config is a drop-in** (`/etc/ssh/sshd_config.d/00-pi.conf`) — `sshd_config`
  is first-occurrence-wins; the base image has `UsePAM yes` earlier. Don't append to main.
- **`pi-login` shebang `#!/bin/sh` is required** — sshd execs the login shell via the
  kernel; no shebang → `ENOEXEC` → channel closes right after auth.
- **`SHELL=/bin/sh` in the pi env** — so tmux runs pane commands (`cd /workspace && exec pi`)
  with a real shell, not `pi-login` (ignores `-c`, kills session on EOF).
- **`slim` image lacks `fd`** — Pi logs a cosmetic "offline mode" warning at startup.
  Use `full` for `fd`/`fzf`.

---

## 7. Cleanup

```bash
helm uninstall pi -n pi-kube
kubectl delete ns pi-kube --wait=false
kubectl delete pv pv-pi-home pv-pi-workspace pv-pi-local-tools pv-pi-ssh-hostkeys --wait=false
# hostPath dirs on the pinned node: privileged pod `rm -rf /hosttmp/pi-*`
```
`helm uninstall` does NOT delete PVCs (reclaim `Retain`). Commit/push `/workspace`
first — there are no backups in v1.
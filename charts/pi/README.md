# pi-kube — Helm chart for Pi Coding Agent

A community Helm chart to run [Pi Coding Agent](https://github.com/earendil-works/pi)
(`@earendil-works/pi-coding-agent`) in a Kubernetes pod, preserving all of its features:
interactive TUI, headless RPC/JSON/print modes, extensions/skills/themes, sessions, and
optional GPU.

## Quick start

Prerequisites: a cluster with a StorageClass and the image built/pullable
(see repo `SETUP.md` sections 0–2). Create the two Secrets the default install needs:

```bash
kubectl create namespace pi
# SSH authorized key (mounted at /home/pi/.ssh/authorized_keys)
kubectl -n pi create secret generic pi-ssh-keys \
  --from-file=authorized_keys=$HOME/.ssh/id_ed25519.pub
# WireGuard client config (key: wg0.conf — the .conf your WG server generates
# when you add a peer; see examples/wg-client.conf.template)
kubectl -n pi create secret generic pi-wg \
  --from-file=wg0.conf=pi-client.conf
```

```bash
# Default: interactive mode, `none` exposure (kubectl exec), sshd disabled, 3 PVCs.
# WireGuard is the recommended exposure for real access (zero public ports) —
# see section Ingress. Set ingress.exposure=wireguard + ingress.wireguard.configSecret.
helm install pi ./charts/pi -n pi \
  --set ingress.wireguard.configSecret=pi-wg \
  --set ingress.ssh.authorizedKeysSecret=pi-ssh-keys
```

Then reach the pod. With the default (`exposure: none`) use `kubectl exec`:

```bash
kubectl -n pi exec -it deploy/pi -c pi -- bash -lc pi
```

Or pick an exposure mode (see section Ingress). With WireGuard (recommended, zero public
ports), create the Secret and SSH in — you land in a tmux session running `pi`:

```bash
ssh -p 2222 pi@<pod-tunnel-ip>
```

## Modes

`pi.mode` selects the workload and entrypoint:

| `pi.mode`    | Workload    | Entrypoint             | Access                         |
|--------------|-------------|------------------------|--------------------------------|
| `interactive`| Deployment  | `pi-shell` (tmux+pi)   | SSH / ttyd / `kubectl exec`    |
| `rpc`        | Deployment  | `pi --mode rpc`        | JSONL over stdin/stdout (sidecar bridge) |
| `print`      | Job         | `pi -p "<job.prompt>"` | `kubectl logs`                 |
| `json`       | Job         | `pi --mode json "<job.prompt>"` | `kubectl logs` (JSONL)   |

```bash
# One-shot audit job
helm install audit ./charts/pi --set pi.mode=print --set job.prompt="Audit this repo"
kubectl logs job/audit -c pi
```

## Deployment vs StatefulSet

The MVP uses a **Deployment + explicit PVC** for 1 replica. This is simpler than a StatefulSet
and perfectly sufficient: the PVC is created by the chart and re-mounted by every new pod, so
config/sessions/workspace survive restarts.

- **Deployment** = interchangeable pods; with an external PVC the pod re-mounts the *same* volume
  on restart. Ideal for 1 replica.
- **StatefulSet** = ordered, named pods (`pi-0`) each with their own `volumeClaimTemplates`.
  Useful for N replicas with per-replica storage. Marginal benefit at 1 replica.
- **Recreate** strategy (not RollingUpdate): with 1 replica + RWO PVC, the old pod must release
  the volume before the new one starts.

`workload: statefulset` is accepted by the schema as a documented upgrade path; the chart renders
a Deployment by default. (A StatefulSet template is left as a follow-up.)

## Security profile

`pi.securityProfile`:

- **`permissive` (default):** writable rootfs, non-root (UID/GID 1000), `allowPrivilegeEscalation:
  false`, **capabilities drop ALL**, `seccompProfile: RuntimeDefault`. Lets the agent install
  tools and build *during a run*.
- **`strict`:** adds `readOnlyRootFilesystem: true` + an emptyDir `/tmp`. For untrusted/unattended
  work.

> ⚠️ **`permissive` does NOT persist system packages across pod restarts.** It only lets the
> process write *during* a run. Persistence is a separate concern — see below.

`runtimeClassName` (gVisor/Kata) is **off by default** — gVisor can break builds/tools. Enable it
only when you understand the impact.

## Persistence — 3-level model

A container has 3 storage layers: image layers (immutable), the writable container layer
(**ephemeral** — lost on every pod restart, even in `permissive`), and volumes (PVC, persistent).

The chart gives you all three levels so you choose where each tool lands:

| Level | Where | Persists? | Examples |
|-------|-------|-----------|----------|
| **1. Image** | baked in Dockerfile | ✅ across restarts | system packages (`apt install`) |
| **2. `~/.pi/agent` PVC** | `persistence.home` | ✅ | `pi install`, extensions/skills/themes, sessions, settings, auth.json |
| **3. `~/.local` + `/workspace` PVC** | `persistence.localTools` / `persistence.workspace` | ✅ | `npm i -g` (prefix `~/.local`), `pip install --user`, downloaded SDKs |
| writable container layer | `/usr`, `/etc` | ❌ lost on restart | `apt install x` at runtime |

**Rule of thumb:** to make a tool persist, install it on a PVC-mounted path
(`~/.pi/agent`, `~/.local`, `/workspace`). For a system package needed on every run, bake it into
a custom image (Level 1).

### Image variants (Level 1)

```bash
# slim (default chart image)
docker build --target slim -t ghcr.io/dr34dl10n/pi-kube:0.2.0 -f docker/Dockerfile.pi .
# full (batteries included)
docker build --target full -t ghcr.io/dr34dl10n/pi-kube:0.2.0-full -f docker/Dockerfile.pi .
# custom (your own apt packages)
docker build --build-arg PACKAGES="terraform helm kubectl" \
             -t myorg/pi-kube:0.2.0-custom -f docker/Dockerfile.pi .
```

Select with `image.tag` (e.g. `0.2.0-full`) or point `image.repository` at your custom image.

## No backups in v1

There is **no VolumeSnapshot or backup job**. Two safety rails:

1. **Commit & push** your code in `/workspace` *before* any `helm upgrade`, `helm uninstall`, or
   pod deletion.
2. `helm uninstall` does **not** delete PVCs (reclaim policy `Retain`). Delete them manually only
   when you really want to reclaim space.

`auth.json` lives in a Secret (re-mountable), so it survives even if the home PVC is lost.

## Ingress / exposure

The pod is unreachable from outside the cluster unless you tunnel in. **Default is
`none`** (safest: zero ingress, reach the pod with `kubectl exec`). **WireGuard is
the recommended exposure** for real access because it needs *no* port exposed on
the cluster: the pod dials out to *your* WireGuard server. (WireGuard is not the
default because a bare `helm install` would CrashLoop without a `configSecret`;
the chart fails fast at render time if the Secret is missing.)

| `ingress.exposure` | How you get in | Needs | Use case |
|---|---|---|---|
| **`none`** (default) | no sshd; `kubectl exec -it deploy/pi -c pi -- bash -lc pi` | RBAC `pods/exec` | simplest, zero ingress |
| **`wireguard`** (recommended) | sidecar WG **client** dials out to your WG server; SSH on the tunnel IP | Secret key `wg0.conf` (standard WG client config) | pod otherwise inaccessible, zero public ports ✅ |
| `tailscale`   | sidecar Tailscale, pod on tailnet | Secret `{authKey}` | managed WireGuard |
| `cloudflare`  | sidecar `cloudflared`, sshd over CF tunnel | Secret `{token}` | zero public ports, CF identity |
| `loadbalancer`| Service `type: LoadBalancer` TCP 2222 | LB + firewall/SG | cluster with a LB |
| `none`        | no sshd; `kubectl exec -it deploy/pi -c pi -- bash -lc pi` | RBAC `pods/exec` | simplest, zero ingress |

sshd runs in every mode except `none`. SSH host keys are persisted on a PVC (`ingress.ssh.hostKeysPVC`)
so the pod's identity is stable; `authorized_keys` come from a Secret. **The chart fails
fast at `helm install/template`** if `wireguard`/`tailscale`/`cloudflare` is selected
without its required Secret, instead of producing a CrashLooping pod.

### WireGuard setup (recommended)

1. Run a WireGuard **server** on a machine you control (public IP, UDP 51820).
2. Create a peer for the pod and produce a Secret from the client `.conf` your
   WG server generated:
   ```bash
   kubectl -n pi create secret generic pi-wg \
     --from-file=wg0.conf=pi-client.conf
   ```
   (Have only the raw values? Use `examples/wg-client.conf.template`.)
3. `helm install pi ./charts/pi --set ingress.wireguard.configSecret=pi-wg ...`
4. `ssh -p 2222 pi@<pod-tunnel-ip>` → tmux → `pi`.

The WireGuard sidecar has its own securityContext (`NET_ADMIN` + `/dev/net/tun`), isolated from the
`permissive` pi container. On clusters with Pod Security `restricted`, `NET_ADMIN` may be blocked —
fall back to `tailscale` or `none`.

## Credentials / auth

Two equivalent mechanisms (both Secret-compatible):

- **Env vars** (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, …): chart creates a Secret from
  `credentials.*ApiKey`, or you reference your own via `credentials.existingSecret`.
- **`auth.json`** (incl. OAuth tokens): mounted at `~/.pi/agent/auth.json` from a Secret
  (`credentials.authJson` or `credentials.authJsonSecret`). Survives PVC loss. Read-only
  when set — see the warning in `values.yaml` (blocks the interactive `/login` write path).

## Settings (`settings.json`)

The chart handles `~/.pi/agent/settings.json` differently by mode:

- **`interactive` (default):** no chart-managed `settings.json` — Pi creates and owns the
  file on the home PVC, so `/settings` (save) works and changes persist across restarts.
  Defaults are injected via env (`PI_OFFLINE`, `PI_TELEMETRY=0`, `PI_PROVIDER`, `PI_MODEL`…).
- **`rpc` / `print` / `json` (headless):** the chart mounts a read-only `settings.json`
  from a ConfigMap with `defaultProjectTrust: "always"` and `enableInstallTelemetry: false`
  (headless needs `defaultProjectTrust: always`, which has no env-var equivalent, to avoid
  silently ignoring project resources). `/settings` save is not used in headless modes.

`defaultProvider`/`defaultModel`/`defaultThinkingLevel` (if set in values) are baked into
the ConfigMap for headless modes and also injected as env vars in every mode.

## GPU

```yaml
pi:
  gpu:
    enabled: true
    count: 1
    # runtimeClassName: nvidia   # optional, defaults to top-level runtimeClassName
```

Adds `resources.limits.nvidia.com/gpu`. Use a `-full`/custom image with CUDA if you run llama.cpp.

## NetworkPolicy

`networkPolicy.egress`:

- `allowAllExceptMetadata` (default): free egress except `169.254.169.254`.
- `denyAll`: no egress (fully offline runs).
- `allowAll`: no restriction.

Add explicit rules with `networkPolicy.extraEgress`.

## ttyd (browser terminal, secondary)

`ingress.ttyd.enabled: true` adds a ttyd sidecar serving the same tmux session over WebSocket,
exposable via Service/Ingress. SSH+tmux remains the reference path.

## Values

See `values.yaml` for the full, commented reference. Key sections: `pi`, `persistence`,
`credentials`, `ingress`, `networkPolicy`, `job`, `serviceAccount`, `probes`.

## Verifying the chart

```bash
helm lint --strict ./charts/pi
helm template pi ./charts/pi
helm template pi ./charts/pi --set pi.mode=print --set job.prompt="hello"
```
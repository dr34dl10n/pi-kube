# pi-kube — expose your [Pi Coding Agent](https://github.com/earendil-works/pi) on Kubernetes, the easy & secure way 🤖⚓

**Goal:** take a running [Pi Coding Agent](https://github.com/earendil-works/pi)
harness and expose it on a Kubernetes cluster *simply* and *securely* — no
manual YAML juggling, no cluster ports left open by default. One Helm chart,
sane isolation defaults, and your agent is reachable over SSH / WireGuard in
minutes.

> 🙏 **BigUp** to [Pi](https://github.com/earendil-works/pi)
> ([`@earendil-works/pi-coding-agent`](https://www.npmjs.com/package/@earendil-works/pi-coding-agent))
> — without it this chart is just empty templates. Go star it. ⭐

### What is Pi?

Pi is a modern coding-agent **harness** (not just a chat client): it runs the
agent loop, manages sessions, mounts skills / themes / extensions, and talks to
*any* LLM provider. It ships an interactive TUI for hands-on work and headless
modes (RPC / JSON / print) for automation, keeps your config and sessions on
disk, and runs entirely on your own machine. Among today's agent harnesses it's
a genuine monster — provider-agnostic, scriptable, and built for real daily
driving, not demos. **pi-kube exists to put that monster in a pod you can reach
from anywhere.**

---

## 🧩 PREREQ — stage what the pod needs

The pod wants three small things (two are optional, depends on how you reach it):
an SSH pubkey, a WireGuard client config, and — only if you're going headless —
an `auth.json`. You stage them as plain files under `prereq/`, then one script
turns them into the K8s Secrets the chart expects.

```bash
mkdir prereq
cp examples/my-values.yaml prereq/my-values.yaml      # edit exposure / sizes if you like
cp ~/.ssh/id_ed25519.pub  prereq/ssh_key.pub           # required for wireguard & loadbalancer
cp pi-client.conf          prereq/wg.conf             # required for wireguard (your WG peer config)
cp ~/.pi/agent/auth.json   prereq/auth.json           # optional — pre-seeds login (read-only)
scripts/prereq-secrets.sh
```

The script creates the namespace + Secrets and prints the exact `helm install`
command to run next. Want the why behind each prereq? See `SETUP.md` section 0.

> Prefer doing it by hand? `SETUP.md` has the raw `kubectl create secret` for
> each mode (SSH keys, WG, tailscale, cloudflare, headless API keys).

---

## ⛵ HELM — install the chart

Just run the command the script printed. It looks like:

```bash
helm install pi ./charts/pi -n pi-kube -f prereq/my-values.yaml
#   --set credentials.authJsonSecret=pi-auth   # only if you staged auth.json
```

That's it — no API key needed at install for the interactive case. SSH in, run
`pi`, then `/login` in the TUI; `auth.json` lands on the home PVC and survives
restarts. (Inject a key only for headless/Job runs.)

`examples/my-values.yaml` carries your install-time choices (exposure, ssh,
persistence sizes) so you don't `--set` everything by hand. The full field
reference + rationale lives in `charts/pi/values.yaml`.

---

## 🔌 SSH — reach the pod

The pod is isolated by default (`exposure: none` → `kubectl exec`). For real
access, WireGuard is the sweet spot: the pod dials *out* to your WG server, so
**zero cluster ports** get exposed.

```bash
# once rollout is done:
kubectl -n pi-kube rollout status deploy/pi --timeout=180s
ssh -p 2222 pi@<pod-tunnel-ip>      # the Address from your wg.conf
```

You land in a `tmux` session running Pi. 🎉 All exposure modes
(`wireguard` / `tailscale` / `cloudflare` / `loadbalancer` / `none`) are
documented in `charts/pi/README.md` section Ingress.

---

## 🤖 Your Pi agent — `/login` and go

```bash
/login        # in the TUI — writes auth.json on the PVC, persists across restarts
```

Then it's just Pi: extensions, skills, themes, sessions — all preserved on the
home PVC. First-run validation tips and the `kubectl exec` fallback are in
`SETUP.md` section 5.

---

## 🐳 The container image

`ghcr.io/dr34dl10n/pi-kube:<chartVersion>` is **built from this repo** (not the
upstream npm image), via `charts/pi/docker/Dockerfile.pi`. The image is versioned
with the **chart** (`Chart.yaml` `version`); Pi's own npm version lives in
`appVersion` and is pinned inside the image — don't conflate the two.

```bash
scripts/build-image.sh                      # slim, local
VARIANT=full PUSH=1 scripts/build-image.sh  # full variant → push to ghcr
VARIANT=custom PACKAGES="terraform helm kubectl" PUSH=1 scripts/build-image.sh
```

| Variant | Tag pattern            | Use                          |
|---------|-----------------------|------------------------------|
| slim    | `:<chartVersion>`       | default chart image           |
| full    | `:<chartVersion>-full`  | batteries-included toolchain  |
| custom  | `:<chartVersion>-custom`| your own apt packages         |

CI (`.github/workflows/release.yml`) publishes `slim` + `full`
(linux/amd64 + arm64) on `v*` tags (`:<chartVersion>`, `:latest`, `:-full`) and on
`main` snapshots (`:<chartVersion>-<sha>`). The chart's `image.repository` already
points at ghcr — just pick `image.tag`.

```yaml
image:
  repository: ghcr.io/dr34dl10n/pi-kube
  tag: "0.2.0"        # or "0.2.0-full"
```

Private package? Make it public for a test, or wire a pull Secret
(`global.imagePullSecrets`) — see `SETUP.md` section 1.

## 🧭 Modes

| `pi.mode`     | Workload   | Access                         |
|---------------|------------|-------------------------------|
| `interactive` | Deployment | SSH / ttyd / `kubectl exec`    |
| `rpc`         | Deployment | JSONL over stdin/stdout        |
| `print`       | Job        | `kubectl logs`                 |
| `json`        | Job        | `kubectl logs` (JSONL)         |

## 📚 Repo layout & docs

```
pi-kube/
├── charts/pi/               # the Helm chart (templates, values.yaml, README)
│   └── docker/             # Dockerfile.pi + pi-shell/pi-login wrappers
├── scripts/
│   ├── prereq-secrets.sh    # stage files → K8s secrets, prints helm command
│   └── build-image.sh       # build/push the image (slim/full/custom)
├── examples/my-values.yaml  # minimal install values
└── .github/workflows/       # CI: build image + package the chart
```

- **Chart design & rationale:** `charts/pi/README.md`
- **Operational setup / from-scratch deploy test:** `SETUP.md`
- **Values reference:** `charts/pi/values.yaml`

## 🚧 In Development

This chart is early / community work. It renders lint-clean and has been
deployed end-to-end on a bare-metal cluster (see `SETUP.md`), and images are
published to `ghcr.io/dr34dl10n/pi-kube` by CI — but there are **no stability or
backward-compatibility guarantees yet**, and values / APIs may move between
releases. Use it, break it, send PRs. 🛠️
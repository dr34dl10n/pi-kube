# pi-kube — run your [Pi Coding Agent](https://github.com/earendil-works/pi) on Kubernetes 🤖⚓

A community Helm chart that drops Pi (`@earendil-works/pi-coding-agent`) into a pod
with everything it loves kept intact: interactive TUI, headless RPC/JSON/print
modes, extensions/skills/themes, sessions, optional GPU.

> Nobody had packaged Pi for Kubernetes yet — so here we are. ✨

The flow is four steps, top to bottom:

```
PREREQ → HELM → SSH → your Pi agent
```

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
command to run next. Want the why behind each prereq? See `SETUP.md` §0.

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
documented in `charts/pi/README.md` §Ingress.

---

## 🤖 Your Pi agent — `/login` and go

```bash
/login        # in the TUI — writes auth.json on the PVC, persists across restarts
```

Then it's just Pi: extensions, skills, themes, sessions — all preserved on the
home PVC. First-run validation tips and the `kubectl exec` fallback are in
`SETUP.md` §5.

---

## 🐳 The container image

`ghcr.io/dr34dl10n/pi-kube:<appVersion>` is **built from this repo** (not the
upstream npm image), via `charts/pi/docker/Dockerfile.pi`.

```bash
scripts/build-image.sh                      # slim, local
VARIANT=full PUSH=1 scripts/build-image.sh  # full variant → push to ghcr
VARIANT=custom PACKAGES="terraform helm kubectl" PUSH=1 scripts/build-image.sh
```

| Variant | Tag pattern            | Use                          |
|---------|-----------------------|------------------------------|
| slim    | `:<appVersion>`       | default chart image           |
| full    | `:<appVersion>-full`  | batteries-included toolchain  |
| custom  | `:<appVersion>-custom`| your own apt packages         |

CI (`.github/workflows/release.yml`) publishes `slim` + `full`
(linux/amd64 + arm64) on `v*` tags (`:<appVersion>`, `:latest`, `:-full`) and on
`main` snapshots (`:<appVersion>-<sha>`). The chart's `image.repository` already
points at ghcr — just pick `image.tag`.

```yaml
image:
  repository: ghcr.io/dr34dl10n/pi-kube
  tag: "0.83.0"        # or "0.83.0-full"
```

Private package? Make it public for a test, or wire a pull Secret
(`global.imagePullSecrets`) — see `SETUP.md` §1.

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

## ⚠️ Status

Early / community. The chart renders lint-clean and has been deployed
end-to-end on a bare-metal cluster (`SETUP.md`), but the image isn't on a
public registry yet and there are no release guarantees. PRs welcome. 🛠️
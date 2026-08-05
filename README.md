# pi-kube — run [Pi Coding Agent](https://github.com/earendil-works/pi) on Kubernetes

A community Helm chart to run Pi (`@earendil-works/pi-coding-agent`) in a pod,
preserving all of its features: interactive TUI, headless RPC/JSON/print modes,
extensions/skills/themes, sessions, and optional GPU.

> No one has packaged Pi for Kubernetes yet — this is that project.

## Repo layout

```
pi-kube/
├── charts/pi/              # the Helm chart (Chart.yaml, templates/, values.yaml, README)
│   └── docker/            # Dockerfile.pi + pi-shell/pi-login wrapper scripts
├── scripts/build-image.sh # build/push the container image (slim/full/custom)
├── examples/my-values.yaml # minimal install values
├── .github/workflows/      # CI: build & push image to ghcr + package the chart
└── SETUP.md                # operational guide from a from-scratch deploy test
```

## Quick start

1. **Install the chart** (you need a cluster with a StorageClass):

   ```bash
   helm install pi ./charts/pi -f examples/my-values.yaml
   ```

   No API key needed at install: SSH in, run `pi`, then `/login` in the TUI —
   `auth.json` is persisted on the home PVC. (Inject a key only for headless/Job
   runs.)

   `examples/my-values.yaml` carries the install-time choices (exposure,
   ssh keys, persistence sizes) so you don't `--set` everything by hand. Copy
   it and edit. The full field reference with rationale is
   `charts/pi/values.yaml`.

2. **Reach the pod.** It's unreachable from outside the cluster unless you
   tunnel in. The default exposure is `none` (safest — reach the pod with
   `kubectl exec`). WireGuard is the recommended exposure for real access (pod
   dials out — zero public ports). See `charts/pi/README.md` §Ingress for all
   modes (`wireguard`, `tailscale`, `cloudflare`, `loadbalancer`, `none`).

## The container image

The image `ghcr.io/dr34dl10n/pi-kube:<appVersion>` is **built from this repo** from
`charts/pi/docker/Dockerfile.pi`. It is not the upstream Pi npm package image.

Build it locally (slim/full/custom, optional multi-arch + push):

```bash
# slim, local only
scripts/build-image.sh

# full variant, push to ghcr (requires docker login to ghcr.io)
VARIANT=full PUSH=1 scripts/build-image.sh

# custom variant with extra apt packages baked in
VARIANT=custom PACKAGES="terraform helm kubectl" PUSH=1 scripts/build-image.sh
```

Tag conventions (derived from `charts/pi/Chart.yaml` `appVersion`):

| Variant | Tag pattern              | Use                         |
|---------|--------------------------|-----------------------------|
| slim    | `:<appVersion>`          | default chart image         |
| full    | `:<appVersion>-full`     | batteries-included toolchain |
| custom  | `:<appVersion>-custom`   | your own apt packages        |

### Publishing to ghcr.io

The `.github/workflows/release.yml` workflow builds the `slim` + `full`
variants (linux/amd64 + linux/arm64) and pushes them to
`ghcr.io/dr34dl10n/pi-kube` on:

- **`v*` tags** → release tags (`:<appVersion>`, `:<appVersion>-full`, `:latest`).
- **pushes to `main`** → snapshot tags (`:<appVersion>-<sha>`).

To use the published image, the chart's `image.repository` default already
points at `ghcr.io/dr34dl10n/pi-kube`; just pick the right `image.tag`:

```yaml
image:
  repository: ghcr.io/dr34dl10n/pi-kube
  tag: "0.83.0"        # or "0.83.0-full"
```

## Modes

| `pi.mode`     | Workload   | Access                         |
|---------------|------------|-------------------------------|
| `interactive` | Deployment | SSH / ttyd / `kubectl exec`    |
| `rpc`         | Deployment | JSONL over stdin/stdout        |
| `print`       | Job        | `kubectl logs`                 |
| `json`        | Job        | `kubectl logs` (JSONL)         |

## Documentation

- **Chart design & rationale:** `charts/pi/README.md`.
- **Operational setup / from-scratch deploy test:** `SETUP.md`.
- **Values reference:** `charts/pi/values.yaml`.

## Status

Early / community. The chart renders lint-clean and has been deployed
end-to-end on a bare-metal cluster (see `SETUP.md`), but the image is not yet
published on a public registry and there are no release guarantees.
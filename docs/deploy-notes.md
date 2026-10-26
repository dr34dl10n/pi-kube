# Deploy notes — from-scratch bare-metal test

Operational notes from deploying the chart on a bare-metal cluster with no
StorageClass and no LoadBalancer provisioner (3 nodes, k8s v1.35). Kept here
because `SETUP.md` stays on the happy path (see its sections 3–4).

## Static hostPath PVs (no StorageClass)

Without a StorageClass, the chart's 4 PVCs stay `Pending` and the pod never
schedules. The provisioner route (local-path, longhorn, …) is described in
`SETUP.md`; this test used static PVs instead:

1. Pre-create the dirs on **one node**, owned `1000:1000` — the chart runs as
   `pi:1000`, and `fsGroup` does **not** chown hostPath volumes.
2. Create static PVs with `claimRef` pre-bound to the chart's PVC names
   (`<release>-home`, `-workspace`, `-local-tools`, `-ssh-host-keys`),
   with `storageClassName: ""`.
3. Pin the pod to that node: `--set nodeSelector.kubernetes\.io/hostname=<node>`.

Gotcha: mount the host dir at a non-`/tmp` path, or you create `/tmp/tmp/<dir>`.

## The install that worked (this test)

```bash
helm install pi ./charts/pi -n pi-kube \
  --set image.repository=registry.pi-kube.svc.cluster.local:5000/pi-kube \
  --set image.tag=0.83.2-slim \
  --set image.pullPolicy=IfNotPresent \
  --set ingress.exposure=loadbalancer \
  --set ingress.ssh.authorizedKeysSecret=pi-ssh-keys \
  --set ingress.wireguard.configSecret="" \
  --set nodeSelector.kubernetes\.io/hostname=k8s-w1
```

## Gotchas (from this test)

- **`fsGroup` won't chown hostPath** — pre-create the dirs as `1000:1000`
  (see above).
- **Bust the `IfNotPresent` cache** after rebuilding an image locally: bump the
  tag, or set `image.pullPolicy: Always` — with a same-tag rebuild the node
  happily serves the stale image.
- **sshd config is a drop-in** (`/etc/ssh/sshd_config.d/00-pi.conf`) — the base
  image ships `UsePAM yes` and sshd is first-occurrence-wins, so overrides must
  live in the drop-in, never be appended to `sshd_config`.
- **`pi-login`'s `#!/bin/sh` shebang is load-bearing** — sshd execs the login
  shell via the kernel; without a shebang you get `ENOEXEC` and the SSH channel
  closes right after auth.
- **`SHELL=/bin/sh` in the pi env** — tmux runs pane commands
  (`cd /workspace && exec pi`) with a real shell, not `pi-login` (which ignores
  `-c` and would kill the session on EOF).
- **the `slim` image lacks `fd`** — Pi logs a cosmetic "offline mode" warning at
  startup; use the `full` variant for `fd`/`fzf`.
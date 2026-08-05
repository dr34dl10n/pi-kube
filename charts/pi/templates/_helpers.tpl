{{/*
pi-kube — shared helpers
*/}}

{{- define "pi.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "pi.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "pi.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "pi.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels.
*/}}
{{- define "pi.labels" -}}
helm.sh/chart: {{ include "pi.chart" . }}
{{ include "pi.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: pi-kube
{{- end -}}

{{- define "pi.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pi.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: pi
{{- end -}}

{{- define "pi.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "pi.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Resolved image reference.
*/}}
{{- define "pi.image" -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}

{{/*
Is the workload a long-lived Deployment (interactive/rpc) vs a one-shot Job
(print/json)?
*/}}
{{- define "pi.isDeployment" -}}
{{- if or (eq .Values.pi.mode "interactive") (eq .Values.pi.mode "rpc") -}}true{{- end -}}
{{- end -}}

{{- define "pi.isJob" -}}
{{- if or (eq .Values.pi.mode "print") (eq .Values.pi.mode "json") -}}true{{- end -}}
{{- end -}}

{{/*
sshd runs for every exposure mode except `none` (and when explicitly disabled).
Only meaningful for the long-lived Deployment: the Job has no sshd sidecar, so we
never create the ssh-host-keys PVC/volume/Service for a Job.
*/}}
{{- define "pi.sshEnabled" -}}
{{- if and (include "pi.isDeployment" .) .Values.ingress.ssh.enabled (ne .Values.ingress.exposure "none") -}}true{{- end -}}
{{- end -}}

{{/*
WireGuard / Tailscale / Cloudflare sidecars are mutually exclusive exposure modes.
*/}}
{{- define "pi.wireguardEnabled" -}}
{{- if eq .Values.ingress.exposure "wireguard" -}}true{{- end -}}
{{- end -}}

{{- define "pi.tailscaleEnabled" -}}
{{- if eq .Values.ingress.exposure "tailscale" -}}true{{- end -}}
{{- end -}}

{{- define "pi.cloudflareEnabled" -}}
{{- if eq .Values.ingress.exposure "cloudflare" -}}true{{- end -}}
{{- end -}}

{{- define "pi.loadbalancerEnabled" -}}
{{- if eq .Values.ingress.exposure "loadbalancer" -}}true{{- end -}}
{{- end -}}

{{/*
Fail-fast validation: an exposure mode that requires a sidecar Secret must
have one, otherwise the pod would CrashLoop (wireguard/tailscale) or do
nothing (cloudflare). Fail at render time so `helm install/template` errors
out with an actionable message instead of producing a broken pod.
*/}}
{{- define "pi.validate" -}}
{{- $exp := .Values.ingress.exposure -}}
{{- if and (eq $exp "wireguard") (not .Values.ingress.wireguard.configSecret) -}}
{{- fail "ingress.exposure=wireguard requires ingress.wireguard.configSecret (a Secret with keys: privatekey, peer_pubkey, endpoint, allowedips). Set ingress.wireguard.configSecret or use ingress.exposure=none (kubectl exec access)." -}}
{{- end -}}
{{- if and (eq $exp "tailscale") (not .Values.ingress.tailscale.authKeySecret) -}}
{{- fail "ingress.exposure=tailscale requires ingress.tailscale.authKeySecret (a Secret with key: authKey). Set it or use ingress.exposure=none." -}}
{{- end -}}
{{- if and (eq $exp "cloudflare") (not .Values.ingress.cloudflare.tunnelTokenSecret) -}}
{{- fail "ingress.exposure=cloudflare requires ingress.cloudflare.tunnelTokenSecret (a Secret with key: token). Set it or use ingress.exposure=none." -}}
{{- end -}}
{{- end -}}

{{/*
Build the env block for the pi container: Pi runtime vars + provider keys +
user extraEnv. Returns a list rendered as `env:` entries.
*/}}
{{- define "pi.env" -}}
- name: PI_CODING_AGENT_DIR
  value: {{ .Values.persistence.home.mountPath | quote }}
- name: PI_OFFLINE
  value: {{ .Values.pi.offline | ternary "1" "0" | quote }}
- name: PI_SKIP_VERSION_CHECK
  value: "1"
- name: PI_TELEMETRY
  value: "0"
- name: HOME
  value: "/home/pi"
- name: PATH
  value: "/home/pi/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# SHELL must be a real shell (/bin/sh), NOT the user's login shell (pi-login).
# tmux uses $SHELL (or the passwd login shell) as default-shell for panes; pi-login
# ignores -c (it attaches to tmux / falls back to /bin/sh on EOF) so pane commands
# like `cd /workspace && exec pi` would never run and the session would die at once.
# SSH login still uses pi-login (sshd reads /etc/passwd, not $SHELL).
- name: SHELL
  value: "/bin/sh"
{{- if .Values.pi.defaultProvider }}
- name: PI_PROVIDER
  value: {{ .Values.pi.defaultProvider | quote }}
{{- end }}
{{- if .Values.pi.defaultModel }}
- name: PI_MODEL
  value: {{ .Values.pi.defaultModel | quote }}
{{- end }}
{{- with .Values.pi.extraEnv }}
{{- toYaml . }}
{{- end }}
{{- end -}}

{{/*
securityContext for the pi container, per `pi.securityProfile`.
permissive: writable rootfs, non-root UID 1000, drop ALL caps, no privilege esc.
strict:     readOnlyRootFilesystem, same identity, tmp via emptyDir.
*/}}
{{- define "pi.containerSecurityContext" -}}
runAsNonRoot: true
runAsUser: 1000
runAsGroup: 1000
allowPrivilegeEscalation: false
privileged: false
capabilities:
  drop:
    - ALL
seccompProfile:
  type: RuntimeDefault
{{- if eq .Values.pi.securityProfile "strict" }}
readOnlyRootFilesystem: true
{{- else }}
readOnlyRootFilesystem: false
{{- end }}
{{- end -}}

{{/*
The command for the pi container depending on mode.
interactive: sleep infinity via the pi-shell supervisor (sshd/tmux land here).
rpc:         pi --mode rpc, long-lived.
print/json:  one-shot, prompt from .Values.job.prompt.
*/}}
{{- define "pi.command" -}}
{{- if eq .Values.pi.mode "interactive" -}}
- /usr/local/bin/pi-shell
{{- else if eq .Values.pi.mode "rpc" -}}
- pi
- --mode
- rpc
{{- else if eq .Values.pi.mode "print" -}}
- pi
- -p
- {{ .Values.job.prompt | quote }}
{{- else if eq .Values.pi.mode "json" -}}
- pi
- --mode
- json
- {{ .Values.job.prompt | quote }}
{{- end -}}
{{- end -}}

{{/*
Volumes + volumeMounts shared by Deployment and Job.
*/}}
{{- define "pi.volumes" -}}
{{- if .Values.persistence.home.enabled -}}
- name: home
  persistentVolumeClaim:
    claimName: {{ include "pi.fullname" . }}-home
{{- end }}
{{- if .Values.persistence.workspace.enabled }}
- name: workspace
  persistentVolumeClaim:
    claimName: {{ include "pi.fullname" . }}-workspace
{{- end }}
{{- if .Values.persistence.localTools.enabled }}
- name: local-tools
  persistentVolumeClaim:
    claimName: {{ include "pi.fullname" . }}-local-tools
{{- end }}
{{- if eq .Values.pi.securityProfile "strict" }}
- name: tmp
  emptyDir: {}
{{- end }}
{{- if include "pi.sshEnabled" . }}
- name: ssh-host-keys
{{- if .Values.ingress.ssh.hostKeysPVC }}
  persistentVolumeClaim:
    claimName: {{ include "pi.fullname" . }}-ssh-host-keys
{{- else }}
  emptyDir: {}
{{- end }}
{{- if .Values.ingress.ssh.authorizedKeysSecret }}
- name: ssh-authorized-keys
  secret:
    secretName: {{ .Values.ingress.ssh.authorizedKeysSecret | quote }}
    defaultMode: 0644
{{- end }}
{{- end }}
{{- if .Values.credentials.authJsonSecret }}
- name: auth-json
  secret:
    secretName: {{ .Values.credentials.authJsonSecret | quote }}
    defaultMode: 0400
{{- else if .Values.credentials.authJson }}
- name: auth-json
  secret:
    secretName: {{ include "pi.fullname" . }}-auth
    defaultMode: 0400
{{- end }}
{{- if ne .Values.pi.mode "interactive" }}
- name: settings
  configMap:
    name: {{ include "pi.fullname" . }}-settings
    defaultMode: 0644
{{- end }}
{{- end -}}

{{- define "pi.volumeMounts" -}}
{{- if .Values.persistence.home.enabled -}}
- name: home
  mountPath: {{ .Values.persistence.home.mountPath | quote }}
{{- end }}
{{- if .Values.persistence.workspace.enabled }}
- name: workspace
  mountPath: {{ .Values.persistence.workspace.mountPath | quote }}
{{- end }}
{{- if .Values.persistence.localTools.enabled }}
- name: local-tools
  mountPath: {{ .Values.persistence.localTools.mountPath | quote }}
{{- end }}
{{- if eq .Values.pi.securityProfile "strict" }}
- name: tmp
  mountPath: /tmp
{{- end }}
{{- if include "pi.sshEnabled" . }}
- name: ssh-host-keys
  mountPath: /etc/ssh/host-keys
{{- if .Values.ingress.ssh.authorizedKeysSecret }}
- name: ssh-authorized-keys
  mountPath: /home/pi/.ssh/authorized_keys
  subPath: authorized_keys
{{- end }}
{{- end }}
{{- if or .Values.credentials.authJsonSecret .Values.credentials.authJson }}
- name: auth-json
  mountPath: {{ printf "%s/auth.json" .Values.persistence.home.mountPath | quote }}
  subPath: auth.json
  readOnly: true
{{- end }}
{{- if ne .Values.pi.mode "interactive" }}
- name: settings
  mountPath: {{ printf "%s/settings.json" .Values.persistence.home.mountPath | quote }}
  subPath: settings.json
  readOnly: true
{{- end }}
{{- end -}}
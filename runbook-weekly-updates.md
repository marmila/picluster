# Runbook: Weekly Cluster Updates

**Cluster:** picluster (k3s HA, FluxCD GitOps)
**Cadence:** every Monday, ~15–30 min. Critical updates one at a time, when you can watch.
**Tracking:** a `Weekly maintenance YYYY-Www` issue opens every Monday at 07:00 UTC with this checklist and that week's PRs. Closing it records the week as done.

---

## How updates reach the cluster

```
Renovate opens PR ──> you merge into master ──> Flux applies it (within minutes) ──> alerts on ntfy if it fails
```

Nothing reaches the cluster until it is merged into `master`. Your merge is the "go" button.

| What | Who merges | When | Reaches the cluster? |
|---|---|---|---|
| **all non-major dependencies** (charts, images, Ansible, Terraform) | you | weekly bundle, Monday | yes, on merge |
| **Critical:** k3s, system-upgrade-controller, Longhorn, Istio, CloudNativePG, Vault, Cilium, Flux operator | you, one at a time | when you can watch | yes, on merge |
| **Major versions** (`type/major`) | you, after reading release notes | no rush | yes, on merge |
| **Other:** CLI tool groups (helm, kubectl, velero, flux CLI) | you, any time | any time | no, workstation and ansible-runner only |
| mise tools, GitHub Actions, Grafana dashboards | Renovate (automerge) | automatically | dashboards only |
| **Blocked** (`blocked` label) | **never** | | |

Ansible, Terraform and ansible-runner changes only take effect when you run `make …` / `tofu` or rebuild the runner.

### Blocked packages

| Package | Why | Unblock when |
|---|---|---|
| `ubuntu` v26 | nodes run Ubuntu 24.04 LTS; tag is the base of `metal/x86/build/Dockerfile` | nodes move to a new LTS |
| `elastic/elasticsearch` v9 | fluent-plugin-elasticsearch breaks on ES 9 ([#1061](https://github.com/uken/fluent-plugin-elasticsearch/issues/1061)); would break Fluentd → threatmap ingestion | the plugin works with ES 9 |

The block list lives in `.github/renovate/automerge.json5` (add the name in both places noted there).
The `mongo` client image is capped at `<8.1` to match the MongoDB 8.0.x server; raise it when the server is upgraded.

---

## Weekly procedure

### 1. Before you start

- No unresolved alerts on ntfy.
- healthchecks.io check `picluster` is green. If it is red, alerting itself is broken: fix that first, you would not be told about problems.

If something is already broken, fix it before merging anything. Otherwise you can't tell old problems from new ones.

### 2. Merge the weekly bundle

1. Open the **all non-major dependencies** PR from the weekly issue.
2. Skim the PR description: Renovate lists every package with release notes. Look for "breaking", "removed", "migration".
3. CI green → **Merge pull request** → **Confirm merge**.

### 3. Health check (15 min after any merge)

Run on node2:

```bash
echo "== nodes";            kubectl get nodes -o wide
echo "== unhealthy pods";   kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
echo "== helmreleases";     kubectl get helmreleases -A | grep -v "True"
echo "== kustomizations";   kubectl get kustomizations -A | grep -v "True"
echo "== longhorn volumes"; kubectl -n longhorn-system get volumes.longhorn.io | grep -v healthy
```

Each section should be empty apart from its header lines. A HelmRelease showing `Unknown` for a few minutes is normal while it upgrades.

The alerts below watch the same things continuously, so you don't need to keep checking. They reach ntfy if something stays broken for 15 minutes.

### 4. Critical updates (one per session)

Merge at most **one** critical PR per session. Run the health check after it, and only move on once it's clean.

Suggested order: Vault → CloudNativePG → Cilium → Istio → Longhorn → Flux operator → system-upgrade-controller → **k3s last**.

- **Longhorn:** check that all volumes are `healthy` before *and* after. Longhorn does not support downgrades, so you cannot roll it back.
- **CloudNativePG:** the operator restarts Postgres pods (Keycloak DB, e-commerce DB). Expect a short Keycloak blip.
- **Istio:** control plane first, then the data plane restarts. Check the gateway and ingress still answer.

#### k3s upgrade

Merging the k3s PR makes system-upgrade-controller upgrade every node, control plane first, **one node at a time** (cordon → upgrade → uncordon). Plan for about an hour and stay around.

```bash
kubectl -n system-upgrade get plans,jobs
kubectl get nodes -w          # watch VERSION change node by node
```

The upgrade is finished when all nodes show the new version.

**If it gets stuck:** a failed upgrade job is **never retried** by system-upgrade-controller (this left node6 behind from 2026-09-27 to 2026-11-07). You get `KubeJobFailed` (namespace `system-upgrade`) and later `KubeVersionMismatch` on ntfy. Fix the node problem (power, disk, network), then:

```bash
kubectl -n system-upgrade delete job <failed-job>
kubectl -n system-upgrade rollout restart deploy/system-upgrade-controller
```

k3s cannot be downgraded either, so fix forward.

### 5. Close the weekly issue

Tick the checklist, comment anything unusual, close the issue.

---

## Monthly

- **Majors:** go through the `type/major` PRs. Read the release notes (or paste the PR link to Claude), then merge one or leave it for later.
- **OS packages:** `make os-upgrade` (runs node by node), then reboot following `runbook-node-os-reboot.md` if a restart is required.
- **Stale PRs:** close Renovate PRs you will never merge. Renovate then stops offering that version.

---

## Alerts (ntfy) and what to do

| Alert | Severity | Meaning | Action |
|---|---|---|---|
| `FluxHelmReleaseNotReady` | critical | a chart install or upgrade failed for 15 min | `kubectl -n <ns> describe helmrelease <name>`; often bad values or a breaking chart change → revert the PR |
| `FluxKustomizationNotReady` | critical | Flux can't apply a folder from Git, or a dependency failed | `kubectl -n flux-system describe kustomization <name>` |
| `FluxSourceNotReady` | warning | Flux can't fetch Git, a chart or an OCI artifact | version doesn't exist, registry down, or credentials |
| `FluxResourceSuspended` | warning | something suspended for over 24h | resume it once the fix is done |
| `KubeJobFailed` (system-upgrade) | warning | a k3s node upgrade failed | see "If it gets stuck" above |
| `KubeVersionMismatch` | warning | nodes on different k3s versions | upgrade unfinished, same fix |
| healthchecks.io email/alert | | Watchdog pings stopped: Prometheus or Alertmanager is down | check `kube-prom-stack` pods; you are blind until fixed |

---

## Rolling back

1. On the merged PR, click **Revert** → merge the revert PR.
2. Flux applies the previous version within minutes. Check with the health check.

Rollback doesn't work for **Longhorn**, **k3s** or **database major versions** (no downgrades): fix forward instead. That's why they go one at a time.

---

## Automation in place

| Piece | Where |
|---|---|
| Renovate grouping, schedule, automerge, block list | `.github/renovate.json5`, `.github/renovate/*.json5` |
| Weekly maintenance issue | `.github/workflows/weekly-maintenance.yml` + `.github/maintenance-checklist.md` |
| Flux failure alerts | `kubernetes/platform/kube-prometheus-stack/app/components/flux-monitoring/flux-alert-rules.yaml` |
| Alert routing to ntfy and healthchecks.io | `kubernetes/platform/kube-prometheus-stack/app/components/alertmanager-notifications/` |

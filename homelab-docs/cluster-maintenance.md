# Runbook: Cluster Maintenance and Updates

**Cluster:** picluster (k3s HA, FluxCD GitOps)
**Owner:** Marco
**Where to run commands:** `kubectl` on **node2** (no `flux` CLI there), host commands on **node1**, `gh` on the workstation.

This document is the single reference for keeping the cluster up to date and healthy: how Renovate works in this repo, what runs automatically, and what you do daily, weekly, monthly and after specific events.

---

## 0. The schedule at a glance

| When | Time | What | Section |
|---|---|---|---|
| **Daily** | 1 min | look at ntfy; act only if there is an alert | [3](#3-daily-1-minute) |
| **Monday** | 15–30 min | weekly maintenance issue: merge the weekly bundle, health check | [4](#4-weekly-monday-1530-minutes) |
| **During the week** | 30–60 min each | merge **one** critical update when you can watch (k3s last) | [5](#5-critical-updates-one-at-a-time) |
| **First Monday of the month** | 30–60 min | majors, OS packages, backups check, stale PRs | [6](#6-monthly-first-monday) |
| **After events** | varies | k3s upgrade, node reboot, power outage, volume resize | [7](#7-event-driven-procedures) |

Times are UTC. Renovate creates the bundle **before 06:00 UTC on Monday**, and the weekly issue opens at **07:00 UTC**.

---

## 1. How updates reach the cluster

```
 new version released
        │  (wait 3 days: minimumReleaseAge)
        ▼
 Renovate opens / updates a PR  ──────────────►  automerge?  ──yes──►  merged by Renovate
        │ no                                    (tools, CI, dashboards)
        ▼
 you review and merge into master
        │
        ▼
 Flux sees the new commit on master (minutes) and applies it to the cluster
        │
        ▼
 if it fails or hangs for 30 min ──► Prometheus alert ──► Alertmanager ──► ntfy on your phone
```

Nothing reaches the cluster until it is merged into `master`. **Your merge is the "go" button.**

Only Grafana dashboard updates reach the cluster without you (via automerge). They are harmless.

---

## 2. How Renovate works in this repo

### 2.1 Where it runs

- Renovate runs as the **Mend Renovate GitHub App** on `marmila/picluster` (hosted, nothing to run yourself). Job logs: <https://developer.mend.io/github/marmila/picluster>.
- It reads its configuration **from `master` only**. Config changes on a branch have no effect until merged.
- It runs several times per hour, but creates PRs only within its schedule.

### 2.2 Configuration files

| File | What it does |
|---|---|
| `.github/renovate.json5` | entry point: presets to load, file patterns per manager (flux, helm-values, kubernetes, kustomize, ansible, …), PR limit 20, dashboard title |
| `.github/renovate/clusters.json5` | updates under `kubernetes/clusters/prod` or `dev` get a `prod-` / `dev-` branch prefix and a `[prod]` / `[dev]` suffix |
| `.github/renovate/customManagers.json5` | finds versions that are not in a standard format: `# renovate: datasource=… depName=…` comments, CloudNativePG `imageName`, Ansible Helm/OCI charts |
| `.github/renovate/grafanaDashboards.json5` | tracks Grafana.com dashboard revisions |
| `.github/renovate/automerge.json5` | weekly bundle, automerge rules, **block list**, mongo version cap |
| `.github/renovate/groups.json5` | named groups: one PR per tool or critical component |
| `.github/renovate/labels.json5` | labels: `type/major` / `minor` / `patch`, and `renovate/<source>` |

Rules are applied in the order the presets are listed. A later rule overrides an earlier one, so the named groups in `groups.json5` win over the weekly bundle.

### 2.3 What kind of PR you get

| PR | Contains | Created | Merged by |
|---|---|---|---|
| **all non-major dependencies** | all minor/patch/digest updates not covered below: Helm charts, images, Ansible collections, Terraform providers, Python deps | Monday before 06:00 UTC | **you** |
| **Critical groups:** `k3s`, `Longhorn`, `Istio`, `CloudNativePG`, `Vault`, `Cilium`, `Flux` (operator), `system-upgrade-controller` | one PR per component | Monday | **you, one at a time** |
| **Tool groups:** `Helm CLI`, `kubectl`, `Flux CLI`, `Velero CLI`, `Prometheus Operator CRDs` | the same tool pinned in several files (mise, Dockerfile, Ansible) bumped together | Monday | you, any time |
| **tooling** | `.mise.toml` workstation tools and GitHub Actions (minor/patch) | Monday | **Renovate** (automerge after CI passes) |
| **Grafana dashboards** | dashboard revision bumps | any time | **Renovate** (automerge) |
| **Majors** (`type/major`) | one PR per package | any time | **you, after reading release notes** |
| **Blocked** (`blocked` label) | packages on the block list | any time | **never** |

Automerge uses **branch automerge**: Renovate pushes straight to `master` once CI passes, so no PR appears.

### 2.4 Blocked packages and caps

| Package | Rule | Why | Lift it when |
|---|---|---|---|
| `ubuntu` | blocked | nodes run Ubuntu 24.04 LTS; tag is the base of `metal/x86/build/Dockerfile` | nodes move to a new LTS |
| `elastic/elasticsearch` | blocked | fluent-plugin-elasticsearch breaks on ES 9 ([#1061](https://github.com/uken/fluent-plugin-elasticsearch/issues/1061)); would break Fluentd → threatmap ingestion | the plugin works with ES 9 |
| `mongo` | capped `<8.1` | the seed job's `mongosh` must match the MongoDB **8.0.x** server (`mongodb-community.yaml`, not tracked by Renovate) | you upgrade the MongoDB server |

Blocked packages never join a group and are never automerged. Their PRs get the `blocked` label automatically. **Blocking covers the whole package**, so Elasticsearch 8.x patches also come as separate blocked PRs.

**To block a package:** in `.github/renovate/automerge.json5` add the name to both lists (the negated `!name` list in the weekly bundle rule, and the "Blocked packages" rule). Merge to `master`.

**To unblock:** remove it from both lists.

### 2.5 The Renovate Dashboard (issue #238)

| Section | Meaning | What you can do |
|---|---|---|
| Awaiting Schedule | waiting for Monday | tick to create the PR now |
| Rate-Limited | PR limit (20) or hourly limit reached | tick to force it, or close stale PRs |
| Pending Status Checks | waiting the 3-day release age, or CI | nothing; it appears on its own |
| Open | PRs that exist | tick to rebase or retry |
| Detected Dependencies | everything Renovate tracks | reference |
| Repository Problems | config or lookup warnings | fix if new |

### 2.6 Closing a Renovate PR

Closing a PR (without merging) tells Renovate to **ignore that version**. It won't offer it again until a newer version appears. Use it for updates you will never take. For "not now", leave the PR open.

---

## 3. Daily (1 minute)

1. **ntfy:** any alert since yesterday? If none → done.
2. If there is one → look it up in [section 8](#8-alerts-and-what-to-do).
3. **healthchecks.io** emails or alerts you only if the Watchdog stops. That means alerting is down and you are blind: fix it first.

Nothing else daily. Renovate, Flux, backups (Velero, 02:00 UTC) and alerting run on their own.

---

## 4. Weekly: Monday (15–30 minutes)

The **"Weekly maintenance YYYY-Www"** issue (label `maintenance`) opens at 07:00 UTC. It contains this checklist and the open Renovate PRs sorted into: weekly bundle / critical / major / other / blocked. If it didn't open, run it by hand: GitHub → **Actions** → **Weekly maintenance** → **Run workflow**.

### 4.1 Before you start

- No unresolved alerts on ntfy.
- healthchecks.io check `picluster` is green.
- Quick health check (4.3) is clean.

**If something is already broken, fix it first.** Otherwise you can't tell old problems from new ones.

### 4.2 Merge the weekly bundle

1. Open the **all non-major dependencies** PR (linked in the issue).
2. Read the PR description: Renovate lists every package with links to release notes. Look for **breaking**, **removed**, **deprecated**, **migration**, **requires**.
3. If one package looks risky: tick it off in the Dependency Dashboard, or merge the rest and deal with it separately.
4. CI green → **Merge pull request** → **Confirm merge**.

### 4.3 Health check (15 minutes after any merge)

Run on node2:

```bash
echo "===== NODES";            kubectl get nodes -o wide
echo "===== UNHEALTHY PODS";   kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
echo "===== NOT READY PODS";   kubectl get pods -A --no-headers | awk '{split($3,a,"/"); if (a[1]!=a[2] && $4=="Running") print}'
echo "===== HELMRELEASES";     kubectl get helmreleases -A | grep -v "True"
echo "===== KUSTOMIZATIONS";   kubectl get kustomizations -A | grep -v "True"
echo "===== LONGHORN VOLUMES"; kubectl -n longhorn-system get volumes.longhorn.io | grep -v healthy
echo "===== POSTGRES";         kubectl -n databases get clusters.postgresql.cnpg.io
```

**Clean** means each section shows only its header lines, and every Postgres cluster says `Cluster in healthy state`.

`Unknown` / "reconciliation in progress" for a few minutes right after a merge is normal.

If a Kustomization says `DependencyNotReady`, it's only waiting. Follow the `dependency '…' is not ready` chain to the **one** that has a different reason: that's the one to fix.

### 4.4 Close the issue

Tick the checklist, add a comment if anything was unusual, close the issue. The closed issues are your maintenance log.

---

## 5. Critical updates (one at a time)

Rules:
- **One critical PR per session.** Merge, run the health check (4.3), and only continue when it's clean.
- Do them when you have **30–60 minutes** to watch.
- Order: **Vault → CloudNativePG → Cilium → Istio → Longhorn → Flux operator → system-upgrade-controller → k3s (always last)**.

| Component | Watch out for | Can roll back? |
|---|---|---|
| Vault | Vault on node1 (`hashicorp/vault`) is Ansible: merging only changes the repo; apply with `make external-services`. The in-cluster chart is the agent injector | yes |
| CloudNativePG | operator restart; Postgres pods may restart → short Keycloak blip. Check `kubectl -n databases get clusters.postgresql.cnpg.io` | operator yes, DB major versions no |
| Cilium | CNI: brief network blips while agents roll node by node | yes, carefully |
| Istio | control plane first, then ztunnel/CNI roll. Check gateway and ingress answer | yes |
| Longhorn | all volumes `healthy` **before and after**. Engine upgrades run in the background | **no** (no downgrades) |
| Flux operator | Flux controllers restart; reconciliation pauses briefly | yes |
| system-upgrade-controller | runs k3s upgrades; check the controller pod restarts cleanly | yes |
| **k3s** | upgrades every node (see 7.1) | **no** |

---

## 6. Monthly: first Monday

1. **Major updates** (`type/major` label):
   - Read the release notes (or paste the PR link to Claude for a review).
   - Merge one at a time like critical updates, or leave it open for later.
   - Close the ones you will never take ([2.6](#26-closing-a-renovate-pr)).
2. **OS packages:** on node1 run `make os-upgrade` (cluster nodes one at a time). If nodes report `*** System restart required ***`, reboot them following [node-os-reboot.md](node-os-reboot.md), then do [7.2](#72-after-a-node-reboot-or-k3s-agent-restart).
3. **Backups:** check that the last Velero backups completed:
   ```bash
   kubectl -n velero get backups --sort-by=.metadata.creationTimestamp | tail -4
   ```
   All should be `Completed`. Daily full backup at 02:00 UTC, kept 72h.
4. **Disk space:**
   ```bash
   kubectl -n longhorn-system get nodes.longhorn.io
   kubectl get pvc -A
   ```
   Also run `df -h` on node1 (Vault and the RustFS S3 backup store).
5. **Stale PRs and the Dependency Dashboard:** clear anything stuck in "Rate-Limited" or "Repository Problems".
6. **Blocked list:** is any reason in [2.4](#24-blocked-packages-and-caps) gone? Unblock it.

---

## 7. Event-driven procedures

### 7.1 k3s upgrade

Merging the `k3s` PR changes the version in the system-upgrade-controller plans (`kubernetes/platform/system-upgrade/config/base/k3s-*.yaml`) and in `ansible/vars/picluster.yml`. The controller then upgrades **control plane first (node2–4), then workers**, one node at a time (cordon → upgrade → uncordon).

1. Make sure the health check (4.3) is clean and all Longhorn volumes are `healthy`.
2. Merge, then watch:
   ```bash
   kubectl -n system-upgrade get plans,jobs
   kubectl get nodes -w        # VERSION changes node by node
   ```
3. Done when all nodes show the new version. Then do [7.2](#72-after-a-node-reboot-or-k3s-agent-restart) for **each** node.

**If it gets stuck:** a failed upgrade job is **never retried** (this left node6 behind from 2026-09-27 to 2026-11-07). You get `KubeJobFailed` (namespace `system-upgrade`) and then `KubeVersionMismatch`. Fix the node problem (power, disk, network), then:

```bash
kubectl -n system-upgrade get jobs
kubectl -n system-upgrade delete job <failed-job>
kubectl -n system-upgrade rollout restart deploy/system-upgrade-controller
```

k3s cannot be downgraded: fix forward.

### 7.2 After a node reboot or k3s-agent restart

Longhorn's instance-manager on a node keeps a host process ID from when it started. If `k3s-agent` or `iscsid` restarts **without a reboot** (k3s upgrade, manual restart), that PID goes stale. **Volume expansion then fails silently** on that node: the data grows but the filesystem doesn't, and the error is only in the instance-manager log. This blocked the Keycloak DB recovery in October 2026 (see `postmortems/incident-2026-10-06-keycloak-db-outage.md`).

Check the age of the instance-managers:

```bash
kubectl -n longhorn-system get pods -l longhorn.io/component=instance-manager -o wide
```

If one is older than the node's last k3s restart, restart it **when you need a volume expansion on that node** (or right after a k3s upgrade, if you prefer). Restarting it interrupts every volume on that node, so drain the node first:

```bash
NODE=<node>
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data
kubectl -n longhorn-system delete pod -l longhorn.io/component=instance-manager --field-selector spec.nodeName=$NODE
kubectl -n longhorn-system get pods -l longhorn.io/component=instance-manager -o wide -w   # wait for Running
kubectl uncordon $NODE
```

A full reboot ([node-os-reboot.md](node-os-reboot.md)) also clears it.

### 7.3 Growing a volume (PVC)

1. Check [7.2](#72-after-a-node-reboot-or-k3s-agent-restart) for the node the volume is on (`kubectl -n longhorn-system get volumes.longhorn.io -o wide`).
2. Patch the PVC:
   ```bash
   kubectl -n <ns> patch pvc <pvc> -p '{"spec":{"resources":{"requests":{"storage":"<size>"}}}}'
   kubectl -n <ns> get pvc <pvc> -w      # CAPACITY must change to the new size
   ```
   If CAPACITY doesn't change within ~5 minutes, check the instance-manager log on that node for `nsenter` / `no such process`.
3. Update Git to the same size so a rebuild doesn't recreate the old one.
4. **StatefulSets** (Helm charts like Loki): `volumeClaimTemplates` can't be changed in place, so the Helm upgrade fails with `spec.volumeClaimTemplates: Invalid value`. Delete only the StatefulSet object (pods and data stay), then reset the HelmRelease (7.4):
   ```bash
   kubectl -n <ns> delete sts <name> --cascade=orphan
   ```
5. **CloudNativePG:** the operator may not resize the PVCs itself (October 2026). Patch each instance's PVC by hand after changing `storage.size` in Git.

### 7.4 A HelmRelease is stuck (`Stalled` / `RetriesExceeded`)

After its retries run out, Flux stops trying. Once the cause is fixed, reset it (`flux reconcile hr --reset`, without the flux CLI):

```bash
NS=<ns>; HR=<name>; TS=$(date +%s)
kubectl -n $NS annotate hr $HR --overwrite reconcile.fluxcd.io/requestedAt=$TS reconcile.fluxcd.io/resetAt=$TS
kubectl -n $NS get hr $HR -w
```

### 7.5 After a power outage or ungraceful shutdown

1. Wait 15 minutes, then run the health check (4.3).
2. Check the k3s upgrade jobs (7.1, "If it gets stuck"), the tofu-controller Terraform CRs, and the Longhorn volumes. These are the things that got stuck in September 2026 (see the incident notes).
3. Check that the Velero backup that night completed (section 6, step 3).

---

## 8. Alerts and what to do

Alerts arrive on **ntfy** (warning and critical). `info` alerts are dropped. The **Watchdog** heartbeat goes to **healthchecks.io**, which alerts you if it stops.

| Alert | Severity | Meaning | Do this |
|---|---|---|---|
| `FluxHelmReleaseNotReady` | critical | a chart install/upgrade failed or hung for 30 min | `kubectl -n <ns> describe hr <name>`; bad values or a breaking chart change → revert the PR (section 9), or fix then reset (7.4) |
| `FluxKustomizationNotReady` | critical | Flux can't apply a folder from Git for 30 min. Resources only waiting on another one are not alerted | `kubectl -n flux-system describe kustomization <name>` |
| `FluxSourceNotReady` | warning | Flux can't fetch Git, a chart or an OCI artifact for 15 min | the version doesn't exist, the registry is down, or credentials |
| `FluxResourceSuspended` | warning | something has been suspended for more than 24h | resume it once the fix is done |
| `KubeJobFailed` (system-upgrade) | warning | a k3s node upgrade failed | 7.1 "If it gets stuck" |
| `KubeVersionMismatch` | warning | nodes on different k3s versions | same |
| `KubePersistentVolumeFillingUp` | warning/critical | a volume is almost full | grow it (7.3) or find what fills it |
| `KubePodCrashLooping` / `KubeDeploymentReplicasMismatch` | warning | a workload is unhealthy | `kubectl -n <ns> describe pod`, logs; did a recent merge touch it? |
| `TargetDown` | warning | Prometheus can't scrape something | the pod or node is down, or a NetworkPolicy blocks it |
| healthchecks.io alert | | Watchdog stopped: Prometheus or Alertmanager is down | `kubectl -n kube-prom-stack get pods`; **you are blind until this is fixed** |

**Was it a recent merge?** Check the last commits: `git log --oneline -10 origin/master`, or the closed weekly issue.

---

## 9. Rolling back an update

1. Open the merged PR on GitHub → **Revert** → merge the revert PR.
2. Flux applies the previous version within minutes. Run the health check (4.3).
3. If the HelmRelease is `Stalled`, reset it (7.4).

**Rollback doesn't work for:** Longhorn, k3s, and database major versions (Postgres, MongoDB, Elasticsearch). They don't support downgrades: fix forward. That's why they go one at a time, and why you check health **before** merging.

---

## 10. What is automated

| Piece | Where | What it does |
|---|---|---|
| Renovate | `.github/renovate.json5`, `.github/renovate/*.json5` | finds updates, groups, schedules, automerges safe ones, blocks the listed ones |
| CI | `.github/workflows/ci.yml` | yamllint on PRs, `master` and `renovate/**` branches |
| Weekly issue | `.github/workflows/weekly-maintenance.yml`, `.github/maintenance-checklist.md` | Monday 07:00 UTC checklist issue with that week's PRs |
| Flux failure alerts | `kubernetes/platform/kube-prometheus-stack/app/components/flux-monitoring/flux-alert-rules.yaml` | alerts when what's in Git can't be applied |
| Cluster alerts | `kubernetes/platform/kube-prometheus-stack/k3s-mixins/` | standard Kubernetes, node, etcd, Prometheus alerts |
| Alert routing | `kubernetes/platform/kube-prometheus-stack/app/components/alertmanager-notifications/` | ntfy for warning/critical, Watchdog → healthchecks.io |
| Backups | `kubernetes/platform/velero/config/base/backup-schedule.yaml` | daily full Velero backup 02:00 UTC, kept 72h |
| k3s upgrades | `kubernetes/platform/system-upgrade/` | node-by-node upgrade when the version changes in Git |

**Still manual, on purpose:** merging cluster updates (you decided to keep this manual), OS upgrades, majors.

---

## 11. Related documents

- [node-os-reboot.md](node-os-reboot.md): safe reboot of nodes (etcd quorum, Longhorn)
- `postmortems/incident-2026-10-06-keycloak-db-outage.md`: Longhorn stale PID, CNPG PVC resize
- `postmortems/incident-2026-09-27-cowrie-pipeline-outage.md`
- [alerting.md](alerting.md): "Alert notifications" (ntfy and healthchecks.io setup)

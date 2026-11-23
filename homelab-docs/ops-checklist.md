# Ops checklist (November 2026)

A working list of what was done, which checks remain over the next days, and the open follow-ups.
Tick a box (`- [x]`) in a commit when an item is done; move finished sections to "Done" with the date.

Where commands run: `kubectl` and `flux` on **node2**, `make` / Ansible on **pimaster** (`~/picluster`),
RustFS disk and `rc` on **node1**.

---

## Done

### 14 Nov 2026
- [x] **Longhorn snapshot bloat fixed:**
  - Longhorn deletes the Velero backup snapshot right after the upload; the cleanup job fails on errors (`d4eaa57f`).
  - Cleanup purges one volume at a time (`5efad74e`).
  - Runbook LONGHORN-003 (`26dcf6ec`). Before this, Prometheus carried 110 GB of snapshots on a 50 GB volume.
- [x] **Triage agent phases 0–3:** workstation tests (`4d378a4a`), image (`ffab15cf`), credentials in
  `secret-files` and Vault (`32a7c1ad`), read-only deployment (`343ff6b2`, `62d98695`, `0f72f49c`).
- [x] **First full `make os-upgrade` run:** all nodes upgraded, masters and node1 included. The pre-flight
  stopped once (node6 overloaded by drained pods); the rerun went through (`d5b17a5d`).
- [x] **Prometheus prefers amd64 nodes** (`3b4a219c`).
- [x] **Rancher-move playbook written:** `move_rancher_to_storage.yml`, CLUSTER-012 step 6 (`04251c0f`).

### 15 Nov 2026
- [x] **Velero:** the failed backup was a passing API connection reset; a manual backup Completed.
- [x] **Prometheus excluded from Velero backups**, triage agent can read Leases (`a939279d`).
- [x] **node1:** 70 GB of orphaned Loki copies removed in RustFS, 86% → 54%; postmortem, OBS-004 step 6,
  CLUSTER-012 step 7 (`27f522c8`).
- [x] **Eviction threshold** confirmed at 95% (k3s), docs corrected (`b937274e`).
- [x] **PXE layout:** node-esp root LV is 80G for future reinstalls (`ac19f095`).
- [x] **Rancher move done on node-esp-1 and node-esp-2**, reboot-tested, root at about 30% (`2a19a78d`).
- [x] **Triage agent finished (phases 4–5):** Triage button added automatically by Stage 5 (`594f2167`),
  acceptance tests passed, runbook OBS-006, skill sees node1 disks and Velero (`d4bb25f7`).
- [x] **Journald cap** in effect on all nodes.
- [x] **Orphaned keycloak volume** deleted; runbook LONGHORN-004 (`1a3ba3ac`).
- [x] **OS-upgrade playbook:** capacity pre-flight on the other nodes, progress-based Longhorn wait,
  durations (`1d4caf87`); disk check uses available bytes (`2a78b2ae`, `4e8a6ee1`). Validated with
  `make os-upgrade-check`: all OK, 0 packages pending.
- [x] **Docs consistency check** (`acbd2330`).

### 19 Nov 2026
- [x] **ntfy messages lost or cut on the phone** ([alerting.md](alerting.md#message-size) "Message size"):
  - Alerts: ntfy's built-in `template=alertmanager` went over 4096 bytes with 4+ alerts in a group, so
    ntfy answered HTTP 400 and Alertmanager dropped the notification; 2–3 alerts arrived cut by the
    Android push limit. Now a compact inline template set by Stage 5 and `max_alerts: 5` (about 2 KB
    for 5 alerts, "+N more") (`e036859d`, `afdfba3e`). Vault updated with `make load-external-services-keys`.
  - Triage reports: were cut at 3,800 bytes; now sent as parts of at most 2,500 bytes ("1/2", "2/2"),
    image `sha-e036859` (`3563b947`). Pod running the new image.
- [x] **Flux blocked for about 20 min:** at 07:30 UTC the External Secrets validating webhook timed out
  once, so `external-secrets-config` failed and almost every Kustomization waited on it. A manual
  `flux reconcile kustomization external-secrets-config` went through; webhook healthy, Cilium health
  1/1 on all nodes. `FluxKustomizationNotReady` did not fire because the block lasted under its 30 min.
  No change needed; if it repeats, add a short `retryInterval` to `external-secrets-config`.
- [x] **Phone check:** next alert arrives in the compact format; a long triage report arrives in parts.
  Both confirmed on the phone 2026-11-19.

### 20 Nov 2026
- [x] **Upstream cherry-picks applied** (PR #992, merged into master): external-dns annotation prefix (`7195fbf4`),
  node1 fluent-bit agent fixes: RFC5424 syslog parser, Vault lookup on the controller, `Self_Hostname` indentation
  (`1e3e36e2`, `e9de567f`), role `ricsanfre.fluentbit` v1.0.6 (`4234219a`), `make k3s-config` (`2ad60d9a`),
  k3s v1.37.2+k3s1 with the `gateway-api-crd` add-on disabled (`99b0bfa9`), mixin pins and fixes
  (`e9d1a0f9`, `9d7be770`, `de9ae120`, `0da0c056`).
- [x] **Applied on pimaster:** `make k3s-config`, `make deploy-monitoring-agent` (role v1.0.6 installed by hand in
  the running container). Verified: node1 logs reach Fluentd (2e), the gateway-api-crd retry loop stopped.
- [x] **Rebuild the runner image** (done 2026-11-20, image built in 233 s, `ricsanfre.fluentbit, v1.0.6`) so v1.0.6 is baked in (`make ansible-runner-setup` does not rebuild):
  `cd ~/picluster/ansible-runner && docker compose build && docker compose up --detach`, then
  `./ansible-runner/ansible-runner.sh ansible-galaxy role list 2>/dev/null | grep fluentbit` → v1.0.6.
- [x] **Quick start doc** for all make targets and playbooks, with the fork additions:
  [quick-start.md](quick-start.md) (`9f130947`, `c737c7fd`).
- [x] **Node temperature alerts and weekly ntfy digest** pushed ([alerting.md](alerting.md#weekly-digest),
  runbook CLUSTER-017). Baseline: Pis at most 51 °C in a week, HP CPUs at most 72 °C. Checks in section 1.
  (`a45fef8f`). First test digest arrived on the phone; layout rewritten to "problems first", RustFS sizes and
  Flux false positives fixed (`cb1ceac6`, `f9a48cf3`).
- [x] **Found by the first digest:**
  - **Tempo ingester OOMKilled every ~30 min** (256 restarts in 7 days): one ingester since replicas 3 → 1
    (`2306a8f0f`) but still the 768Mi limit sized for 3; it sat at 767Mi and died at each block flush, losing
    the traces in memory. Limit 1536Mi, request 1Gi (`4b7bdbfe`). Check in section 1.
  - **Flux 48 not ready:** a cascade while `cilium-app` was mid-reconcile; recovered by itself within minutes,
    no root left. No action.
  - **Velero "1 failed/partial":** the 15 Nov API-reset failure, still in the 7-day window. The 18, 19 and 20 Nov
    nightly backups are all Completed.

---

## 1. Checks over the next days

### 16 Nov morning (node2)
- [x] Nightly Velero backup Completed, empty ERR
- [x] Newest Prometheus backup (`pvc-e1c0c8e4`) still 2026-11-15T03:27
- [x] 0 degraded Longhorn volumes, all nodes Ready, all Kustomizations True
- [x] node1 about 54%, no disk alerts

Outcome 2026-11-16: `full-20261116020024` Completed with no errors (the first nightly run since Prometheus was
excluded). No new Prometheus backup after 15 Nov. 0 degraded volumes, 7/7 nodes Ready, no Kustomization
not Ready. node1 `/` at 43%, below the expected 54%: the old backups are already expiring. Highest disk:
node5 `/storage` 67% (section 3).

```bash
echo "== velero =="; kubectl -n velero get backups.velero.io -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,ERR:.status.errors | tail -3
echo "== prometheus not backed up =="; kubectl -n longhorn-system get backups.longhorn.io -o custom-columns=VOL:.status.volumeName,CREATED:.status.backupCreatedAt | grep pvc-e1c0c8e4
echo "== longhorn =="; ~/bin/lh-snaps.sh | tail -3
echo "== nodes =="; kubectl get nodes
echo "== flux =="; flux get kustomizations -A | grep -v True || echo "all True"
echo "== disks =="; P="/api/v1/namespaces/kube-prom-stack/services/kube-prometheus-stack-prometheus:http-web/proxy/api/v1/query?query="
kubectl get --raw "${P}sort_desc%28100%20%2A%20%281%20-%20node_filesystem_avail_bytes%7Bjob%3D%22node-exporter%22%2Cfstype%21%3D%22%22%2Cmountpoint%3D~%22%2F%7C%2Fstorage%22%7D%20%2F%20node_filesystem_size_bytes%7Bjob%3D%22node-exporter%22%2Cfstype%21%3D%22%22%2Cmountpoint%3D~%22%2F%7C%2Fstorage%22%7D%29%20%2A%20on%20%28instance%29%20group_left%20%28nodename%29%20node_uname_info%7Bjob%3D%22node-exporter%22%7D%29" | jq -r '.data.result[] | "\(.metric.nodename) \(.metric.mountpoint) \(.value[1] | tonumber | floor)%"' | head -6
```
Or tap **Triage** on an alert notification.

### 17 Nov (node1): Loki retention deletes current data
- [x] Count close to 0. Checked 2026-11-19: 99, all from 2026-09-26 (412 KB, chunks never indexed after the
  ungraceful shutdown, out of retention's reach); 0 objects from 11-09 to 11-12, so retention works.

```bash
sudo sh -c 'cd /storage/rustfs/k3s-loki && find fake -name xl.meta ! -newermt 2026-11-09 | wc -l'
```

### 18 Nov (node1): old Prometheus backups expired
- [x] `/` below 54% (40% on 2026-11-19)
- [x] `k3s-longhorn` well below 97 GB (67 GB on 2026-11-19)

```bash
df -h /
sudo sh -c 'du -sh /storage/rustfs/k3s-longhorn'
```

- [x] **When all three days are OK:** close actions 1 and 4 in
  [the node1 postmortem](../postmortems/incident-2026-11-15-node1-disk-rustfs-loki-orphans.md).

### 20 Nov (node2): temperature alerts and weekly digest live
- [x] Rules loaded, nothing firing. 2026-11-22: `node-temperature` and `weekly-digest` PrometheusRules in
  `kube-prom-stack` (37h), no `NodeTemperature*`, `RaspberryPiSoftTempLimit` or `WeeklyDigestMissing` alert.
- [x] CronJob, Secret and ConfigMap exist; a test run sends the digest to the phone (2026-11-20, 18:49).
- [x] 20 Nov nightly Velero backup Completed (first since the 19 Nov orphan cleanup), 18 and 19 Nov too.

```bash
echo "== flux =="; flux get kustomizations -A | grep -E "sre-triage|kube-prometheus-stack|NAME"
echo "== rules =="; kubectl get prometheusrules -A | grep -E "node-temperature|weekly-digest"
echo "== firing =="; kubectl get --raw "/api/v1/namespaces/kube-prom-stack/services/kube-prometheus-stack-prometheus:http-web/proxy/api/v1/query?query=ALERTS%7Balertname%3D~%22NodeTemperature.*%7CRaspberryPiSoftTempLimit%7CWeeklyDigestMissing%22%7D" | jq -r '.data.result[] | .metric.alertname' | sort | uniq -c; echo "(empty = none)"
echo "== digest objects =="; kubectl -n sre-triage get cronjob,externalsecret,secret,configmap | grep -i digest
echo "== test run =="; kubectl -n sre-triage create job --from=cronjob/weekly-digest weekly-digest-test && kubectl -n sre-triage wait --for=condition=complete job/weekly-digest-test --timeout=120s; kubectl -n sre-triage logs job/weekly-digest-test; kubectl -n sre-triage delete job weekly-digest-test
echo "== velero =="; kubectl -n velero get backups.velero.io -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,ERR:.status.errors | tail -3
```

### 21 Nov (node2): Tempo ingester stable
- [x] Restart count unchanged since the new limit, memory well below 1536Mi, pod requests 1Gi. 2026-11-22:
  0 restarts, limit 1536Mi, 187Mi used.

```bash
kubectl -n tempo get pod tempo-ingester-0 -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,NODE:.spec.nodeName,REQ:.spec.containers[0].resources.requests.memory,LIM:.spec.containers[0].resources.limits.memory
kubectl -n tempo top pod tempo-ingester-0
kubectl -n tempo describe pod tempo-ingester-0 | grep -A3 "Last State"
```

### 22 Nov: triage agent gives shallow reports (assessed 2026-11-21)
Causes found in the config, most important first:
1. **No alert context:** the Triage button always sends `body=triage` (fixed in the ntfy URL), so the prompt is
   "Triage all firing alerts" and the skill sweeps the whole cluster (10 steps). The tapped alert is not passed.
2. **Budget forces breadth:** Sonnet, 600 s, under 3,500 characters, one check per tool call. The reply is now
   split into parts (up to 4 × 2,500 bytes), so the 3,500 cap is no longer needed.
3. **Tool friction:** allow list has kubectl/flux read verbs plus jq, grep, sort, uniq, head, tail, wc, date; no
   awk, sed, cut, xargs; no Python in the image. Refusals are logged per run (`denied=[...]`).
4. **Read gaps:** no log history (Loki not reachable: no `services/proxy` Role in `loki`); CRD groups missing
   from `sre-triage-read`: kafka.strimzi.io, networking.istio.io, security.istio.io, gateway.envoyproxy.io,
   k8s.keycloak.org, mongodbcommunity.mongodb.com, grafana.integreatly.org, opentelemetry.io. No host access
   (by design; node metrics cover part of it).

- [x] **Measure first** (node2): turns, cost, timeouts and refused commands of the last runs.
  2026-11-22, 13 runs since 19 Nov: every run ends by itself in **12-32 s** (limit 600 s), 6-25 turns,
  $0.09-0.26, `denied=[]` every time, no timeouts. So budget (cause 2) and tool refusals (cause 3) are not
  what makes reports shallow: the agent stops early by choice. Free-text requests do reach it ("focusing on
  this request from the operator: ..."); only the Triage button carries no alert. What limited the 22 Nov
  backup report was cause 4: it could not read the Velero error details or RustFS on node1, so it guessed
  ("bucket missing", medium confidence). Fix order: prompt (go deep, verify before concluding, say what it
  could not check), then read gaps, then the alert context on the button.
  ```bash
  kubectl -n sre-triage logs deploy/sre-triage --since=168h | grep -E "triage (start|end)|Triage failed" | tail -30
  ```
- [x] Decided and implemented 2026-11-22 (timeout, model and allow list unchanged: not the bottleneck):
  - prompt (`docker/sre-triage/agents.json`, needs the image rebuild): focus on the operator's request or
    the newest alert, follow the evidence, test each cause before writing it, report with Checked and
    Not checked, up to ~6000 characters (parts already supported);
  - skill: Velero/Longhorn error details without `kubectl exec`, Loki recipes, node1 disk busy %, the
    NoSuchBucket failure mode;
  - RBAC: Loki `services/proxy` GET in `loki`; CRD groups strimzi, istio, envoy gateway, keycloak,
    mongodb, grafana operator, opentelemetry.
  - The Triage button still sends only `triage`: ntfy does not template action bodies, so a plain tap
    now means "the newest alert".
- [x] Deployed 2026-11-22 (`sha-6bc59c2`, Flux on master): the pod runs the new image (`kubectl -n sre-triage get deploy sre-triage -o jsonpath='{.spec.template.spec.containers[0].image}'`)
  and Loki answers through the proxy as the agent:
  ```bash
  kubectl get --raw "/api/v1/namespaces/loki/services/loki-gateway:80/proxy/loki/api/v1/labels" --as=system:serviceaccount:sre-triage:sre-triage | jq -r '.data[]' | head
  ```
- [x] After the change: ask the agent "Why did the 21 and 22 Nov backups fail?" and compare with the 22 Nov
  report (it said "bucket missing"). 2026-11-22: 3 min 26 s (was 32 s), 22 turns, $0.31 API-equivalent
  (Pro plan usage, not billed); found node1 sda 81-88% busy 02:10-03:00 both nights in Prometheus, tested
  the cause, listed Not checked. Report reached ntfy in parts. One `awk` refused (skill now says `jq`).
  It also found the failed `longhorn-snapshot-cleanup` of 21 Nov (ES purge HTTP 500 during the backup
  window): CronJob moved 03:30 → 06:30 UTC.

### 22 Nov: Velero backups PartiallyFailed (Elasticsearch volume)
`full-20261121` and `full-20261122` PartiallyFailed, `VeleroNoRecentBackup` critical. Only the Elasticsearch
Longhorn backup failed, both nights (02:44 and 03:14 UTC) with `NoSuchBucket`, although `k3s-longhorn` exists
and has no orphaned objects. **Cause: node1's single disk saturates during the backups.** `/var/log/rustfs/`
(RustFS does not log to the journal) shows `Io error: timeout` every night 02:00-04:00 UTC since at least
12 Nov; requests took 52-65 s and returned 500 or `NoSuchBucket`. The hourly bucket-metrics walk made it worse
(22 Nov: walk started 03:14:23, error 03:14:44; `IOSchedulingClass=idle` does nothing with `mq-deadline`).
Also: node1 runs RustFS **`1.0.0-beta.7`** while git says `1.0.4` (bumped 1 Nov, never deployed).
Runbooks: BACKUP-004 step 3a, MINIO-001; postmortem 11-15 actions 11-13.

- [x] **Manual backup `full-manual-6gsmq`** Completed, ES `LASTBACKUPAT` 2026-11-22T06:47 (clears
  `VeleroNoRecentBackup`).
- [x] **RustFS logs at the failure times:** I/O timeouts on `.rustfs.sys/config/iam/`, 500s after 52-65 s.
- [x] **Timer out of the backup window** (committed 22 Nov): hourly at :15, paused 02:00-04:59 UTC;
  `RustFSBucketMetricsMissing` 3 h → 5 h.
- [x] **Timer applied** on node1 (22 Nov, `update_node_config.yml --limit node1`; NEXT at `:15`).
- [x] **Night of 23 Nov:** `full-20261123020036` Completed, 0 errors; ES `LASTBACKUPAT` 2026-11-23T02:01;
  snapshot cleanup Complete at 06:30. RustFS timeouts 260 (02h 252, 03h 8) against ~1,000 the night before.
  Also 160 timeouts on 22 Nov 17:00-19:00 UTC, outside the window (the timer/metrics work on node1 that afternoon, a manual bucket walk; never run it 02:00-04:59 UTC).
- [x] **RustFS upgraded to 1.0.4** (23 Nov, by day): `.rustfs.sys` saved to `~/rustfs-sys-2026-11-23.tgz` on
  node1, `make deploy-rustfs`, service active, 6 buckets listed.
- [ ] **24 Nov backup** Completed with 0 errors, first night on 1.0.4; count the timeouts (node1):
  ```bash
  sudo sh -c 'cat /var/log/rustfs/*' | grep -i timeout | grep -oE '"timestamp":"[0-9-]+T[0-9]{2}' | cut -c14- | sort | uniq -c | tail -6
  ```
  If ES fails again, or the 02h count stays in the hundreds: a separate disk for `/storage` on node1
  (postmortem action 11) and the upstream report (action 10). If clean, close action 11 as not needed.

### 23 Nov 08:00: first scheduled digest
- [x] Monday's digest arrives on the phone by itself (`kubectl -n sre-triage get jobs` shows a Complete job).
- [x] It no longer lists `tempo-ingester-0` (no restarts). It will still show the 21/22 Nov Velero failures (7-day window).
- [x] Not woken by `RustFSBucketMetricsMissing` at night (threshold now 5 h for the 01:15 → 05:15 gap).

### 27 Nov: RustFS growth in the digest
- [ ] The RustFS line shows the 7-day growth per bucket (first full week of bucket metrics).

### 22 Nov: SMART disk alerts (`ea8a1db2`, [alerting.md](alerting.md#disk-health-smart-alerts), runbook CLUSTER-018)
- [x] **Install on the nodes** (pimaster): `cd ~/picluster && git pull && make node-config-update`. Done 22 Nov:
  all 8 nodes report (`smartmon_device_info`). Flux only picked the rules up after
  `flux reconcile source git flux-system` (source interval 1h); `node-smart.rules` loaded (57 groups).
- [x] **Check one Pi** (node5): `systemctl list-timers smart-metrics.timer` and
  `grep -v "^#" /var/lib/node_exporter/smartmon.prom | grep -E "lifetime|healthy|read_ok|devices|id=\"199\""`
  (expect lifetime 100, CRC 92, `read_ok` 1). Done 22 Nov: as expected. All 8 match the SMART table in
  disk-replacement.md (wear node4/5/6 100%, node-esp-2 109%; health PASSED everywhere; old error totals only).
  Write latency 0-4 ms on healthy disks, 43 ms on node6. `DiskWornOut` pending for node4, node5, node6,
  node-esp-2.
- [ ] **Silence the known worn disks** until each swap: `DiskWornOut` for node4, node5, node6, node-esp-2
  (and `DiskSmartFailing` if it fires on the BX500s).
- [ ] **Write latency baseline:** after a quiet day, check that `DiskWriteLatencyHigh` (100 ms for 15 min) does
  not fire on healthy disks (node-esp-1, node1–3); raise the threshold if it does.

### 22 Nov: write reduction (worn disks)
- [x] **Longhorn 1 replica, live patch (stays out of Git on purpose):** `postgres-keycloak-1`,
  `postgres-keycloak-2`, `loki/data-loki-write-0` → `numberOfReplicas: 1`, `dataLocality: best-effort` (saves
  ~43 GB/day of 269). Nothing to revert for disk swaps; reapply only after a rebuild, a restore or a recreated PVC
  ([disk-replacement.md 2.4](disk-replacement.md#24-make-every-disk-last-longer-fewer-disk-writes)).
- [x] **Patch applied and checked** (22 Nov): 1 replica each, on the pod's node: `postgres-keycloak-1` node6,
  `postgres-keycloak-2` node5 (both worn disks), `data-loki-write-0` node-esp-1. Keycloak backups verified:
  WAL archiving working, daily backups completed (last 22 Nov 02:30), recoverable from 7 Nov.
- [x] **Measure the saving** (23 Nov evening): **177 GB/day** (was 269, target ~200), see
  disk-replacement.md 2.4.
- [x] **Threatmap disabled** (MongoDB ~27 GB/day): `threatmap-app` and `mongodb-community-operator-app` have
  `suspend: true` in Git (namespace and MongoDB volume kept). Live, node2:
  `kubectl -n databases scale deploy -l app.kubernetes.io/name=community-operator --replicas=0` (or the operator
  deployment by name), `kubectl -n threatmap scale deploy --all --replicas=0`,
  `kubectl -n threatmap scale statefulset mongodb --replicas=0`. Honeypots stopped on both Oracle VMs
  (`docker stop cowrie`, `systemctl disable --now fluent-bit`).
  Velero skips the `threatmap` namespace (`excludedNamespaces` in the `full` schedule).
  **Re-enable:** remove both `suspend: true` and the Velero exclusion, push, scale the operator back to 1, then the operator brings MongoDB
  back; `kubectl -n threatmap scale deploy --all --replicas=1`; on the VMs `docker start cowrie` and
  `sudo systemctl enable --now fluent-bit`.

### Next steps (from 22 Nov evening)

**Tonight, before the 02:00 UTC backup (node2):**
- [x] **Cluster back on `master`** (done 22 Nov evening: source on master, `velero-config` re-applied at `82a0cda0`, exclusion `["threatmap"]` back). The Grafana folders test (PR #1003, merged) switched Flux to
  `feature/grafana-folders`, which did not have the Velero threatmap exclusion (`b43bdbe4`). Point the
  GitRepository back to master and check:
  ```bash
  GR_NAME="$(kubectl -n flux-system get gitrepository -o jsonpath='{range .items[?(@.spec.url=="https://github.com/marmila/picluster")]}{.metadata.name}{"
"}{end}' | head -n1)"
  kubectl -n flux-system patch gitrepository "${GR_NAME}" --type merge -p '{"spec":{"ref":{"name":"refs/heads/master","branch":null}}}'
  flux reconcile source git "${GR_NAME}" -n flux-system && flux reconcile kustomization flux-system -n flux-system --with-source
  flux get sources git -n flux-system                                                   # refs/heads/master@sha1:...
  flux reconcile kustomization velero-config -n flux-system
  kubectl -n velero get schedule full -o jsonpath='{.spec.template.excludedNamespaces}{"
"}'   # ["threatmap"]
  flux get kustomizations -A | tail -n +2 | awk '$5!="True"' | cut -c1-160                       # only the 2 suspended threatmap ones
  ```
- [x] **`DiskWornOut` silenced** 22 Nov until 22 Dec 2026 (silence `e33eec49`; swap the disks before it ends or extend it):
  `kubectl -n kube-prom-stack exec alertmanager-kube-prometheus-stack-0 -c alertmanager -- amtool silence add alertname=DiskWornOut 'nodename=~"node4|node5|node6|node-esp-2"' --duration=30d --author=marmila --comment="Known worn disks, replacement planned" --alertmanager.url=http://localhost:9093`

- [x] **`FluxResourceSuspended` silenced** 22 Nov until 20 Feb 2027 (silence `1d710e92`): it fires after 24 h for
  `threatmap-app`, `mongodb-community-operator-app` and HelmRelease `mongodb-community-operator`, suspended on
  purpose. Its text says to resume them: do not, that restarts threatmap.
  `kubectl -n kube-prom-stack exec alertmanager-kube-prometheus-stack-0 -c alertmanager -- amtool silence add alertname=FluxResourceSuspended 'name=~"threatmap-app|mongodb-community-operator-app|mongodb-community-operator"' --duration=90d --author=marmila --comment="threatmap disabled on purpose 2026-11-22: do NOT resume" --alertmanager.url=http://localhost:9093`.
  When it expires: re-enable threatmap, or remove it for good (the two `suspend: true` lines, the Velero
  exclusion and, if unused, the MongoDB operator).

**23 Nov morning (node2):**
- [x] Nightly Velero backup `Completed`; namespace `threatmap` excluded. The 10 `grep` hits are objects in
  other namespaces named `threatmap-*` (Kafka user and secrets, Flux Kustomizations and their events, the
  blackbox probe); no threatmap PVC or volume.
- [x] Keycloak Postgres daily backup `completed` (22 and 23 Nov) (`kubectl -n databases get backups.postgresql.cnpg.io | tail -2`).
- [x] No `DiskWriteLatencyHigh` on healthy disks (node-esp-1, node1–node3) overnight; no `DiskMediaErrors`.
  23 Nov: fired on node5 and node6 (worn, expected). node1 showed up in a 24 h `max_over_time(ALERTS)` but
  never `firing` in the last 24 h, the backup night included: pending only, or the 22 Nov afternoon manual
  bucket walk. Threshold stays.
- [x] Threatmap still off: `kubectl -n threatmap get pods` empty, both MongoDB volumes `detached`.

**23 Nov evening (node2):**
- [x] **Measure the saving** (23 Nov evening): **177 GB/day** (was 269, target ~200), see
  disk-replacement.md 2.4.

**This week:**
- [ ] **Decide the purchase** ([disk-replacement.md 2.3](disk-replacement.md#23-shopping-list)): pick the Pi model
  (MX500, else 870 EVO, else WD Red/Blue SA500; no Kingston, no SA510/QVO), **order the one 1 TB test drive**,
  then the other 6 once node6 passes A5.
- [ ] Before the node6 swap: pre-flight 4.1 and the Keycloak backup check in A1.
- [ ] CoreDNS: one pod restarted around the 22 Nov DNS timeout (Flux `Could not resolve host`). Check its last
  termination reason: `kubectl -n kube-system get pods -l app.kubernetes.io/name=coredns -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName} {.status.containerStatuses[0].restartCount} {.status.containerStatuses[0].lastState.terminated.reason} {.status.containerStatuses[0].lastState.terminated.finishedAt}{"
"}{end}'`.
- [ ] Postmortem action 7 leftovers: Kafka ×3 and Prometheus volumes, which still have a replica on node5/node6.

---

## 2. node1 / RustFS follow-ups (read-only, node1)

- [x] **2a. Live Loki objects with extra copies** (postmortem action 5). 2026-11-19: 4 objects, negligible.
  Fast check (one `find`, seconds; a loop with one `find` per object takes far too long):
  ```bash
  sudo sh -c 'cd /storage/rustfs/k3s-loki && find fake -mindepth 3 -maxdepth 3 -type d -printf "%h\n"' | sort | uniq -c | awk '$1>1' | wc -l
  ```
- [x] **2b. Orphaned objects in other buckets.** 2026-11-19: longhorn, tempo, barman 0. **velero 95**: the
  `full-*.tar.gz` of every expired daily backup since 10 Aug (TTL 72h), 3.2 GB; same RustFS bug as Loki.
  94 removed on disk (list in `~/velero-orphans.txt` on node1, `xl.meta` re-checked before each `rm`);
  the 15 Nov `full-manual-qzwqh` archive left in place. node1 `/` 39% → 37%.
  Check per bucket (objects with data but no `xl.meta`); expect about one new Velero orphan per day
  until RustFS is fixed, so repeat now and then:
  ```bash
  b=k3s-velero; f=$(mktemp)
  sudo find /storage/rustfs/$b -type f -name xl.meta -printf '%h\n' | sort -u > $f.m
  sudo find /storage/rustfs/$b -type f -name 'part.1' -printf '%h\n' | sed 's|/[^/]*$||' | sort -u > $f.d
  comm -13 $f.m $f.d | wc -l; rm -f $f $f.m $f.d
  ```
- [x] **2c. node1 `/var/log` (2.7 GB):** 2 GB was `/var/log/fluentbit.log` (about 54k lines/day, no rotation),
  truncated 2026-11-19. The errors in it (syslog parse errors, mis-indented `Self_Hostname`) are fixed by
  cherry-pick Batch A (`e513a832`, `6ae134a1`, `4d30396a`), applied 2026-11-20.
- [x] **2e. node1 logs never reach Fluentd** (found 2026-11-19; **fixed 2026-11-20** with the cherry-picks, PR #992:
  `7195fbf4` = upstream `89e0ced1`. Verified: `dig @10.0.0.11` → 10.0.0.66, no new `getaddrinfo` errors.): `getaddrinfo(fluentd.homelab.marmilan.com):
  Domain name not found`. Inside the network the zone is served by bind9 on node1 (`host_vars/node1.yml`,
  via gateway 10.0.0.1), which has no `fluentd` record (`dig @10.0.0.11` empty; the public IONOS record
  `@1.1.1.1` = 10.0.0.66 is not used inside). external-dns (rfc2136 → node1 bind) should create it, but the
  Fluentd Service uses `external-dns.alpha.kubernetes.io/hostname`, which external-dns v0.22 ignores.
  Fix: upstream `89e0ced1`, so it is **required, not optional**: apply it with cherry-pick Batch A.
  Verify after: `dig +short fluentd.homelab.marmilan.com @10.0.0.11` → 10.0.0.66, and the error stops in
  `/var/log/fluentbit.log`.
- [x] **2d. Per-bucket size metric and growth alert** (postmortem action 7): live 2026-11-19 (`9faef903`). Hourly `rustfs-bucket-metrics` timer on node1 (first run 192 s), rules `rustfs-bucket-rules.yaml`, CLUSTER-012 step 7. Prometheus has all 6 buckets; no RustFS alert. First values: longhorn 70 GB, loki 1.5 GB, velero 0.36 GB (1 orphan, 51 MB: the 15 Nov manual backup).

---

## 3. Longhorn replica balance and node5

node5 has 13 replicas and 67% of `/storage`; node6 has 9 and 16%; node-esp-1 has 7, node-esp-2 has 13.
Replica auto-balance is off and scheduling stops at 90% (`storageMinimalAvailablePercentage: 10`), so not urgent.

- [x] **Which volumes are on node5** (node2): skipped, not needed after the I/O check.
  ```bash
  kubectl -n longhorn-system get replicas.longhorn.io -o custom-columns=NODE:.spec.nodeID,VOL:.spec.volumeName --no-headers | grep '^node5' | awk '{print $2}' | while read v; do kubectl -n longhorn-system get volumes.longhorn.io "$v" -o jsonpath='{.status.kubernetesStatus.pvcName}{" "}{.spec.size}{"\n"}'; done | awk '{printf "%-45s %.0f GiB\n",$1,$2/1073741824}' | sort -k2 -n
  ```
- [x] **node5 I/O** (node5): `iostat -x 5 3`. 2026-11-19: sda 2–19 % util, write wait under 1 ms; sdb, sdc idle; iowait 0.3–2.5 %.
- [x] Decide whether to move a few big replicas by hand: **no**, watch only (I/O fine, `/storage` 67 % < 90 % scheduling stop).

---

## 4. Quick items
- [x] Unsubscribe the old triage ntfy topic in the phone app (the one replaced on 15 Nov). Done 2026-11-19.
- [x] **Certificates:** `kubectl get certificate -A`. `pi-cluster-tls` renews around 7 Dec. 2026-11-19: all 6 Ready.
- [ ] **Let's Encrypt automation** before February 2027.

---

## 5. Backlog
- [ ] **Pi root disks:** images live on root there (node6 48%, node5 44%). Watch only; the 80% alert and
  the 85% os-upgrade pre-flight cover it.
- [ ] **Triage agent:** `curl -4` if the reconnects come back; smaller image; token renewal reminder
  ([sre-triage-agent.md](sre-triage-agent.md) 9.2, also update `sre-triage.ini`); optionally rename the alerts topic.
- [ ] **fluent-bit:** raise the CPU limit.
- [ ] **Fixed ntfy action buttons** for known alerts.
- [ ] **RustFS upstream issue** (optional, postmortem action 10).
- [ ] **Hardware:** node1/node6 power cables; keep an eye on node3.
- [ ] **Small items:** vendor the SUC files; check the Kafka 4.3.0/4.3.1 pin;
  `RaspberryPiUnderVoltage` alert only after 2 dips.
- [ ] **RustFS bumps are not applied by Flux:** after Renovate changes `rustfs_server_version` (or
  `rustfs_cli_version`), run `make deploy-rustfs` on pimaster and check `rustfs --version` on node1.
  Missed once: 1.0.4 merged 1 Nov, node1 still on 1.0.0-beta.7 on 22 Nov.
- [ ] **Open Renovate PRs (10, limit 20):** the 6 GitHub Actions majors were merged by 22 Nov. Decide merge or close for each (Cilium #991; Istio #988; kube-prometheus-stack v93 #967 with CRDs v33 #964, which Renovate replaces with one "Prometheus Operator" group PR since 22 Nov; Vault v2 #963; Elasticsearch 8.19.25 #842; community.general 14 #955; Python #974; Node 26 #987; cp-schema-registry v8 #390, auto-closed since 22 Nov because its major is disabled). Do not delete their branches: closing the PR is the way to drop one. `renovate/all-non-major` is the normal weekly bundle (Monday).
- [ ] **Before any node-esp reinstall:** `make pxe-setup`.
- [ ] **Runbook coverage review:** check that every alert has a runbook and every runbook covers its real scenarios. Start from the alert rules (`ALERTS` names, `runbook` annotations) against `runbooks/README.md` and `.opencode/skills/cluster-triage/references/runbook-map.md`; list alerts without a runbook, runbooks without a matching alert, and incidents in `postmortems/` whose scenario no runbook describes.

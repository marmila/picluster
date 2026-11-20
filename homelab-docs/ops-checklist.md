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
- [ ] Rules loaded, nothing firing (all nodes far below the thresholds).
- [ ] CronJob, Secret and ConfigMap exist; a test run sends the digest to the phone.
- [ ] 20 Nov nightly Velero backup Completed (first since the 19 Nov orphan cleanup).

```bash
echo "== flux =="; flux get kustomizations -A | grep -E "sre-triage|kube-prometheus-stack|NAME"
echo "== rules =="; kubectl get prometheusrules -A | grep -E "node-temperature|weekly-digest"
echo "== firing =="; kubectl get --raw "/api/v1/namespaces/kube-prom-stack/services/kube-prometheus-stack-prometheus:http-web/proxy/api/v1/query?query=ALERTS%7Balertname%3D~%22NodeTemperature.*%7CRaspberryPiSoftTempLimit%7CWeeklyDigestMissing%22%7D" | jq -r '.data.result[] | .metric.alertname' | sort | uniq -c; echo "(empty = none)"
echo "== digest objects =="; kubectl -n sre-triage get cronjob,externalsecret,secret,configmap | grep -i digest
echo "== test run =="; kubectl -n sre-triage create job --from=cronjob/weekly-digest weekly-digest-test && kubectl -n sre-triage wait --for=condition=complete job/weekly-digest-test --timeout=120s; kubectl -n sre-triage logs job/weekly-digest-test; kubectl -n sre-triage delete job weekly-digest-test
echo "== velero =="; kubectl -n velero get backups.velero.io -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,ERR:.status.errors | tail -3
```

### 23 Nov 08:00: first scheduled digest
- [ ] Monday's digest arrives on the phone by itself (`kubectl -n sre-triage get jobs` shows a Complete job).

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
- [ ] **Before any node-esp reinstall:** `make pxe-setup`.
- [ ] **Runbook coverage review:** check that every alert has a runbook and every runbook covers its real scenarios. Start from the alert rules (`ALERTS` names, `runbook` annotations) against `runbooks/README.md` and `.opencode/skills/cluster-triage/references/runbook-map.md`; list alerts without a runbook, runbooks without a matching alert, and incidents in `postmortems/` whose scenario no runbook describes.

# Incident: Elasticsearch stalled by a slow Longhorn replica, Pi USB disks saturated, Fluentd scale-out made it worse
**Date:** 2026-11-22  
**Duration:** Elasticsearch writes failing intermittently since at least 2026-11-16 (Fluentd ES retries 3,600–10,500 per
day). Acute phase 12:18–13:10 UTC, found at about 12:25 UTC during the Fluentd 1.20.1 rollout.  
**Impact:** Elasticsearch indexing slow or failing for days; during the acute phase Elasticsearch did not answer at all
(ECK health `unknown`, a system-index shard briefly RED). Fluentd buffered the Elasticsearch copy of the logs; the
buffers of the 10 extra Fluentd pods were discarded when they were removed, so the **Elasticsearch copy** of about 40
minutes of logs is incomplete. Loki and Kafka (threatmap `attack-events`) kept receiving everything. node5 and node6 lost
their Kubernetes API connection for short periods; 10 Longhorn volumes went `degraded`.

---

## Summary

The Elasticsearch data volume (`pvc-a6e3a543…`) had three Longhorn replicas: node-esp-2, node-esp-1 and **node5** (a
Raspberry Pi with a USB SSD). Longhorn writes synchronously to every replica, so the slowest one sets the write latency.
node5's USB SSD was saturated: 88% utilisation for 220 kB/s, 300 ms per write. A 20 MB direct write inside the
Elasticsearch pod took **25 s (829 kB/s)**. Elasticsearch timed out its own refreshes and stats calls, and Fluentd's bulk
requests timed out (`read timeout reached`).

During the Fluentd 1.20.1 rollout (PR #1002) the new CPU requests made the Fluentd HPA work for the first time (before it
showed `<unknown>` and never scaled). The failing Elasticsearch retries kept CPU above target, so the HPA went to **12
pods** (max was 100). The new image is multi-arch, so for the first time Fluentd pods could run on the Pis: 3 landed on
node5 and 3 on node6, each pulling the image and writing its file buffer to the same USB SSD that holds the Longhorn
replicas, and each running 8 Elasticsearch flush threads. node6 stalled at 12:37 and node5 at 12:48 (kernel RCU stalls,
`containerd-shim` blocked > 120 s, k3s lease updates timing out). Longhorn marked their replicas failed at once (4 on
node6, 8 on node5) and started rebuilding them, which added more load to the same disks.

Removing the node5 replica from the Elasticsearch volume brought the write test to 0.8 s (25.7 MB/s) and Elasticsearch
back. Capping the Fluentd HPA at 2 removed the extra pods from the Pis.

---

## Timeline

Times are UTC.

| Time | Event |
|------|-------|
| 2026-11-13 | Elasticsearch volume replicas recreated after the 2026-11-12 incident; one lands on node5 (replica age 9d on 11-22) |
| 2026-11-16 → 11-21 | Fluentd Elasticsearch retries 3,630 / 5,294 / 9,945 / 5,501 / 7,235 / 10,512 per day. No alert |
| 11-22 10:52 | Cilium 1.20.5 merged (#991, separate session) |
| 11-22 ~12:00 | Step 0 baseline: Fluentd 1 pod on node-esp-1, HPA `<unknown>`, 1.19.0, old pod already retrying ES (330 retries in the hour before) |
| 11-22 12:18 | Fluentd 1.20.1 deployed from the branch (Flux branch test). HPA now reads CPU |
| 11-22 12:23 | Fluentd logs `read timeout reached` to Elasticsearch, one Loki `DeadlineExceeded` |
| 11-22 12:18–12:50 | HPA scales Fluentd to 12 pods; up to 3 on node5, 3 on node6, 4 on node-esp-2, 2 on node-esp-1 |
| 11-22 12:32–12:37 | node6 replicas fail (5 volumes); node6 kernel RCU stalls, k3s loses the API server |
| 11-22 12:45 | Diagnosis: Elasticsearch does not answer inside its own pod (20 s timeout), ECK `ElasticsearchIsReachable=False` |
| 11-22 12:48:09–12:49:30 | node5 replicas fail on 8 volumes, including Elasticsearch (12:49:26). ES shard `.kibana_task_manager` fails, cluster RED, back to GREEN at 12:49:35 |
| 11-22 12:49 | Fluentd PR #1002 merged (Elasticsearch already failing before the change, so not the cause of ES) |
| 11-22 ~12:55 | 20 MB write test in the ES pod: 25 s. ES volume `degraded`, node5 replica `WO` rebuilding at 8%, 0 MB/s |
| 11-22 ~12:57 | Live patch: Fluentd HPA `maxReplicas: 2`. Committed to master as `bad01d8b9` |
| 11-22 13:00 | node5 load 50 (4 cores), IO pressure some 99.5% / full 51%; node6 load 20, IO full 30% |
| 11-22 ~13:05 | ES volume set to 2 replicas, node5 replica deleted. Volume `healthy`, write test 0.8 s (25.7 MB/s). Fluentd back to 2 pods on node-esp-1 / node-esp-2 |

---

## Root Causes

### Primary: a Pi USB SSD in the write path of Elasticsearch

Longhorn acknowledges a write only when every replica has it. The Elasticsearch volume had a replica on node5, whose USB
SSD (`00SSD1`, 447 GB, also holding `/` and 228 GB of other replicas) answers writes in about 300 ms at 88% utilisation
for 220 kB/s. Every Elasticsearch write waited for it. Nothing restricted the volume to the amd64 nodes: the StorageClass
has no node or disk selector, so Longhorn places replicas on any schedulable disk (node-esp-1, node-esp-2, node5, node6).

**Fix applied:** Elasticsearch volume at 2 replicas, node5 replica deleted (live, on the Longhorn volume CR; not in git).

### Primary: node5's disk is far slower than its load needs (cause still open)

During the incident node5 did 220 kB/s at 88% utilisation with 300 ms per write. After the Elasticsearch rebuild and
the Fluentd pods were gone (13:15), the same disk did **51.9 MB/s at 28% utilisation, 3.6 ms per write**. The drive and
the USB link are fine (`uas` driver, 5000M link); it collapses only under sustained writes.

The reason it collapses: **TRIM never reaches the SSD.** The USB bridge reports `DISC-MAX 0B` (`lsblk -D`), so
`fstrim.timer` runs every week and "succeeds" but discards nothing. Without TRIM a cheap SSD (`00SSD1`) runs out of
clean blocks under sustained writes and its garbage collection stalls every write. A rebuild storm (Elasticsearch 12 GB
plus Loki plus MongoDB onto node5), the Kafka broker and 3 Fluentd pods were enough. node6 has the same model; its check
is pending. SMART could not be read (`smartmontools` not installed).

### Trigger: Fluentd HPA scale-out onto the Pis (introduced by PR #1002)

- `a76e48ec8` added CPU requests (100m), which made the HPA work. Elasticsearch retries alone kept CPU over 80% of the
  request, and `maxReplicas` was 100 (upstream default).
- The new image is built for arm64 too, so the scheduler could place Fluentd on the Pis for the first time (the old
  amd64-only image would have crashed there).
- Each new pod pulled the image and wrote its file buffer (emptyDir, on the node's root disk = the same USB SSD) and
  added 8 Elasticsearch flush threads against an Elasticsearch that was already timing out.

**Fix applied:** `autoscaling.maxReplicas: 2` (`bad01d8b9`).

### Contributing: replica failure → rebuild → more IO

A stalled node fails all its replicas at once. Longhorn then rebuilds them onto the same disk
(`concurrent-replica-rebuild-per-node-limit: 1`, `replica-replenishment-wait-interval: 600`), which keeps the disk
saturated and makes the next stall more likely.

### Contributing: no alert for days of Elasticsearch write failures

Fluentd logged thousands of Elasticsearch retries a day from at least 2026-11-16, with no alert.
`ElasticsearchNotHealthy` did not fire: the cluster was green most of the time, just slow. `LonghornVolumeDegraded` was
the only signal, and degraded volumes after a rebuild are common enough to be ignored.

---

## What went well

- The Fluentd rollout was tested from a branch with a baseline taken first; the baseline showed the old pod already
  retrying Elasticsearch, which separated the Elasticsearch problem from the Fluentd change quickly.
- Disk buffers (`a76e48ec8`) kept the Elasticsearch backlog bounded and kept Loki and Kafka flowing during the outage.
- The ES volume fix was safe to do live: the two amd64 replicas were `RW` and held all the data.

## What went poorly

- `maxReplicas: 100` came in with the upstream values and was not questioned when the requests made the HPA live.
- The multi-arch build widened where Fluentd can run without a matching node affinity.
- Elasticsearch had been slow for at least 6 days without anyone knowing.
- `ssh node5` from node2 failed (no key) and the first disk test used `sh` (no `time` builtin), costing round trips.
- A push of the HPA cap to master was blocked until approved, while the 12 pods kept running (worked around with a
  live `kubectl patch`).

---

## Actions to prevent recurrence

| # | Action | Status |
|---|---|---|
| 1 | Fluentd HPA `maxReplicas: 2` | Done (`bad01d8b9`) |
| 2 | Elasticsearch volume on the amd64 nodes only (2 replicas) | Done live (Longhorn volume CR). Make it durable: Longhorn disk tag `fast` on node-esp-1/2 and a StorageClass with `diskSelector: fast` for write-heavy volumes (Elasticsearch, Prometheus, Loki, Kafka), or `numberOfReplicas`/selectors per volume |
| 3 | Pi USB SSDs get no TRIM (bridge `DISC-MAX 0B`). Try enabling UNMAP on the bridge (`provisioning_mode=unmap` via a udev rule for its USB ID, then `fstrim -v /storage`); if the bridge refuses it, keep write-heavy replicas off the Pis (action 2). Install `smartmontools` on the Pis to read drive health. Check node6 the same way | Open: node5 checked (link and drive fine at normal load, no TRIM); node6 pending |
| 4 | Fluentd node affinity to `kubernetes.io/arch: amd64` (or prefer node-esp-*), so the aggregator stays off the Pi disks | Open |
| 5 | Alert on Fluentd output retries (`rate(fluentd_output_status_retry_count[15m]) > 0` for 30 min, per output) | Open |
| 6 | Alert on node IO pressure (`node_pressure_io_stalled_seconds_total` rate > 0.5 for 15 min) | Open |
| 7 | Review the other 9 degraded volumes after their rebuilds (Kafka ×3, Postgres-Keycloak ×2, Loki, MongoDB ×2, Prometheus): which have a replica on node5/node6 | Open |
| 8 | Runbook: "Longhorn volume slow" with the in-pod `dd` test, `replicaModeMap`, and the safe replica removal used here | Open |

## Open questions

- Since when exactly has Elasticsearch been slow? Prometheus showed 7 days of retries; older data needs a longer query.
- Did the Cilium 1.20.5 rollout at 10:52 add to the Pi load? Not checked.
- Why did `ElasticsearchNotHealthy` stay silent while ECK reported health `unknown`?

---

## Quick health check

On node2:

```bash
V=$(kubectl -n elastic get pvc elasticsearch-data-efk-es-default-0 -o jsonpath='{.spec.volumeName}')
kubectl -n longhorn-system get volumes.longhorn.io $V -o jsonpath='{.status.robustness} replicas={.spec.numberOfReplicas}{"\n"}'
kubectl -n elastic exec efk-es-default-0 -c elasticsearch -- bash -c 'time (dd if=/dev/zero of=/usr/share/elasticsearch/data/.iotest bs=1M count=20 oflag=direct 2>&1 | tail -1); rm -f /usr/share/elasticsearch/data/.iotest'
kubectl -n fluent get pods -l app.kubernetes.io/name=fluentd -o wide; kubectl -n fluent get hpa
kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,ROBUST:.status.robustness | grep -vc healthy
```

Healthy: Elasticsearch volume `healthy` with 2 replicas, the 20 MB write under 2 s, at most 2 Fluentd pods on
node-esp-*, and the count of non-healthy volumes going down as rebuilds finish.

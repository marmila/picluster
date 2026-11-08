# Incident: node6 CPU throttled to 600MHz by under-voltage (loose power cable)
**Date:** 2026-11-05 → 2026-11-06  
**Duration:** Found 2026-11-05 ~19:00 UTC, fixed 2026-11-06 ~07:33 UTC. The real start is unknown. The node had been under-voltage at some point since its last boot on 2026-09-26, and the strongest clue points to about 2026-11-01 10:00 UTC.  
**Impact:** node6 ran at 86–98% CPU with the Pi firmware holding the CPU at 600MHz (a third of 1.8GHz). Pods on node6 kept failing health checks and restarting: the cert-manager IONOS webhook 128 times, the two Longhorn engine-image pods about 70 times each. A tofu-controller state lock that blocked `elastic-stack-config` for four days was probably caused by the same thing. No data was lost.

---

## Summary

node6's USB-C power cable was not fully pushed into the port. The Pi got too little voltage, and its firmware dropped the CPU to its minimum clock, 600MHz. Everything on the node then needed about three times as much CPU time for the same work. Health checks timed out, and Kubernetes showed one pod after another as "using too much CPU".

None of the normal Linux or Kubernetes tools showed the real cause. `kubectl top` blamed the Cilium agent. `/sys/.../scaling_cur_freq` reported 1.8GHz. `dmesg` was empty. The investigation went through Cilium, Longhorn and a real but unrelated connection leak in the ECK operator before `sudo vcgencmd get_throttled` returned `0x50005`. Reseating the cable fixed it straight away, without a reboot: node6 dropped from 86% to 35%.

---

## Timeline

Times are UTC. Entries marked "inferred" were reconstructed from pod ages and lock timestamps, not observed.

| Time | Event |
|------|-------|
| 2026-09-26 17:58 | node6 last booted, after the UPS-failure outage. Not rebooted since |
| 2026-09-27 10:20 | k3s worker upgrade to v1.37.0 times out on node6 (`DeadlineExceeded` after 30 min). The system-upgrade-controller stops retrying, so no worker gets upgraded for six weeks (inferred link to under-voltage) |
| ~2026-11-01 10:00 | Many containers on node6 restart together without a node reboot: node-exporter, longhorn-csi-plugin, both engine-image pods (inferred from "4d9h ago" restart ages). Probable start or worsening of under-voltage |
| 2026-11-01 10:54 | The tofu-controller runner for `config-elastic` takes the state lock during a plan and never releases it (inferred link to the 10:00 event) |
| 2026-11-05 07:15 | `elastic-stack-config` found not ready (6577 failed reconciles). Lock force-unlocked |
| 2026-11-05 18:59 | node6 at 3779m (94%). Every other node at 17–37% |
| 2026-11-05 19:00 | Pods on node6 add up to only 1682m of the node's 3614m |
| 2026-11-05 19:16 | Cilium agent on node6 at 620m; on other nodes 128–191m. IONOS webhook at 124 restarts, engine-image pods at 66 and 71 |
| 2026-11-05 20:16 | Hubble shows constant `elastic-operator-0 → efk-es-default-0:9200` traffic |
| 2026-11-05 20:19 | ECK operator holds 2076 established connections to Elasticsearch |
| 2026-11-05 ~20:20 | `elastic-operator-0` deleted; it is rescheduled to node5. Elastic traffic disappears from node6 |
| 2026-11-05 20:26 | node6 still at 3938m (98%), Cilium agent at 674m. The leak was not the cause |
| 2026-11-05 ~21:15 | Cilium agent on node6 restarted (`cilium-glj88` → `cilium-kk8rb`) |
| 2026-11-06 07:20 | node6 at 86%, Cilium at 480m. Cilium healthy (176/176 controllers, 0 errors). No pod restarts since the night before |
| 2026-11-06 07:30 | Host check: 58% kernel CPU, CPU pressure ~70%, frequency file says 1.8GHz. `vcgencmd get_throttled` = `0x50005` |
| 2026-11-06 07:31 | `vcgencmd measure_clock arm` = 600MHz. Under-voltage confirmed as active |
| 2026-11-06 ~07:33 | Power cable reseated in node6's USB-C port. No reboot |
| 2026-11-06 07:34 | Clock 1.2–1.5GHz, `get_throttled` = `0x50000` (only the "since boot" bits are left) |
| 2026-11-06 07:36 | node6 at 1410m (35%), in line with the other nodes |
| 2026-11-07 07:10 | system-upgrade-controller restarted (pod was 41 days old). It immediately re-creates the node6 upgrade job |
| 2026-11-07 17:34 | k3s v1.37.2 merged. The controller creates the master jobs and the node5 agent job at the same time. The agent job's prepare step waits for all masters |
| 2026-11-07 ~17:59 | Last master job (node4) finishes and node4 is labelled done, but k3s on node4 is not restarted: binary v1.37.2 on disk, process still v1.37.0 |
| 2026-11-07 18:04 | node5 agent job hits the 30-minute deadline while still waiting (`DeadlineExceeded`). The workers stop again |
| 2026-11-07 ~18:50 | `systemctl restart k3s` on node4, controller restarted. node5 upgrades; the controller then finishes node6, node-esp-1 and node-esp-2 on its own. All 7 nodes on v1.37.2 |

---

## Root Causes

### Primary: under-voltage from a loose power cable

`get_throttled` returned `0x50005`:

| Bit | Meaning | State |
|---|---|---|
| `0x1` | Under-voltage | active |
| `0x4` | CPU throttled | active |
| `0x10000` | Under-voltage has happened since boot | yes |
| `0x40000` | Throttling has happened since boot | yes |

The firmware held the ARM clock at 600MHz. Because everything ran three times slower, every process looked heavier: the Cilium agent, k3s-agent (~73%), containerd shims and kernel time (58% `sy`). Kubernetes showed the node at 86–98% even though nothing on it was doing extra work.

node6 is a Pi 4 that boots from a USB 3 SSD (StarTech adapter, `14b0:0207`) powered from the Pi's own USB port. This adds current spikes under write load (Longhorn replicas, Loki, Tempo) and makes it more sensitive to a poor connection.

**Fix applied:** cable reseated. **Not done:** making sure it can't work loose again, and checking the other Pis.

**Not established:** when the under-voltage started. The "since boot" bit only says it happened at some point after 2026-09-26. The containers that restarted together on 2026-11-01 ~10:00 are the best clue. node6 has also been flaky since the September outage (same-node gossip timeouts that broke the Loki ring), and that may have the same cause.

### Primary: nothing measures or alerts on Pi throttling

node-exporter reports CPU frequency from `scaling_cur_freq`, which kept reading 1.8GHz while the firmware ran the CPU at 600MHz. No metric anywhere showed under-voltage. Alertmanager also sends every alert to the `null` receiver, so even the existing node CPU and pod restart alerts reached nobody.

**No fix yet.** See actions.

### Separate defect found on the way: ECK operator connection leak

`elastic-operator-0` (ECK 3.5.0, chart defaults) held 2076 idle keep-alive connections to `efk-es-default-0:9200`, producing about 460 flows/s of ACK-only traffic through Cilium. Restarting the operator cleared it but did not fix node6, so it was not the cause of this incident. The leak will grow back over time on whichever node runs the operator (now node5).

**Workaround applied:** operator pod restarted. **No fix yet.**

### Contributing: the slow node broke other things that hid the cause

- **tofu-controller lock:** the runner for `config-elastic` most likely died mid-plan in the 2026-11-01 event, and the lock blocked `elastic-stack-config` for four days.
- **Health checks:** exec probes every 5s on the two Longhorn engine-image pods, and the IONOS webhook's `/healthz`, timed out on the slow CPU. The resulting restarts looked like problems with those apps.
- **Stuck k3s upgrade:** the k3s-agent upgrade job on node6 hit its 30-minute deadline on 2026-09-27. The plan stayed `JobFailed`, and the controller (v0.20.1) never retried, even after the job was gone. All four workers stayed on v1.36.4 while the control plane ran v1.37.0. This showed up only as a `KubeVersionMismatch` alert that nobody received. Restarting the controller made it retry.
- **Cilium restart:** restarting the Cilium agent lowered its CPU from 674m to 480m and stopped the restart loop for the night. This made it look like progress, though the node was still throttled.

---

## What went well

- `kubectl top` comparisons across nodes quickly showed the problem was specific to node6.
- Comparing the sum of pod CPU with the node total (1.7 vs 3.6 cores) showed that host processes were using most of the CPU, not any single pod.
- The ECK leak was proven (2076 connections, Hubble flows) before acting, and the result was checked afterwards. That ruled it out as the cause instead of leaving it as a guess.
- The fix needed no reboot, no drain and no config change.

## What went poorly

- About 12 hours were spent on software suspects (Loki, Longhorn, Cilium, ECK) before checking the hardware. The September outage notes already flagged node6 as flaky with a possible power cause.
- `scaling_cur_freq` was taken as proof the CPU was at full speed. On a Pi, only `vcgencmd measure_clock arm` shows the real clock.
- There was no alerting, so the node may have been throttled for days before anyone noticed.

---

## Actions to prevent recurrence

| # | Action | Status |
|---|---|---|
| 1 | Route Alertmanager alerts to a real receiver (ntfy) and add a dead-man's switch (healthchecks.io on the Watchdog alert) | In progress |
| 2 | Export `get_throttled` from every Pi as a Prometheus metric (node-exporter textfile collector, root cron or systemd timer every minute) and alert when bit `0x1` or `0x4` is set | Open |
| 3 | Check all Pis now: `./ansible-runner/ansible-runner.sh ansible raspberrypi -b -m shell -a 'vcgencmd get_throttled; vcgencmd measure_clock arm'` | Open |
| 4 | Secure node6's power cable so it can't work loose again; consider a powered USB hub for the SSD | Open |
| 5 | ECK operator leak: pin `elastic-operator` to amd64 and look for an ECK release newer than 3.5.0 that fixes it | Open |
| 6 | When a Pi misbehaves, run `sudo vcgencmd get_throttled` first | Recorded |
| 7 | Finish the k3s worker upgrade: restart system-upgrade-controller (`kubectl -n system-upgrade rollout restart deploy/system-upgrade-controller`) | Done (2026-11-07, all nodes on v1.37.0+k3s1) |
| 8 | After any outage, check `kubectl get plans.upgrade.cattle.io -n system-upgrade` for `JobFailed` and restart the controller if a plan is stuck | Recorded |
| 9 | Raise `jobActiveDeadlineSecs` on the `k3s-agent` Plan from 1800 to 7200: the agent prepare step's wait for the masters counts against it. The 2026-09-27 node6 failure was probably the same timing problem, made worse by under-voltage | Done (feature/k3s-upgrade-fixes) |
| 10 | Alert on a stuck upgrade plan (`K3sUpgradePlanStuck`) and on a node whose version matches no plan (`K3sNodeVersionDrift`), with runbook `CLUSTER-015` | Done (feature/k3s-upgrade-fixes) |
| 11 | Alert on a stuck tofu-controller state lock (`TerraformStateLocked`, `TerraformNotReady`) and write the unlock runbook `GITOPS-007` | Done (feature/terraform-alerts) |

## Open questions

- When did the under-voltage start? Prometheus can show when node6's CPU rose: `100 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle",instance=~".*node6.*"}[1h])) * 100` over 30 days. Prometheus was down 2026-10-27 → 2026-10-31, so that window has no data.
- Was the 2026-09 same-node network flakiness on node6 the same cause?

---

## Quick health check

On the Pi (needs sudo; `vcgencmd` cannot open `/dev/vcio` without it):

```bash
sudo bash -c 'vcgencmd get_throttled; vcgencmd measure_clock arm; vcgencmd measure_volts core'
```

- `throttled=0x0` and a clock of up to 1.8GHz: healthy.
- Bits `0x1` or `0x4` set: under-voltage or throttling happening now. Check the cable and power supply.
- Only `0x50000`: it happened earlier since boot but is not happening now.

From node2:

```bash
kubectl top nodes; kubectl -n kube-system top pod -l k8s-app=cilium --no-headers | sort -k2 -h -r | head -3
```

A healthy Pi node sits at about 20–40% CPU, with its Cilium agent around 130–200m.

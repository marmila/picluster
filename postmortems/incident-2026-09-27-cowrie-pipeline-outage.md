# Incident: Cowrie Pipeline Outage
**Date:** 2026-09-27 → 2026-10-06  
**Duration:** ~9 days  
**Impact:** Zero cowrie honeypot events ingested into MongoDB. OpenCanary events unaffected.

---

## Summary

Cowrie SSH honeypot events stopped appearing in MongoDB on September 27. The pipeline break was in Fluentd's `<match cowrie>` kafka2 output, which entered an exponential retry backoff state after a transient Kafka error and silently stopped producing events. The identical `<match opencanary>` output was unaffected. The outage was compounded by the Fluentd Prometheus HTTP server thread dying after 8+ days of uptime, making retry/buffer metrics invisible. Resolved by restarting the Fluentd pod.

---

## Timeline

| Time | Event |
|------|-------|
| 2026-09-27 | Last cowrie events in MongoDB |
| 2026-09-27 | Fluent-Bit cowrie.json offset drift begins (midnight log rotation, new inode, offset not reset in SQLite DB) |
| 2026-10-04 | Fluent-Bit SQLite DB offset manually reset; events start forwarding to Fluentd again |
| 2026-10-05 | Fluentd confirmed receiving cowrie events (Prometheus `${host}` filter warnings every ~50s) |
| 2026-10-05 | Kafka topic scan confirms zero cowrie events at recent offsets; OpenCanary flowing normally |
| 2026-10-05 | Fluentd Prometheus endpoint returns 0 bytes; confirmed HTTP server thread dead |
| 2026-10-06 | `kubectl -n fluent rollout restart deployment/fluentd` clears stuck retry state |
| 2026-10-06 | Cowrie events immediately appear in MongoDB dashboard |

---

## Root Causes

### Primary: Fluentd kafka2 stuck in exponential backoff

Fluentd's kafka2 output plugin for `<match cowrie>` hit a transient error on ~Sep 27 (likely a Kafka broker leadership rebalance or producer timeout). With `retry_forever true` and no `retry_max_interval` set, the default backoff cap is 72 hours. After 9 days the plugin was retrying at 72-hour intervals — functionally silent. Events accumulated in the in-memory buffer (never flushed to disk, so no visible buffer files). The `<match opencanary>` output in the same config block was unaffected, which masked the issue.

**Fix applied:** Added `retry_max_interval 300` (5 minutes) to both kafka2 buffer configs in [kubernetes/platform/fluent/fluentd/base/fluentd-config.yaml](kubernetes/platform/fluent/fluentd/base/fluentd-config.yaml).

### Contributing: Fluentd Prometheus HTTP server thread died

The `in_prometheus` HTTP server (`Async::Task`, running since pod start) hung after 8+ days of uptime. Every metric check — buffer queue length, retry count, output status — returned empty, making the stuck kafka2 output invisible. The filter pipeline itself was unaffected (events still processed), but the observability layer was dead.

**No fix yet:** Prometheus thread stability is a Fluentd upstream issue. The pod restart also resets the async task. Consider adding a liveness probe on port 24231.

### Secondary: Fluent-Bit offset drift after log rotation

Cowrie logs rotate daily at midnight. When `cowrie.json` is replaced (new inode), Fluent-Bit's SQLite tracking DB retains the old file's offset. If the old offset exceeds the new file's size, Fluent-Bit reads nothing until the new file grows past that offset (or indefinitely if it doesn't). This delayed event delivery for ~7 days after the rotation.

**Manual fix applied on 2026-10-04:** SQLite DB entry deleted, Fluent-Bit restarted.  
**Permanent fix pending (manual):** Add `Rotate_Wait 30` to the Fluent-Bit tail input on the Oracle honeypot VM:

```ini
# /etc/fluent-bit/fluent-bit.conf
[INPUT]
    Name              tail
    Path              /var/lib/docker/volumes/cowrie-var/_data/log/cowrie/cowrie.json
    Tag               cowrie
    DB                /var/lib/fluent-bit/cowrie.db
    Parser            json
    Read_from_Head    False
    Refresh_Interval  5
    Rotate_Wait       30
```

This config lives on the Oracle VM (`/etc/fluent-bit/fluent-bit.conf`) and is not managed by this repo.

---

## Detection Gap

The outage ran for 9 days before being noticed. MongoDB was queried manually to spot the gap. No alert fired.

**Recommended:** Add a Prometheus/Grafana alert: `increase(mongodb_collection_count{collection="events", filter="cowrie"}[1h]) == 0` for >30 minutes during active hours.

---

## Lessons

- `retry_forever true` without `retry_max_interval` is dangerous: a single transient error can permanently strand a Fluentd output with no visible signal.
- Two independent failures (Fluent-Bit offset drift + Fluentd kafka2 backoff) in the same pipeline stacked and prolonged the outage.
- Fluentd's Prometheus endpoint silently dying removed all in-process observability. Output health should be checked via an external probe, not just metrics scraping.

Weekly cluster update. Full instructions: [homelab-docs/cluster-maintenance.md](https://github.com/marmila/picluster/blob/master/homelab-docs/cluster-maintenance.md)

## 1. Before you start
- [ ] No alerts on ntfy that are still unresolved
- [ ] healthchecks.io check `picluster` is green (alerting works)

## 2. Weekly bundle (merges by itself, Monday 10:00–18:00 Rome)
- [ ] The **all non-major dependencies** PR got merged by Renovate. Still open after 18:00? Open it: a failed check tells you why (see homelab-docs/update-automation.md)
- [ ] No alert on ntfy in the hour after it merged

## 3. Critical updates
Automatic, one per weekday 10:00–18:00 Rome, releases at least 7 days old:
Vault (Tue), CloudNativePG (Wed), Istio (Thu). Nothing to do unless ntfy alerts.

Manual, one per session, k3s always last: **Longhorn, Cilium, Flux, system-upgrade-controller, k3s**, majors.
- [ ] Merged one manual critical PR from the list below (or none this week)
- [ ] Health check clean after it (runbook 4.3)

## 4. Close
- [ ] Note anything odd in a comment, then close this issue

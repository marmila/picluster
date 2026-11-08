Weekly cluster update. Full instructions: [homelab-docs/cluster-maintenance.md](https://github.com/marmila/picluster/blob/master/homelab-docs/cluster-maintenance.md)

## 1. Before you start
- [ ] No alerts on ntfy that are still unresolved
- [ ] healthchecks.io check `picluster` is green (alerting works)

## 2. Weekly bundle
- [ ] Open the **all non-major dependencies** PR, skim the release notes, CI green → merge
- [ ] Wait 15 min, run the health check (runbook 4.3), all clean
- [ ] No `Flux…NotReady` alert on ntfy in the next hour

## 3. Critical updates (one per session, k3s always last)
- [ ] Merged one critical PR from the list below (or none this week)
- [ ] Health check clean after it

## 4. Close
- [ ] Note anything odd in a comment, then close this issue

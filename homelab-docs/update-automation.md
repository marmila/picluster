# Update automation

How Renovate updates move from "PR waiting for a manual merge" to "merged automatically when it is safe",
with alerts and runbooks watching the cluster instead of a person.

The day-to-day procedure (what to do daily, weekly, monthly) stays in
[cluster-maintenance.md](cluster-maintenance.md). This page explains the automation behind it.

## The plan

| Step | What | Status |
|---|---|---|
| 1 | **CI check worth trusting**: every Renovate PR is built and rendered like Flux would apply it | **done** (PR #979) |
| 2 | **Automerge by risk level** in Renovate, only when the step 1 check passes | **done** |
| 3 | **Alerts and runbooks** that replace watching the cluster after a merge (ntfy) | **done** |

Decisions already taken (2026-11-09):

- **k3s and Longhorn stay manual.** They cannot be downgraded, so a bad version means fixing forward.
- **Majors and blocked packages stay manual** (release notes have to be read; see the blocked list in
  [cluster-maintenance.md](cluster-maintenance.md#24-blocked-packages-and-caps)).
- **Automerge window: weekdays 10:00–18:00 Europe/Rome**, so nothing merges while nobody can react.
- **Notifications go to ntfy.sh**, which GitHub Actions can reach directly.

---

## Step 1: Validate Kubernetes (CI)

**Files:**
- [.github/workflows/validate-kubernetes.yml](../.github/workflows/validate-kubernetes.yml): the workflow
- [.github/scripts/validate_flux.py](../.github/scripts/validate_flux.py): the build and render logic

**When it runs:** on every PR, on pushes to `renovate/**` branches (Renovate branch automerge has no PR)
and `master`, and by hand (Actions → Validate Kubernetes → Run workflow).

**What it checks, for the prod cluster:**

1. **Builds every Flux Kustomization** the cluster actually applies. It reads
   `kubernetes/clusters/prod/*/kustomization.yaml` the way Flux does, so a stray file that is not listed
   there is ignored, like in the cluster. `${VARIABLES}` are filled from
   `kubernetes/clusters/prod/config/cluster-settings.yaml`; variables that come from secrets get a
   placeholder.
2. **Renders every HelmRelease** with `helm template` at the chart version pinned in Git, with its values
   (`spec.values` plus `valuesFrom` ConfigMaps). This catches:
   - a chart version that does not exist (wrong tag, release pulled);
   - values the new chart version rejects (renamed or removed settings, schema errors).
3. **Validates every resource** with kubeconform against the Kubernetes 1.37 schemas and the
   [CRD catalog](https://github.com/datreeio/CRDs-catalog) (Flux, cert-manager, Istio, CNPG, …).
   Resources with no published schema are skipped and counted in the summary.

**What it cannot check:** anything that needs the live cluster. A chart that renders fine can still fail to
start (image missing for arm64, a migration that breaks, a pod that crashes). That is what Flux's automatic
Helm rollback and the step 3 alerts are for.

### Reading a failure

Open the failed run (PR → Checks → Validate Kubernetes). The step that failed tells you which kind of problem
it is:

| Failed step | Example message | Meaning | What to do |
|---|---|---|---|
| Build Flux Kustomizations and render HelmReleases | `FAIL velero/velero (velero 99.9.9)` / `chart "velero" version "99.9.9" not found` | the chart version does not exist in the repository | wait for Renovate to correct it, or close the PR |
| same | `kustomize build <name> ... : error: ...` | a Kustomize overlay is broken (missing file, bad patch) | fix the overlay in the PR |
| same | `HelmRelease <ns>/<name> chart ...: Error: values don't meet the specifications of the schema` | the new chart version rejects the current values | read the chart's upgrade notes, adapt `values.yaml` in the PR |
| Validate schemas | `<file> - <Kind> <name> is invalid: ...` | a resource has a wrong field or type | fix the manifest in the PR |

The end of a good run looks like this:

```
All builds and charts OK
Summary: 461 resources found in 63 files - Valid: 450, Invalid: 0, Errors: 0, Skipped: 11
```

### Running it on your machine

Needs `python3` with `pyyaml`, `helm`, and `kustomize` (or `kubectl`):

```bash
python3 .github/scripts/validate_flux.py --env prod --out /tmp/flux-validate
# without the kustomize binary:
KUSTOMIZE="kubectl kustomize" python3 .github/scripts/validate_flux.py --env prod --out /tmp/flux-validate
# builds only, no chart downloads:
python3 .github/scripts/validate_flux.py --env prod --out /tmp/flux-validate --skip-helm
```

The script uses an empty helm and docker configuration, so local logins do not interfere. On Windows, a
stale ghcr.io login in the Windows credential store can still make ghcr.io charts fail with `403 denied`
locally; GitHub Actions is not affected.

### Keeping it current

- **Kubernetes version** (`KUBE_VERSION` in the workflow): raise it when k3s moves to a new minor version.
- **kubeconform** is updated by Renovate (the `# renovate:` comment in the workflow).
- `kustomize` and `helm` come with GitHub's Ubuntu runner image.

---

## Step 2: Automerge by risk level

**File:** [.github/renovate/automerge.json5](../.github/renovate/automerge.json5) (group names stay in
[groups.json5](../.github/renovate/groups.json5)).

### What merges by itself, and when

Renovate merges a PR only when **every check on it passes** (Validate Kubernetes, Lint, CodeQL, ...), and
only on **weekdays between 10:00 and 18:00 Europe/Rome**. Renovate does the merge itself
(`platformAutomerge: false`), so the time window and the checks are always respected.

| What | When it merges | Release age |
|---|---|---|
| Weekly bundle **all non-major dependencies** | Monday 10:00–18:00 | 3 days |
| Tools: mise, GitHub Actions, kubectl / Helm / Velero CLI | any weekday 10:00–18:00 | — |
| Grafana dashboard revisions | any weekday 10:00–18:00 | — |
| **Vault** (minor/patch) | Tuesday 10:00–18:00 | 7 days |
| **CloudNativePG** operator (minor/patch) | Wednesday 10:00–18:00 | 7 days |
| **Istio** (minor/patch) | Thursday 10:00–18:00 | 7 days |

A PR whose check fails stays open, with the failure on it: nothing broken is merged. Renovate tries again
on the next run, and the weekly issue lists it.

### What stays manual, and why

| What | Why |
|---|---|
| **k3s** | upgrades every node; Kubernetes cannot be downgraded |
| **Longhorn** | storage; no downgrades |
| **Cilium** | its chart comes from quay.io, which publishes no release dates, so the 7-day wait cannot be enforced |
| **Flux** (operator, instance charts, and the **Flux distribution** group `fluxcd/flux2`) | if Flux breaks, it cannot roll anything back, itself included |
| **system-upgrade-controller** | it runs the k3s node upgrades |
| every **major** version | release notes have to be read |
| **blocked** packages | see the blocked list in [cluster-maintenance.md](cluster-maintenance.md#24-blocked-packages-and-caps) |

Flux, system-upgrade-controller and Cilium were planned as automatic; they moved to manual for the reasons
above.

### Flux upgrades: operator first, then the distribution

The Flux operator only installs Flux versions it knows. Upgrade in two steps, on separate days:

1. **Operator** (Renovate group "Flux", `controlplaneio-fluxcd` charts). Check it on node2:
   `kubectl -n flux-system get deploy flux-operator -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'`
2. **Distribution** (group "Flux distribution", `fluxcd/flux2`), only once the operator release notes list
   that Flux version. Otherwise the FluxInstance stalls (`FluxInstanceNotReady`, runbook GITOPS-008).

Example: Flux 2.10 needs flux-operator 0.62.0 or later. On 2026-11-09 it was merged with operator 0.60 and
stalled; Flux went back to 2.9.5, the operator went to 0.62.1 the same day, and **2.10 is the next manual
update** (tick "fluxcd/flux2 to v2.10.0" in the Dependency Dashboard, issue #238).

### Releases without a date (ghcr.io, quay.io)

Renovate waits a minimum age before offering an update (3 days for the weekly bundle, 7 for critical
components), using the release date from the registry. **ghcr.io and quay.io publish no release dates.**
Since Renovate 42 an undated release then waits forever: it shows as "Pending Status Checks" in the
Dependency Dashboard, with `renovate/stability-days` pending on its PR.

The repo sets `minimumReleaseAgeBehaviour: "timestamp-optional"`: undated releases are offered without the
wait. The automerged critical components (Vault, CloudNativePG, Istio) set it back to
`timestamp-required`, so they are only merged once a dated release is 7 days old. That is why Cilium
(quay.io) is manual.

> **Flux distribution, not "Flux CLI".** `fluxcd/flux2` is pinned in three places: `.mise.toml` (the CLI on
> your workstation), `ansible/vars/picluster.yml` (bootstrap) and
> `kubernetes/platform/flux-operator/instance/base/values.yaml` (**the Flux running in the cluster**).
> They are one group, so that PR upgrades the cluster. It used to be called "Flux CLI", which hid that.

### Stopping automerge

To stop every automerge at once (for example during an incident), add this rule at the **end** of
`packageRules` in [.github/renovate.json5](../.github/renovate.json5) and push to `master`:

```json5
packageRules: [
  { matchPackageNames: ["*"], automerge: false },
],
```

Renovate then opens PRs as before but merges nothing. Remove the rule to turn automerge back on. To hold
back a single package, untick it in the Dependency Dashboard (issue #238).

### The Validate Kubernetes check runs on every PR

It has no path filter, so it can be made a **required check** on `master`
(Settings → Branches → `master` → Require status checks → **Validate prod manifests**). A required check that
only runs for some paths would never start on the other PRs and block them forever.

## Step 3: Alerts and runbooks

All alerts go to ntfy. Runbooks are in [runbooks/](../runbooks/README.md); each alert carries its runbook ID.

| Alert | Fires when | Severity | Runbook |
|---|---|---|---|
| `FluxHelmReleaseRolledBack` | Flux rolled a failed Helm install/upgrade back by itself (1 min). The cluster is fine, the update in Git did not go in | warning | [GITOPS-009](../runbooks/cluster/gitops-release.md#runbook-gitops-009) |
| `FluxInstanceNotReady` | the Flux operator cannot install the Flux version in Git (15 min); Flux keeps running the old one | critical | [GITOPS-008](../runbooks/cluster/gitops-release.md#runbook-gitops-008) |
| `WebEndpointDown` | one web UI does not answer through the gateway (5 min) | critical | [NET-010](../runbooks/components/networking-ingress.md#runbook-net-010) |
| `WebEndpointsAllDown` | every web UI is down: gateway, Istio or Cilium (3 min) | critical | [NET-010](../runbooks/components/networking-ingress.md#runbook-net-010) |
| "Renovate: N automerge PR(s) stuck" | an automerge PR failed a check, or has been open more than 7 days (weekdays ~18:30 Rome) | ntfy message | [GITOPS-011](../runbooks/cluster/gitops-release.md#runbook-gitops-011) |

To undo an update, merged by hand or automatically: [GITOPS-010](../runbooks/cluster/gitops-release.md#runbook-gitops-010).

The existing Flux alerts (`FluxHelmReleaseNotReady`, `FluxKustomizationNotReady`, `FluxSourceNotReady`,
`FluxResourceSuspended`) now carry runbook links too. `FluxHelmReleaseNotReady` skips a release that was
rolled back, so one failed upgrade sends one alert.

### How each one works

- **Rolled back, FluxInstance:** kube-state-metrics reads the Flux objects
  (`kubernetes/platform/kube-prometheus-stack/app/components/flux-monitoring/values.yaml`): HelmReleases get a
  `remediated` label from their `Remediated` condition, and FluxInstance is now exported like the other Flux
  objects. Rules: `flux-alert-rules.yaml` next to it.
- **Web UIs:** the blackbox exporter (`kubernetes/platform/blackbox-exporter/`) calls
  `https://grafana.<domain>/api/health`, Keycloak's `/realms/master/.well-known/openid-configuration`,
  Prometheus `/-/healthy` and Threatmap `/`, through the gateway (targets `web-*` in the prod overlay,
  module `http_reachable`). A redirect to the SSO login and 401/403 count as up; connection errors,
  timeouts and 5xx count as down. For an app behind the gateway SSO this only proves the gateway answers,
  not the app behind it. Rules: `web-rules.yaml`. The certificate alerts ignore `web-*` (cert-manager
  watches those certificates).
- **Automerge stuck:** [.github/workflows/renovate-watch.yml](../.github/workflows/renovate-watch.yml) runs on
  weekdays at 17:30 UTC (after the merge window). It looks only at Renovate PRs with "Automerge: Enabled",
  skips blocked ones, and posts the list to ntfy. Manual PRs are not nagged about; the weekly issue lists them.

### Setup: the ntfy secret for the Renovate watch

The workflow posts straight to ntfy.sh, so it needs the topic URL as a repository secret:

1. GitHub → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**.
2. Name `NTFY_URL`, value the topic URL, for example `https://ntfy.sh/<your-topic>`. Use the plain topic
   URL, without the `?template=alertmanager` part Alertmanager uses.
3. If the topic needs a token, add a second secret `NTFY_TOKEN`.
4. Test: **Actions** → **Renovate watch** → **Run workflow**, tick "Send a test notification".

Without the secret the workflow fails with "NTFY_URL is not set", visible in the Actions tab.

### Checking that the alerts work

In Prometheus (**Query** tab, `https://prometheus.<domain>`), run each query **on its own**: pasting two
lines in one box gives `parse error: unexpected identifier`.

| Query | Healthy result |
|---|---|
| `probe_success{target=~"web-.*"}` | 4 rows (`web-grafana`, `web-keycloak`, `web-prometheus`, `web-threatmap`), all `1` |
| `gotk_resource_info{customresource_kind="FluxInstance"}` | 1 row with `ready="True"` |
| `ALERTS{alertname=~"Flux.*\|WebEndpoint.*"}` | empty when nothing is wrong |

The same from node2, without a browser:

```bash
P=$(kubectl -n kube-prom-stack get pod -l app.kubernetes.io/name=prometheus -o name | head -1)
kubectl -n kube-prom-stack exec $P -c prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=probe_success%7Btarget%3D~%22web-.*%22%7D'
kubectl -n kube-prom-stack exec $P -c prometheus -- wget -qO- 'http://localhost:9090/api/v1/rules' | grep -oE 'FluxHelmReleaseRolledBack|FluxInstanceNotReady|WebEndpointDown|WebEndpointsAllDown' | sort -u
```

A probe at `0` while the site opens fine in a browser usually means the URL or the expected status code is
wrong: fix the target in `kubernetes/platform/blackbox-exporter/app/overlays/prod/`.

The Renovate watch is checked with its test run (step 4 of the setup above): the phone gets
"Renovate watch: test notification". Verified 2026-11-09.

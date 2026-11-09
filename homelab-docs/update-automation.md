# Update automation

How Renovate updates move from "PR waiting for a manual merge" to "merged automatically when it is safe",
with alerts and runbooks watching the cluster instead of a person.

The day-to-day procedure (what to do daily, weekly, monthly) stays in
[cluster-maintenance.md](cluster-maintenance.md). This page explains the automation behind it.

## The plan

| Step | What | Status |
|---|---|---|
| 1 | **CI check worth trusting**: every Renovate PR is built and rendered like Flux would apply it | **done** (PR #979) |
| 2 | **Automerge by risk level** in Renovate, only when the step 1 check passes | planned |
| 3 | **Alerts and runbooks** that replace watching the cluster after a merge (ntfy) | planned |

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

**When it runs:** on every PR that touches `kubernetes/**`, on pushes to `renovate/**` branches (Renovate
branch automerge has no PR) and `master`, and by hand (Actions → Validate Kubernetes → Run workflow).

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

## Step 2: Automerge by risk level (planned)

| Level | What | How |
|---|---|---|
| Auto | weekly non-major bundle, tools (mise, GitHub Actions), Grafana dashboards | automerge on Monday, release at least 3 days old |
| Auto, one per day | Vault, CloudNativePG, Cilium, Istio, Flux operator, system-upgrade-controller | each on its own weekday, release at least 7 days old; Flux rolls a failed Helm upgrade back by itself |
| Manual | k3s, Longhorn, all majors, blocked packages | as today, see [cluster-maintenance.md](cluster-maintenance.md) |

Automerge happens only when the step 1 check passes, and only on weekdays between 10:00 and 18:00
Europe/Rome.

## Step 3: Alerts and runbooks (planned)

| Alert | Fires when | Runbook |
|---|---|---|
| Upgrade rolled back | Flux reverted a Helm upgrade by itself: the cluster is fine, but the update did not go in | to write |
| Site down after update | a URL probe (Grafana, Keycloak, apps through the gateway) fails, even if Flux reports Ready | to write |
| Automerge stuck | a Renovate PR failed the step 1 check, or has been open for more than 7 days | to write |

Plus a runbook for **reverting an automerged update** (find the commit, `git revert`, Flux rolls back).

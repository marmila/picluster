# GitOps and Release Runbooks

Run the commands on node2. `kubectl` works there; the `flux` CLI is installed with `make admin-cli`
(Ansible, version `fluxcd_version` in `ansible/vars/picluster.yml`; re-run it after every Flux upgrade).
Without the CLI, `flux reconcile <kind> <name>` is the same as
`kubectl -n <namespace> annotate <kind> <name> reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite`.

## GITOPS-001 Flux Source Outage Triage

<a id="runbook-gitops-001"></a>
Runbook ID: `GITOPS-001`
Owner: Platform
Severity: `SEV-1` or `SEV-2`

Objective: Restore Git source synchronization when Flux cannot fetch repository artifacts.

Preconditions:

- Cluster admin access.
- `flux` and `kubectl` CLIs authenticated.

Procedure:

1. Check source status and failure reason.

```bash
flux get sources git -n flux-system
kubectl -n flux-system describe gitrepository flux-system
```

2. Validate controller pods and DNS/connectivity.

```bash
kubectl -n flux-system get pods
kubectl -n flux-system logs deploy/source-controller --tail=200
```

3. If credentials or repo ref changed, fix manifest/secret in Git.
4. Reconcile source and dependent kustomizations.

```bash
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization flux-system -n flux-system --with-source
```

Verify:

- `GitRepository/flux-system` shows `Ready=True`.
- Downstream Kustomizations start reconciling.

Rollback:

1. Revert the last Git change that modified source URL/ref/secret.
2. Reconcile source again.

## GITOPS-002 Kustomization Stuck or Not-Ready Triage

<a id="runbook-gitops-002"></a>
Runbook ID: `GITOPS-002`
Owner: Platform
Severity: `SEV-2`

Objective: Recover Kustomizations that are stuck or repeatedly failing.

Procedure:

1. Identify failing Kustomizations and error messages.

```bash
flux get kustomizations -n flux-system
kubectl -n flux-system describe kustomization <name>
```

2. Check dependencies and health-check expressions.
3. Inspect relevant controller logs.

```bash
kubectl -n flux-system logs deploy/kustomize-controller --tail=200
```

4. If needed, pause noisy reconciliations while fixing Git state.

```bash
flux suspend kustomization <name> -n flux-system
# apply fix in Git
flux resume kustomization <name> -n flux-system
flux reconcile kustomization <name> -n flux-system --with-source
```

Verify:

- Target Kustomization transitions to `Ready=True`.
- Dependency chain also healthy.

Rollback:

1. Revert offending commit.
2. Reconcile source and target Kustomization.

## GITOPS-003 HelmRelease Stuck or Not-Ready Triage

<a id="runbook-gitops-003"></a>
Runbook ID: `GITOPS-003`
Owner: Platform
Severity: `SEV-2`

Objective: Recover Helm releases managed by Flux when reconciliation is stuck or failing.

Preconditions:

- Cluster admin access.
- `flux`, `kubectl`, and optionally `helm` CLIs authenticated.

Procedure:

1. Identify failing HelmRelease and reason.

```bash
flux get helmreleases -A
kubectl -n <namespace> describe helmrelease <name>
```

2. Determine whether the failure is a stale-spec problem or a rollout/runtime problem.

```bash
kubectl -n <namespace> get helmrelease <name> -o jsonpath='{.metadata.generation}{"\n"}{.status.observedGeneration}{"\n"}'
kubectl -n <namespace> get helmrelease <name> -o yaml | grep -E 'chartRef:|sourceRef:|valuesFrom:|lastAttempted|message:'
```

Interpretation:

- If `metadata.generation` is ahead of `status.observedGeneration`, or the live HelmRelease spec still shows the old broken value, Flux has not synchronized the updated HelmRelease object yet.
- If `metadata.generation == status.observedGeneration`, the live HelmRelease spec is current and the failure is in the chart rollout, health checks, or Helm remediation path.

3. Check helm-controller logs for template, install, upgrade, rollback, or remediation errors.

```bash
kubectl -n flux-system logs deploy/helm-controller --tail=200
```

4. Validate chart source availability.

```bash
flux get sources helm -A
kubectl -n <namespace> get helmchart
```

5. If the HelmRelease spec is stale, inspect and reset the owning Kustomization.

```bash
kubectl -n flux-system get kustomization -o wide
kubectl -n flux-system describe kustomization <owning-kustomization>
flux suspend kustomization <owning-kustomization> -n flux-system
flux resume kustomization <owning-kustomization> -n flux-system
flux reconcile kustomization <owning-kustomization> -n flux-system --with-source
```

Expected outcome:

- The live HelmRelease spec updates to the fixed values from Git.
- `status.observedGeneration` advances to match `metadata.generation`.

6. If the HelmRelease spec is current but rollout is failing, inspect the managed workload directly.

```bash
kubectl -n <namespace> get deploy,pod,svc,ingress
kubectl -n <namespace> describe deployment <deployment-name>
kubectl -n <namespace> logs <pod-name> --all-containers --tail=200
```

Common signals:

- `Running 'upgrade' action with timeout ...` followed by `rollback` indicates Helm is applying the new spec but the workload is not becoming healthy fast enough.
- `context deadline exceeded`, readiness probe failures, or deployment `InProgress` messages indicate runtime rollout issues rather than stale Flux state.

7. Fix values, dependencies, workload readiness, or chart version in Git, then reconcile the source and HelmRelease.

```bash
flux reconcile source helm <source-name> -n <source-namespace>
flux reconcile helmrelease <name> -n <namespace> --with-source
```

For GitRepository-backed app-of-apps layouts, also reconcile the app Kustomization if needed.

```bash
flux reconcile source git <git-source-name> -n flux-system
flux reconcile kustomization <owning-kustomization> -n flux-system --with-source
```

Verify:

- HelmRelease transitions to `Ready=True`.
- `metadata.generation` and `status.observedGeneration` match.
- Target workload pods become Ready.

Rollback:

1. Revert to last known-good values/chart version in Git.
2. If the HelmRelease object is stuck on an older spec, reset and reconcile the owning Kustomization.
3. Reconcile source and HelmRelease again.

## GITOPS-004 Safe Suspend and Resume Strategy

<a id="runbook-gitops-004"></a>
Runbook ID: `GITOPS-004`
Owner: Platform
Severity: `Maintenance`

Objective: Pause and resume Flux reconciliation safely during maintenance or incident containment.

Procedure:

1. Identify the exact object set to suspend.
2. Suspend from the highest-impact leaf first to minimize churn.

```bash
flux suspend kustomization <name> -n flux-system
flux get kustomizations -n flux-system
```

3. Perform maintenance/fix while reconciliations are paused.
4. Resume in dependency order (foundations first, then dependents).

```bash
flux resume kustomization <foundation> -n flux-system
flux reconcile kustomization <foundation> -n flux-system --with-source
flux resume kustomization <dependent> -n flux-system
flux reconcile kustomization <dependent> -n flux-system --with-source
```

Verify:

- All resumed Kustomizations reach `Ready=True`.
- No repeated reconcile failures in controller logs.

Rollback:

1. Re-suspend problematic Kustomization.
2. Revert maintenance change and resume again.

## GITOPS-005 Flux Upgrade and Rollback

<a id="runbook-gitops-005"></a>
Runbook ID: `GITOPS-005`
Owner: Platform
Severity: `Maintenance` or `SEV-2`

Objective: Upgrade Flux controllers safely and recover quickly if regressions occur.

Preconditions:

- Current Flux versions recorded.
- Change window and rollback plan approved.

Procedure:

1. Capture pre-upgrade state.

```bash
flux check
flux get all -A
kubectl -n flux-system get deploy
```

2. Apply upgrade via Git-managed manifests (preferred).
3. Reconcile Flux root objects.

```bash
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization flux-system -n flux-system --with-source
```

4. Validate controllers and managed workloads.

Verify:

- Flux controllers healthy.
- Source and kustomization reconciliation continues normally.

Rollback:

1. Revert Flux manifest version bump in Git.
2. Reconcile source and flux-system Kustomization.
3. Confirm controller recovery.

## GITOPS-006 Branch-Based Live Validation Workflow

<a id="runbook-gitops-006"></a>
Runbook ID: `GITOPS-006`
Owner: Platform
Severity: `Maintenance`

Objective: Validate feature branch changes in live Flux-managed environments with controlled revert.

Procedure:

1. Create and push feature branch.
2. Point Flux instance sync ref to branch in Git.
3. Patch in-cluster `GitRepository` to branch.
4. Reconcile source and root Kustomization.

```bash
GR_NAME="$(kubectl -n flux-system get gitrepository -o jsonpath='{range .items[?(@.spec.url=="https://github.com/marmila/picluster")]}{.metadata.name}{"\n"}{end}' | head -n1)"
kubectl -n flux-system patch gitrepository "${GR_NAME}" --type merge -p '{"spec":{"ref":{"branch":"<feature-branch>"}}}'
flux reconcile source git "${GR_NAME}" -n flux-system
flux reconcile kustomization flux-system -n flux-system --with-source
```

5. Execute validation checklist for changed components.
6. After merge, restore branch refs to `master` and reconcile again.

Verify:

- Cluster is reconciling against intended branch.
- Expected changes are applied and healthy.

Rollback:

1. Patch `GitRepository` ref back to `master`.
2. Reconcile source and root Kustomization.

## GITOPS-007 Terraform (tofu-controller) Not Ready: State Lock or Plan Error

<a id="runbook-gitops-007"></a>
Runbook ID: `GITOPS-007`
Owner: Platform
Severity: `SEV-3`

Objective: Get a tofu-controller `Terraform` resource back to `Ready=True`. There are two, in `flux-system`:

| Resource | Module | Needs | Flux Kustomization that waits for it |
| --- | --- | --- | --- |
| `config-elastic` | `terraform/elastic` | Vault, Elasticsearch (`efk-es-http:9200`), Kibana (`efk-kb-http:5601`) | `elastic-stack-config` |
| `config-keycloak` | `terraform/keycloak` | Vault, Keycloak (`keycloak-service.keycloak.svc:8080`) | `keycloak-config` |

Alerts: `TerraformStateLocked`, `TerraformNotReady`. The Kustomization in the table goes not ready too, so
`FluxKustomizationNotReady` usually fires as well: fix the Terraform resource, the Kustomization follows.

Two different problems show the same status, `error running Plan: ... exit status 1...`:

- **Stuck state lock.** State is a Secret, the lock is the Lease `lock-tfstate-default-<resource>` in
  `flux-system`. If the `tf-runner` pod dies during a plan (node reboot, eviction, OOM), the lock stays and every
  later run fails on it. Seen 2026-10-31, 2026-11-01 to 11-05 (6577 failed runs), 2026-11-12.
- **Something the module talks to is down.** Elasticsearch, Kibana, Keycloak or Vault. Nothing is wrong with
  Terraform; fix the dependency. Seen 2026-11-12: Elasticsearch volume could not attach (`LONGHORN-002`).

`kubectl get terraform` (and `-w`) cuts the message off, so it cannot tell them apart. Step 2 prints the
full error.

Preconditions:

- `kubectl` on node2.
- Before a force-unlock: no `tf-runner` pod for this resource is running a plan or apply (step 2 lists them).
  Unlocking a live run can corrupt the state.

Procedure:

1. Pick the resource. This is the only line to edit; everything below is copy-paste.

```bash
TF=config-elastic          # or: TF=config-keycloak
```

2. Read the status and the full error:

```bash
echo "=== conditions ==="
kubectl -n flux-system get terraform $TF -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}{"lock pending: "}{.status.lock.pending}{"\nfailures: "}{.status.reconciliationFailures}{"\nforce-unlock patch: "}{.spec.tfstate}{"\n"}'
echo "=== distinct errors (count, first line of each) ==="
kubectl -n flux-system get terraform $TF -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' | grep -A1 "^Error" | grep -v "^--" | sed -E 's/[0-9a-f-]{36}/<id>/g' | sort | uniq -c | sort -rn | head -15
echo "=== runner pods ==="
kubectl -n flux-system get pods | grep tf-runner || echo "none running"
```

3. Match what step 2 shows:

| Step 2 shows | Meaning | Do |
| --- | --- | --- |
| `StateLocked=True`, or `Error acquiring the state lock` | Stuck lock | Step 4 |
| `dial tcp ...:9200` timeout or refused, `efk-es-http` | Elasticsearch down | `ELASTIC-001`, then step 6. Do not touch Terraform |
| `dial tcp ...:5601`, `efk-kb-http` | Kibana down | `ELASTIC-001` (Kibana), then step 6 |
| `keycloak-service` or `:8080` errors | Keycloak down | `kubectl -n keycloak get pods`; database: `KEYCLOAK-008`. Then step 6 |
| `permission denied`, `403`, `vault` | Vault sealed, or login or policy broken | `VAULT-001`, `VAULT-006`, then step 6 |
| `Failed to query available provider packages`, `Unsupported argument`, `Inconsistent dependency lock file` | A recent commit to `terraform/` broke the module or a provider | `GITOPS-010` (revert), then step 6 |
| `Ready=Unknown` "Reconciliation in progress", no errors | Not stuck: waiting for its 30-minute interval | Step 6 |
| `force-unlock patch:` not empty, no lock | A patch from an earlier unlock was left behind | Remove it: last command of step 4 |

4. Stuck lock: save the lock details, force-unlock, wait, remove the patch. One paste:

```bash
LOCK_ID=$(kubectl -n flux-system get terraform $TF -o jsonpath='{.status.lock.pending}')
[ -n "$LOCK_ID" ] || LOCK_ID=$(kubectl -n flux-system get terraform $TF -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' | grep -oE 'ID: +[0-9a-f-]{36}' | head -1 | awk '{print $2}')
if [ -z "$LOCK_ID" ]; then echo "NO LOCK ID FOUND: not a lock problem, go back to step 3"; else
  echo "lock: $LOCK_ID"
  echo "=== lock info: who took it and when (keep it for step 7) ==="
  kubectl -n flux-system get lease lock-tfstate-default-$TF -o jsonpath='{.metadata.annotations.app\.terraform\.io/lock-info}{"\n"}'
  kubectl -n flux-system patch terraform $TF --type merge -p "{\"spec\":{\"tfstate\":{\"forceUnlock\":\"yes\",\"lockIdentifier\":\"${LOCK_ID}\"}}}"
  echo "waiting 2 minutes for the unlock run..."; sleep 120
  kubectl -n flux-system get terraform $TF -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
fi
kubectl -n flux-system patch terraform $TF --type json -p '[{"op":"remove","path":"/spec/tfstate"}]'
```

   - Both fields are needed: `forceUnlock` without `lockIdentifier` silently does nothing.
   - The last command removes the patch so force-unlock does not stay armed. Flux does not remove it by
     itself. If it says `the server rejected our request ... /spec/tfstate`, there was nothing to remove.
   - No `StateLocked=True` any more: continue with step 6. If `Ready=False` now shows another error, go back
     to step 2: the lock may have hidden it.
   - Still locked: step 5.

5. Fallback, only if step 4 did not release the lock: delete the Lease, then step 6.

```bash
kubectl -n flux-system delete lease lock-tfstate-default-$TF
```

6. Run it again and wait for the result (instead of `get terraform -w`):

```bash
kubectl -n flux-system annotate terraform $TF reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
kubectl -n flux-system wait terraform $TF --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True --timeout=5m && echo "FIXED" || echo "STILL FAILING: run step 2 again"
case $TF in config-elastic) KS=elastic-stack-config;; config-keycloak) KS=keycloak-config;; esac
kubectl -n flux-system annotate kustomization $KS reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
kubectl -n flux-system get kustomization $KS
```

   The Kustomization can show `dependency ... is not ready` for a while after the Terraform resource is fixed,
   when the app it depends on (`elastic-stack-app`, `keycloak-app`) is still recovering. It follows on its
   own.

7. After a lock: find why the runner died, around the time in the lock info from step 4. Node reboots or
   `NotReady`, evictions, OOM:

```bash
kubectl get events -A --sort-by=.lastTimestamp | grep -iE "tf-runner|evict|oom|NodeNotReady" | tail -20
kubectl get nodes
```

   Events are kept for about an hour. For older locks, check the node uptime (`uptime` on the node) and
   `postmortems/` for an outage at that time.

Verify:

- `kubectl -n flux-system get terraform` shows `READY True` for both resources.
- Step 2 shows `failures: 0` and an empty `force-unlock patch:`.
- `TerraformStateLocked`, `TerraformNotReady` and the related `FluxKustomizationNotReady` resolve.

Rollback:

1. If a run fails after the unlock, suspend the resource while you fix the cause, then resume:

```bash
kubectl -n flux-system patch terraform $TF --type merge -p '{"spec":{"suspend":true}}'
# fix the cause
kubectl -n flux-system patch terraform $TF --type merge -p '{"spec":{"suspend":false}}'
```

   No alert fires for a suspended Terraform resource, so do not forget to resume it.
2. If the state looks damaged, keep it suspended and restore the state Secret `tfstate-default-$TF` in
   `flux-system` from a Velero backup.

References:

- [tofu-controller: force unlock Terraform states](https://flux-iac.github.io/tofu-controller/use-tf-controller/force-unlock-terraform-states/)
- `kubernetes/platform/elastic-stack/config/base/terraform.yaml`, `kubernetes/platform/keycloak/config/base/terraform.yaml`
- `kubernetes/platform/kube-prometheus-stack/app/components/flux-monitoring/tofu-alert-rules.yaml`
- `postmortems/incident-2026-11-05-node6-undervoltage.md` (lock), `postmortems/incident-2026-11-12-longhorn-instance-manager-outofcpu.md` (Elasticsearch down)

## GITOPS-008 FluxInstance Not Ready (Flux Cannot Be Upgraded)

<a id="runbook-gitops-008"></a>
Runbook ID: `GITOPS-008`
Owner: Platform
Severity: `SEV-2`

Objective: Get the FluxInstance back to Ready when the Flux operator cannot apply the Flux version in Git.
Alert: `FluxInstanceNotReady`.

What it means: the running Flux controllers keep working on their current version, but the operator cannot
install the version in Git, so Flux cannot be upgraded or repaired. Most common cause: the Flux
**distribution** version (`fluxcd/flux2`, Renovate group "Flux distribution") is newer than what the
installed **flux-operator** knows. Example 2026-11-09: Flux 2.10.0 merged with flux-operator 0.60.0
(`BuildFailed: no match found for semver: 2.10.0`); 2.10 needs flux-operator 0.62.0 or later.

Preconditions:

- `kubectl` on node2.

Procedure:

1. Read the reason.

```bash
kubectl -n flux-system get fluxinstance flux -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
kubectl -n flux-system get fluxinstance flux -o jsonpath='{.spec.distribution.version}{" wanted, running "}{.status.lastAppliedRevision}{"\n"}'
kubectl -n flux-system get deploy flux-operator -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

2. `BuildFailed` / `no match found for semver`: the operator is too old for the wanted version. Check the
   [flux-operator releases](https://github.com/controlplaneio-fluxcd/flux-operator/releases) for the first
   version that mentions the Flux version, then pick one:
   - **Set the distribution back** to the running version in
     `kubernetes/platform/flux-operator/instance/base/values.yaml` (`instance.distribution.version`) and in
     `ansible/vars/picluster.yml` (`fluxcd_version`), push to `master`. Then upgrade the operator (Renovate
     group "Flux", `controlplaneio-fluxcd` charts) first, and the distribution after it, on separate days.
   - Or upgrade the operator now, if its PR is already at a version that supports the distribution.
3. Other reasons: the message usually names the failing component; check the operator log.

```bash
kubectl -n flux-system logs deploy/flux-operator --since=2h | grep -iE "error|fail" | tail -20
```

4. Speed up reconciliation after pushing the fix (no flux CLI on node2):

```bash
NOW=$(date +%s)
kubectl -n flux-system annotate gitrepository flux-system reconcile.fluxcd.io/requestedAt="$NOW" --overwrite
kubectl -n flux-system annotate kustomization flux-operator-instance reconcile.fluxcd.io/requestedAt="$NOW" --overwrite
kubectl -n flux-system annotate helmrelease flux-instance reconcile.fluxcd.io/requestedAt="$NOW" --overwrite
```

Verify:

- `kubectl -n flux-system get fluxinstance flux` shows `Ready=True`; the `Stalled` condition is gone.
- `kubectl -n flux-system get pods`: all controllers Running.
- The alert resolves on ntfy.

Rollback:

1. Reverting the version change in Git is the rollback; the running controllers were never changed.

References:

- `kubernetes/platform/flux-operator/` (operator and instance)
- `homelab-docs/update-automation.md` (Flux stays a manual update)

## GITOPS-009 HelmRelease Upgrade Rolled Back

<a id="runbook-gitops-009"></a>
Runbook ID: `GITOPS-009`
Owner: Platform
Severity: `SEV-3`

Objective: Decide what to do after Flux rolled a failed Helm upgrade back by itself.
Alert: `FluxHelmReleaseRolledBack`.

What it means: a new chart version (or new values) failed to install or upgrade, and Flux's
`upgrade.remediation` restored the previous release. The cluster runs the **old** version and is usually
fine. Git still asks for the new version, so Flux retries and may roll back again.

Preconditions:

- `kubectl` on node2, `gh` or the GitHub UI.

Procedure:

1. Find out what failed.

```bash
NS=<namespace>; HR=<name>
kubectl -n $NS get helmrelease $HR -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
kubectl -n $NS get helmrelease $HR -o jsonpath='{range .status.history[*]}{.chartVersion} {.status} {.firstDeployed}{"\n"}{end}'
kubectl -n $NS get events --sort-by=.lastTimestamp | tail -20
```

2. Find the commit that changed it (usually a Renovate PR, possibly automerged):

```bash
git log --oneline -5 -- kubernetes/platform/<component>/
```

3. Decide:
   - **Bad release, or values incompatible with the new chart:** revert the commit (`GITOPS-010`).
     Closing the Renovate PR makes Renovate skip that version.
   - **Transient** (image pull timeout, node pressure during the upgrade): reset the retries and let Flux
     try again.

```bash
NOW=$(date +%s)
kubectl -n $NS annotate helmrelease $HR reconcile.fluxcd.io/requestedAt="$NOW" reconcile.fluxcd.io/resetAt="$NOW" --overwrite
```

Verify:

- `kubectl -n $NS get helmrelease $HR` is Ready=True on the intended chart version (reverted or new).
- Pods of the release are Running; the alert resolves.

Rollback:

1. Nothing to roll back: Flux already restored the previous release.

References:

- `GITOPS-003` (HelmRelease Not-Ready triage), `GITOPS-010` (revert an automerged update)

## GITOPS-010 Revert an Automerged (or Merged) Update

<a id="runbook-gitops-010"></a>
Runbook ID: `GITOPS-010`
Owner: Platform
Severity: `SEV-2` or `SEV-3`

Objective: Undo a dependency update that was merged (by Renovate automerge or by hand) and broke something.

Preconditions:

- A local clone of the repo with push access to `master` (the owner can push past branch protection).

Procedure:

1. Stop more automerges while you work (optional, during a larger incident): add
   `{ matchPackageNames: ["*"], automerge: false }` at the end of `packageRules` in `.github/renovate.json5`
   and push (see `homelab-docs/update-automation.md`).
2. Find the merge commit. Renovate PRs are titled `chore(deps): update ...` or `fix(deps): update ...`.

```bash
git pull
git log --oneline --since="2 days ago" --first-parent master
```

3. Revert it and push.

```bash
git revert --no-edit <sha>          # squash or rebase merge
git revert --no-edit -m 1 <sha>     # merge commit
git push origin master
```

4. Reconcile faster (node2, no flux CLI):

```bash
NOW=$(date +%s)
kubectl -n flux-system annotate gitrepository flux-system reconcile.fluxcd.io/requestedAt="$NOW" --overwrite
kubectl -n flux-system annotate kustomization --all reconcile.fluxcd.io/requestedAt="$NOW" --overwrite
```

5. If Renovate opens the PR again, close it so Renovate skips that version. To block the package for good,
   add it to the blocked list in `.github/renovate/automerge.json5` (both places).

Verify:

- The alert that started this resolves; the health check in `homelab-docs/cluster-maintenance.md`
  section 4.3 is clean.

Rollback:

1. Revert the revert (`git revert <revert-sha>`) once the cause is understood.

Caveats:

- **No downgrade for k3s, Longhorn, database major versions**: reverting Git does not undo them. These are
  manual updates for that reason; fix forward.
- CRD changes are not removed by a revert.

References:

- `homelab-docs/update-automation.md`, `homelab-docs/cluster-maintenance.md` section 9

## GITOPS-011 Renovate Automerge Stuck

<a id="runbook-gitops-011"></a>
Runbook ID: `GITOPS-011`
Owner: Platform
Severity: `Maintenance`

Objective: Unblock a Renovate PR that should have merged by itself.
Notification: "Renovate: N automerge PR(s) stuck" on ntfy, from the `Renovate watch` workflow (weekdays after
18:00 Rome).

Procedure:

1. Open the PR from the notification. Two cases:
   - **A check failed** (most often `Validate prod manifests`). Open the failed check and use the table
     "Reading a failure" in `homelab-docs/update-automation.md`. Fix it in the PR branch, or close the PR if
     the release is bad (Renovate then skips that version).
   - **Open for more than 7 days** with green checks. Look at the `renovate/stability-days` check and the
     PR body:
     - `renovate/stability-days` pending: the release is younger than the required age, or the registry
       publishes no release date (the critical components require one). Wait, or merge by hand.
     - Outside its merge day: Vault merges on Tuesday, CloudNativePG Wednesday, Istio Thursday, the weekly
       bundle Monday, all 10:00-18:00 Rome. Wait for the next window or merge by hand.
     - Merge conflict: tick the rebase box in the PR body.
2. To make Renovate run now: tick "Check this box to trigger a request for Renovate to run again" at the
   bottom of the Dependency Dashboard (issue #238).

Verify:

- The PR is merged or closed; the next `Renovate watch` run sends nothing.

References:

- `.github/workflows/renovate-watch.yml`, `.github/renovate/automerge.json5`

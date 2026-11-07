# Incident: elastic-stack-config Terraform State Loss

**Date:** 2026-03-30 / 2026-03-31
**Status:** Resolved
**Affected component:** `flux-system/elastic-stack-config` Kustomization → `flux-system/config-elastic` Terraform

---

## Symptom

The `elastic-stack-config` Flux Kustomization was stuck in a perpetual health-check failure loop with 651+ reconciliation failures:

```
flux-system   elastic-stack-config   False   health check failed after 20s:
  failed early due to stalled resources:
  [Terraform/flux-system/config-elastic status: 'Failed']
```

The underlying Terraform Apply error was:

```
error running Apply: rpc error: code = Internal desc = exit status 1
Error: Unexpected status code from server: got HTTP 400
  with elasticstack_kibana_data_view.data_views["app-logs"],
  on dataviews.tf line 22, in resource "elasticstack_kibana_data_view" "data_views"

{"statusCode":400,"error":"Bad Request","message":"Duplicate data view: app-logs"}
```

---

## Root Cause

The `config-elastic` Terraform resource (managed by tofu-controller) has **no remote backend configured** — state is stored in a Kubernetes Secret in `flux-system`. This Secret was lost at some point (likely due to a tf-controller reinstall or cluster disruption).

When tofu-controller resumed reconciliation with an empty state, Terraform believed all resources were new and attempted to create them. The `app-logs` Kibana data view already existed (backed by a persistent volume), so Kibana returned HTTP 400 Duplicate and Terraform went into a permanent failed loop.

The key files involved:
- `terraform/elastic/backend.tf` — no backend configured (state in K8s Secret)
- `terraform/elastic/dataviews.tf` — creates Kibana data views via `elasticstack_kibana_data_view`
- `terraform/elastic/resources/dataviews/app-logs.json` — the conflicting data view definition
- `kubernetes/platform/elastic-stack/config/base/terraform.yaml` — tofu-controller Terraform resource

---

## Fix Applied (Short Term)

Deleted the duplicate `app-logs` data view from Kibana directly via its API, allowing Terraform to recreate it cleanly on the next reconciliation.

```bash
# Get elastic superuser password from the ECK-managed secret
PASS=$(kubectl get secret -n elastic efk-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)

# Get the internal ID of the conflicting data view
DV_ID=$(kubectl exec -n elastic deployment/efk-kb -c kibana -- \
  curl -s -u "elastic:$PASS" http://localhost:5601/api/data_views \
  | jq -r '.data_view[] | select(.name == "app-logs") | .id')

# Delete it (kbn-xsrf header required by Kibana for mutating requests)
kubectl exec -n elastic deployment/efk-kb -c kibana -- \
  curl -s -X DELETE \
  -u "elastic:$PASS" \
  -H "kbn-xsrf: true" \
  "http://localhost:5601/api/data_views/data_view/$DV_ID"
```

Then forced an immediate Terraform reconciliation (since the resource was stuck in `Failed` state and wouldn't self-recover):

```bash
kubectl annotate terraform -n flux-system config-elastic \
  reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
```

**Result:** Terraform successfully applied, `elastic-stack-config` went `True`.

---

## Long-Term Solution: Remote S3 Backend via MinIO

### Why this will happen again

Any event that wipes the `tfstate-default-config-elastic` Secret in `flux-system` (cluster rebuild, tf-controller reinstall, namespace wipe) while Elasticsearch/Kibana PVs are preserved will reproduce this exact failure for **all** Terraform-managed resources — not just `app-logs`.

### Solution

Configure a persistent S3 remote backend for `terraform/elastic` (and all other Terraform modules) using the MinIO instance already deployed in the cluster (`minio.picluster.marmilan.com:9000`). State stored in MinIO survives cluster rebuilds as long as MinIO's Longhorn-backed PVs are retained.

### Changes required

#### 1. MinIO: new bucket, policy, user

Add these files to `terraform/minio/resources/`:

**`buckets/terraform-state.json`**
```json
{
  "name": "k3s-terraform-state",
  "versioning": true,
  "object_lock": false,
  "description": "Terraform remote state storage"
}
```

**`policies/terraform-state.json`**
```json
{
  "name": "terraform-state",
  "description": "Terraform state S3 access policy",
  "statements": [
    {
      "effect": "Allow",
      "actions": [
        "s3:DeleteObject",
        "s3:GetObject",
        "s3:ListBucket",
        "s3:PutObject",
        "s3:GetBucketVersioning",
        "s3:GetBucketLocation"
      ],
      "resources": [
        "arn:aws:s3:::k3s-terraform-state",
        "arn:aws:s3:::k3s-terraform-state/*"
      ]
    }
  ]
}
```

**`users/terraform-state.json`**
```json
{
  "access_key": "terraform-state",
  "policies": ["terraform-state"],
  "description": "Terraform remote state S3 user"
}
```

Store the user password in Vault (one-time manual step during bootstrap):
```bash
vault kv put secret/minio/terraform-state key=<strong-password>
```

#### 2. ExternalSecret — expose MinIO credentials in `flux-system`

Add `kubernetes/platform/elastic-stack/config/base/minio-backend-external-secret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: minio-terraform-state-secret
spec:
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: minio-terraform-state-secret
  data:
  - secretKey: secret_key
    remoteRef:
      key: minio/terraform-state
      property: key
```

Add it to `kubernetes/platform/elastic-stack/config/base/kustomization.yaml`:
```yaml
resources:
  - terraform.yaml
  - minio-backend-external-secret.yaml
```

#### 3. Configure S3 backend in `terraform/elastic/backend.tf`

```hcl
terraform {
  required_version = ">= 1.0.0"

  backend "s3" {
    bucket                      = "k3s-terraform-state"
    key                         = "elastic/terraform.tfstate"
    region                      = "eu-west-1"
    endpoint                    = "https://minio.picluster.marmilan.com:9000"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    use_path_style              = true
  }
}
```

#### 4. Inject credentials into the tofu-controller runner pod

Update `kubernetes/platform/elastic-stack/config/base/terraform.yaml` — add `runnerPodTemplate`:

```yaml
  runnerPodTemplate:
    spec:
      env:
      - name: AWS_ACCESS_KEY_ID
        value: "terraform-state"
      - name: AWS_SECRET_ACCESS_KEY
        valueFrom:
          secretKeyRef:
            name: minio-terraform-state-secret
            key: secret_key
```

#### 5. Add `minio-app` dependency to `elastic-stack-config`

In `kubernetes/clusters/prod/infra/elastic-stack-app.yaml`, update the `elastic-stack-config` Kustomization:

```yaml
  dependsOn:
    - name: elastic-stack-app
    - name: external-secrets-config
    - name: minio-app       # <-- add this
```

### Migration note (for existing clusters)

Switching to a remote backend requires state migration. On an already-running cluster:

1. Apply the code changes above.
2. Delete the old K8s state Secret to avoid a migration conflict:
   ```bash
   kubectl delete secret -n flux-system tfstate-default-config-elastic
   ```
3. Force reconciliation — Terraform will initialize with the empty S3 backend and re-apply all resources from scratch. Since tofu-controller uses `approvePlan: auto`, this is safe as long as the resources don't already exist (they won't, since Terraform just created them).

On a **fresh cluster rebuild**, no migration is needed — both the S3 state and Kibana will start empty.

### Applies to other modules too

The same pattern should be applied to `terraform/keycloak` (backend key: `keycloak/terraform.tfstate`) to prevent the same class of failure there.

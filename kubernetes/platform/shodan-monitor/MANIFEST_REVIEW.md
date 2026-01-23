# Kubernetes Manifest Review - ApexForge

## Summary

This document reviews all Kubernetes manifests under `k8s/shodan-monitor` to verify they declare all required resources, secrets, and dependencies to run the application.

**Review Date**: 2026-01-23

---

## 🔧 Changes Applied

The following changes were made to fix identified issues:

### 1. Fixed Missing Profiles ConfigMap (CRITICAL)

**Files Modified:**
- `k8s/shodan-monitor/app/base/kustomization.yaml`
  - **Added**: ConfigMapGenerator for `shodan-profiles` ConfigMap
  - **Change**: Added new configMapGenerator entry that creates ConfigMap from `profiles.yaml` file

**Files Created:**
- `k8s/shodan-monitor/app/base/profiles.yaml`
  - **Created**: Default profiles.yaml file with all 47 intelligence profiles
  - **Purpose**: Provides default threat intelligence profiles for base deployment
  - **Content**: Complete set of profiles covering databases, remote access, malware, web apps, cloud services, ICS, etc.

**Files Created (Documentation):**
- `k8s/shodan-monitor/MANIFEST_REVIEW.md`
  - **Created**: Comprehensive review document listing all resources, issues, and recommendations

**Impact:**
- ✅ Base deployment can now run independently without requiring prod overlay
- ✅ Default profiles are available for immediate use
- ✅ Production overlay can still override with custom profiles if needed

**Before:**
```yaml
# kustomization.yaml - Missing shodan-profiles ConfigMapGenerator
configMapGenerator:
  - name: shodan-config
    literals:
      - INTERVAL_SECONDS=3600
      - LOG_LEVEL=INFO
```

**After:**
```yaml
# kustomization.yaml - Now includes shodan-profiles
configMapGenerator:
  - name: shodan-config
    literals:
      - INTERVAL_SECONDS=3600
      - LOG_LEVEL=INFO

  - name: shodan-profiles
    behavior: create
    files:
      - profiles.yaml
```

---

## ✅ Declared Resources

### Core Application Resources
- ✅ **Namespace**: `shodan-monitor` (declared in both app/base and db/base)
- ✅ **Deployment**: `apexforge-collector` (app/base/deployment.yaml)
- ✅ **Service**: `apexforge-collector` (app/base/apexforge-collector-service.yaml)
- ✅ **Ingress**: `apexforge-ingress` (app/base/ingress.yaml)
- ✅ **ServiceMonitor**: `apexforge-metrics` (app/base/service-monitor.yaml)

### Database Resources
- ✅ **PostgreSQL Deployment**: `shodan-postgres` (db/base/postgres.yaml)
- ✅ **PostgreSQL Service**: `shodan-postgres` (db/base/postgres.yaml)
- ✅ **PostgreSQL PVC**: `shodan-postgres-pvc` (db/base/postgres.yaml)
- ✅ **MongoDB Community Resource**: `shodan-mongo` (db/base/mongodb.yaml)
  - Note: MongoDB Community Operator automatically creates a service named `shodan-mongo-svc`

### Secrets (External Secrets)
- ✅ **Shodan API Key**: `shodan-secret` (app/base/external-secret.yaml)
- ✅ **VirusTotal API Key**: `virustotal-secret` (app/base/external-secret-virustotal.yaml)
- ✅ **PostgreSQL Credentials**: `shodan-db-credentials` (db/base/external-secret.yaml)
- ✅ **MongoDB Credentials**: `shodan-mongo-credentials` (db/base/external-secret.yaml)

### ConfigMaps
- ✅ **Application Config**: `shodan-config` (app/base/kustomization.yaml)
  - Contains: `INTERVAL_SECONDS`, `LOG_LEVEL`
- ✅ **Profiles ConfigMap**: `shodan-profiles` (app/base/kustomization.yaml) ✅ **FIXED**
  - Contains: `profiles.yaml` file
  - **Note**: Now declared in base (was only in prod overlay before)

### Jobs & CronJobs
- ✅ **DB Init Job**: `apexforge-db-init` (db/base/db-init-job.yaml)
- ✅ **Maintenance CronJob**: (db/base/maintenance-cronjob.yaml)
- ✅ **Mongo Sync CronJob**: `shodan-mongo-sync` (db/base/mongo-sync-cronjob.yaml)
- ✅ **PostgreSQL Backup CronJob**: (db/base/postgres-backup-cronjob.yaml)
- ✅ **MongoDB Backup CronJob**: (db/base/mongo-backup-cronjob.yaml)

---

## ⚠️ Issues Found

### 1. **Missing ConfigMap in Base Kustomization** (CRITICAL) ✅ FIXED

**Issue**: The `shodan-profiles` ConfigMap is only created in the `app/overlays/prod/kustomization.yaml`, but the deployment in `app/base/deployment.yaml` references it:

```yaml
volumes:
  - name: profiles-volume
    configMap:
      name: shodan-profiles
```

**Impact**: The base deployment will fail to start if deployed without the prod overlay, as the ConfigMap won't exist.

**Status**: ✅ **FIXED** - Added `shodan-profiles` ConfigMapGenerator to `app/base/kustomization.yaml` and created default `profiles.yaml` file in base directory.

**Location**: 
- `app/base/deployment.yaml` (line 115)
- `app/base/kustomization.yaml` (✅ now includes ConfigMapGenerator)
- `app/base/profiles.yaml` (✅ created default file)
- `app/overlays/prod/kustomization.yaml` (line 21-24) - can override with custom profiles

---

### 2. **Missing Targets ConfigMap** (OPTIONAL but RECOMMENDED)

**Issue**: The application supports a `targets.yaml` file for the "My Assets" monitoring feature, but there's no ConfigMap declared for it.

**Impact**: Users cannot use the "My Assets" feature without manually creating the ConfigMap.

**Recommendation**: Add a ConfigMapGenerator in the base or overlay kustomization:

```yaml
configMapGenerator:
  - name: shodan-targets
    behavior: create
    files:
      - targets.yaml
```

And mount it in the deployment:

```yaml
volumeMounts:
  - name: targets-volume
    mountPath: /app/targets.yaml
    subPath: targets.yaml
volumes:
  - name: targets-volume
    configMap:
      name: shodan-targets
      optional: true  # Make it optional so app can run without it
```

**Location**: 
- `app/base/targets.yaml.example` exists but no ConfigMap
- `apex_forge/config.py` (line 102, 194-215) - app loads targets.yaml

---

### 3. **Missing AI External Secrets** (OPTIONAL)

**Issue**: The application supports AI features (OpenAI, Anthropic, Ollama) as documented in `config.example.env` and `VAULT_KEYS_REFERENCE.md`, but there are no ExternalSecret resources for these API keys.

**Impact**: Users cannot use AI features without manually creating ExternalSecrets or setting environment variables.

**Recommendation**: Create ExternalSecret resources for AI providers:

- `app/base/external-secret-openai.yaml`
- `app/base/external-secret-anthropic.yaml`

And optionally add environment variables to the deployment (or use envFrom with secrets).

**Location**:
- `apex_forge/config.py` (lines 81-91, 140-158) - AI config support
- `config.example.env` (lines 18-37) - AI configuration examples
- `VAULT_KEYS_REFERENCE.md` (lines 88-137) - Vault paths documented

---

### 4. **Ingress Domain Variable** (MINOR)

**Issue**: The ingress uses `${CLUSTER_DOMAIN}` variable which needs to be replaced:

```yaml
cert-manager.io/common-name: apexforge.${CLUSTER_DOMAIN}
hosts:
  - apexforge.${CLUSTER_DOMAIN}
```

**Impact**: The ingress won't work until the variable is replaced with an actual domain.

**Recommendation**: 
- Use kustomize replacements/patches in overlays
- Or document that users must replace `${CLUSTER_DOMAIN}` before applying

**Location**: `app/base/ingress.yaml` (lines 10, 17, 20)

---

### 5. **MongoDB Service Name Verification** (VERIFY)

**Issue**: The deployment references `shodan-mongo-svc.shodan-monitor.svc.cluster.local`, but the MongoDB resource doesn't explicitly declare a Service.

**Status**: The MongoDB Community Operator should automatically create a service. The service name convention is typically `<resource-name>-svc` or `<resource-name>`, so `shodan-mongo-svc` should be correct.

**Recommendation**: Verify that the MongoDB Community Operator creates a service named `shodan-mongo-svc`. If not, either:
- Add an explicit Service resource
- Update the deployment to use the correct service name

**Location**: 
- `app/base/deployment.yaml` (line 64)
- `db/base/mongodb.yaml` (no explicit Service)

---

## 📋 Required External Dependencies

These are not declared in the manifests but are required for the application to function:

1. **External Secrets Operator**: Required to sync secrets from Vault
   - ClusterSecretStore: `vault-backend` (referenced in all ExternalSecret resources)

2. **MongoDB Community Operator**: Required for MongoDB deployment
   - CRD: `MongoDBCommunity` (mongodbcommunity.mongodb.com/v1)

3. **cert-manager**: Required for TLS certificates in Ingress
   - ClusterIssuer: `letsencrypt-issuer` (referenced in ingress.yaml)

4. **Prometheus Operator**: Required for ServiceMonitor
   - CRD: `ServiceMonitor` (monitoring.coreos.com/v1)

5. **NGINX Ingress Controller**: Required for Ingress
   - IngressClass: `nginx` (referenced in ingress.yaml)

6. **HashiCorp Vault**: Required for secret storage
   - Vault backend with secrets at documented paths (see VAULT_KEYS_REFERENCE.md)

---

## ✅ Environment Variables Summary

### Required Environment Variables (All Declared)
- ✅ `SHODAN_API_KEY` - From `shodan-secret`
- ✅ `VIRUSTOTAL_API_KEY` - From `virustotal-secret` (optional but declared)
- ✅ `MONGO_PASS` - From `shodan-mongo-credentials`
- ✅ `MONGO_URL` - Constructed from MONGO_PASS
- ✅ `DB_HOST` - Hardcoded
- ✅ `DB_NAME` - Hardcoded
- ✅ `DB_USER` - From `shodan-db-credentials`
- ✅ `DB_PASS` - From `shodan-db-credentials`
- ✅ `INTERVAL_SECONDS` - From `shodan-config` ConfigMap
- ✅ `LOG_LEVEL` - From `shodan-config` ConfigMap
- ✅ `PYTHONPATH` - Hardcoded

### Missing Environment Variables (Optional Features)
- ❌ `AI_PROVIDER` - Not declared (optional)
- ❌ `OPENAI_API_KEY` - Not declared (optional)
- ❌ `OPENAI_MODEL` - Not declared (optional)
- ❌ `ANTHROPIC_API_KEY` - Not declared (optional)
- ❌ `ANTHROPIC_MODEL` - Not declared (optional)
- ❌ `OLLAMA_BASE_URL` - Not declared (optional)
- ❌ `OLLAMA_MODEL` - Not declared (optional)
- ❌ `TARGETS_PATH` - Not declared (defaults to `/app/targets.yaml`)

---

## 📝 Recommendations Priority

### High Priority (Blocks Deployment)
1. **Fix missing `shodan-profiles` ConfigMap in base** - Deployment will fail without it

### Medium Priority (Feature Gaps)
2. **Add targets.yaml ConfigMap** - Enables "My Assets" feature
3. **Add AI ExternalSecrets** - Enables AI features
4. **Document/verify MongoDB service name** - Ensure connectivity

### Low Priority (Documentation/Polish)
5. **Fix ingress domain variable** - Document replacement process
6. **Add optional AI environment variables** - For users who want AI features

---

## ✅ Conclusion

**Overall Status**: The manifests are **mostly complete** with one critical issue fixed:

- ✅ **Core functionality**: All required secrets and resources for basic operation are declared
- ✅ **Profiles ConfigMap**: ✅ FIXED - Now declared in base kustomization with default profiles.yaml
- ⚠️ **Optional features**: Missing ConfigMaps/Secrets for "My Assets" and AI features (optional)
- ✅ **Database resources**: Properly declared with all required secrets
- ✅ **Monitoring**: ServiceMonitor properly configured

**Action Items**:
1. ✅ ~~Add `shodan-profiles` ConfigMap to base kustomization~~ **COMPLETED**
2. Consider adding `shodan-targets` ConfigMap for "My Assets" feature (optional)
3. Consider adding AI ExternalSecrets for users who want AI features (optional)
4. Document external dependencies (operators, Vault, etc.)

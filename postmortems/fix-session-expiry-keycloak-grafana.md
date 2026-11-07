# Fix: Session Expiry — Kiali and Grafana

## Summary

Users were being logged out of Kiali and Grafana very frequently (within minutes) despite active use. The issue affected both apps through different mechanisms but shared the same root cause: Keycloak's default 5-minute access token lifetime was never overridden in the cluster configuration, and Grafana was not configured to refresh tokens before expiry.

---

## Root Cause Analysis

### Root Cause 1 — Keycloak realm using all defaults

`terraform/keycloak/resources/realm/realm.json` only defined `realm` and `enabled`. Keycloak's defaults kicked in for all token and session lifetimes:

| Setting | Default | Impact |
|---|---|---|
| `accessTokenLifespan` | **5 minutes** | All access tokens and ID tokens expire in 5 min |
| `ssoSessionIdleTimeout` | **30 minutes** | SSO session ends after 30 min of inactivity |
| `ssoSessionMaxLifespan` | 10 hours | OK |

**Effect on Kiali**: Kiali's `openid` strategy stores the Keycloak ID token in a session cookie and validates its `exp` claim on requests. After 5 minutes, the token was expired, causing Kiali to redirect to Keycloak. Even if the Keycloak SSO session was still alive, the redirect interrupted navigation and appeared as a logout.

**Effect on Grafana**: Grafana's `auth.generic_oauth` obtains a Keycloak access token at login. Without token refresh enabled, Grafana held the initial 5-minute token indefinitely. When Grafana made any back-channel call (userinfo, token validation), the expired token caused it to redirect to Keycloak login.

### Root Cause 2 — Grafana not configured to refresh tokens

`kubernetes/platform/grafana/instance/components/sso/grafana-patch.yaml` was missing `use_refresh_token: "true"`. Without this, Grafana never used its refresh token to obtain a new access token before expiry, regardless of how long the Keycloak session lasted.

---

## Changes Made

### 1. `terraform/keycloak/resources/realm/realm.json`

Added explicit session and token lifetime settings:

```diff
 {
   "enabled": true,
-  "realm": "picluster"
+  "realm": "picluster",
+  "sso_session_idle_timeout": "8h",
+  "sso_session_max_lifespan": "10h",
+  "access_token_lifespan": "1h"
 }
```

- `access_token_lifespan: "1h"` — directly fixes both Kiali and Grafana; tokens are now valid for 1 hour instead of 5 minutes
- `sso_session_idle_timeout: "8h"` — users can step away for up to 8 hours without needing to re-authenticate
- `sso_session_max_lifespan: "10h"` — maximum session duration per login (now explicit in code)

### 2. `terraform/keycloak/main.tf`

Mapped the three new JSON fields to the `keycloak_realm` Terraform resource:

```diff
 resource "keycloak_realm" "realm" {
   realm   = local.realm.realm
   enabled = try(local.realm.enabled, true)
+
+  sso_session_idle_timeout = try(local.realm.sso_session_idle_timeout, null)
+  sso_session_max_lifespan = try(local.realm.sso_session_max_lifespan, null)
+  access_token_lifespan    = try(local.realm.access_token_lifespan, null)
 }
```

### 3. `kubernetes/platform/grafana/instance/components/sso/grafana-patch.yaml`

Enabled token refresh in Grafana's OAuth config:

```diff
     signout_redirect_url: https://iam.${CLUSTER_DOMAIN}/...
+    use_refresh_token: "true"
+    token_rotation_interval_minutes: "5"
```

- `use_refresh_token: "true"` — Grafana will now use the refresh token to obtain a new access token before expiry (Grafana already requested `offline_access` in its scopes, so the refresh token was available but unused)
- `token_rotation_interval_minutes: "5"` — Grafana proactively refreshes 5 minutes before token expiry

---

## How to Apply

### Terraform changes (Keycloak realm settings)

The cluster uses **Flux TF Controller** (`infra.contrib.fluxcd.io/v1alpha2/Terraform`) with `approvePlan: auto` and a 30-minute reconciliation interval. After pushing to git, the TF Controller will automatically run `tofu plan` and `tofu apply` on the Keycloak realm.

**Push the changes:**
```bash
git add terraform/keycloak/resources/realm/realm.json \
        terraform/keycloak/main.tf \
        kubernetes/platform/grafana/instance/components/sso/grafana-patch.yaml

git commit -m "Increase Keycloak session/token lifetimes and enable Grafana token refresh"
git push
```

**To apply immediately without waiting for the 30-minute interval:**
```bash
# Force Flux to pull the latest git commit
flux reconcile source git flux-system

# Force the TF Controller to reconcile the Keycloak Terraform workspace
flux reconcile terraform config-keycloak -n flux-system
```

**To verify the TF Controller applied the changes:**
```bash
# Check the Terraform resource status
kubectl get terraform config-keycloak -n flux-system

# Watch the TF runner pod logs
kubectl logs -n flux-system -l app.kubernetes.io/name=tf-runner --follow
```

### Kubernetes changes (Grafana)

Flux Kustomization picks up the Grafana manifest changes from git automatically. The Grafana Operator will roll out a new Grafana pod with the updated OAuth config.

**To trigger immediately:**
```bash
flux reconcile kustomization grafana-instance -n flux-system
```

**To verify the Grafana pod restarted with the new config:**
```bash
kubectl rollout status deployment/grafana -n grafana
kubectl logs -n grafana -l app.kubernetes.io/name=grafana | grep -i "token_rotation\|use_refresh"
```

---

## Verification

After the changes are applied:

1. **Keycloak realm settings** — confirm via the Keycloak admin console under `Realm Settings > Sessions` and `Realm Settings > Tokens`:
   - Access Token Lifespan: 1 hour
   - SSO Session Idle: 8 hours
   - SSO Session Max: 10 hours

2. **Grafana** — log in via Keycloak and confirm the session persists beyond 5 minutes without being redirected to login. Check Grafana logs for `token refresh` entries.

3. **Kiali** — log in and navigate freely; the 1-hour token lifetime means no mid-session redirects during a normal work session.

---

## Notes

- The Keycloak `grafana` client already had `offline_access` in its optional scopes, and Grafana already requested it in `scopes: openid email profile offline_access roles`. The refresh token was therefore already being issued — it just wasn't being used. Enabling `use_refresh_token` activates it without any Keycloak-side changes.
- Kiali does not support refresh token rotation natively in its `openid` strategy. The fix for Kiali is entirely on the Keycloak side (longer `access_token_lifespan`).
- The 1-hour access token lifetime is a reasonable trade-off for a homelab cluster. For higher-security environments, keep the token short (5–15 min) and focus on ensuring refresh token flow works correctly for every app.

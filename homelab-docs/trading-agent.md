# Trading agent (Freqtrade)

Freqtrade bot running the TrendFollow4h strategy, later supervised by Claude. The bot's manifests, strategy and
mode-switch scripts live in the **private** repo `marmila/trading-agent`; this repo only wires it in.

| What | Where |
|---|---|
| Bot manifests, strategy, `set-mode.sh` / `readiness.sh` / `kill-switch.sh` | `marmila/trading-agent` (`deploy/`, `scripts/`) |
| Flux source for the private repo + deploy key | `kubernetes/apps/trading/source/base` |
| FreqUI HTTPRoute (HTTPS, LAN only) | `kubernetes/apps/trading/lan/base` on `lan-gateway` |
| `lan-gateway` (10.0.0.70, `LAN_GATEWAY_LOAD_BALANCER_IP`, wildcard cert `pi-cluster-tls`) | `kubernetes/platform/envoy-gateway/config/components/lan-gateway` |
| Flux Kustomizations `trading-source` → `trading-app` → `trading-lan` | `kubernetes/clusters/prod/apps/trading-app.yaml` |
| Generated secrets `trading/freqtrade`, `trading/freqtrade-jwt`, `trading/freqtrade-ws` | `terraform/vault/resources/secrets/trading.json` |
| Hand-made secrets `trading/deploy-key`, `trading/binance` (live only) | Vault, created by hand (below) |

## Access: LAN / WireGuard only

FreqUI is on `https://freqtrade.homelab.marmilan.com` (`lan-gateway`, 10.0.0.70; public IONOS A record to that private IP, like the other homelab names), user `marco`, password from Vault:

```bash
vault kv get -mount=secret -field=password trading/freqtrade
```

`lan-gateway` is a second Envoy Gateway on an IP the router does not forward, with the cluster
wildcard certificate. There is deliberately **no route on public-gateway**. Envoy Gateway's OIDC filter strips the incoming `Authorization` header
(Envoy `preserve_authorization_header` defaults to false and Envoy Gateway does not expose it), and FreqUI sends
its own JWT in that header, so a Keycloak-protected route would load the UI and fail every API call. Keycloak
comes back in Phase 2 for the MCP server.

## Status

Phase 0 done **2026-11-22** (PR #997): dry-run running since 2026-11-22, FreqUI on HTTPS through `lan-gateway`,
backtest gate passed (tuned `adx_min` 22, out of sample 2025–26: profit factor 1.87, max drawdown 6.2%, +13.7%
vs market −56.7%, only 22 trades). Go-live earliest after 8–12 weeks and at least 20–30 closed dry-run trades.

## Weekly check (about 5 minutes)

1. FreqUI → Dashboard: state `running`, closed trades, profit. Change nothing in the UI.
   Login form: Bot Name is only a label stored in the browser (e.g. `trendfollow`), API Url
   `https://freqtrade.homelab.marmilan.com`, user `marco`, password from Vault (above).
2. Optional, node2: `./scripts/readiness.sh` from a `trading-agent` checkout (read-only).

Few trades are normal: 4h candles, roughly one entry per pair per month.

## Network policy (Cilium, in `trading-agent/deploy/base/networkpolicy.yaml`)

- **In:** port 8080 only from the `lan-gateway` Envoy pods, plus `host` / `remote-node` (kubelet probes).
- **Out:** DNS, `*.binance.com` / `*.binance.vision` (443, 9443), `api.coingecko.com` (443).
  Freqtrade calls CoinGecko at startup for the EUR display (`fiat_display_currency`); if it is blocked the
  API server never starts and the liveness probe kills the pod.
- A new outbound host shows up as a drop. `hubble` is not installed on node2, run it in the Cilium agent of the
  pod's node:
  ```bash
  NODE=$(kubectl -n trading get pod -l app.kubernetes.io/name=freqtrade -o jsonpath='{.items[0].spec.nodeName}')
  CIL=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=$NODE -o name)
  kubectl -n kube-system exec $CIL -c cilium-agent -- hubble observe -n trading --verdict DROPPED --last 20
  kubectl -n kube-system exec $CIL -c cilium-agent -- cilium-dbg fqdn cache list | grep -v binance   # name of a dropped IP
  ```
- Do not try to allow LAN clients by CIDR on a LoadBalancer Service: traffic forwarded from the announcing node
  arrives with that node's `cilium_host` IP (pod CIDR) and is labelled `world`, so CIDR rules never match.
  That is one reason FreqUI goes through `lan-gateway`.

## First setup (rebuild from scratch)

1. **Generated secrets** (pimaster). `make configure-vault` plans **and applies with `-auto-approve`**, so plan
   by hand first. The provider lock file is gitignored: after Renovate bumps a provider, `init -upgrade` is needed.
   ```bash
   ./ansible-runner/ansible-runner.sh bash -lc '
   set -a; . ~/.secrets/vault.env; set +a
   export VAULT_ADDRESS="$VAULT_ADDR" TF_VAR_vault_address="$VAULT_ADDR" TF_VAR_vault_token="$VAULT_TOKEN"
   export TF_VAR_kubernetes_host=https://10.0.0.10:6443 TF_VAR_enable_kubernetes_auth=true
   export TF_VAR_enable_policies=true TF_VAR_enable_roles=true TF_VAR_enable_secrets=true
   cd /terraform/vault
   tofu init -upgrade -no-color | tail -3
   tofu plan -no-color -lock=false | grep -E "will be|must be|Plan:|No changes|Error"
   '
   make configure-vault      # only if the plan shows adds you expect
   ```
2. **Deploy key** (node1, where the Vault CLI is): read-only key for Flux.
   ```bash
   ssh-keygen -t ed25519 -N "" -C flux-trading-agent -f /tmp/trading-deploy
   vault kv put -mount=secret trading/deploy-key identity=@/tmp/trading-deploy
   cat /tmp/trading-deploy.pub        # copy the ssh-ed25519 line before the next command
   shred -u /tmp/trading-deploy /tmp/trading-deploy.pub
   ```
   GitHub web: `marmila/trading-agent` → Settings → Deploy keys → Add deploy key, title `flux-picluster`,
   **Allow write access unchecked**. Not `gh repo deploy-key add`: that key is tied to the gh token.
3. **DNS**: IONOS A record `freqtrade.homelab` → `10.0.0.70`, like the other homelab names. The laptop resolves
   through the router and public DNS; the node1 bind zone written by external-dns is not used there.
4. **Check** (node2):
   ```bash
   echo "== source"; flux get sources git trading-agent -n flux-system
   echo "== ks"; flux get ks -n flux-system | grep -E "trading|envoy-gateway-config"
   echo "== secrets"; kubectl -n trading get externalsecret; kubectl -n flux-system get externalsecret trading-agent-deploy-key
   echo "== bot"; kubectl -n trading get pod,pvc -o wide
   echo "== gateway"; kubectl -n envoy-gateway-system get gateway lan-gateway
   echo "== https"; curl -s -o /dev/null -w "%{http_code}
" https://freqtrade.homelab.marmilan.com/api/v1/ping
   ```
   Expected: all `True`, pod `1/1 Running`, gateway `10.0.0.70` programmed, `200`.

## Backtest (Phase 0 gate)

```bash
STAMP=bt-$(date +%Y%m%d-%H%M)
kubectl -n trading create job --from=cronjob/freqtrade-backtest $STAMP
kubectl -n trading logs -f job/$STAMP | tee /tmp/$STAMP.log
grep -nE "^== |Total profit %|Profit factor|Max % of account underwater|Market change|\"adx_min\"" /tmp/$STAMP.log
```

Gate: the last run (tuned parameters, TEST window) shows profit factor > 1.3, max drawdown < 25%, and is better
risk-adjusted than "Market change". Takes about 15–40 min. The tuned value goes into the strategy by commit.

## Going live / kill switch

Never by `kubectl`: the mode is a commit in `marmila/trading-agent`, made by `scripts/set-mode.sh` on the laptop.
`readiness.sh` and `kill-switch.sh` run on node2. The `trading/binance` secret (spot trading only, withdrawals off,
IP whitelist on) is created by hand just before go-live:

```bash
vault kv put -mount=secret trading/binance key=... secret=...
```

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

## First setup

1. **Generated secrets** (pimaster, on the branch or after merge):
   ```bash
   make configure-vault
   ```
2. **Deploy key** (node1, where the Vault CLI is): read-only key for Flux.
   ```bash
   ssh-keygen -t ed25519 -N "" -C flux-trading-agent -f /tmp/trading-deploy
   vault kv put -mount=secret trading/deploy-key identity=@/tmp/trading-deploy
   cat /tmp/trading-deploy.pub        # copy this line
   shred -u /tmp/trading-deploy /tmp/trading-deploy.pub
   ```
   Add the public key in GitHub: `marmila/trading-agent` → Settings → Deploy keys → Add deploy key, title
   `flux-picluster`, **Allow write access unchecked**. Prefer the web UI over `gh repo deploy-key add`: a key
   added by `gh` is tied to the gh token and disappears if that token is revoked.
3. **Check** (node2):
   ```bash
   echo "== LB IP free?"; kubectl get svc -A | grep 10.0.0.70 || echo free
   echo "== source"; flux get sources git trading-agent -n flux-system
   echo "== kustomizations"; flux get ks -n flux-system | grep trading
   echo "== secrets"; kubectl -n trading get externalsecret; kubectl -n flux-system get externalsecret trading-agent-deploy-key
   echo "== bot"; kubectl -n trading get pod,pvc,svc
   echo "== logs"; kubectl -n trading logs deploy/freqtrade --tail=30
   ```
   Egress or LAN access blocked? The namespace has a CiliumNetworkPolicy:
   `hubble observe -n trading --verdict DROPPED`.

## Backtest (Phase 0 gate)

```bash
kubectl -n trading create job --from=cronjob/freqtrade-backtest bt-$(date +%Y%m%d-%H%M)
kubectl -n trading logs -f job/bt-<stamp>
```

Gate: the last run (tuned parameters, TEST window) shows profit factor > 1.3, max drawdown < 25%, and is better
risk-adjusted than "Market change". Then the 8–12 week dry-run clock starts.

## Going live / kill switch

Never by `kubectl`: the mode is a commit in `marmila/trading-agent`, made by `scripts/set-mode.sh` on the laptop.
`readiness.sh` and `kill-switch.sh` run on node2. The `trading/binance` secret (spot trading only, withdrawals off,
IP whitelist on) is created by hand just before go-live:

```bash
vault kv put -mount=secret trading/binance key=... secret=...
```

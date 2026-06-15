# Incident Report: WireGuard VPN DNS Outage

**Date:** 2026-05-18  
**Duration:** ~1 day (broke after Cloudflare tunnel setup on 2026-05-17)  
**Severity:** High — full VPN access to homelab lost  
**Status:** Resolved

---

## Summary

WireGuard VPN stopped working after a Cloudflare tunnel was set up for `marmilan.com`. The domain `vpn.homelab.marmilan.com` could no longer be resolved by clients, making it impossible to connect to the homelab remotely. The DNS A record still existed in IONOS but was no longer being served because Cloudflare had become the authoritative nameserver for `marmilan.com`.

---

## Architecture

```
Internet
   │
   ▼
Home Router (192.168.1.1)
Port forward: UDP 51820 → GL-iNet WAN (192.168.1.21)
   │
   ▼
GL-iNet OpenWRT (192.168.1.21 WAN / 10.0.0.1 LAN)
Firewall DNAT: UDP 51820 → 10.0.0.25
   │
   ▼
vpnweb01 / vpn01 (10.0.0.25)
WireGuard listening on UDP 51820
PiVPN, Debian, Raspberry Pi
   │
   ▼
Homelab network (10.0.0.0/24)
```

DNS chain:
- External: `vpn.homelab.marmilan.com` → `93.40.1.188` (home public IP)
- Previously authoritative: IONOS
- After Cloudflare tunnel setup: **Cloudflare** (IONOS records became invisible)

---

## Root Cause

On 2026-05-17, a Cloudflare Tunnel was configured for `marmilan.com`. This required moving `marmilan.com`'s nameservers to Cloudflare. As a result:

- Cloudflare became the sole authoritative DNS for `marmilan.com` and all subdomains
- The `vpn.homelab.marmilan.com` A record only existed in IONOS — it was never added to Cloudflare
- All DNS queries for `vpn.homelab.marmilan.com` returned `NXDOMAIN` / "No such host is known"
- WireGuard clients could not resolve the endpoint and failed to connect

The IONOS dashboard still showed the record (IONOS retains records even when no longer authoritative), which caused confusion during diagnosis.

---

## Investigation Steps

1. Confirmed DNS record existed in IONOS (`vpn.homelab.marmilan.com` → `93.40.1.188`) ✓
2. Confirmed port forward on home router was set (UDP 51820) ✓
3. SSHed into `vpnweb01` — reachable at `10.0.0.25` ✓
4. Confirmed WireGuard running and healthy (`sudo wg show`, `systemctl status wg-quick@wg0`) ✓
5. Confirmed OpenWRT DNAT rule pointed to `10.0.0.25` ✓
6. Observed Windows WireGuard client error: **"No such host is known"** — pure DNS failure
7. Identified that Cloudflare tunnel setup the day before involved nameserver migration
8. Confirmed `marmilan.com` NS records now point to Cloudflare → **root cause found**

---

## Fix

Added the missing A record in **Cloudflare DNS**:

| Field | Value |
|-------|-------|
| Type | A |
| Name | `vpn.homelab` |
| IPv4 | `93.40.1.188` |
| Proxy status | DNS only (grey cloud) |
| TTL | Auto |

> **Important:** Proxy status must be **DNS only** (not proxied). WireGuard uses UDP which cannot be routed through Cloudflare's HTTP proxy.

DNS propagated within seconds. VPN connectivity restored immediately.

---

## Follow-up Actions

- [ ] Set up DDNS on OpenWRT to auto-update `vpn.homelab.marmilan.com` in Cloudflare when home public IP changes (`ddns-scripts` with Cloudflare API)
- [ ] Audit all other `homelab.marmilan.com` subdomains in IONOS — verify they are also present in Cloudflare DNS now that Cloudflare is authoritative

---

## Lessons Learned

- When migrating domain nameservers to a new provider, **all existing DNS records must be recreated** in the new provider before or immediately after the migration
- IONOS retaining old records after losing authority is misleading — always verify which nameserver is actually authoritative with `nslookup -type=NS marmilan.com 8.8.8.8`
- WireGuard A records in Cloudflare must always be **unproxied (grey cloud)** — Cloudflare proxy only handles HTTP/HTTPS traffic

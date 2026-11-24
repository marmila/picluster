# Disk replacement: worn disks first, one at a time, no downtime

Plan and procedure to replace the SSD of every node, made after the 2026-11-22 incident
([postmortem](../postmortems/incident-2026-11-22-elasticsearch-slow-longhorn-pi-disks.md)). The cluster keeps
running during each swap; only node1 (Vault, RustFS, DNS, outside k3s) needs a short planned downtime.

## Contents

- [1. Why](#1-why)
- [2. New disks: model, size, compatibility](#2-new-disks-model-size-compatibility)
- [3. Order](#3-order)
- [4. Rules for every swap](#4-rules-for-every-swap)
- [5. Procedure A: Raspberry Pi Longhorn worker (node5, node6)](#5-procedure-a-raspberry-pi-longhorn-worker-node5-node6)
- [6. Procedure B: x86 worker (node-esp-1, node-esp-2)](#6-procedure-b-x86-worker-node-esp-1-node-esp-2)
- [7. Procedure C: master (node4, node3, node2)](#7-procedure-c-master-node4-node3-node2)
- [8. Procedure D: node1 (clone, short downtime)](#8-procedure-d-node1-clone-short-downtime)
- [9. After phase 1](#9-after-phase-1)
- [10. Progress](#10-progress)

---

## 1. Why

SMART on 2026-11-22 (all nodes):

| Node | Current drive | Lifetime used | Errors | Holds |
|---|---|---|---|---|
| node-esp-2 | Crucial MX500 500 GB, SATA | **109%** | **1,754 reported uncorrectable, 6 offline uncorrectable, 2 reallocations** | Longhorn (ES + Prometheus copies) |
| node6 | Crucial BX500 240 GB, USB | **100%** `FAILING_NOW` | none | Longhorn |
| node5 | Crucial BX500 480 GB, USB | **100%** `FAILING_NOW` | 92 CRC (old, not increasing: see 2.2) | Longhorn |
| node4 | Crucial BX500 240 GB, USB | **100%** `FAILING_NOW` | none | etcd |
| node3 | Crucial BX500 240 GB, USB | 47% | none | etcd |
| node2 | Crucial BX500 240 GB, USB | 35% | 10 CRC | etcd |
| node1 | Crucial BX500 240 GB, USB | 37% | 7 CRC | Vault, RustFS, DNS |
| node-esp-1 | Crucial BX500 480 GB, SATA | 34% | none | Longhorn (ES + Prometheus copies) |

Models confirmed with `smartctl -i`: `CT240BX500SSD1` (firmware M6CR056) on node1–node4, `CT240BX500SSD1` on node6,
`CT480BX500SSD1` on node5 and node-esp-1, `CT500MX500SSD1` on node-esp-2. The BX500 is DRAM-less (recent
batches QLC) and slows down under sustained writes; the 240 GB size is rated only 80 TBW. Since the 2026-11-23
changes (TRIM, fewer writes, Elasticsearch off the Pis) a **1 TB** BX500 is acceptable on a Pi as a last
fallback (2.1.2), never on the mini PCs.

Budget DRAM-less drives (BX500) without TRIM wear out in about two years under Longhorn and etcd writes, and slow
to hundreds of milliseconds per write long before they fail. That stalled node5 and node6 on 2026-11-22.

The Pi disks never had TRIM: the kernel leaves USB bridges at `provisioning_mode=full` (`DISC-MAX 0B`), so
`fstrim` failed and every SSD treated the whole disk as live data. The adapters do support it: TRIM is enabled
since 2026-11-23 by a udev rule (2.2, condition 5). The first trim, by hand on each Pi, freed 135–295 GiB per
disk (about 1.4 TB in all), with no errors (results in ops-checklist.md, 23 Nov).

**4 disks are worn out** (node4, node5, node6, node-esp-2) and must be replaced. The other 4 still have years
left. Writes were reduced (2.4: 269 → 177 GB/day) and the Pis have TRIM, so every disk lasts longer.

**Decided 2026-11-23** (retail SSD shortage, Nov 2026: shops often stock only BX500 and Kingston A400): buy
**2 drives first** (2.3, step 1): a 1 TB for node6 (the Pi test drive; sizes from measured writes, 2.1.3) and a used enterprise 960 GB for node-esp-2
(the busiest worn disk: ~60 GB/day of Elasticsearch and Prometheus writes on 109% wear). Then node5 and node4;
node1, node3, node2 and node-esp-1 when their `DiskWornOut` fires or a good price shows up. Sizes stay as in 2.1.1.

## 2. New disks: model, size, compatibility

### 2.1 What to buy

All nodes take a **2.5" SATA SSD**: the Pis through their existing USB-SATA adapter, the mini PCs internally.
Only drives **with DRAM cache and TLC flash** (2.1.2).

#### 2.1.1 Size and timing per node

| Node | Role | Now (wear 2026-11-22) | **New size** | Buy | Why |
|---|---|---|---|---|---|
| node6 | Longhorn worker (Pi) | BX500 240 GB, 100% | **1 TB** | **now** | worn out; 1 TB holds with ES/Prometheus kept off the Pis (2.1.3) |
| node5 | Longhorn worker (Pi) | BX500 480 GB, 100% | **1 TB** | **now** | worn out; same condition |
| node4 | master, etcd (Pi) | BX500 240 GB, 100% | **1 TB** (500 GB minimum) | **now** | worn out; etcd needs endurance: 1 TB lasts twice as long (2.1.3) |
| node-esp-2 | Longhorn worker (x86) | MX500 500 GB, 109%, 1,754 errors | **960 GB enterprise** | **now** | worn out, media errors; ~230 GB/day (2.1.3) |
| node1 | Vault, RustFS, DNS (Pi) | BX500 240 GB, 37% | **1 TB** | now (recommended) | no second copy of Vault/RustFS/DNS; RustFS needs room |
| node3 | master, etcd (Pi) | BX500 240 GB, 47% | **1 TB** (500 GB minimum) | later (2.3 step 3) | ~2 years left |
| node2 | master, etcd (Pi) | BX500 240 GB, 35% | **1 TB** (500 GB minimum) | later (2.3 step 3) | same |
| node-esp-1 | Longhorn worker (x86) | BX500 480 GB, 34% | **960 GB enterprise** | later | buy when `DiskWornOut` fires; ~235 GB/day (2.1.3) |

Different sizes are fine: masters hold etcd, not Longhorn data, and Longhorn places replicas by free space.
On 2026-11-23 Longhorn used only 39 GB on node5 and node6 (130–141 GB on the mini PCs): the sizes come from
endurance (rated TBW grows with size) and room for new apps, not from today's space (2.1.3).

The "Buy" column was the 2026-11-22 recommendation; the 2026-11-23 decision is in 2.3: worn disks first, the
rest when needed.

#### 2.1.2 Models

**For the Pis** (same model on all six; max power ≤ 4 W in the datasheet, 2.2), in order of preference:

| # | Model | 1 TB / 500 GB part number | TBW (1 TB / 500 GB) | Notes |
|---|---|---|---|---|
| 1 | **Crucial MX500** | `CT1000MX500SSD1` / `CT500MX500SSD1` | 360 / 180 | Same family the adapters run today. Crucial left retail in Feb 2026: leftover stock only, check the seller. About €120 for 1 TB (Trovaprezzi, Nov 2026) |
| 2 | **Samsung 870 EVO** | `MZ-77E1T0B/EU` / `MZ-77E500B/EU` | 600 / 300 | Most common SSD on Pi 4s. **Not** the 870 **QVO** |
| 3 | **WD Red SA500** or **WD Blue SA500** | Red `WDS100T1R0A` / `WDS500G1R0A`; Blue `WDS100T2B0A` / `WDS500G2B0A` | 600 / 350 (Red), 400 / 200 (Blue) | **Not** the WD Blue **SA510** (no DRAM) |
| 4 | **Crucial BX500**, only if 1–3 are out of stock | `CT1000BX500SSD1` (1 TB, 360 TBW, €149 on Amazon, 23 Nov 2026) for every Pi. Never 240/480/500 GB | 720 / 360 | Last fallback (shortage, Nov 2026). DRAM-less: fine as long as Elasticsearch and Prometheus stay off the Pis (growth condition in 2.1.3), with TRIM on. Treat as a consumable: `DiskWornOut` tells when |

2 TB part numbers, only if Pi workers ever get heavy volumes again (2.1.3): MX500 `CT2000MX500SSD1` (700 TBW), 870 EVO `MZ-77E2T0B/EU` (1,200),
WD Red SA500 `WDS200T1R0A` (1,300), BX500 `CT2000BX500SSD1` (720). All within the Pi's 4 W power budget.

**Never a Kingston A400** on the Pis, even when it is the only drive in stock: often not recognised behind these
adapters, and DRAM-less.

#### 2.1.3 Sizing from measured writes (2026-11-23)

Physical writes to each node's disk (`node_disk_written_bytes_total`, device `sda`; Prometheus keeps 14 days)
and SMART lifetime counters (Crucial attributes 246 host sectors written, 247/248 host/FTL NAND pages):

| Node | Last 1 d | 7 d average | Worst day (14 d) | Lifetime average (SMART) | Write amplification (lifetime) | Wear |
|---|---|---|---|---|---|---|
| node-esp-1 | 166 | 213 | 300 | 236 | 1.7 | 34% |
| node-esp-2 | 100 | 167 | 391 | 226 | 2.3 | 109% |
| node5 | 31 | 156 | 288 | 152 | 8.0 | 100% |
| node6 | 37 | 57 | 69 | 64 | 12.5 | 100% |
| node4 | 37 | 39 | 42 | 66 | 7.4 | 100% |
| node3 | 38 | 40 | 43 | 52 | 3.5 | 48% |
| node2 | 38 | 41 | 50 | 34 | 2.1 | 35% |
| node1 | 25 | 17 | 25 | 8 | **22.5** | 37% |

GB/day. Two findings:

- **The disks write about 2.5× what Longhorn reports** (~470 GB/day physical on the last day against 177
  from `longhorn_volume_write_throughput` in 2.4): replica rebuilds, snapshots, backups, etcd, OS and logs
  come on top. Size on the physical numbers.
- **Write amplification** (NAND writes per host write) is normal on the mini PCs (1.7–2.3, TRIM always worked)
  and high on the Pis (up to 12.5; 22.5 on node1, whose root disk is nearly full): years without TRIM on small,
  full disks. With TRIM (2.2) and big, mostly empty disks it should drop to the mini PC level. The years below
  assume that; check it 2 weeks after each swap (9).

**Design load = sustained load (the higher of the 7-day and lifetime averages) × 2**, room for new apps:

| Node type | Sustained | **Design** | Drive (rated TBW) | Years at design load |
|---|---|---|---|---|
| Mini PC (Longhorn, Elasticsearch, Prometheus) | 235 | **470** | Kingston KC600 / 870 EVO 1 TB (600) | ~3.5 |
| | | | used PM883 960 GB (~1,370) | ~8 |
| | | | Micron 5300/5400 PRO, PM893, Kingston DC600M 960 GB (~1,500–1,750) | ~9–10 |
| | | | Intel D3-S4510 960 GB (~3,400) | ~20 |
| Pi Longhorn worker (node5, node6) | 156 | **310** | MX500 / BX500 1 TB (360) | ~3 (6 at today's load) |
| | | | 870 EVO / WD Red SA500 1 TB (600) | ~5 |
| | | | MX500 / BX500 2 TB (700–720) | ~6 |
| | | | 870 EVO / WD Red SA500 2 TB (1,200–1,300) | ~11 |
| Master, etcd (node2–4) | 66 | **130** | 500 GB MX500 (180) | ~4 |
| | | | 1 TB MX500 / BX500 (360) | ~7.5 |
| | | | 1 TB 870 EVO / WD Red (600) | ~12.5 |
| node1 (Vault, RustFS, DNS) | 17 | **35** | any 1 TB | 25+: space is the limit, not wear |

**Result:**

- **Mini PCs: a used enterprise drive**, best value an Intel D3-S4610 (table below). A new enterprise drive
  (Kingston DC600M) costs €727 (Amazon, 23 Nov 2026): too much. Fallback: a 600 TBW consumer 1 TB (KC600, 870 EVO,
  WD Red SA500), about 7 years at today's load, 3.5 if it doubles.
- **Pi workers (node5, node6): 1 TB BX500, €149 each (decided 2026-11-23)**, with the condition below. The
  ~156 GB/day "sustained" figure
  for node5 is inflated: the 7-day average includes the 22 Nov incident rebuilds (288 GB that day) and the
  lifetime average includes the months when Elasticsearch and Prometheus had copies on node5. On the last day
  node5 wrote 31 GB and node6 37 GB. With Elasticsearch and Prometheus kept on the mini PCs, a Pi worker writes
  about 30–60 GB/day, 60–120 doubled: a 1 TB MX500/BX500 (360 TBW) lasts **8–16 years**. Only if they land on a
  Pi again does it drop to about 3 years, hence the condition. 2 TB (€247) is not worth it with the condition.
- **Masters: 1 TB** (500 GB is half the life).
- **node1: 1 TB**, for space (RustFS); wear is not a concern there once the root disk is no longer full.

**Condition for the 1 TB Pi workers:** Elasticsearch, Prometheus and any new write-heavy app stay off the Pis.
Today that is a live setting on the volumes, not in Git (postmortem action 2). Make it permanent (Longhorn disk
tag `fast` on the mini PCs and a StorageClass with `diskSelector: fast` for write-heavy volumes) before adding
write-heavy apps, or a rebuild can put them back on a Pi disk.

**For the mini PCs** (node-esp-2 now, node-esp-1 later): no power limit. First choice: a **used enterprise SATA
SSD**, 2.5", health ≥ 95%. Cheapest and most durable per euro: the Intel **D3-S4610** (mixed-use, 3 drive writes
per day). Datacenters retire them in bulk, so used ones are common and often cost less than a new consumer 1 TB.

| Model | Part number 960 GB / 480 GB | Endurance 960 / 480 GB | Years at the design load (470 GB/day), 960 / 480 GB |
|---|---|---|---|
| **Intel (Solidigm) D3-S4610** | `SSDSC2KG960G8` / `SSDSC2KG480G8` | ~5.8 / ~3.0 PB | 30+ / ~17 |
| Intel (Solidigm) D3-S4510 | `SSDSC2KB960G8` / `SSDSC2KB480G8` | ~3.4 / ~1.2 PB | ~20 / ~7 |
| Samsung PM893 | `MZ7L3960HCJR` | ~1.7 PB | ~10 |
| Micron 5300 PRO / 5400 PRO | `MTFDDAK960TDS` / `MTFDDAK960TGA` | ~1.5–1.7 PB | ~9–10 |
| Samsung PM883 | `MZ7LH960HAJR` | ~1.3 PB | ~8 |

**480 GB is enough if 960 GB is over budget:** Longhorn uses 130–141 GB on each mini PC (2.1.1) and the disks
today are 480/500 GB. Prefer the S4610 at 480 GB (3 PB) over the S4510 at 480 GB (1.2 PB).

DRAM, power-loss protection, and endurance far above any consumer drive; datacenter pull-outs stay available
during the retail shortage. Buy from a refurbished-server shop or an eBay seller with history who shows the
SMART data (wear, power-on hours, 0 reallocated/uncorrectable). Fallback, new: a 600 TBW consumer 1 TB (Kingston
KC600 `SKC600/1024G`, 870 EVO, WD Red SA500), about 7 years at today's load (2.1.3); Kingston is fine here, no
USB adapter. A new enterprise drive (Kingston DC600M `SEDC600M/960G`) only if its price drops: €727 on 23 Nov
2026. **Never a BX500 or A400** on the mini PCs: they write ~230 GB/day each.

**Do not buy:**

| Drive | Why |
|---|---|
| Crucial BX500 240/480/500 GB; any BX500 on the mini PCs | DRAM-less, low TBW at small sizes: the drive that wore out here (1 TB on a Pi: fallback row 4) |
| Any Kingston on the Pis (A400, KC600, ...) | Often not recognised behind these USB adapters in the past |
| Samsung 870 QVO, WD Blue SA510, WD Green, Kingston A400, Crucial P-series | DRAM-less or QLC |
| No-name drives, marketplace sellers with no history | fakes of discontinued models (MX500) are common |

For comparison, node-esp-2's MX500 500 GB is rated 180 TBW and had written about 187 TB, as the busiest Longhorn
node with the smallest drive.

### 2.2 Raspberry Pi compatibility (checked 2026-11-22)

On a Pi the part that must be compatible is the **USB-SATA adapter**, not the SSD: the Pi only sees the
adapter's bridge chip, which then speaks plain SATA to any 2.5" SSD. Checked on all six Pis:

| Pi | Model | Adapter (`lsusb`) | Driver / link |
|---|---|---|---|
| node1, node2, node3, node5, node6 | Raspberry Pi 4 Model B Rev 1.5 | `14b0:0207` StarTech USB-SATA | `uas`, 5000M |
| node4 | Raspberry Pi 4 Model B Rev 1.5 | `14b0:0206` StarTech USB-SATA (older revision) | `uas`, 5000M |

These StarTech adapters are widely used on the Pi 4, and these ones have run the BX500s with UAS for two years.
So **all drives can be bought at once**; keep the adapters. Conditions:

1. **2.5" SATA** drive (not NVMe, not mSATA, not M.2).
2. **Max power ≤ 4 W** in the drive's datasheet: the Pi 4 gives about 1.2 A (6 W) to all its USB ports
   together. Use the official 3 A power supply and nothing else on the Pi's USB ports.
3. **node5's adapter stays.** Its drive shows 92 CRC errors, but they are old. Tested on 2026-11-22:
   - reading 33 GB raw from the disk ran at 354 MB/s and the CRC count stayed at 92;
   - the SATA Phy counters (`smartctl -l sataphy`: ICRC, R_ERR, COMRESET) were all 0 after 8 days of uptime,
     including that day's incident load;
   - the link was `uas` at 5000M, the kernel log showed no USB/UAS errors in 7 days, and `vcgencmd get_throttled`
     returned `0x0`.

   A spare StarTech adapter of the same model is optional.
4. The `fio` + `dmesg` check in procedure A5 stays as a **check after each swap**, not a reason to wait before
   buying.
5. **TRIM must work through the adapter.** Both StarTech IDs support UNMAP over UAS (`sg_vpd -p lbpv /dev/sda`:
   `Unmap command supported (LBPU): 1`; `sg_vpd -p bl`: maximum unmap LBA count 4194240, i.e. 2 GiB), but the
   kernel does not enable it on USB bridges. The udev rule `/etc/udev/rules.d/60-usb-ssd-trim.rules`
   (`basic_setup/tasks/usb_ssd_trim.yml`, adapter IDs in the role defaults) sets `provisioning_mode=unmap` and caps
   `discard_max_bytes` at 2 GiB; the weekly `fstrim.timer` does the rest. A new adapter model needs its
   `lsusb` ID added to `usb_ssd_trim_adapters` after the same `sg_vpd` check. Checked in A7.

### 2.3 Shopping list

**Decided 2026-11-23: 2 drives first, then the other worn ones.** No adapter needed (node5's was tested fine; a
spare StarTech USB 3.0 to 2.5" SATA adapter of the same model is optional).

**Step 1: the first 2 drives.**

| Qty | For | Buy (first one in stock) | Swap |
|---|---|---|---|
| 1 | **node6** (Pi test drive) | **1 TB**: Crucial BX500 `CT1000BX500SSD1` (in stock, €149) or MX500 `CT1000MX500SSD1`. Never a Kingston | 1st (procedure A) |
| 1 | **node-esp-2** (x86) | used enterprise 960 GB (2.1.2 mini PC table: PM883, PM893, S4510, Micron 5300/5400), health ≥ 95%. Fallback new: KC600 `SKC600/1024G` or another 600 TBW 1 TB. Not DC600M at €727, not BX500, not A400 | 2nd (procedure B) |

If only one can be bought now, buy node-esp-2's: it is the disk with media errors and the heaviest writes.
Then node-esp-2 goes first, and node6 waits for its drive.

The node6 drive tests the Pi model in procedure A, step A5. All must pass:

- `lsusb -t`: `Driver=uas, 5000M`;
- `fio`: hundreds of MB/s, no `reset` / `abort` lines in `dmesg`;
- after A6 (which installs the SMART timer): `smartmon_read_ok` is 1 for node6 (SMART readable through the adapter, so the
  disk alerts cover it).

If it fails, nothing is wasted: keep that drive for node-esp-1's swap (internal SATA, no adapter, any drive
works) and test the next model on node6. The used enterprise drives are for the mini PCs only, never a Pi (power).

**Step 2: the other 2 worn disks**, once node6 passed A5 (a model from 2.1.2; the same one as node6 if in stock,
mixing models is fine):

| Qty | Size | For |
|---|---|---|
| 1 | 1 TB (BX500 `CT1000BX500SSD1`, or the node6 model) | node5 |
| 1 | 1 TB (500 GB only if 1 TB is unaffordable, and never a BX500 below 1 TB) | node4 (etcd) |

**Step 3, later** (when their `DiskWornOut` fires, or at a good price): node1, node3 and node2 1 TB,
node-esp-1 960 GB enterprise. Their wear on 2026-11-22: 34–47%.

Cost (Amazon, 23 Nov 2026; prices move fast during the shortage): Crucial BX500 1 TB €149, 2 TB €247; Kingston
DC600M 960 GB €727 (too much: look for a used enterprise drive instead). The 3 worn Pis: 3 × 1 TB = **€447**,
plus node-esp-2 (used S4610/S4510).

**When each drive arrives**, before using it (any Linux machine, or a Pi through the adapter):

```bash
sudo smartctl -i -A -d sat /dev/sdX | grep -iE "model|serial|firmware|Power_On_Hours|Total_LBAs"
```

- the model is exactly the part number ordered (`CT1000MX500SSD1`, `Samsung SSD 870 EVO 1TB`, `WDC WDS100T1R0A`,
  `CT1000BX500SSD1`, `SAMSUNG MZ7LH960HAJR...`, ...);
- power-on hours close to 0 (a few hours from factory test is normal; for the used enterprise drive, check the
  health the seller stated: wear indicator ≥ 95%, no reallocated or uncorrectable sectors);
- otherwise send it back.

Write the model and serial in the progress table (10).

### 2.4 Make every disk last longer: fewer disk writes

Measured on 2026-11-22 (24 h average of `longhorn_volume_write_throughput` × each volume's replica count):
Longhorn writes **269 GB/day** to the cluster's disks (about 98 TB/year).

| Volume | Disk GB/day | Replicas | Redundancy outside Longhorn | Action |
|---|---|---|---|---|
| Elasticsearch | 84 | 2 | none (1 node, index replicas 0) | keep |
| Prometheus | 55 | 2 | none (not in Velero) | keep |
| Loki write (WAL) | 36 | 3 → **1** | chunks are in S3; only not-yet-uploaded logs are on the volume | **done, live** |
| MongoDB threatmap | 27 | 3 | none (1 member) | **threatmap disabled** |
| Postgres Keycloak ×2 | 29 | 3 → **1** | 2 CNPG instances + WAL archive and backups in RustFS (barman) | **done, live** |
| Kafka ×3 | 32 | 3 | none for the app topics (`replicas: 1`) | keep |
| Others | 6 | 3 | – | keep |

The earlier idea ("Kafka, Postgres and MongoDB keep 3 copies themselves") was wrong for this cluster: only
Postgres has its own copy (2 instances). Lowering Kafka's Longhorn replicas would need its topics at 3 copies
first, which writes the same amount.

**Done 2026-11-22:**

- **threatmap disabled** (MongoDB ~27 GB/day): see [ops-checklist.md](ops-checklist.md) for how to re-enable.
- **1 Longhorn replica, data locality `best-effort`** for `databases/postgres-keycloak-1`,
  `databases/postgres-keycloak-2` and `loki/data-loki-write-0` (~43 GB/day). The single copy stays on the node
  where its pod runs, so the two Postgres instances keep their data on two different nodes.

Expected after both: about **200 GB/day** (-25%).

**Measured 2026-11-23** (same method, 24 h): **177 GB/day** (-34%). Elasticsearch 81, Prometheus 40,
Kafka ×3 32, Loki write 10 (1 replica), Postgres Keycloak ×2 9 (1 replica each), threatmap 3 (only the hours
before it stopped), others 2. Prometheus is lower than on 22 Nov (55); measure again before deciding anything
on it.

Result of the patch (2026-11-22): each volume kept one replica, on its pod's node:

| Volume | Replica (and pod) on | Note |
|---|---|---|
| `postgres-keycloak-1` | node6 | worn disk (100%) |
| `postgres-keycloak-2` | node5 | worn disk (100%) |
| `data-loki-write-0` | node-esp-1 | |

Both Keycloak Postgres instances now have their only Longhorn copy on the two most worn Pi disks. The safety net
is the CNPG backup in RustFS, checked the same day: WAL archiving working, daily backups `completed` (last
2026-11-22 02:30), recoverable from 2026-11-07. Check it again before each swap of node5 or node6 (procedure A1).

**This is a live patch, not in Git.** The Longhorn volume's `numberOfReplicas` is not managed by Flux. A
StorageClass in Git is not used on purpose: Loki's write volume comes from a StatefulSet, whose storage template
cannot be changed, so a new StorageClass would break the Loki Helm upgrade.

- **Disk swaps (procedures A–D): nothing to revert or redo.** Draining a node and evicting its Longhorn replicas
  (A1/B1) copies the single replica to another node first; the volume keeps 1 replica.
- **Do not put these back to 3 after the new disks:** the reason is the applications' own redundancy, not disk
  wear.
- **Reapply** only when the volumes are recreated: a full cluster rebuild (`make clean` / `make init`), a Velero
  restore of `databases` or `loki`, or a deleted and recreated PVC (for example CNPG rebuilding an instance). New
  volumes get Longhorn's default of 3 replicas. Command (node2):

  ```bash
  PVCS="databases/postgres-keycloak-1 databases/postgres-keycloak-2 loki/data-loki-write-0"
  vol() { kubectl -n ${1%/*} get pvc ${1#*/} -o jsonpath='{.spec.volumeName}'; }
  for p in $PVCS; do v=$(vol $p); kubectl -n longhorn-system patch volumes.longhorn.io $v --type merge -p '{"spec":{"dataLocality":"best-effort","numberOfReplicas":1}}'; done
  for p in $PVCS; do v=$(vol $p); echo "$p $(kubectl -n longhorn-system get volumes.longhorn.io $v -o jsonpath='{.spec.numberOfReplicas} {.spec.dataLocality} {.status.robustness}')"; done
  ```

  CNPG names new instances with a higher number (`postgres-keycloak-3`, ...): check the current PVC names with
  `kubectl -n databases get pvc | grep keycloak` first. Undo: the same patch with `"dataLocality":"disabled","numberOfReplicas":3`.
- **To check the saving**, rerun the measurement (node2):

  ```bash
  P="/api/v1/namespaces/kube-prom-stack/services/kube-prometheus-stack-prometheus:http-web/proxy/api/v1/query?query="
  Q='avg_over_time(longhorn_volume_write_throughput[1d])'
  kubectl get --raw "${P}$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$Q")" > /tmp/lh_w.json
  kubectl -n longhorn-system get volumes.longhorn.io -o json > /tmp/lh_v.json
  python3 -c '
  import json
  w = {r["metric"].get("volume"): float(r["value"][1]) for r in json.load(open("/tmp/lh_w.json"))["data"]["result"]}
  rows = []
  for v in json.load(open("/tmp/lh_v.json"))["items"]:
      ks = v["status"].get("kubernetesStatus", {}); rep = v["spec"]["numberOfReplicas"]; app = w.get(v["metadata"]["name"], 0) * 86400 / 1e9
      rows.append((app * rep, rep, ks.get("namespace", "-") + "/" + ks.get("pvcName", "-")))
  for r in sorted(rows, reverse=True)[:12]: print("%7.1f GB/d  rep %d  %s" % r)
  print("%7.1f GB/day total" % sum(r[0] for r in rows))'
  ```

## 3. Order

One node per day at most. Each swap waits for Longhorn to be fully healthy before the next.

### 3.1 Every swap at a glance

The same 7 stages for every node; the procedure (A–D) only changes what happens in the middle. Commands are in
sections 4–8.

| Stage | Where | What | Done when | Time |
|---|---|---|---|---|
| 0. Before | node2 | Pre-flight (4.1); lighten the cluster (4.2); for node5/node6 also the Keycloak backup check (A1) | all nodes `Ready`, no `degraded` volume, CPU < 80% | 10 min |
| 1. Empty | node2 | Evict the node's Longhorn replicas (A1/B1). Masters: etcd snapshot instead (C1). node1: nothing (D) | replicas on the node = 0, degraded = 0 | 1–6 h |
| 2. Remove | node2, then the node | Drain, `sudo poweroff`, delete node + `node-password` secret + Longhorn node | node gone from `kubectl get nodes` | 15 min |
| 3. New disk | laptop or the node | Pi: image the SSD and write `user-data`/`network-config` (A4). Mini PC: fit the SSD, `make pxe-setup`, PXE boot (B4). node1: clone the old disk (D2) | node boots and answers SSH | 30–45 min |
| 4. First boot check | the node | Pi: `lsusb -t` (uas, 5000M), `fio` + `dmesg` (A5, mandatory on the first Pi with the new model) | no `reset`/`abort` in `dmesg` | 10 min |
| 5. Join | pimaster | `setup_picluster.yml --tags node`, `backup_configuration.yml`, `k3s_install.yml` (masters: `-e k3s_primary_control_node=false`), `update_node_config.yml` | playbooks green | 20–30 min |
| 6. Check | node2 + the node | `Ready`, Longhorn node schedulable, pods running (A7/B6/C6); SMART baseline and `smartmon_read_ok` 1; Pi: TRIM works (A7) | all green | 10 min |

Then restore what was scaled down (4.2), uncordon the Pis if they were cordoned, and fill in the progress table (10).
**Stop and ask** if any "done when" is not met: do not start the next node.

| Node | Procedure | Downtime | Watch out for |
|---|---|---|---|
| node6, node5 | A (Pi Longhorn worker) | none (cluster keeps running) | node6 first: its A5 test validates the drive model for all Pis |
| node-esp-2 | B (x86 worker, PXE reinstall) | none | Prometheus and ES move to node-esp-1: cordon the worn Pis during the drain (4.2) |
| node4, node3, node2 | C (master) | none, etcd runs on 2 of 3 | never two masters out at once; node2 needs `-e k3s_primary_control_node=false`, and kubectl from node3 during its swap |
| node1 | D (clone) | 30–45 min of Vault, RustFS, DNS | evening, not 02:00–04:00; unseal Vault after boot; keep the old disk a week |

**Phase 1 (now):**

| # | Node | Procedure | Why this position |
|---|---|---|---|
| 1 | node6 | A | Worst Pi disk; first run of the new drive in a Pi adapter (A5 check) |
| 2 | node-esp-2 | B | Disk with errors. After node6, so its ES/Prometheus copies move to a healthy disk |
| 3 | node5 | A | Worn (adapter tested OK, kept) |
| 4 | node4 | C | Worn etcd disk |

If node-esp-2's drive arrives before node6's, swap node-esp-2 first (it does not depend on the Pi test).

**Later (2.3 step 3), when bought:** one per day, in this order:

| # | Node | Procedure | Why this position |
|---|---|---|---|
| 5 | node1 | D | Short downtime: a quiet evening, not during Velero (02:00) or the Longhorn cleanup (03:30) |
| 6 | node3 | C | Masters at least an hour apart, only with all three `Ready` |
| 7 | node2 | C | First master in the inventory: `-e k3s_primary_control_node=false` is mandatory (7) |

node-esp-1 (B) whenever its drive is bought; it does not depend on the others.

## 4. Rules for every swap

- **One node at a time.** The next one only when the previous is `Ready`, Longhorn has **no** `degraded`
  volume, and the new disk shows sane latency.
- **Masters:** etcd needs 2 of 3. Never touch a second master while one is out.
- **Where to run kubectl:** node2 for everything, except when node2 itself is swapped: then node3.
- **Ansible** runs on pimaster through the runner (`./ansible-runner/ansible-runner.sh ...`), from `~/picluster`.
- Imaging a Pi disk: on the **laptop** (Raspberry Pi Imager + PowerShell) or on any Linux machine with the
  repository (`metal/rpi/Makefile`).
- **No image of the running OS.** Workers and masters are rebuilt from cloud-init/PXE + Ansible and hold nothing
  that is not in git or in Longhorn (moved off in stage 1). A copy of a mounted disk (`dd`, `rpi-clone`) is not
  consistent, and it would carry the worn disk's errors (node-esp-2: 1,754 uncorrectable). Only node1 is
  cloned, powered off (procedure D).
- **Keep the old disk** untouched and labelled for a week: if the new one fails, put the old one back and the
  node comes back as it was (delete the node + `node-password` secret first, as in A3/B3).

### 4.1 Pre-flight (node2), before every swap

```bash
echo "== nodes (all Ready, none SchedulingDisabled)"; kubectl get nodes
echo "== Longhorn volumes not healthy (only detached ones allowed)"
kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUST:.status.robustness | grep -v healthy
echo "== Longhorn disk space per node"
kubectl -n longhorn-system get nodes.longhorn.io -o json | jq -r '.items[] | .metadata.name as $n | .status.diskStatus | to_entries[] | "\($n) avail=\(.value.storageAvailable/1e9|floor)G scheduled=\(.value.storageScheduled/1e9|floor)G max=\(.value.storageMaximum/1e9|floor)G"'
echo "== load"; kubectl top nodes
```

Go only if every node is `Ready`, no volume is `degraded`/`faulted`, and no node is above about 80% CPU.

### 4.2 Lighten the cluster during a swap

Draining a node moves its pods to the others, and on 2026-11-14 and 2026-11-22 that overloaded the Pis. Before a
drain, scale down what is not needed for a day, and keep heavy pods off the worn Pis.

**Scale down** (node2). Pick the namespaces; the current replica counts are saved so they can be restored:

```bash
NS="e-commerce trading"          # add or remove namespaces as you like
for ns in $NS; do
  kubectl -n $ns get deploy,statefulset -o json | jq -r '.items[] | "\(.kind) \(.metadata.name) \(.spec.replicas)"' | sed "s|^|$ns |" >> ~/scaled-down-$(date +%F).txt
  kubectl -n $ns scale deploy --all --replicas=0
  kubectl -n $ns scale statefulset --all --replicas=0
done
cat ~/scaled-down-$(date +%F).txt
```

Flux puts the replica count of a Deployment back on its next reconcile when the manifest sets `replicas:`. To keep
them down for the day, suspend those Kustomizations first (`flux get kustomizations | grep -E "e-commerce|trading"`,
then `flux suspend kustomization <name>`), and `flux resume kustomization <name>` afterwards.

**Restore** (node2), after the swap:

```bash
F=~/scaled-down-YYYY-MM-DD.txt
while read ns kind name n; do kubectl -n $ns scale $kind/$name --replicas=$n; done < $F
```

**Cordon the worn Pis** while draining an x86 node, so its heavy pods (Prometheus, Elasticsearch, Kafka,
Postgres) do not land on them; uncordon right after the drained node is back:

```bash
kubectl cordon node5 node6            # only if node-esp-1 has room: kubectl top node node-esp-1 below ~60% CPU / 70% memory
# ... drain and swap the x86 node ...
kubectl uncordon node5 node6
```

A cordoned node keeps its running pods and its Longhorn replicas; it only receives no new pods.

---

## 5. Procedure A: Raspberry Pi Longhorn worker (node5, node6)

Example for **node6** (IP `10.0.0.16`). For node5 use `node5` and `15`.

### A1. Move all Longhorn data off the node (node2)

node5 and node6 hold the **only** Longhorn copy of a Keycloak Postgres instance (1 replica since 2026-11-22, see
2.4). The eviction below copies it to another node like any other replica, but check first that the other
instance and the backups are fine:

```bash
kubectl -n databases get pods -o wide | grep postgres-keycloak | awk '{print $1, $3, $(NF-2)}'   # both Running
kubectl -n databases get cluster postgres-keycloak -o jsonpath='{"last backup: "}{.status.lastSuccessfulBackup}{"
"}{range .status.conditions[?(@.type=="ContinuousArchiving")]}{"WAL archiving: "}{.status}{"
"}{end}'
```

Go only with both instances `Running`, a backup from the last night and `WAL archiving: True`.


Longhorn copies every replica on node6 to the other nodes. The volumes stay online.

```bash
N=node6
kubectl -n longhorn-system patch nodes.longhorn.io $N --type merge -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}'
watch -n 30 "kubectl -n longhorn-system get replicas.longhorn.io -o json | jq '[.items[]|select(.spec.nodeID==\"$N\")]|length'; kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,ROBUST:.status.robustness | grep -c degraded"
```

Wait until the first number (replicas on node6) is **0** and the second (degraded volumes) is **0**. This can
take hours. If a number stops moving for 30 minutes, paste the output of the pre-flight block.

### A2. Drain and power off (node2, then node6)

```bash
kubectl drain node6 --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=600s
```

On node6:
```bash
sudo poweroff
```

### A3. Remove the node from the cluster (node2)

```bash
kubectl delete node node6
kubectl -n kube-system delete secret node6.node-password.k3s --ignore-not-found
kubectl -n longhorn-system delete nodes.longhorn.io node6
```

The `node-password` secret must go, or k3s rejects the reinstalled node ("Node password rejected").

### A4. Image the new SSD

Put the new SSD in the node's adapter and connect it to the laptop.

**Laptop (Windows):**

1. Download the image named in `metal/rpi/Makefile` (`IMG=` / `URL_IMG=`, today
   `ubuntu-24.04.3-preinstalled-server-arm64+raspi.img.xz`).
2. Raspberry Pi Imager: **Choose OS → Use custom** → that file; **Choose storage** → the new SSD; when it asks
   about OS customisation choose **No** (cloud-init files below do it). Write.
3. Unplug and plug the SSD back. The FAT partition `system-boot` appears (for example `E:`). In PowerShell from
   the repository root:
   ```powershell
   $NODE = "node6"; $IP = "16"; $BOOT = "E:"
   $ud = (Get-Content metal\rpi\cloud-init\nodes\user-data-SSD-partition -Raw).Replace("`r`n", "`n") -creplace 'nodeX', $NODE
   $nc = (Get-Content metal\rpi\cloud-init\nodes\network-config -Raw).Replace("`r`n", "`n") -creplace 'X', $IP
   [IO.File]::WriteAllText("$BOOT\user-data", $ud)
   [IO.File]::WriteAllText("$BOOT\network-config", $nc)
   Select-String -Path "$BOOT\user-data" -Pattern "hostname:"; Select-String -Path "$BOOT\network-config" -Pattern "10.0.0."
   ```
   Expected: `hostname: node6` and `10.0.0.16/24`. Eject the drive.

**Or on a Linux machine** with the repository (check the device with `lsblk` first, it is wiped):
```bash
cd metal/rpi
make img/ubuntu-24.04.3-preinstalled-server-arm64+raspi.img.xz
make wipe-disk burn-image USB=/dev/sdX
make mount-system-boot prepare-node6 USB=/dev/sdX
```

### A5. First boot (node6)

Connect the adapter to the same blue USB 3 port, power on, wait about 5 minutes (cloud-init creates `/storage`
on the rest of the disk). Then on node6:

```bash
hostname; ip -4 addr show eth0 | grep inet
lsblk -o NAME,SIZE,TRAN,MODEL,MOUNTPOINT | grep -v loop     # / about 50G, /storage the rest (~880G on 1 TB)
lsusb -t | grep -i -A1 storage                              # Driver=uas, 5000M
sudo dmesg -T | grep -iE "uas|reset|error" | tail            # nothing new
```

**Compatibility test** (first Pi with the new drive model). Writes and reads 2 GB on `/storage`:

```bash
sudo apt-get install -y -qq fio
sudo fio --name=t --filename=/storage/.fio --size=2G --rw=randwrite --bs=4k --iodepth=16 --direct=1 --ioengine=libaio --runtime=60 --time_based --group_reporting | grep -E "IOPS|lat \(usec\)|clat percentiles" -A1 | head -8
sudo fio --name=t --filename=/storage/.fio --size=2G --rw=write --bs=1M --iodepth=8 --direct=1 --ioengine=libaio --runtime=30 --time_based --group_reporting | grep -E "bw=|IOPS"
sudo rm -f /storage/.fio; sudo dmesg -T | grep -iE "uas|reset|abort|error" | tail -5
```

Good: thousands of IOPS, write bandwidth in the hundreds of MB/s (USB 3 limit about 350–400 MB/s), **no**
`uas`/`reset`/`abort` lines in `dmesg`. If `dmesg` shows UAS resets, stop and paste it: the adapter and drive do
not get along (fix: a UAS quirk for that adapter, or another adapter model).

### A6. Configure the node and join k3s (pimaster)

```bash
cd ~/picluster
ssh-keygen -R node6; ssh-keygen -R 10.0.0.16
./ansible-runner/ansible-runner.sh bash -lc 'ssh-keygen -R node6; ssh-keygen -R 10.0.0.16' || true
./ansible-runner/ansible-runner.sh ansible node6 -m ping
./ansible-runner/ansible-runner.sh ansible-playbook setup_picluster.yml --tags node --limit node6
./ansible-runner/ansible-runner.sh ansible-playbook backup_configuration.yml --limit node6
./ansible-runner/ansible-runner.sh ansible-playbook k3s_install.yml --limit node6
./ansible-runner/ansible-runner.sh ansible-playbook update_node_config.yml --limit node6
```

### A7. Check (node2)

```bash
kubectl get node node6 -o wide                                   # Ready
kubectl -n longhorn-system get nodes.longhorn.io node6           # READY True, SCHEDULABLE True
kubectl -n longhorn-system get nodes.longhorn.io node6 -o json | jq -r '.status.diskStatus | to_entries[] | "\(.value.diskPath // .key) max=\(.value.storageMaximum/1e9|floor)G"'
kubectl get pods -A -o wide --field-selector spec.nodeName=node6 | grep -vE "Running|Completed"   # nothing
```

Longhorn creates node6's disk on `/storage` by itself (`defaultDataPath`). It is empty at first and fills as new
replicas are scheduled there; nothing else to do.

On node6, the SMART baseline for the progress table:
```bash
sudo apt-get install -y -qq --no-install-recommends smartmontools
sudo smartctl -i -H -A -d sat /dev/sda | grep -iE "model|serial|result|Percent|Total_LBAs|Wear"
```

On node6, TRIM (2.2, condition 5; the udev rule comes with `update_node_config.yml` in A6):
```bash
cat /sys/block/sda/device/scsi_disk/*/provisioning_mode          # unmap
lsblk -D -d -o NAME,DISC-GRAN,DISC-MAX /dev/sda                  # DISC-MAX 2G, not 0B
sudo fstrim -v /storage && sudo fstrim -v /                      # "... trimmed", no error
sudo dmesg -T | grep -iE "sda|uas|reset|i/o error" | tail        # no reset or I/O error
```

---

## 6. Procedure B: x86 worker (node-esp-1, node-esp-2)

Example for **node-esp-2**. The mini PC reinstalls itself over PXE: the autoinstall wipes `/dev/sda` and creates
`/` (80G LVM) and `/storage` (the rest), from `ansible/host_vars/node-esp-2.yml`.

### B1. Move Longhorn data off (node2)

As A1 with `N=node-esp-2`. Note: Elasticsearch and Prometheus have 2 replicas, one here; Longhorn rebuilds that
copy on another node (after node6's swap, its new disk). Wait for both numbers to reach 0.

### B2. Drain (node2) and power off (node-esp-2)

Pods move to node-esp-1 and the Pis. First do 4.2: scale down what is not needed, and cordon the Pis that still
have their old disks if node-esp-1 has room (`kubectl top nodes` below about 60% CPU; Prometheus prefers amd64
and will land on node-esp-1). Uncordon them after B6.

```bash
kubectl drain node-esp-2 --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=600s
kubectl get pods -A -o wide | grep -E "Pending|ContainerCreating|CrashLoop"   # wait until empty
```

On node-esp-2: `sudo poweroff`.

### B3. Remove the node (node2)

```bash
kubectl delete node node-esp-2
kubectl -n kube-system delete secret node-esp-2.node-password.k3s --ignore-not-found
kubectl -n longhorn-system delete nodes.longhorn.io node-esp-2
```

### B4. Swap the drive and reinstall over PXE

1. Fit the new SSD inside the mini PC.
2. pimaster: regenerate the autoinstall files (always before a node-esp reinstall):
   ```bash
   cd ~/picluster && make pxe-setup
   ```
3. Power on node-esp-2 and choose **network boot (PXE, IPv4)** in the boot menu. The autoinstall runs without
   questions (about 10–15 minutes) and reboots into Ubuntu.

### B5. Configure and join (pimaster)

```bash
cd ~/picluster
ssh-keygen -R node-esp-2
./ansible-runner/ansible-runner.sh bash -lc 'ssh-keygen -R node-esp-2' || true
./ansible-runner/ansible-runner.sh ansible node-esp-2 -m ping
./ansible-runner/ansible-runner.sh ansible-playbook setup_picluster.yml --tags node --limit node-esp-2
./ansible-runner/ansible-runner.sh ansible-playbook backup_configuration.yml --limit node-esp-2
./ansible-runner/ansible-runner.sh ansible-playbook k3s_install.yml --limit node-esp-2
./ansible-runner/ansible-runner.sh ansible-playbook update_node_config.yml --limit node-esp-2
```

`setup_picluster.yml` bind-mounts `/var/lib/rancher` on `/storage/rancher` on a fresh node-esp
(`rancher_storage_dir`), before k3s is installed. Check on node-esp-2: `findmnt /var/lib/rancher` shows
`/storage/rancher`.

### B6. Check (node2 and node-esp-2)

As A7 with `node-esp-2`; on node-esp-2 SMART without `-d sat`:
```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep -v loop        # / 80G, /storage the rest (~850G on 1 TB)
sudo smartctl -i -H -A /dev/sda | grep -iE "model|serial|result|Percent|Total_LBAs|Wear"
```

---

## 7. Procedure C: master (node4, node3, node2)

Example for **node4** (IP `10.0.0.14`). Masters hold no Longhorn data here, so there is no eviction step. etcd
runs with 2 of 3 members during the swap.

### C1. etcd snapshot first (node2; for node2's own swap, on node3)

```bash
sudo k3s etcd-snapshot save --name pre-swap-node4
sudo k3s etcd-snapshot list | tail -3
```

### C2. Drain, power off, remove (node2)

```bash
kubectl drain node4 --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=600s
```
On node4: `sudo poweroff`. Then on node2:
```bash
kubectl delete node node4
kubectl -n kube-system delete secret node4.node-password.k3s --ignore-not-found
sleep 30
kubectl get --raw='/readyz?verbose' | grep etcd          # [+]etcd ok
kubectl get nodes | grep control-plane                    # node2 and node3 Ready
```

Deleting the node also removes node4 from etcd (k3s does it). The API keeps working on node2 and node3.

### C3. Image the new SSD

As A4 with `$NODE = "node4"; $IP = "14"` (Linux: `prepare-node4`).

### C4. First boot

As A5 (the compatibility test is optional once node6 passed with the same drive model).

### C5. Configure and join as a **secondary** master (pimaster)

```bash
cd ~/picluster
ssh-keygen -R node4; ssh-keygen -R 10.0.0.14
./ansible-runner/ansible-runner.sh bash -lc 'ssh-keygen -R node4; ssh-keygen -R 10.0.0.14' || true
./ansible-runner/ansible-runner.sh ansible node4 -m ping
./ansible-runner/ansible-runner.sh ansible-playbook setup_picluster.yml --tags node --limit node4
./ansible-runner/ansible-runner.sh ansible-playbook backup_configuration.yml --limit node4
./ansible-runner/ansible-runner.sh ansible-playbook k3s_install.yml --limit node4 -e k3s_primary_control_node=false
./ansible-runner/ansible-runner.sh ansible-playbook update_node_config.yml --limit node4
```

**`-e k3s_primary_control_node=false` is mandatory, above all for node2** (the first master in the inventory):
a primary master gets `cluster-init: true` and would start a new, empty one-node cluster instead of joining.
Check on the swapped master before anything else:

```bash
sudo grep -nE "cluster-init|^server:" /etc/rancher/k3s/config.yaml    # must show server: https://...:6443, no cluster-init
```

If it shows `cluster-init`, stop k3s at once (`sudo systemctl stop k3s`) and paste it.

### C6. Check (node2; for node2's swap, node3)

```bash
kubectl get nodes | grep control-plane                    # three Ready
kubectl get --raw='/readyz?verbose' | grep etcd           # [+]etcd ok
kubectl -n kube-system get pods -o wide | grep -E "kube-vip|coredns|cilium-operator"
```

After node2's swap also: `make admin-cli` on pimaster (flux CLI on node2) and copy the kubeconfig if you use one
from node2.

Wait at least an hour between masters, and only with all three `Ready`.

---

## 8. Procedure D: node1 (clone, short downtime)

node1 runs Vault, RustFS (backups, Loki chunks) and DNS outside k3s, with no second instance, so it cannot be
swapped live. The old disk is **cloned** to the new one (data, keys and configuration stay as they are) and the
root filesystem is grown. Downtime about 30–45 minutes; plan it in the evening, not during a Velero backup
(02:00) or the Longhorn snapshot cleanup (03:30).

During the downtime: Vault is unreachable (external-secrets keeps the existing secrets, refreshes fail), Velero
and Loki cannot write to RustFS (Loki keeps its WAL and catches up), DNS answers from node1 stop.

### D1. Before (node1)

```bash
vault status | grep -E "Sealed|Version"         # note how you unseal it
sudo systemctl list-units --type=service | grep -iE "vault|rustfs|bind|named|haproxy"
lsusb | grep -vi hub
```

### D2. Clone (Linux machine with two USB 3 ports, e.g. the pimaster host)

1. On node1: `sudo poweroff`. Take out the old SSD (in its adapter).
2. Connect the **old** SSD and the **new** SSD (in a second adapter) to the Linux machine:
   ```bash
   lsblk -o NAME,SIZE,TRAN,MODEL,MOUNTPOINT          # identify OLD (223.6G) and NEW (931.5G for 1 TB) by size
   OLD=/dev/sdX; NEW=/dev/sdY                       # check twice: NEW is overwritten
   sudo dd if=$OLD of=$NEW bs=16M status=progress conv=fsync
   sudo sgdisk -e $NEW 2>/dev/null || true          # GPT: move the backup header to the end of the bigger disk
   sudo partprobe $NEW; lsblk $NEW
   sudo growpart $NEW 2                             # grow the root partition (partition 2) to the whole disk
   sudo e2fsck -f ${NEW}2
   sudo resize2fs ${NEW}2
   lsblk -o NAME,SIZE,MOUNTPOINT $NEW               # partition 2 about 930G (1 TB disk)
   ```
3. Put the new SSD (with node1's adapter) back on node1 and power on.

### D3. After (node1, then node2)

```bash
df -h /                                          # about 915G (1 TB disk)
vault status | grep Sealed                       # unseal if true (VAULT-001)
sudo systemctl --failed
```
On node2: `kubectl get externalsecrets -A | grep -v SecretSynced` (empty after a few minutes) and check that the
next Velero backup succeeds.

Keep the old node1 SSD untouched for a week as a fallback.

---

## 9. After phase 1

When node6, node-esp-2 and node5 run on new disks:

1. Give Elasticsearch and Prometheus their third replica back (node2). Leave the Keycloak Postgres and Loki write
   volumes at 1 replica (2.4):
   ```bash
   for v in pvc-a6e3a543-70ff-4bc5-a595-82bf0fcf9c45 pvc-e1c0c8e4-c16e-4a91-bf7c-0ebc0b68209b; do
     kubectl -n longhorn-system patch volumes.longhorn.io $v --type merge -p '{"spec":{"numberOfReplicas":3}}'
   done
   ```
2. Spread existing replicas over the bigger disks: Longhorn setting `replica-auto-balance` to `best-effort` (in
   `kubernetes/platform/longhorn/app/base/values.yaml`, `defaultSettings.replicaAutoBalance`), one PR.
3. SMART monitoring and a wear alert on every node (postmortem action 3c): **done 2026-11-22**
   (`DiskWornOut` at 80%, plus health, media error, CRC and write latency alerts; runbook
   [CLUSTER-018](../runbooks/cluster/nodes-capacity.md#runbook-cluster-018)). Phase 2 drives are bought when
   `DiskWornOut` fires for them.

   **Silence on the worn disks:** `DiskWornOut` is silenced for node4, node5, node6 and node-esp-2 from
   2026-11-22 until **2026-12-22 18:54 UTC** (Alertmanager silence `e33eec49`), so the known worn disks do not
   notify every 12 hours until they are swapped. It matches by node name only:

   - a **new disk** on those nodes starts near 0% wear and is far below the 80% threshold, so the silence hides
     nothing real after a swap;
   - the other alerts (`DiskMediaErrors`, `DiskCrcErrorsIncreasing`, `DiskWriteLatencyHigh`, `DiskSmartFailing`)
     are **not** silenced and still notify for these nodes;
   - if the 4 swaps are not done by 2026-12-22, extend it (node2):

     ```bash
     AM="kubectl -n kube-prom-stack exec alertmanager-kube-prometheus-stack-0 -c alertmanager -- amtool --alertmanager.url=http://localhost:9093"
     $AM silence query                                   # current silences and end dates
     $AM silence add alertname=DiskWornOut 'nodename=~"node4|node5|node6|node-esp-2"' --duration=30d --author=marmila --comment="Known worn disks, replacement planned"
     ```

     After the last of the 4 swaps, expire it early: `$AM silence expire e33eec49-ba6e-4267-99c4-d968f0e331d3`.

## 10. Progress

| # | Node | Adapter (`lsusb`) | New drive (model, serial) | Date | SMART baseline | Notes |
|---|---|---|---|---|---|---|
| 1 | node6 | StarTech `14b0:0207` | Crucial BX500 1 TB `CT1000BX500SSD1` (bought 24 Nov) | planned Sat 28 Nov | | |
| 2 | node-esp-2 | internal SATA | Samsung 870 EVO 1 TB `MZ-77E1T0B/EU` (bought 24 Nov) | planned Sun 29 Nov | | |
| 3 | node5 | StarTech `14b0:0207` (kept: tested OK 2026-11-22, CRC 92 not increasing) | Crucial BX500 1 TB (bought 24 Nov) | | | |
| 4 | node-esp-1 | internal SATA | | | | |
| 5 | node4 | StarTech `14b0:0206` | Crucial BX500 1 TB (bought 24 Nov) | | | |
| 6 | node3 | StarTech `14b0:0207` | | | | |
| 7 | node2 | StarTech `14b0:0207` | | | | |
| 8 | node1 | StarTech `14b0:0207` | | | | |

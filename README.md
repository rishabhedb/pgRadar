# 📡 PGRadar

> **PG** — PostgreSQL &nbsp;·&nbsp; **Radar** — scans, detects & surfaces what matters

**PGRadar** is a zero-dependency POSIX shell script that transforms [EDB Lasso](https://www.enterprisedb.com/docs/lasso/latest/) diagnostic bundles into a complete, self-contained HTML cluster health dashboard.

Point it at a folder of `.tar.bz2` bundles — one per node — and get a single HTML file you can open in any browser, share by zip, and read fully offline.

**No Python. No Node.js. No web server. Pure POSIX `sh`.**

---

## 📸 What It Looks Like

| Cluster Overview | Node Deep Dive | Long-Running Queries |
|---|---|---|
| All nodes compared side-by-side | 11 health panels per node | Sessions active > 5 min at collection time |

---

## ✨ Key Features

- **Multi-node tabbed dashboard** — Primary, Standby, and Witness each in their own tab
- **Cluster Overview** — all nodes compared side-by-side: role, CPU, RAM, connections, XID age, EFM status
- **11 health panels** per node covering every operational dimension
- **EDB formula-based parameter remarks** — `shared_buffers`, `work_mem`, `max_connections` evaluated against your server's actual RAM and CPU cores, not generic thresholds
- **Header-aware column detection** — works across EDB EPAS and standard PostgreSQL regardless of column order or version differences
- **Long-Running Query detection** — sessions active > 5 minutes at collection time, timezone-aware
- **Light / Dark mode** — toggle persisted to `localStorage`
- **Font size ruler** — A ▐▌ A slider (11–18 pt) for accessibility, also persisted
- **Collection staleness badge** — topbar turns green → amber → red ⚠ so recipients know how old the data is
- **Tabular sub-pages** — drill-down pages for connections, replication, slots, config, and table statistics
- **Lasso File Explorer** — browse every raw file in the bundle directly in the browser with TSV auto-detection and Copy for Excel
- **Fully offline** — single self-contained HTML file, works over `file://` protocol

---

## 📥 Installation

Install PGRadar with a single command — downloads the binary directly from GitHub into your current directory:

```bash
curl -sSfL https://raw.githubusercontent.com/rishabhedb/pgRadar/main/install.sh | sh
```

Or download and inspect the installer first:

```bash
curl -sSfL https://raw.githubusercontent.com/rishabhedb/pgRadar/main/install.sh -o install.sh
sh install.sh
```

The installer will:
1. Download the `pgRadar` binary from this repository
2. Place it in your **current working directory**
3. Make it executable with `chmod +x`

---

## 🚀 Quick Start

```bash
# 1. Collect EDB Lasso bundles from each node in your cluster
#    Each node produces one .tar.bz2 file

# 2. Place all bundles in one folder and run PGRadar
sh pgRadar /path/to/folder-with-bundles/

# If the folder is in your current directory, just use the folder name
sh pgRadar 6234

# 3. Open the generated dashboard in any browser
open 6234/PGRADAR_OUTPUT/pgradar-report_<timestamp>.html
```

To share the report, zip the output folder:

```bash
zip -r cluster-report.zip PGRADAR_OUTPUT/
# Recipient opens the HTML — no tools needed
```

---

## 📋 Requirements

| Component | Notes |
|---|---|
| `/bin/sh` | `bash`, `zsh`, or `dash` — any POSIX-compliant shell |
| `awk` | mawk, gawk, or BSD awk |
| `tar` | With bzip2 support |
| `find`, `grep`, `sed`, `cut`, `date` | Standard UNIX utilities |
| **EDB Lasso bundles** | One `.tar.bz2` per cluster node |

Tested on **RHEL 8/9**, **Ubuntu 22/24 LTS**, and **macOS 13+**.

---

## 📁 Output Structure

```
PGRADAR_OUTPUT/
├── pgradar-report_<timestamp>.html        ← Main dashboard — open this
└── pgradar-assets_<timestamp>/
    ├── nodes_meta.txt                      ← Node inventory (role, host, path)
    └── <node_id>/
        ├── conn_act.html                   ← Active sessions drill-down
        ├── conn_idl.html                   ← Idle sessions
        ├── conn_itx.html                   ← Idle-in-TX sessions
        ├── conn_raw.html                   ← Full running_activity.out table
        ├── repl_tbl.html                   ← Replication status table
        ├── slots_tbl.html                  ← Replication slots table
        ├── tables_<dbname>.html            ← pg_stat_user_tables per database
        ├── cfg_postgresql.html             ← postgresql.conf viewer
        ├── cfg_auto.html                   ← postgresql.auto.conf viewer
        └── pgradar_tree.html               ← Full Lasso file explorer
```

---

## 🔍 The 11 Monitoring Panels

| # | Panel | Key Information |
|---|---|---|
| 1 | 🌐 **Cluster Overview** | All nodes: role badge, VIP, EFM service status, PG version, CPU %, RAM free, connections, XID age, forced checkpoint % |
| 2 | 🔌 **Connection Donuts** | Active / Idle / Idle-TX session counts with `max_connections` usage bar and drill-down links |
| 3 | 🐘 **PostgreSQL Parameters** | 20 key settings with EDB formula-based remarks for `shared_buffers`, `work_mem`, `maintenance_work_mem`, `max_connections` |
| 4 | 🔄 **Replication Information** | Lag cards (worst non-null across all standbys), per-standby LSN byte gap, write/flush/replay lag, slot status |
| 5 | 💿 **Disk Space** | All mount points with usage bars coloured at 80% (amber) and 90% (red) |
| 6 | ⚠️ **XID Wraparound Risk** | Per-database: age, size, connection count, % toward the 2-billion transaction limit with autovacuum freeze threshold |
| 7 | 🗃 **Top Table Bloat** | Top 5 tables by dead tuple ratio, plus full `pg_stat_user_tables` sub-pages per database |
| 8 | ⏰ **Long-Running Queries** | Sessions active > 5 minutes at collection time, sorted longest-first, WAL sender processes excluded |
| 9 | 🧠 **OS Memory Pressure** | Huge pages configuration, swap usage and pressure, OOM killer events from `dmesg` |
| 10 | 🔒 **Blocking & Lock Analysis** | Full blocking chains, lock mode breakdown, wait event aggregation, root-cause verdict |
| 11 | 🛡️ **EFM Cluster Health** | Service status per node, cluster topology, `auto.failover` and `promotable` configuration verdict |

---

## 🔎 How Node Roles Are Detected

PGRadar automatically identifies Primary, Standby, and Witness nodes using these signals in priority order:

| Priority | Signal | How It Works |
|---|---|---|
| 1 | **`cluster_status.out`** (EFM) | Explicitly lists each node's role and IP — most reliable |
| 2 | **`pg_stat_replication.out`** | If populated, the node is sending WAL to standbys → **Primary** |
| 3 | **`standby.signal`** (PG 12+) | File present in data directory → **Standby** |
| 3 | **`recovery.conf`** (PG 11 and older) | File present in data directory → **Standby** |
| 4 | **`recovery.done`** | Was a standby, now promoted → **Primary** |
| 5 | **No PG activity files** | EFM files present but no PostgreSQL data → **Witness** |

---

## 📊 Lasso Files Consumed

PGRadar reads the following files from each Lasso bundle:

| File | Used For |
|---|---|
| `edb-lasso-report.log` | Collection timestamp (fallback) |
| `running_activity.out` | Connections panel, Long-Running Queries (`actual_time` column used as collection epoch) |
| `replication.out` | Replication lag cards and per-standby details |
| `replication_slots.out` | Slot status, inactive slot detection |
| `configuration.out` | PostgreSQL parameter panel and formula-based remarks |
| `databases.out` | XID wraparound risk per database |
| `blocking_locks.out` | Blocking chain analysis |
| `running_locks.out` | Lock mode breakdown |
| `running_waits_sample.out` | Wait event aggregation |
| `diskspace.data` | Disk space panel |
| `meminfo.data` | Memory pressure panel, overview RAM metrics |
| `cpuinfo.data` | CPU model and core count |
| `top.data` | CPU usage %, load average (1/5/15 min) |
| `dmesg.data` | OOM killer event detection |
| `pg_stat_bgwriter.data` | Checkpoint forced ratio |
| `cluster_status.out` | EFM topology and role detection |
| `efm.properties` | EFM configuration verdict (`auto.failover`, `promotable`) |
| `standby.signal` / `recovery.conf` | Standby role detection |
| `os_release.data` | OS version display |
| `postgresql_server_version.data` | PostgreSQL version display |
| `dbs/*/tables.out` | Per-database table bloat sub-pages |

---

## 🧠 Technical Notes

### macOS Compatibility

PGRadar is fully tested on macOS. Key differences from Linux that are handled internally:

- **`date -d` not available** — `date -j -f "%Y-%m-%d %H:%M:%S"` is used as fallback everywhere
- **BSD awk file argument behaviour** — on macOS, `awk` ignores named file arguments when stdin is consumed inside compound shell redirects. Fixed by writing awk output directly to named temp files rather than using subshells
- **`IFS='\t'` portability** — literal tab characters are embedded in the script rather than the `\t` escape sequence, which is not portable in single-quoted POSIX sh strings

### Collection Timestamp

Long-Running Query durations are calculated against the `actual_time` column in `running_activity.out` — the exact moment Lasso captured the data — rather than the lasso log timestamp. This ensures accurate durations even when the lasso log date is stale or recorded in a different timezone.

### Column Detection

Every file parser resolves columns by name from the header row — not by hardcoded position numbers. Key examples:

| Column name | Used for |
|---|---|
| `status` or `state` | Connection state filtering in LRQ and connections panels |
| `query_start` | LRQ duration calculation |
| `datage` or `age` | XID wraparound risk calculation |
| `write_lag`, `flush_lag`, `replay_lag` | Replication lag cards |
| `actual_time` | Collection epoch for LRQ |

This means the script works correctly regardless of column order changes between EDB EPAS and standard PostgreSQL versions.

---

## 🗺️ Roadmap

The following tools are planned for future releases. **SME input is needed** — if you have domain knowledge in any of these tools, please open an issue or discussion describing which metrics and checks matter most during incidents.

| Tool | What Would Be Added |
|---|---|
| **PEM** (Postgres Enterprise Manager) | Agent-based metrics, dashboard alerts, query analysis, server catalogue |
| **Barman** | Backup catalogue status, WAL retention gaps, RPO/RTO metrics, last successful backup age |
| **Pgpool** | Pool status, backend health cards, load balancing stats, failover configuration verdicts |

---

## 📄 License

MIT License. See [LICENSE](LICENSE) for full terms.

---


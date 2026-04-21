#!/bin/sh
# =============================================================================
# PGRadar — PostgreSQL Lasso Dashboard Generator
# Version : 2.4
# Purpose : Scans a folder for one or more Lasso bundles (.tar.bz2), extracts
#           each one automatically, detects whether each node is a Primary,
#           Standby or Witness, and builds a single tabbed HTML dashboard —
#           one tab per node plus a Cluster Overview comparison tab.
#
# Usage   : sh pgRadar.sh /path/to/folder-containing-tar-bundles
#
# What the folder should look like:
#   my-cluster/
#     edb-lasso-primary.tar.bz2
#     edb-lasso-standby.tar.bz2
#     edb-lasso-witness.tar.bz2
#
# Output  : pgradar-report_<timestamp>.html  (single self-contained file)
#           pgradar-assets_<timestamp>/       (linked sub-pages)
# =============================================================================

VERSION="2.4"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# =============================================================================
# STEP 1 — Accept the folder path that contains the .tar.bz2 bundle files
# =============================================================================
if [ -n "$1" ]; then
    BUNDLE_DIR="$1"
else
    printf "Enter path to folder containing Lasso .tar.bz2 bundles: "
    read -r BUNDLE_DIR
fi

[ ! -d "$BUNDLE_DIR" ] && printf "\033[1;31mERROR:\033[0m Directory not found: %s\n" "$BUNDLE_DIR" && exit 1


# Resolve to absolute path so file:// URLs work regardless of how the folder was specified
BUNDLE_DIR=$(cd "$BUNDLE_DIR" && pwd)


# Count how many .tar.bz2 files exist in that folder
BUNDLE_COUNT=$(find "$BUNDLE_DIR" -maxdepth 1 -name "*.tar.bz2" | wc -l | tr -d ' ')
if [ "$BUNDLE_COUNT" -eq 0 ]; then
    printf "\033[1;31mERROR:\033[0m No .tar.bz2 files found in %s\n" "$BUNDLE_DIR"
    exit 1
fi

# =============================================================================
# STEP 2 — Progress bar (same design as the single-node script)
# =============================================================================
# Total steps = 3 (extract) + 3 (per-node data) + 1 (build HTML) + 1 (done) = ~10
_STEPS=10; _STEP=0; _PB_WIDTH=40

pb_draw() {
    _pct=$(( _STEP * 100 / _STEPS ))
    _filled=$(( _STEP * _PB_WIDTH / _STEPS ))
    _bar=""; _i=0
    while [ "$_i" -lt "$_filled" ]; do _bar="${_bar}█"; _i=$((_i+1)); done
    while [ "$_i" -lt "$_PB_WIDTH" ]; do _bar="${_bar}░"; _i=$((_i+1)); done
    printf "\r  \033[1;36m[%s]\033[0m \033[1m%3d%%\033[0m  %-42s" "$_bar" "$_pct" "$1"
}
pb_step() { _STEP=$((_STEP+1)); pb_draw "$1"; }
pb_done()  { _STEP=$_STEPS; pb_draw "Complete!"; printf "\n"; }

printf "\n\033[1;34m  PGRadar — Cluster Health Dashboard Generator v%s\033[0m\n" "$VERSION"
printf "  Folder  : \033[0;33m%s\033[0m\n" "$BUNDLE_DIR"
printf "  Bundles : \033[0;33m%d .tar.bz2 file(s) found\033[0m\n\n" "$BUNDLE_COUNT"
pb_draw "Starting..."

# =============================================================================
# STEP 3 — Create output paths inside user's folder under PGRADAR_OUTPUT/
# All generated files go into: <BUNDLE_DIR>/PGRADAR_OUTPUT/
# This keeps the user's original .tar.bz2 files separate from generated output.
# =============================================================================
DASHBOARD_ROOT="${BUNDLE_DIR}/PGRADAR_OUTPUT"
mkdir -p "$DASHBOARD_ROOT"

OUTFILE="${DASHBOARD_ROOT}/pgradar-report_${TIMESTAMP}.html"
ASSETS_DIR="${DASHBOARD_ROOT}/pgradar-assets_${TIMESTAMP}"
EXTRACT_DIR="${ASSETS_DIR}/extracted"
mkdir -p "$ASSETS_DIR" "$EXTRACT_DIR"

# =============================================================================
# HELPER FUNCTIONS  (shared across all nodes)
# =============================================================================

# htmlesc: makes text safe to embed inside HTML
htmlesc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# sanitise: makes a string safe for use in filenames and HTML IDs
sanitise() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//'; }

# get_gb_from: reads a meminfo field (in kB) from a specific file and returns GB
# Usage: get_gb_from "/path/to/meminfo.data" "MemTotal"
get_gb_from() {
    _f="$1"; _field="$2"
    _kb=$(grep "^${_field}" "$_f" 2>/dev/null | awk '{print $2}')
    [ -n "$_kb" ] && echo "$_kb" | awk '{printf "%.2f", $1/1024/1024}' || echo "0"
}

# svg_donut: generates a pure SVG doughnut chart — no JS, no CDN, works offline
# Arguments: label centerVal centerSub seg1:color1:lbl1 seg2:color2:lbl2 ...
svg_donut() {
    _cval="$2"; _csub="$3"; shift 3
    _segs=""
    for _s in "$@"; do _segs="${_segs}${_s}\n"; done
    printf '%b' "$_segs" | awk -v cval="$_cval" -v csub="$_csub" '
    BEGIN { PI=3.14159265358979; R=80; r=54; cx=100; cy=100; total=0; n=0 }
    NF>0 { split($0,a,":"); val[n]=(a[1]+0>0)?a[1]+0:0.001; color[n]=a[2]; total+=val[n]; n++ }
    END {
        sw=R-r
        printf "<svg viewBox=\"0 0 200 200\" xmlns=\"http://www.w3.org/2000/svg\" style=\"width:100%%;height:100%%;display:block;\">"
        printf "<circle cx=\"%d\" cy=\"%d\" r=\"%d\" fill=\"none\" stroke=\"#1e2633\" stroke-width=\"%d\"/>",cx,cy,R,sw
        angle=-90
        for(i=0;i<n;i++){
            pct=val[i]/total; sweep=pct*360
            sx=cx+R*cos(angle*PI/180); sy=cy+R*sin(angle*PI/180)
            angle+=sweep
            ex=cx+R*cos(angle*PI/180); ey=cy+R*sin(angle*PI/180)
            large=(sweep>180)?1:0
            printf "<path d=\"M %f %f A %d %d 0 %d 1 %f %f\" fill=\"none\" stroke=\"%s\" stroke-width=\"%d\" stroke-linecap=\"butt\"/>",sx,sy,R,R,large,ex,ey,color[i],sw
        }
        vlen=length(cval); fs=(vlen<=5)?18:(vlen<=7)?15:(vlen<=9)?13:11; mw=88
        tl=(vlen>5) ? sprintf(" textLength=\"%d\" lengthAdjust=\"spacingAndGlyphs\"",mw) : ""
        printf "<text x=\"100\" y=\"94\" text-anchor=\"middle\" font-family=\"JetBrains Mono,monospace\" font-size=\"%d\" font-weight=\"bold\" fill=\"%s\"%s>%s</text>",fs,color[0],tl,cval
        printf "<text x=\"100\" y=\"114\" text-anchor=\"middle\" font-family=\"Inter,sans-serif\" font-size=\"11\" fill=\"#8b949e\">%s</text>",csub
        printf "</svg>"
    }'
}

# write_tabular_asset: creates a styled HTML table sub-page for a data file.
# The back link uses a URL hash (#pane-<node_id>) so clicking "Back to Dashboard"
# returns the user to exactly the right node tab, not just the top of the page.
#
# Args: output_file title source_file filter_string node_id
write_tabular_asset() {
    _fp="$1"; _title="$2"; _src="$3"; _filter="$4"; _nid="$5"
    # Build the back URL: two levels up from assets_xxx/nodeid/ to reach PGRADAR_OUTPUT/
    _home="../../$(basename "$OUTFILE")#pane-${_nid}"
    _raw_link="$(basename "$_fp" .html)_raw.html"

    # ── Raw view sub-page ──
    cat > "$(dirname "$_fp")/$_raw_link" <<RAWEOF
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"/>
<title>Raw — $(basename "$_src")</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400&display=swap');
  *{box-sizing:border-box;margin:0;padding:0;}
  body{background:#0d1117;color:#e6edf3;font-family:'Inter',system-ui,sans-serif;font-size:13px;}
  .nav{background:#161b22;border-bottom:1px solid #30363d;padding:12px 20px;display:flex;align-items:center;gap:10px;position:sticky;top:0;z-index:10;}
  .nav-title{font-size:13px;font-weight:600;color:#e6edf3;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
  .btn{display:inline-flex;align-items:center;gap:6px;padding:6px 14px;border-radius:7px;text-decoration:none;font-size:12px;font-weight:600;white-space:nowrap;border:1px solid;transition:opacity .15s;}
  .btn:hover{opacity:.85;}
  .btn-back{background:#21262d;color:#e6edf3;border-color:#30363d;}
  .btn-tbl{background:#2f81f7;color:#fff;border-color:#2f81f7;}
  .content{padding:24px;}
  .file-label{font-family:'JetBrains Mono',monospace;font-size:11px;color:#8b949e;margin-bottom:12px;}
  pre{font-family:'JetBrains Mono',monospace;font-size:11px;line-height:1.8;color:#adbac7;background:#161b22;border:1px solid #30363d;border-radius:8px;padding:16px 20px;overflow-x:auto;white-space:pre;}
</style></head><body>
<div class="nav">
  <button class="btn btn-back" onclick="if(window.history.length>1){window.history.back();}else{window.location.href='$_home';}">← Back to Dashboard</button>
  <span class="nav-title">$(basename "$_src") — Raw View</span>
  <a href="$(basename "$_fp")" class="btn btn-tbl" target="_self">⊞ Table View</a>
</div>
<div class="content">
  <div class="file-label">$(basename "$_src")</div>
  <pre>$(cat "$_src" | htmlesc)</pre>
</div>
</body></html>
RAWEOF

    # ── Tabular view sub-page ──
    cat > "$_fp" <<TBLEOF
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"/>
<title>$_title</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400&display=swap');
  *{box-sizing:border-box;margin:0;padding:0;}
  body{background:#0d1117;color:#e6edf3;font-family:'Inter',system-ui,sans-serif;font-size:13px;}
  .nav{background:#161b22;border-bottom:1px solid #30363d;padding:12px 20px;display:flex;align-items:center;gap:10px;position:sticky;top:0;z-index:10;}
  .nav-title{font-size:13px;font-weight:600;color:#e6edf3;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
  .btn{display:inline-flex;align-items:center;gap:6px;padding:6px 14px;border-radius:7px;text-decoration:none;font-size:12px;font-weight:600;white-space:nowrap;border:1px solid;transition:opacity .15s;}
  .btn:hover{opacity:.85;}
  .btn-back{background:#21262d;color:#e6edf3;border-color:#30363d;}
  .btn-raw{background:#21262d;color:#8b949e;border-color:#30363d;}
  .content{padding:20px 24px;}
  .tbl-title{font-size:14px;font-weight:600;color:#e6edf3;margin-bottom:4px;}
  .tbl-sub{font-family:'JetBrains Mono',monospace;font-size:10px;color:#8b949e;margin-bottom:16px;}
  .tbl-wrap{overflow-x:auto;border:1px solid #30363d;border-radius:8px;}
  table{border-collapse:collapse;width:max-content;min-width:100%;}
  thead th{background:#161b22;color:#8b949e;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.5px;padding:10px 16px;text-align:left;border-bottom:1px solid #30363d;white-space:nowrap;}
  tbody td{padding:9px 16px;border-bottom:1px solid #21262d;color:#c9d1d9;font-family:'JetBrains Mono',monospace;font-size:11px;white-space:nowrap;vertical-align:middle;}
  tbody tr:last-child td{border-bottom:none;}
  tbody tr:hover{background:#161b22;}
  .empty{padding:32px;text-align:center;color:#8b949e;font-size:12px;}
  /* Two-column key=value properties layout (efm.properties etc) */
  .prop-tbl{table-layout:fixed;width:100%;}
  .prop-tbl thead th:first-child{width:260px;}
  .prop-tbl thead th:last-child{width:auto;}
  .prop-tbl tbody td{white-space:normal;word-break:break-all;}
  .prop-tbl tbody td:first-child{color:#79c0ff;white-space:nowrap;font-weight:600;}
  .prop-tbl tbody td:last-child{color:#e6edf3;}
</style></head><body>
<div class="nav">
  <button class="btn btn-back" onclick="if(window.history.length>1){window.history.back();}else{window.location.href='$_home';}">← Back to Dashboard</button>
  <span class="nav-title">$_title</span>
  <a href="$_raw_link" class="btn btn-raw" target="_self">≡ Raw File</a>
</div>
<div class="content">
  <div class="tbl-title">$_title</div>
  <div class="tbl-sub">$(basename "$_src")</div>
  <div class="tbl-wrap">
TBLEOF
    # For properties files (two-column key/value): use prop-tbl fixed layout
    if echo "$_fp" | grep -q "efm.properties\|\.conf\.html\|\.properties\.html"; then
        echo '  <table class="prop-tbl"><thead><tr>' >> "$_fp"
    else
        echo '  <table><thead><tr>' >> "$_fp"
    fi
    head -n 1 "$_src" | tr '	' '\n' | while read -r col; do
        printf '<th>%s</th>' "$(echo "$col" | htmlesc)" >> "$_fp"
    done
    echo "</tr></thead><tbody>" >> "$_fp"
    _rows=0
    grep -Fi "$_filter" "$_src" | tr -d '\r' | while IFS='	' read -r line_data; do
        echo "<tr>" >> "$_fp"
        echo "$line_data" | sed 's/	/<\/td><td>/g; s/^/<td>/; s/$/<\/td>/' >> "$_fp"
        echo "</tr>" >> "$_fp"
        _rows=$((_rows+1))
    done
    echo "</tbody></table></div>" >> "$_fp"
    echo "</div></body></html>" >> "$_fp"
}

# pg_remark: formula-based badge + remark for each PostgreSQL parameter
# Args: $1=param  $2=current_value  $3=node_role  $4=ram_gb  $5=cpu_cores  $6=autovacuum_max_workers
#
# Three memory parameters use actual server RAM from meminfo.data:
#
#   shared_buffers  — EDB formula:
#       base = RAM / 4
#       if RAM < 3 GB:  base × 0.5
#       if RAM < 8 GB:  base × 0.75
#       if RAM > 64 GB: greatest(16 GB, RAM/6)
#       ideal = least(base, 64 GB)
#
#   work_mem  — EDB formula:
#       ideal = (RAM - shared_buffers) / (16 × cpu_cores)
#
#   maintenance_work_mem  — EDB formula:
#       ideal = 15% × (RAM - shared_buffers) / autovacuum_max_workers
#       capped at 1 GB per worker
pg_remark() {
    _param="$1"; _val="$2"; _node_role="${3:-Primary}"
    _ram_gb="${4:-0}"; _cpu_cores="${5:-1}"; _avm="${6:-3}"; _max_conn="${7:-100}"

    # Convert a PG memory value with unit to MB
    # e.g. 25GB→25600, 512MB→512, 128kB→0
    _to_mb() {
        echo "$1" | awk '{
            v=$1; n=v+0;
            if      (v ~ /[Gg][Bb]$/) n=n*1024;
            else if (v ~ /[Kk][Bb]$/) n=n/1024;
            printf "%d", n
        }'
    }

    # Format MB back to human-readable: >= 1024 → GB, else MB
    _fmt_mb() {
        echo "$1" | awk '{
            if ($1>=1024) printf "%.0f GB", $1/1024;
            else           printf "%d MB", $1
        }'
    }

    # ── Compute EDB ideal values from the actual server RAM ──
    # All intermediate values in MB
    _ram_mb=$(echo "$_ram_gb" | awk '{printf "%d", $1*1024}')
    _cores=$(echo "$_cpu_cores" | awk '{v=$1+0; if(v<1)v=1; print v}')
    _workers=$(echo "$_avm" | awk '{v=$1+0; if(v<1)v=1; print v}')

    # shared_buffers ideal (EDB formula from screenshot)
    _sb_ideal_mb=$(echo "$_ram_mb" | awk '{
        ram=$1; base=ram/4;
        if (ram < 3*1024)       base=base*0.5;
        else if (ram < 8*1024)  base=base*0.75;
        else if (ram > 64*1024) { alt=ram/6; if(alt<16*1024) alt=16*1024; base=alt; }
        if (base > 64*1024) base=64*1024;
        printf "%d", base
    }')
    _sb_ideal=$(_fmt_mb "$_sb_ideal_mb")

    # work_mem ideal: (RAM - shared_buffers) / (16 × cpu_cores)
    # Use actual shared_buffers value if available, else use ideal
    _sb_actual_mb=$(_to_mb "$_val")
    [ "$_param" != "shared_buffers" ] && _sb_actual_mb=$(_to_mb "$(echo "$_ram_mb" | awk '{printf "%d MB",$1}')")
    _wm_ideal_mb=$(echo "$_ram_mb $_sb_ideal_mb $_cores" | awk '{
        free=$1-$2; if(free<0)free=0;
        ideal=free/(16*$3);
        if(ideal<4) ideal=4;
        printf "%d", ideal
    }')
    _wm_ideal=$(_fmt_mb "$_wm_ideal_mb")

    # maintenance_work_mem ideal: 15% × (RAM - shared_buffers) / autovacuum_max_workers, cap 1GB/worker
    _mwm_ideal_mb=$(echo "$_ram_mb $_sb_ideal_mb $_workers" | awk '{
        free=$1-$2; if(free<0)free=0;
        ideal=(free*0.15)/$3;
        cap=1024;
        if(ideal>cap) ideal=cap;
        if(ideal<64) ideal=64;
        printf "%d", ideal
    }')
    _mwm_ideal=$(_fmt_mb "$_mwm_ideal_mb")

    case "$_param" in

        # ── wal_level ──────────────────────────────────────────────────────────
        wal_level)
            case "$_val" in
                logical) echo "<span class='badge-ok'>✔ Optimal — ideal is logical; enables streaming + logical replication &amp; CDC</span>" ;;
                replica) echo "<span class='badge-warn'>⚠ replica — sufficient for streaming only; upgrade to logical to support CDC and logical slots</span>" ;;
                minimal) echo "<span class='badge-bad'>✘ Below minimum — ideal is logical; minimal disables replication entirely; WAL is not shipped to standbys</span>" ;;
                ""|"[Not Set]") echo "<span class='badge-bad'>✘ Not set — ideal is logical; default minimal disables replication</span>" ;;
                *)       echo "<span class='badge-bad'>✘ Unrecognised value — ideal is logical</span>" ;;
            esac ;;

        # ── max_wal_senders ────────────────────────────────────────────────────
        # Ideal: ≥ 8  (standbys + slots + backup tool + 1 spare)
        max_wal_senders)
            _n=$(echo "$_val" | tr -d '[:space:]')
            if   [ "$_n" -ge 20 ] 2>/dev/null; then echo "<span class='badge-warn'>⚑ ${_val} — well above ideal (8); acceptable if many replicas/slots, but review unused capacity</span>"
            elif [ "$_n" -ge 8  ] 2>/dev/null; then echo "<span class='badge-ok'>✔ ${_val} — meets ideal (≥ 8 = standbys + slots + backup tool + 1 spare)</span>"
            elif [ "$_n" -ge 3  ] 2>/dev/null; then echo "<span class='badge-warn'>⚠ ${_val} — below ideal; formula: standbys + slots + backup + 1 spare → recommend ≥ 8; may block new replicas</span>"
            elif [ "$_n" -ge 1  ] 2>/dev/null; then echo "<span class='badge-bad'>✘ ${_val} — critically low; ideal ≥ 8; replication or PITR will fail under any load</span>"
            else                                     echo "<span class='badge-bad'>✘ 0 or unset — ideal ≥ 8; WAL senders disabled; no replication possible</span>"
            fi ;;

        # ── max_replication_slots ──────────────────────────────────────────────
        # Ideal: ≥ max_wal_senders (8–10)
        max_replication_slots)
            _n=$(echo "$_val" | tr -d '[:space:]')
            if   [ "$_n" -ge 20 ] 2>/dev/null; then echo "<span class='badge-warn'>⚑ ${_val} — above ideal (8–10); unused slots retain WAL and fill disk; review</span>"
            elif [ "$_n" -ge 8  ] 2>/dev/null; then echo "<span class='badge-ok'>✔ ${_val} — meets ideal; should equal max_wal_senders; each replica and backup tool needs one slot</span>"
            elif [ "$_n" -ge 3  ] 2>/dev/null; then echo "<span class='badge-warn'>⚠ ${_val} — below ideal; recommend ≥ 8 (= max_wal_senders); insufficient slots cause replication failures at failover</span>"
            else                                     echo "<span class='badge-bad'>✘ ${_val} or unset — ideal ≥ 8; slots exhausted; standbys and backup tools cannot connect</span>"
            fi ;;

        # ── hot_standby ────────────────────────────────────────────────────────
        hot_standby)
            case "$_node_role" in
                Primary|Witness)
                    echo "<span class='badge-info'>Applies to Standby role only — no action needed on ${_node_role}</span>" ;;
                *)
                    case "$_val" in
                        on)  echo "<span class='badge-ok'>✔ on — ideal; standby accepts read-only queries, enabling read offload</span>" ;;
                        off) echo "<span class='badge-bad'>✘ off — ideal is on for Standby; all read queries are blocked; set hot_standby = on</span>" ;;
                        ""|"[Not Set]") echo "<span class='badge-bad'>✘ Not set — ideal is on; default off blocks all queries on Standby</span>" ;;
                        *)   echo "<span class='badge-info'>—</span>" ;;
                    esac ;;
            esac ;;

        # ── archive_mode ───────────────────────────────────────────────────────
        archive_mode)
            case "$_node_role" in
                Standby) echo "<span class='badge-info'>Standby — archiving runs on Primary; no action needed here unless archive_mode = always is desired for cascading</span>" ;;
                Witness) echo "<span class='badge-info'>Witness — no database; does not apply</span>" ;;
                *)
                    case "$_val" in
                        on)     echo "<span class='badge-ok'>✔ on — ideal for Primary; WAL archiving active; enables PITR recovery</span>" ;;
                        always) echo "<span class='badge-ok'>✔ always — archives on Primary and Standby; strongest PITR coverage</span>" ;;
                        off)    echo "<span class='badge-bad'>✘ off — ideal is on for Primary; no WAL archiving means PITR is impossible; set archive_mode = on</span>" ;;
                        ""|"[Not Set]") echo "<span class='badge-bad'>✘ Not set — ideal is on for Primary; default off disables PITR</span>" ;;
                        *)      echo "<span class='badge-warn'>⚠ Unknown value — ideal is on</span>" ;;
                    esac ;;
            esac ;;

        # ── archive_command ────────────────────────────────────────────────────
        archive_command)
            case "$_node_role" in
                Standby) echo "<span class='badge-info'>ℹ Not required on Standby — archiving runs on Primary; leave empty here</span>" ;;
                Witness) echo "<span class='badge-info'>Witness — no database; does not apply</span>" ;;
                *)
                    if [ -z "$_val" ] || [ "$_val" = "''" ] || [ "$_val" = '""' ] || [ "$_val" = "[Not Set]" ]; then
                        echo "<span class='badge-bad'>✘ Empty — set a valid command e.g. cp %p /archive/%f or pgbackrest archive-push %p; without this archiving silently fails even when archive_mode = on</span>"
                    else
                        echo "<span class='badge-ok'>✔ Configured — ensure destination is reachable and has sufficient disk space</span>"
                    fi ;;
            esac ;;

        # ── wal_keep_size ──────────────────────────────────────────────────────
        # Ideal: 1 GB – 10 GB
        wal_keep_size)
            _mb=$(_to_mb "$_val")
            if   [ "$_mb" -ge 10240 ] 2>/dev/null; then echo "<span class='badge-warn'>⚑ ${_val} — above typical ideal (1–10 GB); only needed if standbys lag heavily; verify disk capacity</span>"
            elif [ "$_mb" -ge 1024  ] 2>/dev/null; then echo "<span class='badge-ok'>✔ ${_val} — within ideal range (1–10 GB); sufficient buffer for standby reattachment after short outages</span>"
            elif [ "$_mb" -gt 0     ] 2>/dev/null; then echo "<span class='badge-warn'>⚠ ${_val} — below ideal; recommend ≥ 1 GB; a standby lagging during WAL flush may disconnect permanently</span>"
            else                                         echo "<span class='badge-bad'>✘ 0 or unset — ideal ≥ 1 GB; no WAL retained; any replication lag causes permanent standby disconnect requiring pg_rewind or re-clone</span>"
            fi ;;

        # ── listen_addresses ───────────────────────────────────────────────────
        listen_addresses)
            case "$_val" in
                "'*'"|"*")  echo "<span class='badge-warn'>⚑ * — functional but broad; ideal is specific IPs; restrict access via pg_hba.conf and firewall</span>" ;;
                localhost)  echo "<span class='badge-bad'>✘ localhost — ideal is node IP or *; current value blocks all remote connections including standby replication</span>" ;;
                ""|"[Not Set]") echo "<span class='badge-bad'>✘ Not set — ideal is * or specific host IP; default blocks all remote connections</span>" ;;
                *)          echo "<span class='badge-ok'>✔ Specific address set — ideal practice; ensure replication and EFM IPs are included</span>" ;;
            esac ;;

        # ── port ───────────────────────────────────────────────────────────────
        port)
            case "$_val" in
                5432)           echo "<span class='badge-info'>Standard PostgreSQL port — ensure efm.properties db.port = 5432</span>" ;;
                5444)           echo "<span class='badge-info'>EDB EPAS default port — ensure efm.properties db.port = 5444</span>" ;;
                ""|"[Not Set]") echo "<span class='badge-warn'>⚠ Not set — defaults to 5432; ensure efm.properties db.port matches</span>" ;;
                *)              echo "<span class='badge-info'>Custom port ${_val} — ensure efm.properties db.port = ${_val}</span>" ;;
            esac ;;

        # ── shared_buffers ─────────────────────────────────────────────────────
        # EDB formula (from screenshot):
        #   base = RAM / 4
        #   if RAM < 3 GB: base × 0.5
        #   if RAM < 8 GB: base × 0.75
        #   if RAM > 64 GB: greatest(16 GB, RAM/6)
        #   ideal = least(base, 64 GB)
        shared_buffers)
            _mb=$(_to_mb "$_val")
            # Tolerance: ±15% of ideal is green
            _lo=$(echo "$_sb_ideal_mb" | awk '{printf "%d", $1*0.85}')
            _hi=$(echo "$_sb_ideal_mb" | awk '{printf "%d", $1*1.40}')
            if [ "$_ram_mb" -eq 0 ] 2>/dev/null; then
                # No RAM data — fall back to simple threshold
                if   [ "$_mb" -ge 1024 ] 2>/dev/null; then echo "<span class='badge-ok'>✔ ${_val} — appears adequate; RAM data unavailable for formula check (ideal = RAM ÷ 4, capped at 64 GB)</span>"
                elif [ "$_mb" -ge 128  ] 2>/dev/null; then echo "<span class='badge-warn'>⚠ ${_val} — may be low; ideal = RAM ÷ 4 (EDB formula); RAM data unavailable for precise check</span>"
                else                                        echo "<span class='badge-bad'>✘ ${_val} — very low; ideal = RAM ÷ 4 (EDB formula); RAM data unavailable for precise check</span>"
                fi
            elif [ "$_mb" -ge "$_lo" ] && [ "$_mb" -le "$_hi" ] 2>/dev/null; then
                echo "<span class='badge-ok'>✔ ${_val} — matches EDB formula: RAM(${_ram_gb} GB) ÷ 4 = ${_sb_ideal} ideal; current value is within ±15% of ideal</span>"
            elif [ "$_mb" -gt "$_hi" ] 2>/dev/null; then
                echo "<span class='badge-warn'>⚑ ${_val} — above EDB ideal (${_sb_ideal}); formula: RAM(${_ram_gb} GB) ÷ 4; values above 40% of RAM can cause OS page cache pressure</span>"
            elif [ "$_mb" -gt 0 ] 2>/dev/null; then
                echo "<span class='badge-bad'>✘ ${_val} — below EDB ideal (${_sb_ideal}); formula: RAM(${_ram_gb} GB) ÷ 4; low shared_buffers increases disk I/O and degrades query performance</span>"
            else
                echo "<span class='badge-bad'>✘ Not set or 0 — ideal is ${_sb_ideal}; formula: RAM(${_ram_gb} GB) ÷ 4 (EDB formula)</span>"
            fi ;;

        # ── work_mem ───────────────────────────────────────────────────────────
        # EDB formula (from screenshot):
        #   ideal = (RAM - shared_buffers) / (16 × cpu_cores)
        work_mem)
            _mb=$(_to_mb "$_val")
            _lo=$(echo "$_wm_ideal_mb" | awk '{printf "%d", $1*0.5}')
            _hi=$(echo "$_wm_ideal_mb" | awk '{printf "%d", $1*3.0}')
            if [ "$_ram_mb" -eq 0 ] 2>/dev/null; then
                if   [ "$_mb" -gt 256 ] 2>/dev/null; then echo "<span class='badge-bad'>✘ ${_val} — high; formula: (RAM − shared_buffers) ÷ (16 × CPU cores); RAM data unavailable; risk of OOM</span>"
                elif [ "$_mb" -ge 4   ] 2>/dev/null; then echo "<span class='badge-ok'>✔ ${_val} — appears reasonable; formula: (RAM − shared_buffers) ÷ (16 × CPU cores); RAM data unavailable for precise check</span>"
                else                                       echo "<span class='badge-bad'>✘ ${_val} — very low; sorts and hash joins will spill to disk</span>"
                fi
            elif [ "$_mb" -ge "$_lo" ] && [ "$_mb" -le "$_hi" ] 2>/dev/null; then
                echo "<span class='badge-ok'>✔ ${_val} — within range of EDB ideal (${_wm_ideal}); formula: (RAM(${_ram_gb} GB) − shared_buffers) ÷ (16 × ${_cores} cores)</span>"
            elif [ "$_mb" -gt "$_hi" ] 2>/dev/null; then
                echo "<span class='badge-bad'>✘ ${_val} — above EDB ideal (${_wm_ideal}); formula: (RAM(${_ram_gb} GB) − shared_buffers) ÷ (16 × ${_cores} cores); risk of OOM: work_mem × concurrent sort ops × connections</span>"
            else
                echo "<span class='badge-warn'>⚠ ${_val} — below EDB ideal (${_wm_ideal}); formula: (RAM(${_ram_gb} GB) − shared_buffers) ÷ (16 × ${_cores} cores); sorts and hash joins may spill to disk</span>"
            fi ;;

        # ── maintenance_work_mem ───────────────────────────────────────────────
        # EDB formula (from screenshot):
        #   ideal = 15% × (RAM - shared_buffers) / autovacuum_max_workers
        #   capped at 1 GB per worker
        maintenance_work_mem)
            _mb=$(_to_mb "$_val")
            _lo=$(echo "$_mwm_ideal_mb" | awk '{printf "%d", $1*0.5}')
            _hi=$(echo "$_mwm_ideal_mb" | awk '{printf "%d", $1*2.0}')
            if [ "$_ram_mb" -eq 0 ] 2>/dev/null; then
                if   [ "$_mb" -ge 256 ] 2>/dev/null; then echo "<span class='badge-ok'>✔ ${_val} — appears adequate; formula: 15% × (RAM − shared_buffers) ÷ autovacuum_max_workers, capped at 1 GB; RAM data unavailable for precise check</span>"
                elif [ "$_mb" -ge 64  ] 2>/dev/null; then echo "<span class='badge-warn'>⚠ ${_val} — may be low; formula: 15% × (RAM − shared_buffers) ÷ ${_workers} workers, capped at 1 GB; RAM data unavailable for precise check</span>"
                else                                       echo "<span class='badge-bad'>✘ ${_val} — low; VACUUM and index builds will be slow; formula: 15% × (RAM − shared_buffers) ÷ ${_workers} workers</span>"
                fi
            elif [ "$_mb" -ge "$_lo" ] && [ "$_mb" -le "$_hi" ] 2>/dev/null; then
                echo "<span class='badge-ok'>✔ ${_val} — within range of EDB ideal (${_mwm_ideal}); formula: 15% × (RAM(${_ram_gb} GB) − shared_buffers) ÷ ${_workers} autovacuum workers, capped at 1 GB/worker</span>"
            elif [ "$_mb" -gt "$_hi" ] 2>/dev/null; then
                echo "<span class='badge-warn'>⚑ ${_val} — above EDB ideal (${_mwm_ideal}); formula: 15% × (RAM(${_ram_gb} GB) − shared_buffers) ÷ ${_workers} workers; check ${_workers} workers × ${_val} fits in available RAM</span>"
            else
                echo "<span class='badge-bad'>✘ ${_val} — below EDB ideal (${_mwm_ideal}); formula: 15% × (RAM(${_ram_gb} GB) − shared_buffers) ÷ ${_workers} autovacuum workers, capped at 1 GB; VACUUM and index builds will be slow</span>"
            fi ;;

        # ── max_connections ────────────────────────────────────────────────────
        # EDB formula: GREATEST(4 × CPU_cores, 100)
        # Beyond ideal, use pgbouncer as a connection pooler
        max_connections)
            _ideal_conn=$(echo "$_cpu_cores" | awk '{v=$1+0; ideal=v*4; if(ideal<100)ideal=100; printf "%d",ideal}')
            _n=$(echo "$_val" | tr -d '[:space:]')
            if [ "$_ram_mb" -eq 0 ] 2>/dev/null; then
                echo "<span class='badge-info'>Value: ${_val} — ideal = GREATEST(4 × CPU_cores, 100); CPU data unavailable for precise check</span>"
            elif [ "$_n" -ge "$_ideal_conn" ] 2>/dev/null && [ "$_n" -le $(echo "$_ideal_conn" | awk '{print $1*2}') ] 2>/dev/null; then
                echo "<span class='badge-ok'>✔ ${_val} — within ideal range; formula: GREATEST(4 × ${_cpu_cores} cores, 100) = ${_ideal_conn}; if connections exceed this regularly, add pgbouncer</span>"
            elif [ "$_n" -gt $(echo "$_ideal_conn" | awk '{print $1*2}') ] 2>/dev/null; then
                echo "<span class='badge-warn'>⚑ ${_val} — above ideal (${_ideal_conn}); formula: GREATEST(4 × ${_cpu_cores} cores, 100); high connection count increases memory pressure; consider pgbouncer pooler</span>"
            else
                echo "<span class='badge-warn'>⚠ ${_val} — below EDB ideal (${_ideal_conn}); formula: GREATEST(4 × ${_cpu_cores} cores, 100); may be intentionally restricted; monitor for connection refusals</span>"
            fi ;;

        # ── synchronous_standby_names ──────────────────────────────────────────
        # Value from configuration.out; overridden by postgresql.auto.conf if set
        # Empty = async replication (data loss possible at failover)
        synchronous_standby_names)
            _v2=$(echo "$_val" | sed 's/ (auto\.conf)//')
            if [ -z "$_v2" ] || [ "$_v2" = "[Not Set]" ]; then
                echo "<span class='badge-warn'>⚠ Not set — replication is fully asynchronous; Primary can commit before Standby confirms receipt; potential data loss at failover; set to e.g. FIRST 1 (standby_name) for sync HA</span>"
            else
                echo "<span class='badge-ok'>✔ Configured: $(echo "$_val" | htmlesc) — synchronous replication active; check synchronous_commit for durability level</span>"
            fi ;;

        # ── synchronous_commit ─────────────────────────────────────────────────
        # Ideal: on (safest); alternatives by risk tolerance per screenshot
        synchronous_commit)
            case "$_val" in
                on|"[Not Set]"|"") echo "<span class='badge-ok'>✔ on (default — safest); transaction confirmed only after WAL flushed to disk on Primary and Standby</span>" ;;
                remote_apply)  echo "<span class='badge-ok'>✔ remote_apply — strongest HA; commit waits until Standby has applied the WAL (no data loss, read-your-writes on Standby)</span>" ;;
                remote_write)  echo "<span class='badge-ok'>✔ remote_write — no data loss; commit waits until Standby has received and written WAL (slightly faster than on)</span>" ;;
                local)         echo "<span class='badge-warn'>⚠ local — local durability only; Standby may lag; data loss possible if Primary fails before WAL ships</span>" ;;
                off)           echo "<span class='badge-bad'>✘ off — fastest but up to ~200 ms data loss window; WAL not guaranteed on disk before commit returns; only for non-critical workloads</span>" ;;
                *)             echo "<span class='badge-info'>$(echo "$_val" | htmlesc) — verify value is intentional</span>" ;;
            esac ;;

        # ── max_wal_size ───────────────────────────────────────────────────────
        # Soft limit — WAL can exceed this temporarily
        # Ideal: 200 GB+ for high-perf; or 50–75% of dedicated WAL partition
        # Monitor: checkpoints_req / checkpoints_timed in pg_stat_bgwriter
        max_wal_size)
            _mb=$(_to_mb "$_val")
            if   [ "$_mb" -ge 204800 ] 2>/dev/null; then echo "<span class='badge-ok'>✔ ${_val} — meets high-performance ideal (≥ 200 GB); reduces checkpoint frequency and I/O spikes; monitor pg_stat_bgwriter: checkpoints_req / checkpoints_timed ratio</span>"
            elif [ "$_mb" -ge 10240  ] 2>/dev/null; then echo "<span class='badge-ok'>✔ ${_val} — reasonable; ideal for high-perf is ≥ 200 GB or 50–75% of dedicated WAL partition; if checkpoints_req rises, increase further</span>"
            elif [ "$_mb" -ge 1024   ] 2>/dev/null; then echo "<span class='badge-warn'>⚠ ${_val} — below recommended for production; ideal ≥ 200 GB for high-perf systems; low max_wal_size causes frequent forced checkpoints and I/O spikes that increase replication lag</span>"
            else                                          echo "<span class='badge-bad'>✘ ${_val} — very low; ideal ≥ 200 GB for production; forced checkpoints will occur constantly causing I/O bursts and replication lag; set max_wal_size = 200GB minimum for production</span>"
            fi ;;

        # ── checkpoint_completion_target ───────────────────────────────────────
        # Ideal: 0.9 — spreads checkpoint I/O over 90% of checkpoint interval
        checkpoint_completion_target)
            _f=$(echo "$_val" | awk '{printf "%.2f", $1+0}')
            if [ "$_val" = "0.9" ] || [ "$_f" = "0.90" ]; then
                echo "<span class='badge-ok'>✔ 0.9 — ideal value; spreads checkpoint I/O over 90% of the checkpoint interval, avoiding I/O spikes that cause replication lag</span>"
            elif [ "$(echo "$_val" | awk '{print ($1>=0.7)?1:0}')" = "1" ] 2>/dev/null; then
                echo "<span class='badge-warn'>⚠ ${_val} — below ideal (0.9); checkpoint I/O is less spread out; set checkpoint_completion_target = 0.9 to reduce I/O spikes</span>"
            elif [ -z "$_val" ] || [ "$_val" = "[Not Set]" ]; then
                echo "<span class='badge-warn'>⚠ Not set — default is 0.5; strongly recommend setting to 0.9 to spread checkpoint I/O and reduce replication lag spikes</span>"
            else
                echo "<span class='badge-bad'>✘ ${_val} — too low; ideal is 0.9; checkpoint writes are concentrated causing I/O bursts; set checkpoint_completion_target = 0.9</span>"
            fi ;;

        # ── autovacuum ─────────────────────────────────────────────────────────
        # Must always be on — never disable in production
        autovacuum)
            case "$_val" in
                on|"[Not Set]"|"") echo "<span class='badge-ok'>✔ on (always — never disable); autovacuum prevents table bloat, transaction ID wraparound, and eventual forced shutdowns</span>" ;;
                off) echo "<span class='badge-bad'>✘ off — CRITICAL: disabling autovacuum leads to table bloat, transaction ID wraparound (max ~2 billion XIDs), and eventual forced database shutdown; set autovacuum = on immediately</span>" ;;
                *)   echo "<span class='badge-info'>$(echo "$_val" | htmlesc)</span>" ;;
            esac ;;

        # ── autovacuum_max_workers ─────────────────────────────────────────────
        # EDB Doc p.11: recommended 5 (default 3 is too low)
        # Each worker consumes maintenance_work_mem
        autovacuum_max_workers)
            _n=$(echo "$_val" | tr -d '[:space:]')
            if   [ "$_n" -ge 8  ] 2>/dev/null; then echo "<span class='badge-warn'>⚑ ${_n} workers — above typical ideal (5); reasonable for systems with many large tables; note each worker consumes maintenance_work_mem simultaneously</span>"
            elif [ "$_n" -ge 5  ] 2>/dev/null; then echo "<span class='badge-ok'>✔ ${_n} — meets EDB recommendation (5); default 3 is too low for production; each worker handles one table at a time enabling parallel vacuuming</span>"
            elif [ "$_n" -ge 3  ] 2>/dev/null; then echo "<span class='badge-warn'>⚠ ${_n} — EDB Doc p.11 recommends increasing from default 3 → 5; with only ${_n} workers, VACUUM cannot keep up on busy multi-table workloads; requires DB restart to change</span>"
            else                                     echo "<span class='badge-bad'>✘ ${_n} — critically low; EDB recommends ≥ 5; at ${_n} workers table bloat will accumulate; set autovacuum_max_workers = 5 (requires restart)</span>"
            fi ;;

        # ── log_min_duration_statement ─────────────────────────────────────────
        # EDB Doc p.10: 1000 ms (1 second) is a good initial default
        # -1 = disabled (bad for diagnostics); 0 = log everything (too verbose)
        log_min_duration_statement)
            _ms=$(echo "$_val" | tr -d '[:space:]')
            if [ "$_ms" = "-1" ]; then
                echo "<span class='badge-bad'>✘ -1 (disabled) — no slow queries are ever logged; makes performance diagnosis impossible; EDB Doc p.10 recommends starting at 1000 ms and tuning down to 500 ms or 250 ms as slow queries are resolved</span>"
            elif [ "$_ms" = "0" ]; then
                echo "<span class='badge-warn'>⚑ 0 — logs every statement; very verbose and can fill disk quickly; use only for short diagnostic sessions; reduce to 1000 ms for production</span>"
            elif [ "$_ms" -le 1000 ] 2>/dev/null && [ "$_ms" -gt 0 ] 2>/dev/null; then
                echo "<span class='badge-ok'>✔ ${_ms} ms — within EDB ideal range (250–1000 ms); logs queries exceeding ${_ms} ms; tune down to 500 ms or 250 ms as slow queries are resolved</span>"
            elif [ "$_ms" -le 5000 ] 2>/dev/null; then
                echo "<span class='badge-warn'>⚠ ${_ms} ms — above EDB ideal starting point (1000 ms); slow queries under ${_ms} ms will not appear in logs; consider reducing to 1000 ms</span>"
            elif [ -z "$_val" ] || [ "$_val" = "[Not Set]" ]; then
                echo "<span class='badge-bad'>✘ Not set — defaults to -1 (disabled); set log_min_duration_statement = 1000 to start logging slow queries ≥ 1 second</span>"
            else
                echo "<span class='badge-warn'>⚠ ${_ms} ms — high threshold; queries under this will never appear in logs; EDB recommends starting at 1000 ms</span>"
            fi ;;

        *) echo "<span class='badge-info'>—</span>" ;;
    esac
}

pb_step "Extracting Lasso bundles..."

# =============================================================================
# STEP 4 — Extract every .tar.bz2 bundle into its own subfolder
# Each archive is extracted into EXTRACT_DIR/<bundle_basename>/
# =============================================================================
NODE_DIRS=""   # space-separated list of extracted node paths, built up below

find "$BUNDLE_DIR" -maxdepth 1 -name "*.tar.bz2" | sort | while read -r archive; do
    _base=$(basename "$archive" .tar.bz2)
    _dest="$EXTRACT_DIR/$_base"
    mkdir -p "$_dest"
    printf "\n  Extracting: \033[0;33m%s\033[0m" "$(basename "$archive")"
    tar -xjf "$archive" -C "$_dest" 2>/dev/null
    if [ $? -ne 0 ]; then
        printf " \033[0;31m[FAILED]\033[0m"
    else
        printf " \033[0;32m[OK]\033[0m"
    fi
done
printf "\n"

pb_step "Detecting node roles..."

# =============================================================================
# STEP 5 — Detect node role (Primary / Standby / Witness) for each extracted bundle
#
# Detection strategy (in order of confidence):
#   1. cluster_status.out — look for the node's own IP tagged as "Primary"
#   2. pg_stat_replication.out / replication.out — exists only on primary
#   3. postgresql_server_version.data — missing on witness (no DB)
#   4. recovery.conf / standby.signal — presence means standby
#   5. running_activity.out — exists on nodes running PG
#   6. Default to "Unknown" if nothing matches
# =============================================================================

detect_role() {
    _lp="$1"

    # Strategy 1: check cluster_status.out — most reliable source
    _cs=$(find "$_lp" -name "cluster_status.out" | head -n 1)
    if [ -f "$_cs" ]; then
        # The node's own hostname/IP is in info.data — look it up
        _self_host=$(find "$_lp" -name "info.data" -exec awk '/Hostname:/ {print substr($0,index($0,$2))}' {} + | head -n1 | tr -d '[:space:]')
        if [ -n "$_self_host" ]; then
            # If this host appears as Primary in the Agent Type table, it is Primary
            if awk '/Promote Status/{exit} /Primary/{found=1} END{exit !found}' "$_cs" 2>/dev/null | grep -q "." 2>/dev/null; then
                # More precise: check if self_host appears on a Primary line
                if grep -E "^\s+Primary\s+${_self_host}" "$_cs" >/dev/null 2>&1; then
                    echo "Primary"; return
                fi
                if grep -E "^\s+Standby\s+${_self_host}" "$_cs" >/dev/null 2>&1; then
                    echo "Standby"; return
                fi
                if grep -E "^\s+Witness\s+${_self_host}" "$_cs" >/dev/null 2>&1; then
                    echo "Witness"; return
                fi
            fi
        fi
    fi

    # Strategy 2: pg_stat_replication.out with data rows → Primary
    _repl=$(find "$_lp" -name "pg_stat_replication.out" -o -name "replication.out" 2>/dev/null | head -n1)
    if [ -f "$_repl" ] && [ "$(wc -l < "$_repl")" -gt 1 ]; then
        echo "Primary"; return
    fi

    # Strategy 3: no postgresql version file → Witness (no database instance)
    _pgver=$(find "$_lp" -name "postgresql_server_version.data" | head -n1)
    if [ -z "$_pgver" ]; then
        echo "Witness"; return
    fi

    # Strategy 4: standby.signal file exists → Standby (PostgreSQL 12+)
    if find "$_lp" -name "standby.signal" | grep -q "." 2>/dev/null; then
        echo "Standby"; return
    fi

    # Strategy 5: recovery.conf exists → Standby (PostgreSQL 11 and older)
    if find "$_lp" -name "recovery.conf" | grep -q "." 2>/dev/null; then
        echo "Standby"; return
    fi

    # Strategy 6: has running_activity.out → likely Primary or Standby with hot_standby
    # Check hot_standby flag in configuration to distinguish
    _conf=$(find "$_lp" -name "configuration.out" | head -n1)
    if [ -f "$_conf" ]; then
        _hs=$(awk -F'\t' '$1=="hot_standby"{print $2}' "$_conf" | head -n1)
        [ "$_hs" = "on" ] && echo "Standby" && return
    fi

    # Default
    echo "Primary"
}

pb_step "Collecting per-node data..."

# =============================================================================
# STEP 6 — For each extracted bundle, collect all the data we need and store
#           it in temporary files under ASSETS_DIR/nodes/<node_id>/
#           This avoids carrying dozens of variables per node in shell scope.
# =============================================================================

# Build the list of extracted node directories
NODES_META="$ASSETS_DIR/nodes_meta.txt"  # one line per node: id|role|hostname|path
> "$NODES_META"

_node_idx=0
for _extracted_bundle in "$EXTRACT_DIR"/*/; do
    [ -d "$_extracted_bundle" ] || continue
    _bundle_name=$(basename "$_extracted_bundle")

    # Find the actual lasso root — tar may have created one or two wrapper subdirectories
    # Walk down until we find info.data, up to 3 levels deep
    _lasso_root="$_extracted_bundle"
    _info=$(find "$_lasso_root" -maxdepth 3 -name "info.data" | head -n1)
    if [ -n "$_info" ]; then
        # _lasso_root = directory containing info.data
        _lasso_root=$(dirname "$_info")
    fi

    # Extract hostname
    _host=$(find "$_lasso_root" -name "info.data" -exec awk '/Hostname:/ {print substr($0,index($0,$2))}' {} + | head -n1 | tr -d '[:space:]')
    [ -z "$_host" ] && _host=$(find "$_lasso_root" -name "ifconfig.out" -exec grep -i "inet " {} + | awk '{print $2}' | sed 's/addr://' | grep -v "127.0.0.1" | head -n1)
    [ -z "$_host" ] && _host="$_bundle_name"

    # Detect role
    _role=$(detect_role "$_lasso_root")

    # Create a safe node ID for use in filenames and HTML IDs
    _node_id="node${_node_idx}_$(sanitise "$_host" | cut -c1-20)"
    _node_idx=$((_node_idx + 1))

    # Record node — strip trailing slash from path for consistent later use
    printf "%s|%s|%s|%s\n" "$_node_id" "$_role" "$_host" "$(echo "$_lasso_root" | sed 's|/$||')" >> "$NODES_META"
    printf "  Found node: \033[1m%-20s\033[0m role=\033[0;33m%s\033[0m  host=%s\n" "$_bundle_name" "$_role" "$_host"
done

# Count nodes found
NODE_COUNT=$(wc -l < "$NODES_META" | tr -d ' ')
if [ "$NODE_COUNT" -eq 0 ]; then
    printf "\033[1;31mERROR:\033[0m No valid Lasso bundles could be extracted.\n"
    exit 1
fi
printf "\n  Total nodes: \033[1;32m%d\033[0m\n\n" "$NODE_COUNT"


# =============================================================================
# build_pgradar_tree_viewer: builds a full two-panel file explorer for an entire
# extracted Lasso bundle.
#
# Left panel  : collapsible folder/file tree (all files and subfolders)
# Right panel : file content with Prev / Next / Back buttons
#
# How it works:
#   1. Walk the extracted bundle with find, sorted, to get every file path
#   2. Write all file paths + their htmlesc'd content into a single JS data array
#   3. The left tree is built from those paths using pure JS DOM manipulation
#   4. Clicking a file loads its content into the right panel instantly
#   5. Prev/Next cycle through files in sorted order
#
# Args: node_id  lasso_root_path  node_assets_dir
# =============================================================================
build_pgradar_tree_viewer() {
    _tnid="$1"
    # Strip any trailing slash from the lasso root path so sed stripping works correctly
    _tlp=$(echo "$2" | sed 's|/$||')
    _tndir="$3"
    _tfile="${_tndir}/pgradar_tree.html"
    # Tree file is at: PGRADAR_OUTPUT/pgradar-assets_xxx/nodeid/pgradar_tree.html
    # Report is at:    PGRADAR_OUTPUT/pgradar-report_xxx.html
    # So path is:      ../../pgradar-report_xxx.html#pane-nodeid
    _back_url="../../$(basename "$OUTFILE")#pane-${_tnid}"

    printf '\n  Building Lasso file tree for %s...' "$_tnid"

    # Collect all files under the lasso root, sorted
    _all_files=$(find "$_tlp" -type f | sed "s|^${_tlp}/||" | sort)
    _total=$(echo "$_all_files" | grep -c '.' 2>/dev/null || echo 0)

    cat > "$_tfile" <<TREEEOF
<!DOCTYPE html><html lang="en"><head>
<meta charset="utf-8"/>
<title>Lasso Report — $(basename "$_tlp")</title>
<style>
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400;500&display=swap');
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0;}
html,body{height:100%;overflow:hidden;}

/* ── CSS variables — dark mode (default) ── */
:root{
  --bg:#0d1117; --sur:#161b22; --sur2:#21262d; --bdr:#30363d;
  --txt:#e6edf3; --mut:#8b949e; --pri:#2f81f7;
  --ln-bg:#0d1117; --ln-num:#3d444d; --ln-bdr:#21262d;
  --lc-txt:#c9d1d9; --lc-hover:#161b22;
  --tree-lbl:#c9d1d9; --tree-sel-bg:rgba(47,129,247,.18); --tree-sel-txt:#79c0ff;
  --tree-hover:rgba(47,129,247,.08);
  --empty-txt:#8b949e;
}
/* ── Light mode overrides ── */
body.lt{
  --bg:#f6f8fa; --sur:#ffffff; --sur2:#f0f3f6; --bdr:#d0d7de;
  --txt:#1f2328; --mut:#57606a; --pri:#0969da;
  --ln-bg:#f0f3f6; --ln-num:#6e7781; --ln-bdr:#d0d7de;
  --lc-txt:#1f2328; --lc-hover:#f0f3f6;
  --tree-lbl:#1f2328; --tree-sel-bg:rgba(9,105,218,.12); --tree-sel-txt:#0550ae;
  --tree-hover:rgba(9,105,218,.06);
  --empty-txt:#57606a;
}

body{background:var(--bg);color:var(--txt);font-family:'Inter',system-ui,sans-serif;font-size:13px;display:flex;flex-direction:column;}

/* ── Top navigation bar ── */
.navbar{background:var(--sur);border-bottom:1px solid var(--bdr);padding:10px 16px;display:flex;align-items:center;gap:10px;flex-shrink:0;z-index:100;}
.nb-title{font-size:13px;font-weight:600;color:var(--txt);flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.nb-sub{font-family:'JetBrains Mono',monospace;font-size:10px;color:var(--mut);margin-left:6px;}
.btn{display:inline-flex;align-items:center;gap:5px;padding:6px 13px;border-radius:7px;text-decoration:none;font-size:11px;font-weight:600;border:1px solid;cursor:pointer;white-space:nowrap;transition:opacity .15s;}
.btn:hover{opacity:.8;}
.btn-back{color:var(--txt);border-color:var(--bdr);background:var(--sur2);}
.btn-nav{color:var(--mut);border-color:var(--bdr);background:var(--sur2);}
.btn-nav:disabled{opacity:.35;cursor:default;}
.theme-btn{background:var(--sur2);border:1px solid var(--bdr);border-radius:20px;padding:4px 12px 4px 8px;display:flex;align-items:center;gap:6px;cursor:pointer;font-size:11px;font-weight:600;color:var(--mut);}
.theme-btn:hover{color:var(--txt);}
.nav-sep{width:1px;height:20px;background:var(--bdr);flex-shrink:0;}
.file-counter{font-size:11px;color:var(--mut);font-family:'JetBrains Mono',monospace;white-space:nowrap;}

/* ── Main two-panel layout ── */
.main{display:flex;flex:1;overflow:hidden;}

/* ── Left tree panel ── */
.tree-panel{width:280px;min-width:180px;max-width:420px;background:var(--sur);border-right:1px solid var(--bdr);display:flex;flex-direction:column;overflow:hidden;flex-shrink:0;}
.tree-search-wrap{padding:10px 12px;border-bottom:1px solid var(--bdr);flex-shrink:0;}
.tree-search{width:100%;background:var(--sur2);border:1px solid var(--bdr);border-radius:6px;padding:6px 10px;color:var(--txt);font-size:11px;font-family:'Inter',sans-serif;outline:none;}
.tree-search::placeholder{color:var(--mut);}
.tree-search:focus{border-color:var(--pri);}
.tree-scroll{flex:1;overflow-y:auto;overflow-x:hidden;padding:6px 0;}
.tree-scroll::-webkit-scrollbar{width:4px;}
.tree-scroll::-webkit-scrollbar-thumb{background:var(--bdr);border-radius:2px;}

/* Tree nodes */
.tree-item{display:flex;align-items:center;gap:0;cursor:pointer;user-select:none;padding:2px 0;}
.tree-item:hover > .tree-label{background:var(--tree-hover);}
.tree-item.selected > .tree-label{background:var(--tree-sel-bg);color:var(--tree-sel-txt);}
.tree-toggle{width:16px;flex-shrink:0;text-align:center;font-size:9px;color:var(--mut);padding:3px 0;}
.tree-icon{font-size:12px;flex-shrink:0;width:18px;text-align:center;}
.tree-label{flex:1;padding:3px 6px 3px 2px;border-radius:4px;font-size:11px;color:var(--tree-lbl);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;line-height:1.4;}
.tree-folder > .tree-label{color:var(--txt);font-weight:500;}
.tree-children{overflow:hidden;}
.tree-children.collapsed{display:none;}

/* Resize handle */
.resize-handle{width:4px;background:transparent;cursor:col-resize;flex-shrink:0;transition:background .15s;}
.resize-handle:hover,.resize-handle.dragging{background:var(--pri);}

/* ── TSV table: each cell is its own <td> so copy→paste into Excel works ── */
/* ── Copy for Excel button ── */
.btn-copy-excel{padding:5px 12px;border-radius:6px;font-size:11px;font-weight:600;border:1px solid rgba(47,129,247,.4);cursor:pointer;background:rgba(47,129,247,.12);color:var(--pri);white-space:nowrap;transition:all .15s;}
.btn-copy-excel:hover{background:rgba(47,129,247,.22);}
.btn-copy-excel.copied{background:rgba(63,185,80,.15);color:var(--grn);border-color:rgba(63,185,80,.4);}
body.lt .btn-copy-excel{background:rgba(9,105,218,.08);color:#0969da;border-color:rgba(9,105,218,.3);}
body.lt .btn-copy-excel.copied{background:rgba(26,127,55,.1);color:#1a7f37;}
.tsv-tbl{border-collapse:collapse;font-size:11px;font-family:'JetBrains Mono',monospace;}
.tsv-tbl thead tr{background:var(--sur);}
.tsv-tbl .ln-th{min-width:44px;border-right:1px solid var(--ln-bdr);background:var(--ln-bg);}
.tsv-tbl thead th{color:var(--mut);font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.4px;padding:8px 14px;text-align:left;border-bottom:2px solid var(--bdr);border-right:1px solid var(--ln-bdr);position:sticky;top:0;z-index:2;background:var(--sur);white-space:nowrap;}
.tsv-tbl thead th:last-child{border-right:none;}
.tsv-tbl tbody tr:hover .tc,.tsv-tbl tbody tr:hover .ln{background:var(--lc-hover);}
.tsv-tbl .tc{padding:6px 14px;border-bottom:1px solid var(--ln-bdr);border-right:1px solid var(--ln-bdr);color:var(--lc-txt);white-space:nowrap;vertical-align:top;}
.tsv-tbl .tc:last-child{border-right:none;}
.tsv-tbl .ln{padding:0 10px 0 16px;text-align:right;color:var(--ln-num);font-size:10px;user-select:none;-webkit-user-select:none;-moz-user-select:none;min-width:44px;border-right:1px solid var(--ln-bdr);background:var(--ln-bg);vertical-align:top;white-space:nowrap;border-bottom:1px solid var(--ln-bdr);}
.content-panel{flex:1;display:flex;flex-direction:column;overflow:hidden;}
.content-header{background:var(--sur);border-bottom:1px solid var(--bdr);padding:10px 16px;display:flex;align-items:center;gap:8px;flex-shrink:0;}
.ch-path{font-family:'JetBrains Mono',monospace;font-size:11px;color:var(--mut);flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.ch-lines{font-size:10px;color:var(--mut);white-space:nowrap;}
.content-scroll{flex:1;overflow:auto;padding:0;}
.content-scroll::-webkit-scrollbar{width:6px;height:6px;}
.content-scroll::-webkit-scrollbar-thumb{background:var(--bdr);border-radius:3px;}
/* Prevent selecting navbar/tree/header when doing Ctrl+A — only .content-scroll is selectable */
.navbar,.tree-panel,.content-header{user-select:none;-webkit-user-select:none;}
.content-scroll{user-select:text;-webkit-user-select:text;}
.line-table{border-collapse:collapse;width:100%;min-width:100%;}
.ln{padding:0 12px 0 16px;text-align:right;color:var(--ln-num);font-size:10px;user-select:none;-webkit-user-select:none;-moz-user-select:none;min-width:52px;border-right:1px solid var(--ln-bdr);background:var(--ln-bg);vertical-align:top;white-space:nowrap;font-family:'JetBrains Mono',monospace;}
.lc{padding:0 16px;white-space:pre;vertical-align:top;color:var(--lc-txt);font-family:'JetBrains Mono',monospace;font-size:11.5px;line-height:1.75;}
.lc:hover{background:var(--lc-hover);}
.empty-state{display:flex;flex-direction:column;align-items:center;justify-content:center;height:100%;color:var(--empty-txt);gap:12px;}
.empty-icon{font-size:40px;opacity:.4;}
.empty-msg{font-size:13px;}
/* File size label in tree */
.tree-size{font-size:9px;color:var(--mut);font-family:'JetBrains Mono',monospace;flex-shrink:0;padding:1px 5px;border-radius:3px;background:var(--sur2);margin-left:4px;white-space:nowrap;}
</style>
</head>
<body>

<!-- Top navbar -->
<div class="navbar">
  <button class="btn btn-back" onclick="if(window.history.length>1){window.history.back();}else{window.location.href='$_back_url';}">← Dashboard</button>
  <div class="nav-sep"></div>
  <span class="nb-title">📦 Lasso Report — $(basename "$_tlp" | htmlesc)<span class="nb-sub">$_tnid</span></span>
  <div class="nav-sep"></div>
  <button class="btn btn-nav" id="btn-prev" onclick="navigateFile(-1)" disabled>◀ Prev</button>
  <span class="file-counter" id="file-counter">— / —</span>
  <button class="btn btn-nav" id="btn-next" onclick="navigateFile(1)">Next ▶</button>
  <div class="nav-sep"></div>
  <button class="theme-btn" id="themeBtn" onclick="toggleTheme()"><span id="themeIcon">☀️</span><span id="themeLabel">Light</span></button>
</div>

<!-- Two-panel layout -->
<div class="main">

  <!-- Left: file tree -->
  <div class="tree-panel" id="tree-panel">
    <div class="tree-search-wrap">
      <input class="tree-search" id="tree-search" type="text" placeholder="Filter files..." oninput="filterTree(this.value)"/>
    </div>
    <div class="tree-scroll" id="tree-scroll"></div>
  </div>

  <!-- Resize handle -->
  <div class="resize-handle" id="resize-handle"></div>

  <!-- Right: file content -->
  <div class="content-panel">
    <div class="content-header">
      <span class="ch-path" id="ch-path">Select a file from the tree</span>
      <span class="ch-lines" id="ch-lines"></span>
      <button class="btn-copy-excel" id="btn-copy-excel" onclick="copyForExcel()" style="display:none;">📋 Copy for Excel</button>
    </div>
    <div class="content-scroll" id="content-scroll">
      <div class="empty-state" id="empty-state">
        <div class="empty-icon">📂</div>
        <div class="empty-msg">Select a file from the tree to view its contents</div>
      </div>
      <div id="file-display" style="display:none;"></div>
    </div>
  </div>
</div>

<script>
// ── File data: array of {path, content} objects, built at generation time ──
var FILES = [];
TREEEOF

    # Inject each file's content as a JS array entry.
    # We use awk to do all escaping — this avoids shell backtick/printf conflicts.
    # Each entry: {p:"rel/path",c:"line1\nline2\n..."}
    # Files are capped at 256 KB to keep the HTML file manageable.
    printf 'FILES = [\n' >> "$_tfile"
    echo "$_all_files" | while IFS= read -r _rel; do
        [ -z "$_rel" ] && continue
        _abs="${_tlp}/${_rel}"
        [ -f "$_abs" ] || continue
        # Get file size in bytes, format human-readable
        _fsize=$(wc -c < "$_abs" 2>/dev/null || echo 0)
        _fsize_fmt=$(echo "$_fsize" | awk '{
            if($1>=1048576) printf "%.1f MB",$1/1048576;
            else if($1>=1024) printf "%.0f KB",$1/1024;
            else printf "%d B",$1
        }')
        head -c 262144 "$_abs" | awk -v path="$_rel" -v fsize="$_fsize_fmt" 'BEGIN{
            printf "  {p:\""
            n=split(path, pa, "")
            for(i=1;i<=n;i++){
                c=pa[i]
                if(c=="\\") printf "\\\\"
                else if(c=="\"") printf "\\\""
                else printf c
            }
            printf "\",s:\""
            printf "%s", fsize
            printf "\",c:\""
        }
        {
            line=$0
            gsub(/\\/, "\\\\", line)
            gsub(/"/, "\\\"", line)
            gsub(/\t/, "\\t", line)
            gsub(/\r/, "", line)
            printf "%s\\n", line
        }
        END{ printf "\"},\n" }' >> "$_tfile"
    done
    printf '];\n\n' >> "$_tfile"

    # Inject the JS logic after the data
    cat >> "$_tfile" <<'JSEOF'

// ── State ──
var currentIdx = -1;
var filteredPaths = [];

// ── Build the left tree from FILES paths ──
function buildTree(paths) {
  var root = {};
  paths.forEach(function(p, idx) {
    var parts = p.split('/');
    var node = root;
    parts.forEach(function(part, i) {
      if (!node[part]) node[part] = { __files: [], __dirs: {} };
      if (i === parts.length - 1) {
        node[part].__isFile = true;
        node[part].__idx = idx;
        node[part].__path = p;
        node[part].__size = FILES[idx] ? FILES[idx].s : '';
      } else {
        node = node[part].__dirs || (node[part].__dirs = {});
      }
    });
  });
  return root;
}

function renderTree(node, container, depth, prefix) {
  var keys = Object.keys(node).filter(function(k){ return k !== '__files' && k !== '__dirs' && k !== '__isFile' && k !== '__idx' && k !== '__path'; }).sort(function(a,b){
    var aIsDir = !node[a].__isFile;
    var bIsDir = !node[b].__isFile;
    if (aIsDir !== bIsDir) return aIsDir ? -1 : 1;
    return a.localeCompare(b);
  });
  keys.forEach(function(key) {
    var item = node[key];
    var el = document.createElement('div');
    el.style.paddingLeft = (depth * 14) + 'px';
    el.className = 'tree-item' + (item.__isFile ? ' tree-file' : ' tree-folder');
    if (item.__isFile) {
      el.setAttribute('data-idx', item.__idx);
      el.setAttribute('data-path', item.__path);
      var ext = key.split('.').pop().toLowerCase();
      var icon = ext === 'log' ? '📋' : ext === 'data' ? '📄' : ext === 'out' ? '📊' : ext === 'conf' ? '⚙️' : ext === 'properties' ? '🔧' : ext === 'signal' ? '🔔' : '📄';
      var sizeLabel = item.__size ? '<span class="tree-size">' + item.__size + '</span>' : '';
      el.innerHTML = '<span class="tree-toggle"></span><span class="tree-icon">' + icon + '</span><span class="tree-label">' + escHtml(key) + '</span>' + sizeLabel;
      el.addEventListener('click', function(){ loadFile(parseInt(this.getAttribute('data-idx'))); });
    } else {
      var childContainer = document.createElement('div');
      childContainer.className = 'tree-children';
      var toggle = document.createElement('span');
      toggle.className = 'tree-toggle';
      toggle.textContent = '▶';
      toggle.style.transform = depth === 0 ? 'rotate(90deg)' : '';
      var icon2 = document.createElement('span');
      icon2.className = 'tree-icon';
      icon2.textContent = '📁';
      var label = document.createElement('span');
      label.className = 'tree-label';
      label.textContent = key;
      el.appendChild(toggle);
      el.appendChild(icon2);
      el.appendChild(label);
      el.addEventListener('click', function(e){
        if (e.target === this || e.target.classList.contains('tree-label') || e.target.classList.contains('tree-icon') || e.target.classList.contains('tree-toggle')) {
          var cc = this.nextSibling;
          if (cc) {
            var collapsed = cc.classList.toggle('collapsed');
            this.querySelector('.tree-toggle').style.transform = collapsed ? '' : 'rotate(90deg)';
            this.querySelector('.tree-icon').textContent = collapsed ? '📁' : '📂';
          }
          e.stopPropagation();
        }
      });
      if (depth === 0) { childContainer.classList.remove('collapsed'); toggle.style.transform = 'rotate(90deg)'; icon2.textContent = '📂'; }
      else { childContainer.classList.add('collapsed'); }
      container.appendChild(el);
      if (item.__dirs) renderTree(item.__dirs, childContainer, depth + 1, prefix + key + '/');
      container.appendChild(childContainer);
      return;
    }
    container.appendChild(el);
  });
}


// ── State ──
var currentIdx   = -1;
var currentLines = [];
var currentIsTsv = false;
var currentPath  = '';

// Detect TSV — tabs stored as \t (two-char escape sequence) by awk
// Check first 5 non-empty lines — running_activity.out has embedded SQL mixed in
function detectTsv(lines) {
  var checked = 0;
  for (var i = 0; i < lines.length && checked < 5; i++) {
    if (!lines[i].trim()) continue;
    checked++;
    // If this line has tabs and splits into 2+ fields, it's TSV
    if (lines[i].indexOf('\t') !== -1 && lines[i].split('\t').length >= 2) {
      return true;
    }
  }
  return false;
}

function esc(s) {
  return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

// Build tab+newline plain text from lines (real tabs, real newlines)
// This is what Excel reads when you paste
function linesToTsv(lines) {
  return lines.filter(function(l){ return l.trim(); })
    .map(function(l){ return l.replace(/\t/g, '\t'); })  // \t is already real tab
    .join('\n');
}

// Build HTML table from TSV lines — used as the second clipboard format
// Excel uses this to map each <td> to its own column
function linesToHtmlTable(lines) {
  var rows = lines.filter(function(l){ return l.trim(); });
  if (!rows.length) return '';
  var headers = rows[0].split('\t');
  var html = '<table><thead><tr>' +
    headers.map(function(h){ return '<th>' + esc(h) + '</th>'; }).join('') +
    '</tr></thead><tbody>';
  for (var i = 1; i < rows.length; i++) {
    var cells = rows[i].split('\t');
    html += '<tr>' +
      headers.map(function(_, j){ return '<td>' + esc(cells[j]||'') + '</td>'; }).join('') +
      '</tr>';
  }
  return html + '</tbody></table>';
}

// Render TSV file — displays as a styled table for readability
function renderTsvTable(lines) {
  var rows = lines.filter(function(l){ return l.trim(); });
  if (!rows.length) return '<div class="empty-state"><div class="empty-icon">📄</div><div class="empty-msg">Empty file</div></div>';
  var headers = rows[0].split('\t');
  var stateCol = -1;
  headers.forEach(function(h,i){ if(h.toLowerCase()==='state'||h.toLowerCase()==='status') stateCol=i; });
  var html = '<table class="tsv-tbl" id="tsv-tbl"><thead><tr><td class="ln-th"></td>';
  headers.forEach(function(h){ html += '<th>' + esc(h) + '</th>'; });
  html += '</tr></thead><tbody>';
  for (var i = 1; i < rows.length; i++) {
    var cells = rows[i].split('\t');
    html += '<tr><td class="ln">' + i + '</td>';
    for (var j = 0; j < headers.length; j++) {
      var val = cells[j] !== undefined ? cells[j] : '';
      var extra = '';
      if (j === stateCol && val) {
        if (val === 'active') extra = ' style="color:#3fb950;font-weight:600;"';
        else if (val === 'idle') extra = ' style="color:#79c0ff;"';
        else if (val.indexOf('idle in transaction') === 0) extra = ' style="color:#f85149;font-weight:600;"';
      }
      var display = val; var title = '';
      if (val.length > 80) { display = val.substring(0,77) + '\u2026'; title = ' title="' + val.replace(/"/g,'&quot;') + '"'; }
      html += '<td class="tc"' + extra + title + '>' + esc(display) + '</td>';
    }
    html += '</tr>';
  }
  return html + '</tbody></table>';
}

// Render plain file with line numbers
function renderRaw(lines) {
  var html = '<table class="line-table"><tbody>';
  lines.forEach(function(line, i) {
    var safe = esc(line).replace(/\t/g, '    ');
    html += '<tr><td class="ln">' + (i+1) + '</td><td class="lc">' + (safe||' ') + '</td></tr>';
  });
  return html + '</tbody></table>';
}

function loadFile(idx) {
  if (idx < 0 || idx >= FILES.length) return;
  currentIdx = idx;
  var f = FILES[idx];
  document.querySelectorAll('.tree-item.selected').forEach(function(el){ el.classList.remove('selected'); });
  var tEl = document.querySelector('[data-idx="' + idx + '"]');
  if (tEl) { tEl.classList.add('selected'); tEl.scrollIntoView({block:'nearest'}); }
  currentPath = f.p;
  document.getElementById('ch-path').textContent = f.p;
  var lines = f.c.split('\n');
  if (lines.length > 1 && lines[lines.length-1] === '') lines.pop();
  currentLines = lines;
  document.getElementById('ch-lines').textContent = lines.length + ' lines';
  document.getElementById('file-counter').textContent = (idx+1) + ' / ' + FILES.length;
  currentIsTsv = detectTsv(lines);
  document.getElementById('btn-copy-excel').style.display = currentIsTsv ? '' : 'none';
  var display = document.getElementById('file-display');
  display.innerHTML = currentIsTsv ? renderTsvTable(lines) : renderRaw(lines);
  display.style.display = 'block';
  document.getElementById('empty-state').style.display = 'none';
  document.getElementById('btn-prev').disabled = (idx === 0);
  document.getElementById('btn-next').disabled = (idx === FILES.length - 1);
  document.getElementById('content-scroll').scrollTop = 0;
}

// ── Copy for Excel: builds proper TSV and puts it on the clipboard ──
// Uses a hidden textarea trick which works synchronously in ALL browsers
// (Chrome, Safari, Firefox, Edge) — most reliable cross-browser method.
// Each \t becomes a real tab → Excel column separator
// Each \n becomes a real newline → Excel row separator
function copyForExcel() {
  if (!currentIsTsv || !currentLines.length) return;
  // currentLines already contain real tabs and data — JS parsed \t\n when loading
  var tsv = currentLines
    .filter(function(l){ return l.trim(); })
    .join('\n');
  // Textarea trick: pure plain text — no HTML, no color styles bleed to Excel
  var ta = document.createElement('textarea');
  ta.value = tsv;
  ta.style.cssText = 'position:fixed;left:-9999px;top:-9999px;opacity:0;color:#000000;background:#ffffff;font-size:12px;';
  document.body.appendChild(ta);
  ta.focus();
  ta.select();
  var ok = document.execCommand('copy');
  document.body.removeChild(ta);
  // Visual feedback on button
  var btn = document.getElementById('btn-copy-excel');
  if (ok || true) {  // show feedback regardless (execCommand result unreliable)
    var orig = btn.textContent;
    btn.textContent = '✅ Copied!';
    btn.classList.add('copied');
    setTimeout(function(){
      btn.textContent = orig;
      btn.classList.remove('copied');
    }, 2000);
  }
}


function navigateFile(delta) {
  var next = currentIdx + delta;
  if (next >= 0 && next < FILES.length) loadFile(next);
}

function filterTree(q) {
  q = q.trim().toLowerCase();
  document.querySelectorAll('.tree-file').forEach(function(el){
    var p = (el.getAttribute('data-path') || '').toLowerCase();
    var show = !q || p.indexOf(q) !== -1;
    el.style.display = show ? '' : 'none';
    // Expand parent folders when filtering
    if (show && q) {
      var parent = el.parentNode;
      while (parent && parent.id !== 'tree-scroll') {
        if (parent.classList.contains('tree-children')) { parent.classList.remove('collapsed'); var prev = parent.previousSibling; if (prev && prev.querySelector) { var t = prev.querySelector('.tree-toggle'); if (t) t.style.transform = 'rotate(90deg)'; var ic = prev.querySelector('.tree-icon'); if (ic) ic.textContent = '📂'; } }
        parent = parent.parentNode;
      }
    }
  });
}

function escHtml(s) {
  return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

// Ctrl+A: prevent selecting entire page (navbar + tree + content)
// Users use the "Copy for Excel" button for TSV files instead
document.addEventListener('keydown', function(e) {
  if (!((e.key==='a'||e.key==='A') && (e.ctrlKey||e.metaKey))) return;
  if (document.activeElement === document.getElementById('tree-search')) return;
  var cs = document.getElementById('content-scroll');
  if (cs && cs.matches(':hover')) return; // allow natural select inside content
  e.preventDefault();
});

// ── Copy event: strip line numbers from ALL copies in the content panel ──
// user-select:none on .ln prevents selection visually but browsers still
// include the text when copying a range that spans both columns.
// This handler intercepts the copy event and rebuilds the plain text
// using only .lc (content) cells, discarding .ln (line number) cells.
document.getElementById('content-scroll').addEventListener('copy', function(e) {
  e.preventDefault();
  var sel = window.getSelection();
  if (!sel || sel.isCollapsed) return;
  var display = document.getElementById('file-display');
  if (!display) return;

  if (currentIsTsv) {
    // TSV file: extract only td.tc cells (data columns, no line numbers)
    // Write ONLY text/plain — no HTML — so Excel uses default black font
    var allRows = Array.prototype.slice.call(display.querySelectorAll('tbody tr'));
    var selRows = allRows.filter(function(r){ return sel.containsNode(r, true); });
    if (selRows.length === 0) selRows = allRows;
    var plain = selRows.map(function(row) {
      return Array.prototype.slice.call(row.querySelectorAll('td.tc'))
        .map(function(td){ return td.textContent; }).join('\t');
    }).join('\n');
    e.clipboardData.setData('text/plain', plain);
    return;
  }

  // Raw file: extract only .lc cells (skip .ln line numbers)
  var allRows = Array.prototype.slice.call(display.querySelectorAll('tr'));
  var plain = [];
  allRows.forEach(function(row) {
    if (!sel.containsNode(row, true)) return;
    var lc = row.querySelector('td.lc');
    if (lc) plain.push(lc.textContent);
  });
  if (plain.length === 0) {
    var text = sel.toString().replace(/^\s*\d+\s+/gm, '');
    e.clipboardData.setData('text/plain', text);
    return;
  }
  e.clipboardData.setData('text/plain', plain.join('\n'));
});

// ── Resizable panel ──
(function(){
  var handle = document.getElementById('resize-handle');
  var panel  = document.getElementById('tree-panel');
  var dragging = false, startX, startW;
  handle.addEventListener('mousedown', function(e){ dragging=true; startX=e.clientX; startW=panel.offsetWidth; handle.classList.add('dragging'); e.preventDefault(); });
  document.addEventListener('mousemove', function(e){ if(!dragging) return; var w=Math.max(160,Math.min(520,startW+e.clientX-startX)); panel.style.width=w+'px'; });
  document.addEventListener('mouseup', function(){ dragging=false; handle.classList.remove('dragging'); });
})();

// ── Theme toggle — reads same localStorage key as the main dashboard ──
function setFontSize(sz) {
  document.body.style.fontSize = sz + 'px';
  try { localStorage.setItem('efm-fontsize', sz); } catch(e){}
}
function toggleTheme() {
  var isL = document.body.classList.toggle('lt');
  document.getElementById('themeIcon').textContent  = isL ? '🌙' : '☀️';
  document.getElementById('themeLabel').textContent = isL ? 'Dark' : 'Light';
  try { localStorage.setItem('efm-theme', isL ? 'light' : 'dark'); } catch(e){}
}

// ── Init ──
(function(){
  // Apply same theme as the dashboard (shared localStorage key)
  try { var fs=localStorage.getItem('efm-fontsize'); if(fs){document.body.style.fontSize=fs+'px'; var sl=document.getElementById('fontSlider'); if(sl)sl.value=fs;} } catch(e){}
  try { if(localStorage.getItem('efm-theme')==='light'){ document.body.classList.add('lt'); document.getElementById('themeIcon').textContent='🌙'; document.getElementById('themeLabel').textContent='Dark'; } } catch(e){}
  var paths = FILES.map(function(f){ return f.p; });
  var treeData = buildTree(paths);
  var container = document.getElementById('tree-scroll');
  renderTree(treeData, container, 0, '');
  // Auto-open first file
  if (FILES.length > 0) loadFile(0);
})();
</script>
</body></html>
JSEOF
    printf ' done (%d files)\n' "$_total"
}

pb_step "Building per-node asset files..."

# =============================================================================
# STEP 7 — Pre-build all tabular/raw asset HTML files for every node.
#           These are the sub-pages linked from each node's tab.
# =============================================================================

while IFS='|' read -r _nid _role _host _lp; do
    _ndir="$ASSETS_DIR/$_nid"
    mkdir -p "$_ndir"
    # Back URL: two levels up from assets_xxx/nodeid/ to reach PGRADAR_OUTPUT/, then anchor to node tab
    _back_url="../../$(basename "$OUTFILE")#pane-${_nid}"

    # ── Connection drill-down pages ──
    _cf=$(find "$_lp" -type f -name "running_activity.out" | head -n1)
    if [ -f "$_cf" ]; then
        # Detect state/status column index from header
        _state_col=$(awk -F'\t' 'NR==1{for(i=1;i<=NF;i++){h=tolower($i);gsub(/\r/,"",h);if(h=="state"||h=="status"){print i}}}' "$_cf" 2>/dev/null)
        _state_col="${_state_col:-7}"

        # Write each connection sub-page directly with awk — avoids pipeline subshell issues
        for _cstate in "active" "idle" "idle in transaction"; do
            case "$_cstate" in
                "active")              _cpage="$_ndir/conn_act.html"; _ctitle="Active Connections — $_host" ;;
                "idle")                _cpage="$_ndir/conn_idl.html"; _ctitle="Idle Connections — $_host" ;;
                "idle in transaction") _cpage="$_ndir/conn_itx.html"; _ctitle="Idle in Transaction — $_host" ;;
            esac
            # Write header HTML
            cat > "$_cpage" << CONNHDR
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"/>
<title>$_ctitle</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400&display=swap');
  *{box-sizing:border-box;margin:0;padding:0;}
  body{background:#0d1117;color:#e6edf3;font-family:'Inter',system-ui,sans-serif;font-size:13px;}
  .nav{background:#161b22;border-bottom:1px solid #30363d;padding:12px 20px;display:flex;align-items:center;gap:10px;position:sticky;top:0;z-index:10;}
  .nav-title{font-size:13px;font-weight:600;color:#e6edf3;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
  .btn{display:inline-flex;align-items:center;gap:6px;padding:6px 14px;border-radius:7px;text-decoration:none;font-size:12px;font-weight:600;white-space:nowrap;border:1px solid;transition:opacity .15s;}
  .btn:hover{opacity:.85;}
  .btn-back{background:#21262d;color:#e6edf3;border-color:#30363d;}
  .btn-raw{background:#21262d;color:#8b949e;border-color:#30363d;}
  .content{padding:20px 24px;}
  .tbl-title{font-size:14px;font-weight:600;color:#e6edf3;margin-bottom:4px;}
  .tbl-sub{font-family:'JetBrains Mono',monospace;font-size:10px;color:#8b949e;margin-bottom:16px;}
  .tbl-wrap{overflow-x:auto;border:1px solid #30363d;border-radius:8px;}
  table{border-collapse:collapse;width:max-content;min-width:100%;}
  thead th{background:#161b22;color:#8b949e;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.5px;padding:10px 16px;text-align:left;border-bottom:1px solid #30363d;white-space:nowrap;}
  tbody td{padding:9px 16px;border-bottom:1px solid #21262d;color:#c9d1d9;font-family:'JetBrains Mono',monospace;font-size:11px;white-space:nowrap;vertical-align:middle;}
  tbody tr:last-child td{border-bottom:none;}
  tbody tr:hover{background:#161b22;}
</style></head><body>
<div class="nav">
  <button class="btn btn-back" onclick="if(window.history.length>1){window.history.back();}else{window.location.href='$_back_url';}">← Back to Dashboard</button>
  <span class="nav-title">$_ctitle</span>
  <a href="conn_raw.html" class="btn btn-raw" target="_self">≡ Raw File</a>
</div>
<div class="content">
  <div class="tbl-title">$_ctitle</div>
  <div class="tbl-sub">running_activity.out</div>
  <div class="tbl-wrap">
  <table><thead><tr>
CONNHDR
            # Write column headers from header row
            head -n1 "$_cf" | tr -d '\r' | tr '	' '\n' | while read -r _col; do
                printf '<th>%s</th>' "$(echo "$_col" | htmlesc)" >> "$_cpage"
            done
            echo "</tr></thead><tbody>" >> "$_cpage"
            # Write filtered rows using awk — no pipeline subshell
            _cs="$_cstate"
            awk -F'\t' -v sc="$_state_col" -v st="$_cs" '
            NR>1{
                v=$sc; gsub(/\r/,"",v)
                if(v==st || (st=="idle in transaction" && v~/^idle in transaction/)){
                    printf "<tr>"
                    for(i=1;i<=NF;i++){
                        val=$i; gsub(/&/,"\&amp;",val); gsub(/</,"\&lt;",val); gsub(/>/,"\&gt;",val)
                        printf "<td>%s</td>", val
                    }
                    print "</tr>"
                }
            }' "$_cf" >> "$_cpage"
            echo "</tbody></table></div></div></body></html>" >> "$_cpage"
        done

        # Full raw connection file
        cat > "$_ndir/conn_raw.html" <<RAWEOF
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"/><title>Raw — running_activity.out</title>
<style>@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400&display=swap');*{box-sizing:border-box;margin:0;padding:0;}body{background:#0d1117;color:#e6edf3;font-family:'Inter',system-ui,sans-serif;font-size:13px;}.nav{background:#161b22;border-bottom:1px solid #30363d;padding:12px 20px;display:flex;align-items:center;gap:10px;position:sticky;top:0;}.nav-title{font-size:13px;font-weight:600;color:#e6edf3;flex:1;}.btn{display:inline-flex;align-items:center;gap:6px;padding:6px 14px;border-radius:7px;text-decoration:none;font-size:12px;font-weight:600;border:1px solid;}.btn-back{background:#21262d;color:#e6edf3;border-color:#30363d;}.content{padding:24px;}pre{font-family:'JetBrains Mono',monospace;font-size:11px;line-height:1.8;color:#adbac7;background:#161b22;border:1px solid #30363d;border-radius:8px;padding:16px 20px;overflow-x:auto;}</style></head><body>
<div class="nav"><button class="btn btn-back" onclick="if(window.history.length>1){window.history.back();}else{window.location.href='$_back_url';}">← Back to Dashboard</button><span class="nav-title">running_activity.out — All Connections Raw</span></div>
<div class="content"><pre>$(cat "$_cf" | htmlesc)</pre></div></body></html>
RAWEOF
    fi

    # ── Replication tabular + raw ──
    _rf=$(find "$_lp" -type f \( -name "pg_stat_replication.out" -o -name "replication.out" \) | head -n1)
    if [ -f "$_rf" ]; then
        _rfname=$(basename "$_rf")
        # Write tabular page directly with awk — avoids pipeline subshell issue
        { cat << REPLHDR
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"/>
<title>Stat Replication — $_host</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400&display=swap');
  *{box-sizing:border-box;margin:0;padding:0;}
  body{background:#0d1117;color:#e6edf3;font-family:'Inter',system-ui,sans-serif;font-size:13px;}
  .nav{background:#161b22;border-bottom:1px solid #30363d;padding:12px 20px;display:flex;align-items:center;gap:10px;position:sticky;top:0;z-index:10;}
  .nav-title{font-size:13px;font-weight:600;color:#e6edf3;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
  .btn{display:inline-flex;align-items:center;gap:6px;padding:6px 14px;border-radius:7px;text-decoration:none;font-size:12px;font-weight:600;white-space:nowrap;border:1px solid;}
  .btn-back{background:#21262d;color:#e6edf3;border-color:#30363d;}.btn-raw{background:#21262d;color:#8b949e;border-color:#30363d;}
  .content{padding:20px 24px;}.tbl-title{font-size:14px;font-weight:600;color:#e6edf3;margin-bottom:4px;}
  .tbl-sub{font-family:'JetBrains Mono',monospace;font-size:10px;color:#8b949e;margin-bottom:16px;}
  .tbl-wrap{overflow-x:auto;border:1px solid #30363d;border-radius:8px;}
  table{border-collapse:collapse;width:max-content;min-width:100%;}
  thead th{background:#161b22;color:#8b949e;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.5px;padding:10px 16px;text-align:left;border-bottom:1px solid #30363d;white-space:nowrap;}
  tbody td{padding:9px 16px;border-bottom:1px solid #21262d;color:#c9d1d9;font-family:'JetBrains Mono',monospace;font-size:11px;white-space:nowrap;vertical-align:middle;}
  tbody tr:last-child td{border-bottom:none;}tbody tr:hover{background:#161b22;}
</style></head><body>
<div class="nav">
  <button class="btn btn-back" onclick="if(window.history.length>1){window.history.back();}else{window.location.href='$_back_url';}">← Back to Dashboard</button>
  <span class="nav-title">Stat Replication — $_host</span>
  <a href="repl_raw.html" class="btn btn-raw" target="_self">≡ Raw File</a>
</div>
<div class="content">
  <div class="tbl-title">Stat Replication — $_host</div>
  <div class="tbl-sub">$_rfname</div>
  <div class="tbl-wrap"><table><thead><tr>
REPLHDR
          head -n1 "$_rf" | tr -d '\r' | tr '	' '\n' | while read -r _col; do
              printf '<th>%s</th>' "$(echo "$_col" | htmlesc)"
          done
          echo "</tr></thead><tbody>"
          awk -F'\t' 'NR>1{printf "<tr>"; for(i=1;i<=NF;i++){val=$i; gsub(/&/,"\\&amp;",val); gsub(/</,"\\&lt;",val); gsub(/>/,"\\&gt;",val); printf "<td>%s</td>",val}; print "</tr>"}' "$_rf"
          echo "</tbody></table></div></div></body></html>"
        } > "$_ndir/repl_tbl.html"
        cat > "$_ndir/repl_raw.html" <<RAWEOF
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"/><title>Raw — $_rfname</title>
<style>@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400&display=swap');*{box-sizing:border-box;margin:0;padding:0;}body{background:#0d1117;color:#e6edf3;font-family:'Inter',system-ui,sans-serif;font-size:13px;}.nav{background:#161b22;border-bottom:1px solid #30363d;padding:12px 20px;display:flex;align-items:center;gap:10px;position:sticky;top:0;}.nav-title{font-size:13px;font-weight:600;color:#e6edf3;flex:1;}.btn{display:inline-flex;align-items:center;gap:6px;padding:6px 14px;border-radius:7px;text-decoration:none;font-size:12px;font-weight:600;border:1px solid;}.btn-back{background:#21262d;color:#e6edf3;border-color:#30363d;}.btn-tbl{background:#2f81f7;color:#fff;border-color:#2f81f7;}.content{padding:24px;}pre{font-family:'JetBrains Mono',monospace;font-size:11px;line-height:1.8;color:#adbac7;background:#161b22;border:1px solid #30363d;border-radius:8px;padding:16px 20px;overflow-x:auto;}</style></head><body>
<div class="nav"><button class="btn btn-back" onclick="if(window.history.length>1){window.history.back();}else{window.location.href='$_back_url';}">← Back to Dashboard</button><span class="nav-title">$_rfname — Raw View</span><a href="repl_tbl.html" class="btn btn-tbl" target="_self">⊞ Table View</a></div>
<div class="content"><pre>$(cat "$_rf" | htmlesc)</pre></div></body></html>
RAWEOF
    fi

    # ── Replication slots tabular + raw ──
    _sf=$(find "$_lp" -type f -name "replication_slots.out" | head -n1)
    if [ -f "$_sf" ]; then
        # Write tabular page directly with awk — avoids pipeline subshell issue
        { cat << SLOTHDR
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"/>
<title>Replication Slots — $_host</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400&display=swap');
  *{box-sizing:border-box;margin:0;padding:0;}
  body{background:#0d1117;color:#e6edf3;font-family:'Inter',system-ui,sans-serif;font-size:13px;}
  .nav{background:#161b22;border-bottom:1px solid #30363d;padding:12px 20px;display:flex;align-items:center;gap:10px;position:sticky;top:0;z-index:10;}
  .nav-title{font-size:13px;font-weight:600;color:#e6edf3;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
  .btn{display:inline-flex;align-items:center;gap:6px;padding:6px 14px;border-radius:7px;text-decoration:none;font-size:12px;font-weight:600;white-space:nowrap;border:1px solid;}
  .btn-back{background:#21262d;color:#e6edf3;border-color:#30363d;}.btn-raw{background:#21262d;color:#8b949e;border-color:#30363d;}
  .content{padding:20px 24px;}.tbl-title{font-size:14px;font-weight:600;color:#e6edf3;margin-bottom:4px;}
  .tbl-sub{font-family:'JetBrains Mono',monospace;font-size:10px;color:#8b949e;margin-bottom:16px;}
  .tbl-wrap{overflow-x:auto;border:1px solid #30363d;border-radius:8px;}
  table{border-collapse:collapse;width:max-content;min-width:100%;}
  thead th{background:#161b22;color:#8b949e;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.5px;padding:10px 16px;text-align:left;border-bottom:1px solid #30363d;white-space:nowrap;}
  tbody td{padding:9px 16px;border-bottom:1px solid #21262d;color:#c9d1d9;font-family:'JetBrains Mono',monospace;font-size:11px;white-space:nowrap;vertical-align:middle;}
  tbody tr:last-child td{border-bottom:none;}tbody tr:hover{background:#161b22;}
  .slot-t{color:#3fb950;font-weight:600;}.slot-f{color:#f85149;}
</style></head><body>
<div class="nav">
  <button class="btn btn-back" onclick="if(window.history.length>1){window.history.back();}else{window.location.href='$_back_url';}">← Back to Dashboard</button>
  <span class="nav-title">Replication Slots — $_host</span>
  <a href="slots_raw.html" class="btn btn-raw" target="_self">≡ Raw File</a>
</div>
<div class="content">
  <div class="tbl-title">Replication Slots — $_host</div>
  <div class="tbl-sub">replication_slots.out</div>
  <div class="tbl-wrap"><table><thead><tr>
SLOTHDR
          head -n1 "$_sf" | tr -d '\r' | tr '	' '\n' | while read -r _col; do
              printf '<th>%s</th>' "$(echo "$_col" | htmlesc)"
          done
          echo "</tr></thead><tbody>"
          # Colour-code active column: t=green dot, f=red dot
          awk -F'\t' 'NR>1{
              printf "<tr>"
              for(i=1;i<=NF;i++){
                  val=$i; gsub(/&/,"\\&amp;",val); gsub(/</,"\\&lt;",val); gsub(/>/,"\\&gt;",val)
                  if(val=="t") printf "<td><span class=\"slot-t\">&#9679; (t)</span></td>"
                  else if(val=="f") printf "<td><span class=\"slot-f\">&#9675; (f)</span></td>"
                  else printf "<td>%s</td>",val
              }
              print "</tr>"
          }' "$_sf"
          echo "</tbody></table></div></div></body></html>"
        } > "$_ndir/slots_tbl.html"
        cat > "$_ndir/slots_raw.html" <<RAWEOF
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"/><title>Raw — replication_slots.out</title>
<style>@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400&display=swap');*{box-sizing:border-box;margin:0;padding:0;}body{background:#0d1117;color:#e6edf3;font-family:'Inter',system-ui,sans-serif;font-size:13px;}.nav{background:#161b22;border-bottom:1px solid #30363d;padding:12px 20px;display:flex;align-items:center;gap:10px;position:sticky;top:0;}.nav-title{font-size:13px;font-weight:600;color:#e6edf3;flex:1;}.btn{display:inline-flex;align-items:center;gap:6px;padding:6px 14px;border-radius:7px;text-decoration:none;font-size:12px;font-weight:600;border:1px solid;}.btn-back{background:#21262d;color:#e6edf3;border-color:#30363d;}.btn-tbl{background:#2f81f7;color:#fff;border-color:#2f81f7;}.content{padding:24px;}pre{font-family:'JetBrains Mono',monospace;font-size:11px;line-height:1.8;color:#adbac7;background:#161b22;border:1px solid #30363d;border-radius:8px;padding:16px 20px;overflow-x:auto;}</style></head><body>
<div class="nav"><button class="btn btn-back" onclick="if(window.history.length>1){window.history.back();}else{window.location.href='$_back_url';}">← Back to Dashboard</button><span class="nav-title">replication_slots.out — Raw View</span><a href="slots_tbl.html" class="btn btn-tbl" target="_self">⊞ Table View</a></div>
<div class="content"><pre>$(cat "$_sf" | htmlesc)</pre></div></body></html>
RAWEOF
    fi

    # ── Config files (configuration.out, efm.properties, postgresql.auto.conf) ──
    find "$_lp" -type f \( -name "configuration.out" -o -name "efm.properties" -o -name "postgresql.auto.conf" \) | sort | while read -r _cf2; do
        _cfname=$(basename "$_cf2")
        _cftitle="Config: $_cfname — $_host"
        # Build tabular page directly with awk — avoids pipeline subshell issue
        if [ "$_cfname" = "efm.properties" ]; then
            _cf2_tsv=$(mktemp)
            printf "parameter\tvalue\n" > "$_cf2_tsv"
            grep -v "^[[:space:]]*#" "$_cf2" | grep -v "^[[:space:]]*$" | grep "=" | \
                while IFS='=' read -r _pk _pv; do
                    printf "%s\t%s\n" "$(echo "$_pk" | tr -d '\r')" "$(echo "$_pv" | tr -d '\r')"
                done >> "$_cf2_tsv"
            { printf '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"/><title>%s</title>' "$_cftitle"
              cat << 'CFGCSS'
<style>@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400&display=swap');*{box-sizing:border-box;margin:0;padding:0;}body{background:#0d1117;color:#e6edf3;font-family:'Inter',system-ui,sans-serif;font-size:13px;}.nav{background:#161b22;border-bottom:1px solid #30363d;padding:12px 20px;display:flex;align-items:center;gap:10px;position:sticky;top:0;z-index:10;}.nav-title{font-size:13px;font-weight:600;color:#e6edf3;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}.btn{display:inline-flex;align-items:center;gap:6px;padding:6px 14px;border-radius:7px;text-decoration:none;font-size:12px;font-weight:600;white-space:nowrap;border:1px solid;}.btn:hover{opacity:.85;}.btn-back{background:#21262d;color:#e6edf3;border-color:#30363d;}.btn-raw{background:#21262d;color:#8b949e;border-color:#30363d;}.content{padding:20px 24px;}.tbl-title{font-size:14px;font-weight:600;color:#e6edf3;margin-bottom:4px;}.tbl-sub{font-family:'JetBrains Mono',monospace;font-size:10px;color:#8b949e;margin-bottom:16px;}.tbl-wrap{overflow-x:auto;border:1px solid #30363d;border-radius:8px;}table{border-collapse:collapse;width:100%;table-layout:fixed;}thead th{background:#161b22;color:#8b949e;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.5px;padding:10px 16px;text-align:left;border-bottom:1px solid #30363d;white-space:nowrap;}thead th:first-child{width:260px;}tbody td{padding:9px 16px;border-bottom:1px solid #21262d;color:#c9d1d9;font-family:'JetBrains Mono',monospace;font-size:11px;white-space:normal;word-break:break-all;vertical-align:top;}tbody tr:last-child td{border-bottom:none;}tbody tr:hover{background:#161b22;}.pk{color:#79c0ff;font-weight:600;white-space:nowrap;}</style>
CFGCSS
              printf '</head><body>\n<div class="nav"><button class="btn btn-back" onclick="if(window.history.length>1){window.history.back();}else{window.location.href='"'"'%s'"'"';}">← Back to Dashboard</button><span class="nav-title">%s</span><a href="cfg_%s_raw.html" class="btn btn-raw" target="_self">≡ Raw File</a></div>\n' "$_back_url" "$_cftitle" "$_cfname"
              printf '<div class="content"><div class="tbl-title">%s</div><div class="tbl-sub">%s</div><div class="tbl-wrap"><table><thead><tr><th>Parameter</th><th>Value</th></tr></thead><tbody>\n' "$_cftitle" "$_cfname"
              awk -F'\t' 'NR>1{val=$2; gsub(/&/,"\\&amp;",val); gsub(/</,"\\&lt;",val); gsub(/>/,"\\&gt;",val); printf "<tr><td class=\"pk\">%s</td><td>%s</td></tr>\n",$1,val}' "$_cf2_tsv"
              printf '</tbody></table></div></div></body></html>\n'
            } > "$_ndir/cfg_${_cfname}.html"
            rm -f "$_cf2_tsv"
        else
            { printf '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"/><title>%s</title>' "$_cftitle"
              cat << 'CFGCSS2'
<style>@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400&display=swap');*{box-sizing:border-box;margin:0;padding:0;}body{background:#0d1117;color:#e6edf3;font-family:'Inter',system-ui,sans-serif;font-size:13px;}.nav{background:#161b22;border-bottom:1px solid #30363d;padding:12px 20px;display:flex;align-items:center;gap:10px;position:sticky;top:0;z-index:10;}.nav-title{font-size:13px;font-weight:600;color:#e6edf3;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}.btn{display:inline-flex;align-items:center;gap:6px;padding:6px 14px;border-radius:7px;text-decoration:none;font-size:12px;font-weight:600;white-space:nowrap;border:1px solid;}.btn:hover{opacity:.85;}.btn-back{background:#21262d;color:#e6edf3;border-color:#30363d;}.btn-raw{background:#21262d;color:#8b949e;border-color:#30363d;}.content{padding:20px 24px;}.tbl-title{font-size:14px;font-weight:600;color:#e6edf3;margin-bottom:4px;}.tbl-sub{font-family:'JetBrains Mono',monospace;font-size:10px;color:#8b949e;margin-bottom:16px;}.tbl-wrap{overflow-x:auto;border:1px solid #30363d;border-radius:8px;}table{border-collapse:collapse;width:max-content;min-width:100%;}thead th{background:#161b22;color:#8b949e;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.5px;padding:10px 16px;text-align:left;border-bottom:1px solid #30363d;white-space:nowrap;}tbody td{padding:9px 16px;border-bottom:1px solid #21262d;color:#c9d1d9;font-family:'JetBrains Mono',monospace;font-size:11px;white-space:nowrap;vertical-align:middle;}tbody tr:last-child td{border-bottom:none;}tbody tr:hover{background:#161b22;}</style>
CFGCSS2
              printf '</head><body>\n<div class="nav"><button class="btn btn-back" onclick="if(window.history.length>1){window.history.back();}else{window.location.href='"'"'%s'"'"';}">← Back to Dashboard</button><span class="nav-title">%s</span><a href="cfg_%s_raw.html" class="btn btn-raw" target="_self">≡ Raw File</a></div>\n' "$_back_url" "$_cftitle" "$_cfname"
              printf '<div class="content"><div class="tbl-title">%s</div><div class="tbl-sub">%s</div><div class="tbl-wrap"><table><thead><tr>' "$_cftitle" "$_cfname"
              head -n1 "$_cf2" | tr -d '\r' | tr '	' '\n' | while read -r _col; do printf '<th>%s</th>' "$(echo "$_col" | htmlesc)"; done
              printf '</tr></thead><tbody>\n'
              awk -F'\t' 'NR>1{printf "<tr>"; for(i=1;i<=NF;i++){val=$i; gsub(/&/,"\\&amp;",val); gsub(/</,"\\&lt;",val); gsub(/>/,"\\&gt;",val); printf "<td>%s</td>",val}; print "</tr>"}' "$_cf2"
              printf '</tbody></table></div></div></body></html>\n'
            } > "$_ndir/cfg_${_cfname}.html"
        fi
        cat > "$_ndir/cfg_${_cfname}_raw.html" <<RAWEOF
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"/><title>Raw — $_cfname</title>
<style>@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400&display=swap');*{box-sizing:border-box;margin:0;padding:0;}body{background:#0d1117;color:#e6edf3;font-family:'Inter',system-ui,sans-serif;font-size:13px;}.nav{background:#161b22;border-bottom:1px solid #30363d;padding:12px 20px;display:flex;align-items:center;gap:10px;position:sticky;top:0;}.nav-title{font-size:13px;font-weight:600;color:#e6edf3;flex:1;}.btn{display:inline-flex;align-items:center;gap:6px;padding:6px 14px;border-radius:7px;text-decoration:none;font-size:12px;font-weight:600;border:1px solid;}.btn-back{background:#21262d;color:#e6edf3;border-color:#30363d;}.btn-tbl{background:#2f81f7;color:#fff;border-color:#2f81f7;}.content{padding:24px;}pre{font-family:'JetBrains Mono',monospace;font-size:11px;line-height:1.8;color:#adbac7;background:#161b22;border:1px solid #30363d;border-radius:8px;padding:16px 20px;overflow-x:auto;}</style></head><body>
<div class="nav"><button class="btn btn-back" onclick="if(window.history.length>1){window.history.back();}else{window.location.href='$_back_url';}">← Back to Dashboard</button><span class="nav-title">$_cfname — Raw View</span><a href="cfg_${_cfname}.html" class="btn btn-tbl" target="_self">⊞ Table View</a></div>
<div class="content"><pre>$(cat "$_cf2" | htmlesc)</pre></div></body></html>
RAWEOF
    done
    # ── OS data files (raw view only) ──
    # Build a raw view page for each OS file.
    # For vmstat.data: keep BOTH copies (linux/vmstat.data and linux/proc/vmstat.data)
    # and give each a unique asset filename derived from its parent directory.
    # For all other files: deduplicate by basename (keep first found).
    find "$_lp" -type f \( -name "dmesg.data" -o -name "cpuinfo.data" -o -name "meminfo.data" -o -name "vmstat.data" -o -name "top.data" \) \
        | sort | while read -r _of; do
        _ofname=$(basename "$_of")
        _ofparent=$(basename "$(dirname "$_of")")
        # For vmstat: create unique asset key from parent dir name to keep both
        if [ "$_ofname" = "vmstat.data" ]; then
            _asset_key="vmstat_${_ofparent}.data"
        else
            _asset_key="$_ofname"
        fi
        # Skip duplicates for non-vmstat files
        _asset_file="$_ndir/os_${_asset_key}_raw.html"
        [ -f "$_asset_file" ] && [ "$_ofname" != "vmstat.data" ] && continue
        cat > "$_asset_file" <<RAWEOF
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"/><title>Raw — $_ofname (${_ofparent})</title>
<style>@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400&display=swap');*{box-sizing:border-box;margin:0;padding:0;}body{background:#0d1117;color:#e6edf3;font-family:'Inter',system-ui,sans-serif;font-size:13px;}.nav{background:#161b22;border-bottom:1px solid #30363d;padding:12px 20px;display:flex;align-items:center;gap:10px;position:sticky;top:0;}.nav-title{font-size:13px;font-weight:600;color:#e6edf3;flex:1;}.btn{display:inline-flex;align-items:center;gap:6px;padding:6px 14px;border-radius:7px;text-decoration:none;font-size:12px;font-weight:600;border:1px solid;}.btn-back{background:#21262d;color:#e6edf3;border-color:#30363d;}.content{padding:24px;}pre{font-family:'JetBrains Mono',monospace;font-size:11px;line-height:1.8;color:#adbac7;background:#161b22;border:1px solid #30363d;border-radius:8px;padding:16px 20px;overflow-x:auto;}</style></head><body>
<div class="nav"><button class="btn btn-back" onclick="if(window.history.length>1){window.history.back();}else{window.location.href='$_back_url';}">← Back to Dashboard</button><span class="nav-title">$_ofname (${_ofparent}) — Raw View</span></div>
<div class="content"><pre>$(cat "$_of" | htmlesc)</pre></div></body></html>
RAWEOF
    done

    # ── tables.out — full pg_stat_user_tables tabular page per database ──
    _dbs_d2=$(find "$_lp" -type d -name "dbs" -path "*/postgresql/*" | head -n1)
    if [ -d "$_dbs_d2" ]; then
        for _dbdir2 in "$_dbs_d2"/*/; do
            _dbn2=$(basename "$_dbdir2")
            _tf2="$_dbdir2/tables.out"
            [ -f "$_tf2" ] || continue
            _tpage="$_ndir/tables_${_dbn2}.html"
            _ttitle="Tables — $_dbn2 ($(basename "$_lp"))"
            { cat << TABLEHDR
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"/>
<title>$_ttitle</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400&display=swap');
  *{box-sizing:border-box;margin:0;padding:0;}
  body{background:#0d1117;color:#e6edf3;font-family:'Inter',system-ui,sans-serif;font-size:13px;}
  .nav{background:#161b22;border-bottom:1px solid #30363d;padding:12px 20px;display:flex;align-items:center;gap:10px;position:sticky;top:0;z-index:10;}
  .nav-title{font-size:13px;font-weight:600;color:#e6edf3;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
  .btn{display:inline-flex;align-items:center;gap:6px;padding:6px 14px;border-radius:7px;text-decoration:none;font-size:12px;font-weight:600;white-space:nowrap;border:1px solid;}
  .btn-back{background:#21262d;color:#e6edf3;border-color:#30363d;}
  .content{padding:20px 24px;}
  .tbl-title{font-size:14px;font-weight:600;color:#e6edf3;margin-bottom:4px;}
  .tbl-sub{font-family:'JetBrains Mono',monospace;font-size:10px;color:#8b949e;margin-bottom:16px;}
  .tbl-wrap{overflow-x:auto;border:1px solid #30363d;border-radius:8px;}
  table{border-collapse:collapse;width:max-content;min-width:100%;}
  thead th{background:#161b22;color:#8b949e;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.5px;padding:10px 14px;text-align:left;border-bottom:1px solid #30363d;white-space:nowrap;}
  tbody td{padding:8px 14px;border-bottom:1px solid #21262d;color:#c9d1d9;font-family:'JetBrains Mono',monospace;font-size:11px;white-space:nowrap;vertical-align:middle;}
  tbody tr:last-child td{border-bottom:none;}tbody tr:hover{background:#161b22;}
  .td-hi{color:#f85149;font-weight:600;} .td-warn{color:#d29922;}
  .td-ok{color:#3fb950;}
</style></head><body>
<div class="nav">
  <button class="btn btn-back" onclick="if(window.history.length>1){window.history.back();}else{window.location.href='$_back_url';}">← Back to Dashboard</button>
  <span class="nav-title">$_ttitle</span>
</div>
<div class="content">
  <div class="tbl-title">$_ttitle</div>
  <div class="tbl-sub">tables.out — pg_stat_user_tables</div>
  <div class="tbl-wrap"><table><thead><tr>
TABLEHDR
              head -n1 "$_tf2" | tr -d '\r' | tr '	' '\n' | while read -r _col; do
                  printf '<th>%s</th>' "$(echo "$_col" | htmlesc)"
              done
              echo "</tr></thead><tbody>"
              # Sort by n_dead_tup desc, highlight high seq_scan and bloat
              awk -F'\t' '
              NR==1{
                  for(i=1;i<=NF;i++){h=tolower($i);gsub(/\r/,"",h);col[h]=i}
                  sc_c=col["seq_scan"]+0; ix_c=col["idx_scan"]+0
                  nd_c=(col["n_dead_tup"])?col["n_dead_tup"]:0
                  nl_c=(col["n_live_tup"])?col["n_live_tup"]:0
                  rn_c=col["relname"]?col["relname"]:(col["tablename"]?col["tablename"]:2)
                  next
              }
              NR>1 && NF>1{
                  # Use n_dead_tup as sort key
                  dead=(nd_c>0)?$nd_c+0:0
                  live=(nl_c>0)?$nl_c+0:0
                  total=live+dead
                  ratio=(total>0)?(dead/total)*100:0
                  printf "%010d\t", dead
                  for(i=1;i<=NF;i++){
                      val=$i; gsub(/&/,"\\&amp;",val);gsub(/</,"\\&lt;",val);gsub(/>/,"\\&gt;",val)
                      cls=""
                      # Highlight seq_scan heavy tables
                      if(i==sc_c && val+0>100000) cls=" class=\"td-hi\""
                      else if(i==sc_c && val+0>10000) cls=" class=\"td-warn\""
                      # Highlight high bloat
                      if(i==nd_c && ratio>50) cls=" class=\"td-hi\""
                      else if(i==nd_c && ratio>20) cls=" class=\"td-warn\""
                      printf "<td%s>%s</td>",cls,val
                  }
                  print "</tr>"
              }' "$_tf2" 2>/dev/null | sort -rn | sed 's/^[0-9]*\t/<tr>/'
              echo "</tbody></table></div></div></body></html>"
            } > "$_tpage"
        done
    fi

    # ── Lasso Report full file tree viewer ──
    build_pgradar_tree_viewer "$_nid" "$_lp" "$_ndir"

done < "$NODES_META"

pb_step "Building HTML dashboard..."

# =============================================================================
# STEP 8 — Build the complete tabbed HTML dashboard
#           All output is redirected into OUTFILE via the { ... } > "$OUTFILE"
#           wrapper at the bottom of this section.
# =============================================================================


# Helper: emit a full node dashboard panel (all sections) for one node.
# This is called once per node inside the HTML build loop.
# Args: node_id role hostname lasso_path node_assets_dir
emit_node_panel() {
    _nid="$1"; _role="$2"; _host="$3"; _lp="$4"; _ndir="$5"

    # Relative path from OUTFILE (in PGRADAR_OUTPUT/) to this node's asset folder
    # Used for all hrefs inside the HTML so links work as relative URLs in the browser
    _rel_ndir="$(basename "$ASSETS_DIR")/$(basename "$_ndir")"
    _os=$(find "$_lp" -path "*/linux/id/os_release.data" -exec grep "PRETTY_NAME" {} + | cut -d'"' -f2)
    _pgver=$(find "$_lp" -path "*/postgresql/postgresql_server_version.data" -exec cat {} + 2>/dev/null)
    _cpu_model=$(find "$_lp" -path "*/proc/cpuinfo.data" -exec grep -m1 "model name" {} + 2>/dev/null | sed 's/.*: //')
    _cpu_cores=$(find "$_lp" -path "*/proc/cpuinfo.data" -exec grep -c "processor" {} + 2>/dev/null || echo "N/A")
    _mem_f=$(find "$_lp" -path "*/proc/meminfo.data" | head -n1)

    if [ -f "$_mem_f" ]; then
        _mem_total_raw=$(get_gb_from "$_mem_f" "MemTotal")
        _mem_free_raw=$(get_gb_from "$_mem_f" "MemAvailable")
        _swap_total_raw=$(get_gb_from "$_mem_f" "SwapTotal")
        _swap_free_raw=$(get_gb_from "$_mem_f" "SwapFree")
        _swap_used_raw=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{printf "%.2f",(t-f)/1024/1024}' "$_mem_f")
        # Extra fields for OS Memory Pressure panel
        _huge_total=$(awk '/^HugePages_Total/{print $2}' "$_mem_f" | head -n1)
        _huge_free=$(awk '/^HugePages_Free/{print $2}'  "$_mem_f" | head -n1)
        _huge_rsvd=$(awk '/^HugePages_Rsvd/{print $2}'  "$_mem_f" | head -n1)
        _huge_size=$(awk '/^Hugepagesize/{print $2,$3}'  "$_mem_f" | head -n1)
        _commit_limit=$(awk '/^CommitLimit/{printf "%.1f GB",$2/1024/1024}' "$_mem_f" | head -n1)
        _committed=$(awk '/^Committed_AS/{printf "%.1f GB",$2/1024/1024}'  "$_mem_f" | head -n1)
        _swap_pct=$(echo "$_swap_total_raw $_swap_used_raw" | awk '{if($1>0)printf "%d",($2/$1)*100;else print "0"}' | tr -d '\n\r')
        _swap_pct=${_swap_pct:-0}
    else
        _mem_total_raw="0"; _mem_free_raw="0"; _swap_total_raw="0"; _swap_free_raw="0"; _swap_used_raw="0"
        _huge_total=""; _huge_free=""; _huge_rsvd=""; _huge_size=""; _commit_limit=""; _committed=""; _swap_pct="0"
    fi
    _mem_total="${_mem_total_raw} GB"; _mem_free="${_mem_free_raw} GB"
    _swap_total="${_swap_total_raw} GB"; _swap_free="${_swap_free_raw} GB"; _swap_used="${_swap_used_raw} GB"

    _top_f=$(find "$_lp" -path "*/top.data" | head -n1)
    if [ -f "$_top_f" ]; then
        _load_avg=$(grep "load average:" "$_top_f" | head -n1 | awk -F'load average: ' '{print $2}')
        _load_1=$(echo "$_load_avg" | awk -F',' '{print $1}' | tr -d ' ')
        _cpu_us=$(grep "%Cpu(s):" "$_top_f" | head -n1 | awk '{print $2}' | tr -d '%us,')
        _cpu_sy=$(grep "%Cpu(s):" "$_top_f" | head -n1 | awk '{print $4}' | tr -d '%sy,')
    else
        _load_avg="N/A"; _load_1="0"; _cpu_us="0"; _cpu_sy="0"
    fi
    _cpu_idle=$(echo "$_cpu_us $_cpu_sy" | awk '{i=100-$1-$2;if(i<0)i=0;printf "%.1f",i}')
    _mem_used_raw=$(echo "$_mem_total_raw $_mem_free_raw" | awk '{u=$1-$2;if(u<0)u=0;printf "%.2f",u}')
    _mem_used="${_mem_used_raw} GB"

    _conn_f=$(find "$_lp" -type f -name "running_activity.out" | head -n1)
    _conn_active=0; _conn_idle=0; _conn_idletx=0
    # Extract max_connections directly here so it's available for the connection donut
    _pf_conf=$(find "$_lp" -type f -name "configuration.out" | head -n1)
    _max_conn=$(awk -F'\t' '$1=="max_connections"{print $2+0}' "$_pf_conf" 2>/dev/null | head -n1)
    _max_conn="${_max_conn:-0}"
    if [ -f "$_conn_f" ]; then
        # Detect state/status column from header row — EDB uses "status", standard PG uses "state"
        # Read header to find the right column index, then count exactly by value
        _conn_counts=$(awk -F'\t' '
        NR==1{
            for(i=1;i<=NF;i++){
                h=tolower($i); gsub(/\r/,"",h)
                if(h=="state" || h=="status") sc=i
            }
            next
        }
        NR>1 && sc>0 {
            v=$sc; gsub(/\r/,"",v)
            if(v=="active")            act++
            else if(v=="idle in transaction" || v=="idle in transaction (aborted)") itx++
            else if(v=="idle")         idl++
        }
        END{print act+0, idl+0, itx+0}
        ' "$_conn_f" 2>/dev/null)
        _conn_active=$(echo "$_conn_counts" | awk '{print $1}')
        _conn_idle=$(  echo "$_conn_counts" | awk '{print $2}')
        _conn_idletx=$(echo "$_conn_counts" | awk '{print $3}')
        _conn_active=${_conn_active:-0}; _conn_idle=${_conn_idle:-0}; _conn_idletx=${_conn_idletx:-0}
    fi

    # Colour/style based on role
    case "$_role" in
        Primary) _role_color="#2f81f7"; _role_bg="rgba(29,78,216,.15)"; _role_border="rgba(29,78,216,.4)"; _role_icon="★" ;;
        Standby) _role_color="#3fb950"; _role_bg="rgba(15,110,86,.15)"; _role_border="rgba(15,110,86,.4)"; _role_icon="⟳" ;;
        Witness) _role_color="#94a3b8"; _role_bg="rgba(51,65,85,.3)";   _role_border="rgba(100,116,139,.4)"; _role_icon="◎" ;;
        *)       _role_color="#8b949e"; _role_bg="rgba(51,65,85,.2)";   _role_border="#30363d"; _role_icon="?" ;;
    esac

    # ── Node header ──
    echo "<div class='node-hdr'>"
    echo "  <div class='nh-icon' style='background:${_role_bg};color:${_role_color};'>${_role_icon}</div>"
    echo "  <div class='nh-info'>"
    echo "    <div class='nh-name'>${_host}</div>"
    echo "    <div class='nh-sub'>$(echo "$_os" | htmlesc) &nbsp;·&nbsp; $(echo "$_pgver" | head -c80 | htmlesc)</div>"
    echo "  </div>"
    echo "  <span class='nh-badge' style='background:${_role_bg};color:${_role_color};border:1px solid ${_role_border};'>${_role}</span>"
    echo "</div>"

    # ── Stat cards ──
    echo "<div class='stat-grid'>"
    echo "  <div class='sc' style='border-top:2px solid ${_role_color};'><div class='sc-l'>CPU Model</div><div class='sc-v' style='font-size:11px;'>$(echo "$_cpu_model" | htmlesc)</div></div>"
    echo "  <div class='sc' style='border-top:2px solid #a371f7;'><div class='sc-l'>Total Cores</div><div class='sc-v'>${_cpu_cores} Cores</div></div>"
    echo "  <div class='sc' style='border-top:2px solid #3fb950;'><div class='sc-l'>Total RAM</div><div class='sc-v'>${_mem_total}</div></div>"
    echo "  <div class='sc' style='border-top:2px solid #db6d28;'><div class='sc-l'>Free RAM</div><div class='sc-v'>${_mem_free}</div></div>"
    echo "</div>"

    # ── Donut charts ──
    echo "<div class='chart-row'>"

    # CPU donut
    echo "  <div class='chart-card'><div class='ct'>⚡ CPU Usage</div>"
    echo "    <div class='cl'>"
    echo "      <div class='clr'><span class='cll'><span class='cld' style='background:#2f81f7'></span>User</span><span class='clv'>${_cpu_us}%</span></div>"
    echo "      <div class='clr'><span class='cll'><span class='cld' style='background:#a371f7'></span>System</span><span class='clv'>${_cpu_sy}%</span></div>"
    echo "      <div class='clr'><span class='cll'><span class='cld' style='background:#334155'></span>Idle</span><span class='clv'>${_cpu_idle}%</span></div>"
    echo "    </div>"
    echo "    <div class='dw'>"
    svg_donut "CPU" "${_cpu_us}%" "User" "${_cpu_us}:#2f81f7:User" "${_cpu_sy}:#a371f7:Sys" "${_cpu_idle}:#334155:Idle"
    echo "    </div>"
    echo "    <div class='ss'><div class='sr'><span class='sk'>Load Average</span><span class='sv sw'>${_load_avg}</span></div><div class='sr'><span class='sk'>Cores</span><span class='sv'>${_cpu_cores}</span></div></div>"
    echo "  </div>"

    # Memory donut
    echo "  <div class='chart-card'><div class='ct'>🧠 Memory</div>"
    echo "    <div class='cl'>"
    echo "      <div class='clr'><span class='cll'><span class='cld' style='background:#3fb950'></span>Free</span><span class='clv'>${_mem_free}</span></div>"
    echo "      <div class='clr'><span class='cll'><span class='cld' style='background:#f85149'></span>Used</span><span class='clv'>${_mem_used}</span></div>"
    echo "      <div class='clr'><span class='cll'><span class='cld' style='background:#334155'></span>Total</span><span class='clv'>${_mem_total}</span></div>"
    echo "    </div>"
    echo "    <div class='dw'>"
    svg_donut "MEM" "${_mem_free_raw}" "GB free" "${_mem_free_raw}:#3fb950:Free" "${_mem_used_raw}:#f85149:Used"
    echo "    </div>"
    echo "    <div class='ss'><div class='sr'><span class='sk'>Installed</span><span class='sv'>${_mem_total}</span></div><div class='sr'><span class='sk'>Available</span><span class='sv so'>${_mem_free}</span></div></div>"
    echo "  </div>"

    # Swap donut
    echo "  <div class='chart-card'><div class='ct'>💾 Swap Space</div>"
    echo "    <div class='cl'>"
    echo "      <div class='clr'><span class='cll'><span class='cld' style='background:#d29922'></span>Used</span><span class='clv'>${_swap_used}</span></div>"
    echo "      <div class='clr'><span class='cll'><span class='cld' style='background:#3fb950'></span>Free</span><span class='clv'>${_swap_free}</span></div>"
    echo "      <div class='clr'><span class='cll'><span class='cld' style='background:#334155'></span>Total</span><span class='clv'>${_swap_total}</span></div>"
    echo "    </div>"
    echo "    <div class='dw'>"
    svg_donut "SWAP" "${_swap_used_raw}" "GB used" "${_swap_used_raw}:#d29922:Used" "${_swap_free_raw}:#3fb950:Free"
    echo "    </div>"
    echo "    <div class='ss'><div class='sr'><span class='sk'>Total</span><span class='sv'>${_swap_total}</span></div><div class='sr'><span class='sk'>Used</span><span class='sv sw'>${_swap_used}</span></div><div class='sr'><span class='sk'>Load 1m</span><span class='sv sw'>${_load_1}</span></div></div>"
    echo "  </div>"

    # Connections donut
    echo "  <div class='chart-card'><div class='ct'>🔌 Connections</div>"
    echo "    <div class='dw'>"
    svg_donut "CONN" "$_conn_active" "Active" "${_conn_active}:#3fb950:Active" "${_conn_idle}:#79c0ff:Idle" "${_conn_idletx}:#f85149:Idle-TX"
    echo "    </div>"
    if [ -f "$_conn_f" ]; then
        # Compute total used and pct of max_connections
        _conn_used=$(( _conn_active + _conn_idle + _conn_idletx ))
        _conn_pct=0
        [ "${_max_conn:-0}" -gt 0 ] 2>/dev/null && _conn_pct=$(( ${_conn_used:-0} * 100 / ${_max_conn:-1} ))
        _conn_pct=${_conn_pct:-0}
        if   [ "$_conn_pct" -ge 80 ] 2>/dev/null; then _cpct_c="var(--red)"; elif [ "$_conn_pct" -ge 60 ] 2>/dev/null; then _cpct_c="var(--yel)"; else _cpct_c="var(--grn)"; fi
        echo "    <div style='font-size:10px;color:var(--mut);padding:4px 8px 2px;display:flex;justify-content:space-between;align-items:center;'>"
        echo "      <span>Used <b style='color:${_cpct_c};'>${_conn_used}</b> of <b>${_max_conn:-?}</b> max_connections</span>"
        echo "      <span style='color:${_cpct_c};font-weight:600;'>${_conn_pct}%</span>"
        echo "    </div>"
        echo "    <div style='height:4px;background:var(--bdr);border-radius:2px;margin:0 8px 6px;'><div style='height:100%;width:${_conn_pct}%;background:${_cpct_c};border-radius:2px;'></div></div>"
        echo "    <div class='conn-drill'>"
        echo "      <div class='cdr'><span class='cdl' style='color:#3fb950;'>Active <b>${_conn_active}</b></span><a href='${_rel_ndir}/conn_act.html' class='cdb' target='_self'>View Active Sessions</a></div>"
        echo "      <div class='cdr'><span class='cdl' style='color:#79c0ff;'>Idle <b>${_conn_idle}</b></span><a href='${_rel_ndir}/conn_idl.html' class='cdb' target='_self'>View Idle Sessions</a></div>"
        echo "      <div class='cdr'><span class='cdl' style='color:#f85149;'>Idle-TX <b>${_conn_idletx}</b></span><a href='${_rel_ndir}/conn_itx.html' class='cdb' target='_self'>View Idle-TX Sessions</a></div>"
        echo "      <div class='cdr' style='margin-top:4px;border-top:1px solid var(--bdr);padding-top:6px;'><span class='cdl' style='color:var(--mut);font-size:10px;'>All connections raw</span><a href='${_rel_ndir}/conn_raw.html' class='cdb cdb-raw' target='_self'>View Raw File</a></div>"
        echo "    </div>"
    fi
    echo "  </div>"

    echo "</div>" # end chart-row

    # ── PG Parameters + Config Files + Lasso Report (3-in-1 grid) ──
    # Layout: Left = PG Important Parameters (3fr)
    #         Right = Full Config Files stacked above Lasso Report panel (2fr)
    echo "<div class='params-cfg-grid'>"

    # LEFT: PostgreSQL Important Parameters
    echo "<div>"
    echo "<div class='sh'>🐘 PostgreSQL Important Parameters</div>"
    echo "<div class='tc'><table><thead><tr><th>Parameter</th><th>Value</th><th>Remarks</th></tr></thead><tbody>"
    find "$_lp" -type f -name "configuration.out" | sort | head -n1 | while read -r _pf; do
        _avm=$(awk -F'\t' '$1=="autovacuum_max_workers"{print $2}' "$_pf" | head -n1); _avm="${_avm:-3}"
        _max_conn=$(awk -F'\t' '$1=="max_connections"{print $2}' "$_pf" | head -n1); _max_conn="${_max_conn:-100}"
        _auto_conf=$(find "$_lp" -type f -name "postgresql.auto.conf" | head -n1)
        _ssn_override=""
        [ -f "$_auto_conf" ] && _ssn_override=$(grep "^synchronous_standby_names" "$_auto_conf" | tail -n1 | sed "s/.*= *//;s/'//g;s/\"//g" | tr -d '\r\n')
        for _p in wal_level max_wal_senders max_replication_slots synchronous_standby_names synchronous_commit hot_standby archive_mode archive_command wal_keep_size max_wal_size checkpoint_completion_target listen_addresses port max_connections shared_buffers work_mem maintenance_work_mem autovacuum autovacuum_max_workers log_min_duration_statement; do
            _v=$(awk -F'\t' -v p="$_p" '$1==p{print $2}' "$_pf" | head -n1)
            [ "$_p" = "synchronous_standby_names" ] && [ -n "$_ssn_override" ] && _v="$_ssn_override (auto.conf)"
            _dv="${_v:-[Not Set]}"
            _full_remark=$(pg_remark "$_p" "$_v" "$_role" "$_mem_total_raw" "$_cpu_cores" "$_avm" "$_max_conn")
            # Extract badge class and build short label for the badge
            _badge_class=$(echo "$_full_remark" | sed "s/.*class='//;s/'.*//")
            _full_text=$(echo "$_full_remark" | sed 's/<[^>]*>//g')
            # Short label: first segment up to first — or ; or ( 
            _short=$(echo "$_full_text" | sed 's/ — .*//' | sed 's/ - .*//' | sed 's/;.*//' | cut -c1-40)
            # Tooltip-enhanced badge: short text visible, full text on hover/click
            _rm="<span class='${_badge_class} pg-tip' title='$(echo "$_full_text" | sed "s/'/\&apos;/g")'>${_short}</span>"
            echo "<tr><td class='mc'>$_p</td><td class='mc'>$(echo "$_dv" | htmlesc)</td><td>$_rm</td></tr>"
        done
    done
    echo "</tbody></table></div>"
    echo "</div>"

    # RIGHT: Full Configuration Files + OS System Files + Lasso Report stacked vertically
    echo "<div class='cfg-lasso-col'>"

    echo "<div class='sh'>📄 Full Configuration Files</div>"
    echo "<div class='cfg-grid'>"
    find "$_lp" -type f \( -name "configuration.out" -o -name "efm.properties" -o -name "postgresql.auto.conf" \) | sort | while read -r _cf3; do
        _cfn=$(basename "$_cf3")
        case "$_cfn" in
            configuration.out)    _ci="🐘"; _cd="PostgreSQL runtime parameters"; _cc="var(--pri)" ;;
            efm.properties)       _ci="🛡️"; _cd="EFM cluster configuration";      _cc="var(--pur)" ;;
            postgresql.auto.conf) _ci="⚙️";  _cd="Auto-managed PG overrides";      _cc="var(--org)" ;;
            *)                    _ci="📄"; _cd="Configuration file";              _cc="var(--mut)" ;;
        esac
        echo "  <div class='cfg-card'>"
        echo "    <div class='cfg-left'><div class='cfg-icon' style='color:${_cc};'>$_ci</div><div class='cfg-info'><div class='cfg-name'>$_cfn</div><div class='cfg-desc'>$_cd</div></div></div>"
        echo "    <div class='cfg-acts'><a href='${_rel_ndir}/cfg_${_cfn}.html' class='cfg-btn cfg-pri' target='_self'>⊞ Tabular</a><a href='${_rel_ndir}/cfg_${_cfn}_raw.html' class='cfg-btn cfg-raw' target='_self'>≡ Raw</a></div>"
        echo "  </div>"
    done
    echo "</div>"

    # OS System Files — moved here between Config Files and Lasso Report
    echo "<div class='sh'>🖥️ OS System Files</div>"
    echo "<div class='os-grid'>"
    # For vmstat.data: show BOTH copies with parent directory as label suffix.
    # For all other files: deduplicate by basename (keep first found).
    find "$_lp" -type f \( -name "dmesg.data" -o -name "cpuinfo.data" -o -name "meminfo.data" -o -name "vmstat.data" -o -name "top.data" \) \
        | sort | while read -r _of2; do
        _ofn=$(basename "$_of2")
        _ofparent=$(basename "$(dirname "$_of2")")
        # Build asset key — vmstat gets unique key per parent dir
        if [ "$_ofn" = "vmstat.data" ]; then
            _asset_key="vmstat_${_ofparent}.data"
        else
            _asset_key="$_ofn"
        fi
        # Skip non-vmstat duplicates
        if [ "$_ofn" != "vmstat.data" ]; then
            [ -n "$(eval echo \${_seen_${_asset_key//[^a-zA-Z0-9]/_}:-})" ] && continue
            eval "_seen_${_asset_key//[^a-zA-Z0-9]/_}=1"
        fi
        # Set display name and description
        case "$_ofn" in
            dmesg.data)   _oi="🔔"; _od="Kernel ring buffer messages" ;;
            cpuinfo.data) _oi="⚙️";  _od="CPU model, cores &amp; flags" ;;
            meminfo.data) _oi="🧠"; _od="Memory &amp; swap usage breakdown" ;;
            top.data)     _oi="📈"; _od="Process &amp; CPU snapshot" ;;
            vmstat.data)  _oi="📊"
                case "$_ofparent" in
                    proc) _od="Virtual memory stats — /proc/vmstat" ; _display_name="vmstat.data (proc)" ;;
                    linux) _od="Virtual memory &amp; I/O stats — vmstat command" ; _display_name="vmstat.data (linux)" ;;
                    *)    _od="Virtual memory &amp; I/O stats (${_ofparent})" ; _display_name="vmstat.data (${_ofparent})" ;;
                esac ;;
            *)            _oi="📄"; _od="System data file" ;;
        esac
        # Use display name (with suffix) for vmstat, plain name for others
        [ "$_ofn" = "vmstat.data" ] && _show_name="$_display_name" || _show_name="$_ofn"
        echo "  <div class='os-card'><div class='os-icon'>$_oi</div><div class='os-body'><div class='os-name'>$(echo "$_show_name" | htmlesc)</div><div class='os-desc'>$_od</div></div><a href='${_rel_ndir}/os_${_asset_key}_raw.html' class='os-btn' target='_self'>View File</a></div>"
    done
    echo "</div>"

    # Lasso Report panel — stacked below OS files in same right column
    echo "<div class='sh'>📦 Lasso Report</div>"
    echo "<div class='lasso-report-panel'>"
    echo "  <div class='lr-actions'>"
    echo "    <a href='${_rel_ndir}/pgradar_tree.html' class='lr-open-btn' target='_self'>🗂️ Open Lasso File Explorer</a>"
    echo "    <span class='lr-hint'>Browse every file in this node's Lasso bundle — full directory tree, line numbers, Prev / Next navigation</span>"
    echo "  </div>"
    echo "</div>"

    echo "</div>" # end cfg-lasso-col
    echo "</div>" # end params-cfg-grid

    # ── pg_stat_bgwriter — COMMENTED OUT — reserved for future enhancement ──
    # To re-enable: remove the : '<<BGW_DISABLED' block and the matching BGW_DISABLED line
    if false; then
    # ── pg_stat_bgwriter Checkpoint Health — disabled, preserved for future use ──
    # To re-enable: change "if false; then" above to "if true; then" (or remove wrapper)
    _bgwf=$(find "$_lp" -type f \( \
        -name "pg_stat_bgwriter.out" -o \
        -name "pg_stat_bgwriter.data" -o \
        -name "bgwriter.out" -o \
        -name "stat_bgwriter.out" \
    \) 2>/dev/null | head -n1)
    echo "<div class='sh'>📊 Checkpoint Health <span style='font-size:10px;color:var(--mut);font-weight:400;'>(pg_stat_bgwriter)</span></div>"
    echo "<div class='bgw-panel'>"
    if [ -f "$_bgwf" ]; then
        _bgw_vals=$(awk -F'\t' '
        NR==1{for(i=1;i<=NF;i++){h=tolower($i);gsub(/\r/,"",h);col[h]=i};next}
        NR==2{
            timed=col["checkpoints_timed"]?$col["checkpoints_timed"]:$1
            req=col["checkpoints_req"]?$col["checkpoints_req"]:$2
            bufc=col["buffers_checkpoint"]?$col["buffers_checkpoint"]:$5
            bufs=col["buffers_clean"]?$col["buffers_clean"]:$6
            bufa=col["buffers_alloc"]?$col["buffers_alloc"]:$10
            reset=col["stats_reset"]?$col["stats_reset"]:$11
            gsub(/\r/,"",timed);gsub(/\r/,"",req);gsub(/\r/,"",bufc)
            gsub(/\r/,"",bufs);gsub(/\r/,"",bufa);gsub(/\r/,"",reset)
            print timed"\t"req"\t"bufc"\t"bufs"\t"bufa"\t"reset
        }' "$_bgwf" 2>/dev/null)
        _bgt_ckpt=$(echo "$_bgw_vals" | awk -F'\t' '{print $1}')
        _bgr_ckpt=$(echo "$_bgw_vals" | awk -F'\t' '{print $2}')
        _bgbufc=$(  echo "$_bgw_vals" | awk -F'\t' '{print $3}')
        _bgbufs=$(  echo "$_bgw_vals" | awk -F'\t' '{print $4}')
        _bgbufa=$(  echo "$_bgw_vals" | awk -F'\t' '{print $5}')
        _bgreset=$( echo "$_bgw_vals" | awk -F'\t' '{print $6}')
        _ckpt_ratio=$(echo "$_bgt_ckpt $_bgr_ckpt" | awk '{total=$1+$2;if(total>0)printf "%.1f",($2/total)*100;else print "0"}')
        _cr_n=$(echo "$_ckpt_ratio" | awk '{print int($1)}' | tr -d '\n\r')
            _cr_n=${_cr_n:-0}
        if   [ "$_cr_n" -ge 25 ] 2>/dev/null; then _crc="var(--red)"; _cri="🔴"; _verdict_cls="bgw-bad";  _verdict_msg="⚠ Forced ratio ${_ckpt_ratio}% is high — increase max_wal_size"
        elif [ "$_cr_n" -ge 10 ] 2>/dev/null; then _crc="var(--yel)"; _cri="🟡"; _verdict_cls="bgw-warn"; _verdict_msg="⚑ Forced ratio ${_ckpt_ratio}% is elevated"
        else                                        _crc="var(--grn)"; _cri="🟢"; _verdict_cls="bgw-ok";   _verdict_msg="✔ Forced ratio ${_ckpt_ratio}% — timed checkpoints dominate"
        fi
        echo "  <div class='bgw-grid'>"
        echo "    <div class='bgw-stat'><div class='bgw-val'>${_bgt_ckpt}</div><div class='bgw-lbl'>Timed Checkpoints</div></div>"
        echo "    <div class='bgw-stat'><div class='bgw-val' style='color:${_crc};'>${_bgr_ckpt}</div><div class='bgw-lbl'>Forced Checkpoints</div></div>"
        echo "    <div class='bgw-stat'><div class='bgw-val' style='color:${_crc};'>${_cri} ${_ckpt_ratio}%</div><div class='bgw-lbl'>Forced Ratio</div></div>"
        echo "    <div class='bgw-stat'><div class='bgw-val'>${_bgbufa}</div><div class='bgw-lbl'>Buffers Allocated</div></div>"
        echo "    <div class='bgw-stat'><div class='bgw-val'>${_bgbufc}</div><div class='bgw-lbl'>Buffers at Checkpoint</div></div>"
        echo "    <div class='bgw-stat'><div class='bgw-val'>${_bgbufs}</div><div class='bgw-lbl'>Buffers by bgwriter</div></div>"
        echo "  </div>"
        echo "  <div class='bgw-verdict ${_verdict_cls}'>${_verdict_msg}</div>"
        [ -n "$_bgreset" ] && echo "  <div style='font-size:10px;color:var(--mut);margin-top:6px;'>Stats since: $(echo "$_bgreset" | htmlesc)</div>"
    else
        echo "  <div class='bgw-unavail'><div class='bgw-unavail-icon'>📋</div><div><div style='font-size:12px;font-weight:600;'>pg_stat_bgwriter not collected</div></div></div>"
    fi
    echo "</div>"
    fi  # end if false — Checkpoint Health disabled
    # (Checkpoint Health panel end — commented out)

    # ── Replication + Slots side by side ──
    _rf2=$(find "$_lp" -type f \( -name "pg_stat_replication.out" -o -name "replication.out" \) | head -n1)
    _sf2=$(find "$_lp" -type f -name "replication_slots.out" | head -n1)
    if [ -f "$_rf2" ] || [ -f "$_sf2" ]; then
        echo "<div class='sh'>🔄 PostgreSQL Replication Information</div>"
        echo "<div class='repl-grid'>"

        # Replication panel
        echo "<div class='rpanel'>"
        if [ -f "$_rf2" ]; then
            echo "  <div class='rph'><span class='rp-icon'>🗄️</span><span class='rp-title'>$(basename "$_rf2")</span><a href='${_rel_ndir}/repl_tbl.html' class='rpb rpb-pri' target='_self'>Table View</a><a href='${_rel_ndir}/repl_raw.html' class='rpb rpb-sec' target='_self'>Raw View</a></div>"
            # Detect lag columns by header name, scan ALL rows, pick worst non-null lag
            # Normalize \N (PostgreSQL null marker) to — for display
            _repl_lags=$(awk -F'\t' '
            NR==1{
                for(i=1;i<=NF;i++){h=tolower($i);gsub(/\r/,"",h);col[h]=i}
                next
            }
            NR>1{
                wl = col["write_lag"]  ? $col["write_lag"]  : ""
                fl = col["flush_lag"]  ? $col["flush_lag"]  : ""
                rl = col["replay_lag"] ? $col["replay_lag"] : ""
                st = col["state"]      ? $col["state"]      : ""
                gsub(/\r/,"",wl); gsub(/\r/,"",fl); gsub(/\r/,"",rl); gsub(/\r/,"",st)
                # Replace \N (PG null) with empty so we can detect null
                if(wl=="\\N") wl=""; if(fl=="\\N") fl=""; if(rl=="\\N") rl=""
                # Keep first non-empty state
                if(st!="" && best_st=="") best_st=st
                # Keep worst (largest) non-null lag values
                if(rl!="" && rl>"0") {
                    if(best_rl=="" || rl>best_rl) best_rl=rl
                }
                if(wl!="" && wl>"0") {
                    if(best_wl=="" || wl>best_wl) best_wl=wl
                }
                if(fl!="" && fl>"0") {
                    if(best_fl=="" || fl>best_fl) best_fl=fl
                }
                rows++
            }
            END{
                # Fall back to "in sync" indicator if all lags were null/zero
                if(best_rl=="") best_rl="in sync"
                if(best_wl=="") best_wl="in sync"
                if(best_fl=="") best_fl="in sync"
                if(best_st=="") best_st="—"
                print best_wl"\t"best_fl"\t"best_rl"\t"best_st"\t"rows+0
            }' "$_rf2" 2>/dev/null)
            if [ -n "$_repl_lags" ]; then
                _wlag=$(echo "$_repl_lags" | awk -F'\t' '{print $1}'); _wlag="${_wlag:-in sync}"
                _flag=$(echo "$_repl_lags" | awk -F'\t' '{print $2}'); _flag="${_flag:-in sync}"
                _rlag=$(echo "$_repl_lags" | awk -F'\t' '{print $3}'); _rlag="${_rlag:-in sync}"
                _rst=$(echo  "$_repl_lags" | awk -F'\t' '{print $4}'); _rst="${_rst:-—}"
                _rrows=$(echo "$_repl_lags"| awk -F'\t' '{print $5}'); _rrows="${_rrows:-1}"
                # Colour replay lag: actual time = amber, in sync = green
                if echo "$_rlag" | grep -qE "^[0-9]"; then _rlc="var(--yel)"; else _rlc="var(--grn)"; fi
                # Label: if multiple standbys, show "worst of N"
                _lag_sub=""
                [ "${_rrows:-1}" -gt 1 ] 2>/dev/null && _lag_sub=" <span style='font-size:9px;color:var(--mut);'>(worst of ${_rrows})</span>"
                echo "  <div class='repl-lag-row'>"
                echo "    <div class='repl-lag-card'><div class='repl-lag-v' style='color:${_rlc};'>$(echo "$_rlag" | htmlesc)${_lag_sub}</div><div class='repl-lag-l'>Replay lag</div></div>"
                echo "    <div class='repl-lag-card'><div class='repl-lag-v'>$(echo "$_wlag" | htmlesc)</div><div class='repl-lag-l'>Write lag</div></div>"
                echo "    <div class='repl-lag-card'><div class='repl-lag-v'>$(echo "$_flag" | htmlesc)</div><div class='repl-lag-l'>Flush lag</div></div>"
                echo "    <div class='repl-lag-card'><div class='repl-lag-v'>$(echo "$_rst"  | htmlesc)</div><div class='repl-lag-l'>State</div></div>"
                echo "  </div>"
            fi
            echo "  <div class='rp-body'>"
            tail -n +2 "$_rf2" | tr -d '\r' | while IFS='	' read -r _pid _usesysid _usename _app _caddr _chost _cport _bs _bx _state _slsn _wlsn _flsn _rlsn _wlag _flag _rlag _spri _sstate _rtime _rest; do
                [ -z "$_pid" ] && continue
                case "$_state" in streaming) _sbc="rsbg-s";; catchup) _sbc="rsbg-c";; *) _sbc="rsbg-d";; esac
                case "$_sstate" in sync|quorum) _sybc="rsbg-sy";; async) _sybc="rsbg-a";; *) _sybc="rsbg-d";; esac
                _dn="${_app:-PID $_pid}"
                # Normalize \N (PostgreSQL null) → — for display
                [ "$_caddr" = '\N' ] && _caddr="—"
                [ "$_slsn"  = '\N' ] && _slsn="—"
                [ "$_rlsn"  = '\N' ] && _rlsn="—"
                [ "$_wlag"  = '\N' ] && _wlag="—"
                [ "$_flag"  = '\N' ] && _flag="—"
                [ "$_rlag"  = '\N' ] && _rlag="—"
                echo "    <div class='rcc'>"
                echo "      <div class='rch'><span class='rcn'>$(echo "$_dn" | htmlesc)</span><span class='rsb $_sbc'>$(echo "$_state" | htmlesc)</span>"
                [ -n "$_sstate" ] && echo "        <span class='rsb $_sybc'>$(echo "$_sstate" | htmlesc)</span>"
                echo "      </div>"
                echo "      <div class='rr'><span class='rk'>Client</span><span class='rv'>$(echo "${_caddr:-—}" | htmlesc)</span></div>"
                echo "      <div class='rr'><span class='rk'>Sent LSN</span><span class='rv'>$(echo "${_slsn:-—}" | htmlesc)</span></div>"
                echo "      <div class='rr'><span class='rk'>Replay LSN</span><span class='rv'>$(echo "${_rlsn:-—}" | htmlesc)</span></div>"
                # Compute LSN byte gap between sent and replay
                if [ "$_slsn" != "—" ] && [ "$_rlsn" != "—" ] && [ -n "$_slsn" ] && [ -n "$_rlsn" ]; then
                    _lsn_gap=$(echo "$_slsn $_rlsn" | awk '{
                        split($1,a,"/"); split($2,b,"/")
                        # Convert hex segments to decimal
                        cmd1="printf \"%d\" 0x"a[1]; cmd1 | getline ha; close(cmd1)
                        cmd2="printf \"%d\" 0x"a[2]; cmd2 | getline la; close(cmd2)
                        cmd3="printf \"%d\" 0x"b[1]; cmd3 | getline hb; close(cmd3)
                        cmd4="printf \"%d\" 0x"b[2]; cmd4 | getline lb; close(cmd4)
                        gap=(ha*4294967296+la)-(hb*4294967296+lb)
                        if(gap<0) gap=0
                        if(gap>=1073741824) printf "%.2f GB",gap/1073741824
                        else if(gap>=1048576) printf "%.1f MB",gap/1048576
                        else if(gap>=1024) printf "%.0f KB",gap/1024
                        else printf "%d B",gap
                    }' 2>/dev/null)
                    if [ -n "$_lsn_gap" ]; then
                        _gap_c="var(--grn)"
                        echo "$_lsn_gap" | grep -qE "^[1-9].*GB|^[1-9][0-9]+.*MB" && _gap_c="var(--red)"
                        echo "$_lsn_gap" | grep -qE "^[1-9].*MB" && _gap_c="var(--yel)"
                        echo "      <div class='rr'><span class='rk'>LSN Gap</span><span class='rv' style='color:${_gap_c};font-weight:600;'>$(echo "$_lsn_gap" | htmlesc)</span></div>"
                    fi
                fi
                echo "      <div class='rr'><span class='rk'>Replay Lag</span><span class='rv'>$(echo "${_rlag:-—}" | htmlesc)</span></div>"
                echo "      <div class='rr'><span class='rk'>Write Lag</span><span class='rv'>$(echo "${_wlag:-—}" | htmlesc)</span></div>"
                echo "      <div class='rr'><span class='rk'>Flush Lag</span><span class='rv'>$(echo "${_flag:-—}" | htmlesc)</span></div>"
                echo "    </div>"
            done
            echo "  </div>"
        else
            echo "  <div style='padding:20px;color:var(--mut);font-size:12px;'>No replication data found for this node.</div>"
        fi
        echo "</div>"

        # Slots panel
        echo "<div class='rpanel'>"
        if [ -f "$_sf2" ]; then
            echo "  <div class='rph'><span class='rp-icon'>🗄️</span><span class='rp-title'>$(basename "$_sf2")</span><a href='${_rel_ndir}/slots_tbl.html' class='rpb rpb-pri' target='_self'>Table View</a><a href='${_rel_ndir}/slots_raw.html' class='rpb rpb-sec' target='_self'>Raw View</a></div>"
            echo "  <div class='slots-body'>"
            echo "    <table class='slots-tbl'><thead><tr><th>Slot Name</th><th>Database</th><th>Active</th></tr></thead><tbody>"
            tail -n +2 "$_sf2" | tr -d '\r' | while IFS='	' read -r _sn _plg _stype _doid _db _tmp _act _apid _rest; do
                [ -z "$_sn" ] && continue
                case "$_act" in
                    t|true|1)  _dc="sd-on";  _tc="st-on";  _tl="(t)" ;;
                    f|false|0) _dc="sd-off"; _tc="st-off"; _tl="(f)" ;;
                    *)         _dc="sd-na";  _tc="st-na";  _tl="N/A" ;;
                esac
                echo "        <tr><td class='snc'>$(echo "$_sn" | htmlesc)</td><td class='sdc'>$(echo "${_db:-—}" | htmlesc)</td><td><div class='sac'><span class='sdot $_dc'></span><span class='stxt $_tc'>$_tl</span></div></td></tr>"
            done
            echo "    </tbody></table>"
            echo "  </div>"
        else
            echo "  <div style='padding:20px;color:var(--mut);font-size:12px;'>No replication slot data found for this node.</div>"
        fi
        echo "</div>"

        echo "</div>" # end repl-grid
    fi

    # ── Disk Space ──
    _disk_f=$(find "$_lp" -type f -name "diskspace.data" | head -n1)
    if [ -f "$_disk_f" ]; then
        echo "<div class='sh'>💿 Disk Space</div>"
        echo "<div class='disk-panel'>"
        echo "<details class='disk-det'><summary class='disk-sum'>Show disk usage for all mount points</summary>"
        echo "<table class='disk-tbl'><thead><tr><th>Filesystem</th><th>Size</th><th>Used</th><th>Available</th><th>Use%</th><th>Mounted On</th></tr></thead><tbody>"
        tail -n +2 "$_disk_f" | tr -d '\r' | while read -r _line; do
            [ -z "$_line" ] && continue
            echo "$_line" | awk '{
                fs=$1; sz=$2; used=$3; avail=$4; pct=$5; mnt=$6
                gsub(/%/,"",pct); pct_n=pct+0
                if (pct_n >= 80) cls="disk-crit"
                else if (pct_n >= 60) cls="disk-warn"
                else cls="disk-ok"
                print "<tr><td class=\"disk-fs\">" fs "</td><td class=\"disk-num\">" sz "</td><td class=\"disk-num\">" used "</td><td class=\"disk-num\">" avail "</td><td class=\"disk-pct\"><div class=\"disk-bar-wrap\"><div class=\"disk-bar " cls "\" style=\"width:" pct_n "%;\"></div></div><span class=\"disk-pct-lbl " cls "\">" pct_n "%</span></td><td class=\"disk-mnt\">" mnt "</td></tr>"
            }'
        done
        echo "</tbody></table></details>"
        echo "</div>"
    fi

    # ── Transaction ID Wraparound ──
    _dbf=$(find "$_lp" -path "*/postgresql/databases.out" | head -n1)
    echo "<div class='sh'>⚠ Transaction ID Wraparound Risk</div>"
    echo "<div class='xid-panel'>"
    if [ -f "$_dbf" ]; then
        # Detect age column from header — EDB uses "datage", standard PG uses "age"
        # Also handles "datfrozenxid_age", "xid_age" variants
        _age_col=$(awk -F'\t' 'NR==1{
            for(i=1;i<=NF;i++){
                h=tolower($i); gsub(/\r/,"",h)
                if(h=="datage" || h=="age" || h~/age.*frozen/ || h~/frozen.*age/ || h=="xid_age")
                    {print i}
            }
        }' "$_dbf" 2>/dev/null | head -n1)
        # Fallback: use last column if header detection fails
        _age_col="${_age_col:-0}"

        # Find worst (highest age) database using detected column
        _worst_age=$(awk -F'\t' -v ac="$_age_col" '
        NR==1{next}
        NF>1 {
            gsub(/\r/,"")
            age = (ac>0 && ac<=NF) ? $ac : $NF
            gsub(/\r/,"",age)
            if(age~/^[0-9]+$/ && age+0 > max_age+0){
                max_age=age+0; max_db=$2
            }
        }
        END { if(max_db!="") print max_age"\t"max_db }' "$_dbf" | head -n1)
        _max_age=$(echo "$_worst_age" | awk -F'\t' '{print $1}')
        _max_db=$(echo  "$_worst_age" | awk -F'\t' '{print $2}')
        _pct=$(echo "$_max_age" | awk '{printf "%d", ($1/2000000000)*100}' | tr -d '\n\r')
        _pct=${_pct:-0}
        _pct_autovac=$(echo "$_max_age" | awk '{printf "%d", ($1/200000000)*100}' | tr -d '\n\r')
        _pct_autovac=${_pct_autovac:-0}
        # Colour thresholds
        if   [ "$_pct" -ge 75 ] 2>/dev/null; then _xc="var(--red)"; _xvd="xid-bad";  _xvm="⚠ CRITICAL — $_max_db is past 75% of the 2 billion XID limit. Schedule emergency VACUUM FREEZE immediately."
        elif [ "$_pct" -ge 50 ] 2>/dev/null; then _xc="var(--yel)"; _xvd="xid-warn"; _xvm="⚑ WARNING — $_max_db has consumed over half the XID space. Run VACUUM FREEZE on large tables soon."
        elif [ "$_pct_autovac" -ge 100 ] 2>/dev/null; then _xc="var(--yel)"; _xvd="xid-warn"; _xvm="⚑ $_max_db is past the autovacuum_freeze_max_age threshold — verify autovacuum is running and not being cancelled."
        else _xc="var(--grn)"; _xvd="xid-ok"; _xvm="✔ All databases are within safe XID age limits."
        fi
        # Stat cards row
        _age_fmt=$(echo "$_max_age" | awk '{if($1>=1000000000)printf "%.2fB",$1/1000000000;else if($1>=1000000)printf "%.0fM",$1/1000000;else printf "%d",$1}')
        echo "  <div class='xid-cards'>"
        echo "    <div class='xid-card'><div class='xid-cv' style='color:${_xc};'>$_age_fmt</div><div class='xid-cl'>Oldest DB age</div><div class='xid-cs'>$_max_db</div></div>"
        echo "    <div class='xid-card'><div class='xid-cv'>200M</div><div class='xid-cl'>Autovacuum threshold</div><div class='xid-cs'>autovacuum_freeze_max_age</div></div>"
        echo "    <div class='xid-card'><div class='xid-cv'>2.0B</div><div class='xid-cl'>Hard shutdown limit</div><div class='xid-cs'>no recovery past this</div></div>"
        echo "  </div>"
        # Progress bar
        echo "  <div style='margin:10px 0 4px;font-size:10px;color:var(--mut);'>XID age progress toward forced shutdown (2 billion)</div>"
        echo "  <div class='xid-bar-wrap'>"
        echo "    <div class='xid-bar' style='width:${_pct}%;background:${_xc};'></div>"
        echo "    <div class='xid-marker' style='left:10%;'></div>"
        echo "  </div>"
        echo "  <div style='display:flex;justify-content:space-between;font-size:10px;color:var(--mut);margin-top:3px;'><span>0</span><span style='color:var(--yel);'>200M autovac (10%)</span><span style='color:var(--red);'>2B shutdown</span></div>"
        # Per-database table — include size and connections from databases.out
        # Detect datsize and numbackends columns by header name
        _size_col=$(awk -F'\t' 'NR==1{for(i=1;i<=NF;i++){h=tolower($i);gsub(/\r/,"",h);if(h=="datsize")print i}}' "$_dbf" 2>/dev/null)
        _nbe_col=$(awk  -F'\t' 'NR==1{for(i=1;i<=NF;i++){h=tolower($i);gsub(/\r/,"",h);if(h=="numbackends")print i}}' "$_dbf" 2>/dev/null)
        _size_col="${_size_col:-0}"; _nbe_col="${_nbe_col:-0}"
        echo "  <div style='margin-top:12px;'>"
        echo "  <table class='xid-tbl'><thead><tr><th>Database</th><th>Size</th><th>Connections</th><th>XID Age</th><th>% to Limit</th><th>Status</th></tr></thead><tbody>"
        # XID per-database table — pure shell loop avoids mawk buffering bug
        while IFS='	' read -r _xdb_oid _xdb_name _xdb_nbe _rest; do
            [ -z "$_xdb_name" ] && continue
            # Get age and size from their detected column positions
            _xdb_age=$(echo "$_xdb_oid	$_xdb_name	$_xdb_nbe	$_rest" | awk -F'\t' -v ac="$_age_col" '{if(ac>0&&ac<=NF)print $ac;else print $NF}')
            _xdb_sz=$(echo  "$_xdb_oid	$_xdb_name	$_xdb_nbe	$_rest" | awk -F'\t' -v sc="$_size_col" '{if(sc>0&&sc<=NF)print $sc}')
            _xdb_nbe2=$(echo "$_xdb_nbe" | tr -d '\r')
            _xdb_age=$(echo "$_xdb_age" | tr -d '\r')
            _xdb_sz=$(echo "$_xdb_sz" | tr -d '\r')
            # Skip templates and non-numeric ages
            case "$_xdb_name" in template0|template1) continue;; esac
            echo "$_xdb_age" | grep -qE "^[0-9]+$" || continue
            # Format age
            _xdb_agefmt=$(echo "$_xdb_age" | awk '{if($1>=1000000000)printf "%.2fB",$1/1000000000;else if($1>=1000000)printf "%.0fM",$1/1000000;else print $1}')
            # Format size
            _xdb_szfmt="-"
            if echo "$_xdb_sz" | grep -qE "^[0-9]+$" && [ "$_xdb_sz" -gt 0 ] 2>/dev/null; then
                _xdb_szfmt=$(echo "$_xdb_sz" | awk '{s=$1+0;if(s>=1099511627776)printf "%.1f TB",s/1099511627776;else if(s>=1073741824)printf "%.1f GB",s/1073741824;else if(s>=1048576)printf "%.0f MB",s/1048576;else printf "%.0f KB",s/1024}')
            fi
            # Connection count
            _xdb_nbefmt="-"
            echo "$_xdb_nbe2" | grep -qE "^[0-9]+$" && _xdb_nbefmt="$_xdb_nbe2"
            # Percent
            _xdb_pct=$(echo "$_xdb_age" | awk '{printf "%d",($1/2000000000)*100}' | tr -d '\n\r')
            _xdb_pct=${_xdb_pct:-0}
            # Badge
            if   [ "$_xdb_pct" -ge 75 ] 2>/dev/null; then _xdb_cls="xid-row-bad";  _xdb_badge="<span class='xid-badge xid-b-bad'>critical</span>"
            elif [ "$_xdb_pct" -ge 50 ] 2>/dev/null; then _xdb_cls="xid-row-warn"; _xdb_badge="<span class='xid-badge xid-b-warn'>warning</span>"
            elif [ "$_xdb_age" -gt 200000000 ] 2>/dev/null; then _xdb_cls="xid-row-warn"; _xdb_badge="<span class='xid-badge xid-b-warn'>monitor</span>"
            else _xdb_cls=""; _xdb_badge="<span class='xid-badge xid-b-ok'>healthy</span>"
            fi
            echo "    <tr class='$_xdb_cls'><td class='mc'>$(echo "$_xdb_name" | htmlesc)</td><td class='mc'>$_xdb_szfmt</td><td class='mc'>$_xdb_nbefmt</td><td class='mc'>$_xdb_agefmt</td><td class='mc'>${_xdb_pct}%</td><td>$_xdb_badge</td></tr>"
        done < "$_dbf"
        echo "  </tbody></table></div>"
        echo "  <div class='xid-verdict $_xvd'>$_xvm</div>"
    else
        echo "  <div class='bgw-unavail'><div class='bgw-unavail-icon'>📋</div><div><div style='font-size:12px;font-weight:600;color:var(--txt);margin-bottom:4px;'>databases.out not found</div><div style='font-size:11px;color:var(--mut);'>Expected path: postgresql/databases.out — not present in this Lasso bundle.</div></div></div>"
    fi
    echo "</div>"

    # ── Top 5 Table Bloat ──
    echo "<div class='sh'>🗃 Top Table Bloat <span style='font-size:10px;color:var(--mut);font-weight:400;'>(dead tuple ratio across all databases)</span></div>"
    echo "<div class='bloat-panel'>"
    _dbs_dir=$(find "$_lp" -type d -name "dbs" -path "*/postgresql/*" | head -n1)
    _bloat_found=0
    if [ -d "$_dbs_dir" ]; then
        _btmp=$(mktemp)
        for _dbdir in "$_dbs_dir"/*/; do
            _dbname=$(basename "$_dbdir")
            _tf="$_dbdir/tables.out"
            [ -f "$_tf" ] || continue
            # Read header to find column positions by name dynamically
            # Handles any column ordering (mock uses col 4/5, real PG uses col 11/12)
            awk -F'\t' -v db="$_dbname" '
            NR==1 {
                for(i=1;i<=NF;i++){
                    h=$i
                    # strip carriage return
                    gsub(/\r/,"",h)
                    col[h]=i
                }
                # map common name variants
                if(!col["n_live_tup"] && col["reltuples"]) col["n_live_tup"]=col["reltuples"]
                if(!col["tablename"]   && col["relname"])   col["tablename"]=col["relname"]
                next
            }
            NR>1 {
                schema = col["schemaname"] ? $col["schemaname"] : $1
                tbl    = col["tablename"]  ? $col["tablename"]  : $2
                live   = col["n_live_tup"] ? $col["n_live_tup"]+0 : 0
                dead   = col["n_dead_tup"] ? $col["n_dead_tup"]+0 : 0
                lav    = col["last_autovacuum"] ? $col["last_autovacuum"] : ""
                gsub(/\r/,"",schema); gsub(/\r/,"",tbl); gsub(/\r/,"",lav)
                total = live+dead
                if(total>0 && (live~/^[0-9]/ || dead~/^[0-9]/)){
                    ratio=dead/total
                    printf "%s\t%s\t%s\t%d\t%d\t%.4f\t%s\n", db, schema, tbl, live, dead, ratio, lav
                }
            }' "$_tf" >> "$_btmp" 2>/dev/null
        done
        if [ -s "$_btmp" ]; then
            _bloat_found=1
            # Get collection timestamp from info.data for "X days ago" calculation
            _info_ts=$(find "$_lp" -name "info.data" | head -n1)
            _collect_epoch=$(awk '/Collected:|Date:|Timestamp:/{print $NF}' "$_info_ts" 2>/dev/null | head -n1 | xargs -I{} date -d "{}" +%s 2>/dev/null || date +%s)
            echo "  <table class='bloat-tbl'><thead><tr><th>Database</th><th>Schema.Table</th><th>Live Rows</th><th>Dead Rows</th><th>Bloat %</th><th>Last Autovacuum</th><th>Age</th></tr></thead><tbody>"
            sort -t'	' -k6 -rn "$_btmp" | head -n5 | while IFS='	' read -r _bdb _bsch _btbl _blive _bdead _bratio _blav; do
                _bpct=$(echo "$_bratio" | awk '{printf "%d",$1*100}' | tr -d '\n\r')
                _bpct=${_bpct:-0}
                if   [ "$_bpct" -ge 50 ] 2>/dev/null; then _bc="bloat-bad";  _bbd="<span class='xid-badge xid-b-bad'>critical</span>"
                elif [ "$_bpct" -ge 20 ] 2>/dev/null; then _bc="bloat-warn"; _bbd="<span class='xid-badge xid-b-warn'>high</span>"
                else                                        _bc="";           _bbd="<span class='xid-badge xid-b-ok'>ok</span>"
                fi
                _blav_d="${_blav:-(never)}"
                # Compute days since last autovacuum
                if [ -n "$_blav" ] && [ "$_blav" != "(never)" ]; then
                    _lav_epoch=$(date -d "$_blav" +%s 2>/dev/null || echo "")
                    if [ -n "$_lav_epoch" ] && [ -n "$_collect_epoch" ]; then
                        _lav_days=$(( (_collect_epoch - _lav_epoch) / 86400 ))
                        if   [ "$_lav_days" -gt 30 ] 2>/dev/null; then _age_str="<span style='color:var(--red);font-weight:600;'>${_lav_days}d ago</span>"
                        elif [ "$_lav_days" -gt 7  ] 2>/dev/null; then _age_str="<span style='color:var(--yel);'>${_lav_days}d ago</span>"
                        else _age_str="${_lav_days}d ago"
                        fi
                    else _age_str="—"
                    fi
                else _age_str="<span style='color:var(--red);font-weight:600;'>never</span>"
                fi
                echo "    <tr><td class='mc'>$(echo "$_bdb" | htmlesc)</td><td class='mc'>$(echo "${_bsch}.${_btbl}" | htmlesc)</td><td class='mc'>$(echo "$_blive" | awk '{if($1>=1000000)printf "%.1fM",$1/1000000;else if($1>=1000)printf "%.0fK",$1/1000;else print $1}')</td><td class='mc $_bc'>$(echo "$_bdead" | awk '{if($1>=1000000)printf "%.1fM",$1/1000000;else if($1>=1000)printf "%.0fK",$1/1000;else print $1}')</td><td>$_bbd <span style='font-size:10px;font-family:var(--mono);'>${_bpct}%</span></td><td style='font-size:10px;color:var(--mut);'>$(echo "$_blav_d" | cut -c1-19 | htmlesc)</td><td style='font-size:10px;'>$_age_str</td></tr>"
            done
            echo "  </tbody></table>"
            # Count total and show "View all" links per DB
            _total_tbl_count=$(wc -l < "$_btmp" | tr -d ' ')
            if [ "$_total_tbl_count" -gt 5 ] 2>/dev/null; then
                echo "  <div style='font-size:10px;color:var(--mut);padding:5px 0 3px;'>Showing top 5 of ${_total_tbl_count} tables with dead tuples.</div>"
            fi
            echo "  <div style='display:flex;flex-wrap:wrap;gap:6px;margin-top:6px;'>"
            for _dbdir3 in "$_dbs_dir"/*/; do
                _dbn3=$(basename "$_dbdir3")
                [ -f "$_dbdir3/tables.out" ] || continue
                _tlink="${_rel_ndir}/tables_${_dbn3}.html"
                echo "    <a href='$_tlink' class='cfg-btn cfg-pri' target='_self' style='font-size:10px;'>📋 All tables — ${_dbn3}</a>"
            done
            echo "  </div>"
        fi
        rm -f "$_btmp"
    fi
    if [ "$_bloat_found" -eq 0 ]; then
        echo "  <div class='bgw-unavail'><div class='bgw-unavail-icon'>📋</div><div><div style='font-size:12px;font-weight:600;color:var(--txt);margin-bottom:4px;'>tables.out not found</div><div style='font-size:11px;color:var(--mut);'>Expected path: postgresql/dbs/&lt;dbname&gt;/tables.out — not present in this Lasso bundle.</div></div></div>"
    fi
    echo "</div>"

    # ── Long-Running Query Detection ──
    if [ -f "$_conn_f" ]; then
        # Get collection timestamp from info.data for duration calculation
        _info_f=$(find "$_lp" -maxdepth 3 -name "info.data" | head -n1)
        _lasso_log=$(find "$_lp" -name "edb-lasso-report.log" | head -n1)
        _collect_ts=""
        [ -f "$_lasso_log" ] && _collect_ts=$(head -n1 "$_lasso_log" 2>/dev/null | awk '{print $1}' | sed 's/T/ /')
        [ -z "$_collect_ts" ] && _collect_ts=$(date '+%Y-%m-%d %H:%M:%S')
        # Strip timezone offset so mktime uses same wall-clock reference as query_start
        _collect_ts=$(echo "$_collect_ts" | sed 's/[+-][0-9][0-9]:*[0-9][0-9]$//' | cut -c1-19)
        _collect_epoch_lrq=$(date -d "$_collect_ts" +%s 2>/dev/null || \
            date -j -f "%Y-%m-%d %H:%M:%S" "$_collect_ts" +%s 2>/dev/null || \
            date +%s)
        # Use actual_time column (collect timestamp embedded in file) as reference epoch
        # This is always in sync with query_start — more reliable than the lasso log
        if [ "$_lrq_at" -gt 0 ] 2>/dev/null; then
            _actual_ts=$(awk -F'\t' -v ac="$_lrq_at" 'NR==2 && NF>1{v=$ac; gsub(/\.[0-9]+/,"",v); gsub(/[+-][0-9][0-9](:[0-9][0-9])?$/,"",v); if(v~/^[0-9]{4}/)print v}' "$_conn_f" 2>/dev/null | tr -d '\n\r')
            if [ -n "$_actual_ts" ]; then
                _collect_epoch_lrq=$(date -d "$_actual_ts" +%s 2>/dev/null || \
                    date -j -f "%Y-%m-%d %H:%M:%S" "$_actual_ts" +%s 2>/dev/null || \
                    echo "$_collect_epoch_lrq")
            fi
        fi
        # Fallback: if collect_epoch appears to be in a very different timezone to query_start
        # values (i.e. produces only negative durations), use current time instead.
        # We detect this by checking if the majority of query_start values are AFTER collect_epoch.
        _tz_sanity=$( awk -F'\t' -v cep="$_collect_epoch_lrq" '
        NR==1{next} NF>1{
            for(i=1;i<=NF;i++){
                v=$i; gsub(/[+-][0-9][0-9](:[0-9][0-9])?$/,"",v); gsub(/\.[0-9]+/,"",v)
                if(v~/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$/){
                    n=split(v,t,/[-: ]/)
                    if(n>=6){
                        ep=mktime(t[1]" "t[2]" "t[3]" "t[4]" "t[5]" "t[6])
                        if(ep>cep) after++; else before++
                    }
                    break
                }
            }
            if(NR>20) exit
        }
        END{ if(after+0 > before+0) print "use_now"; else print "ok" }
        ' "$_conn_f" 2>/dev/null )
        if [ "$_tz_sanity" = "use_now" ]; then
            _collect_epoch_lrq=$(date +%s)
        fi

        # Parse column positions from header using shell read — immune to stdin/mawk issues
        _lrq_qs=0; _lrq_xs=0; _lrq_sc=0; _lrq_pc=3; _lrq_uc=5; _lrq_ac=6; _lrq_qc=0; _lrq_wec=0; _lrq_at=0
        _col_i=0
        while IFS='	' read -r _hcol; do
            _col_i=$(( _col_i + 1 ))
            _hn=$(echo "$_hcol" | tr '[:upper:]' '[:lower:]' | tr -d '\r')
            case "$_hn" in
                query_start)       _lrq_qs=$_col_i ;;
                xact_start)        _lrq_xs=$_col_i ;;
                state|status)      _lrq_sc=$_col_i ;;
                pid)               _lrq_pc=$_col_i ;;
                usename|username)  _lrq_uc=$_col_i ;;
                application_name)  _lrq_ac=$_col_i ;;
                query)             _lrq_qc=$_col_i ;;
                wait_event_type)   _lrq_wec=$_col_i ;;
                actual_time)       _lrq_at=$_col_i ;;
            esac
        done << LRQHDR
$(head -1 "$_conn_f" | tr '\t' '\n')
LRQHDR

        # Find sessions with query duration > 5 minutes (300 seconds)
        # Step 1: extract needed columns to temp file using awk (avoids subshell buffering)
        # Step 2: process with shell while-read (avoids eval/substitution issues)
        _lrq_tmp=$(mktemp)
        _lrq_cols_tmp=$(mktemp)
        awk -F'\t' -v qs="$_lrq_qs" -v xs="$_lrq_xs" -v sc="$_lrq_sc" \
            -v pc="$_lrq_pc" -v uc="$_lrq_uc" -v ac="$_lrq_ac" -v qc="$_lrq_qc" '
        NR==1{next} NF>1{
            gsub(/\r/,"")
            qstart = (qs>0) ? $qs : ""
            xstart = (xs>0) ? $xs : ""
            state  = (sc>0) ? $sc : ""
            pid    = (pc>0) ? $pc : $3
            user   = (uc>0) ? $uc : $5
            app    = (ac>0) ? $ac : ""
            query  = (qc>0) ? $qc : ""
            print qstart"\t"xstart"\t"state"\t"pid"\t"user"\t"app"\t"query
        }' "$_conn_f" > "$_lrq_cols_tmp" 2>/dev/null
        # Step 2: shell loop processes the extracted file — no awk buffering, no eval
        while IFS='	' read -r _lrq_qstart _lrq_xstart _lrq_state _lrq_pid _lrq_user _lrq_app _lrq_query; do
            case "$_lrq_state" in
                active|"idle in transaction"|"idle in transaction (aborted)") ;;
                *) continue ;;
            esac
            case "$_lrq_query" in
                START_REPLICATION*|IDENTIFY_SYSTEM*|BASE_BACKUP*) continue ;;
            esac
            # For idle-in-tx prefer xact_start
            _lrq_ts="$_lrq_qstart"
            case "$_lrq_state" in
                *"idle in transaction"*)
                    if [ -n "$_lrq_xstart" ] && [ "$_lrq_xstart" != '\N' ] && [ "$_lrq_xstart" != "" ]; then
                        _lrq_ts="$_lrq_xstart"
                    fi ;;
            esac
            # Strip timezone suffix and microseconds, keep YYYY-MM-DD HH:MM:SS
            _lrq_ts=$(echo "$_lrq_ts" | sed 's/[+-][0-9][0-9]:*[0-9]*$//' | sed 's/\.[0-9]*//' | cut -c1-19)
            [ -z "$_lrq_ts" ] && continue
            case "$_lrq_ts" in
                [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;;
                *) continue ;;
            esac
            # Convert to epoch — try Linux date -d, then macOS date -j
            _lrq_ep=$(date -d "$_lrq_ts" +%s 2>/dev/null || \
                      date -j -f "%Y-%m-%d %H:%M:%S" "$_lrq_ts" +%s 2>/dev/null || echo "")
            [ -z "$_lrq_ep" ] && continue
            _lrq_dur=$(( _collect_epoch_lrq - _lrq_ep ))
            [ "$_lrq_dur" -le 300 ] 2>/dev/null && continue
            # Format HH:MM:SS
            _lrq_h=$(( _lrq_dur / 3600 ))
            _lrq_m=$(( (_lrq_dur % 3600) / 60 ))
            _lrq_s=$(( _lrq_dur % 60 ))
            _lrq_dstr=$(printf "%02d:%02d:%02d" "$_lrq_h" "$_lrq_m" "$_lrq_s")
            # HTML-escape query and app
            _lrq_qshort=$(printf '%s' "$_lrq_query" | cut -c1-70 | \
                sed 's/&/\&amp;/g' | sed 's/</\&lt;/g' | sed 's/>/\&gt;/g')
            _lrq_appesc=$(printf '%s' "$_lrq_app" | \
                sed 's/&/\&amp;/g' | sed 's/</\&lt;/g' | sed 's/>/\&gt;/g')
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$_lrq_dur" "$_lrq_pid" "$_lrq_user" "$_lrq_appesc" \
                "$_lrq_state" "$_lrq_dstr" "$_lrq_qshort" >> "$_lrq_tmp"
        done < "$_lrq_cols_tmp"
        rm -f "$_lrq_cols_tmp"
        _lrq_count=$(grep -c "." "$_lrq_tmp" 2>/dev/null | tr -d '\n\r')
        _lrq_count=${_lrq_count:-0}

        if [ "$_lrq_count" -gt 0 ] 2>/dev/null; then
            echo "<div class='sh'>⏰ Long-Running Queries <span style='font-size:10px;color:var(--mut);font-weight:400;'>(active &gt; 5 minutes at collection time)</span></div>"
            echo "<div class='lrq-panel'>"
            echo "  <table class='lock-tbl'><thead><tr><th>PID</th><th>User</th><th>Application</th><th>State</th><th>Duration</th><th>Query</th></tr></thead><tbody>"
            sort -t'	' -k1 -rn "$_lrq_tmp" | head -n 20 | while IFS='	' read -r _dur _pid _usr _app _st _dstr _qsh; do
                _stc=""; [ "$_st" = "active" ] && _stc=" style='color:var(--grn);'" || _stc=" style='color:var(--red);'"
                echo "    <tr><td class='mc'>$_pid</td><td class='mc'>$_usr</td><td class='mc'>$_app</td><td class='mc'${_stc}>$_st</td><td class='mc' style='color:var(--yel);font-weight:600;'>$_dstr</td><td class='lock-q'>$_qsh</td></tr>"
            done
            echo "  </tbody></table>"
            echo "</div>"
        fi
        rm -f "$_lrq_tmp"
    fi

    # ── OS Memory Pressure ──
    _dmesg_f=$(find "$_lp" -type f -name "dmesg.data" | head -n1)
    echo "<div class='sh'>🧠 OS Memory Pressure</div>"
    echo "<div class='memp-panel'>"
    echo "  <div class='memp-grid'>"
    # Left: Huge Pages + Commit
    echo "  <div>"
    echo "    <div class='memp-section'>Huge pages (from meminfo)</div>"
    if [ -n "$_huge_total" ]; then
        _hp_used=$(echo "$_huge_total $_huge_free" | awk '{print $1-$2}')
        _hp_pct=$(echo "$_huge_total $_huge_free" | awk '{if($1>0)printf "%d",(($1-$2)/$1)*100;else print "0"}' | tr -d '\n\r')
        _hp_pct=${_hp_pct:-0}
        if [ "${_huge_total:-0}" -gt 0 ] 2>/dev/null && [ "${_huge_free:-0}" -eq 0 ] 2>/dev/null; then
            _hp_cls="memp-ok"; _hp_msg="All huge pages in use — shared_buffers benefits from reduced TLB pressure"
        elif [ "${_huge_total:-0}" -gt 0 ] 2>/dev/null; then
            _hp_cls="memp-ok"; _hp_msg="${_hp_used} of ${_huge_total} huge pages in use"
        else
            _hp_cls="memp-info"; _hp_msg="Huge pages not configured — consider enabling for large shared_buffers"
        fi
        echo "    <div class='memp-row'><span class='memp-k'>HugePages_Total</span><span class='memp-v'>${_huge_total:-—}</span></div>"
        echo "    <div class='memp-row'><span class='memp-k'>HugePages_Free</span><span class='memp-v'>${_huge_free:-—}</span></div>"
        echo "    <div class='memp-row'><span class='memp-k'>HugePages_Rsvd</span><span class='memp-v'>${_huge_rsvd:-—}</span></div>"
        echo "    <div class='memp-row'><span class='memp-k'>Hugepagesize</span><span class='memp-v'>${_huge_size:-—}</span></div>"
        echo "    <div class='memp-note memp-note-${_hp_cls}'>$_hp_msg</div>"
    else
        echo "    <div style='font-size:11px;color:var(--mut);padding:8px 0;'>meminfo.data not available</div>"
    fi
    echo "    <div class='memp-section' style='margin-top:10px;'>Commit limit</div>"
    echo "    <div class='memp-row'><span class='memp-k'>CommitLimit</span><span class='memp-v'>${_commit_limit:-—}</span></div>"
    echo "    <div class='memp-row'><span class='memp-k'>Committed_AS</span><span class='memp-v'>${_committed:-—}</span></div>"
    echo "  </div>"
    # Right: Swap + OOM
    echo "  <div>"
    echo "    <div class='memp-section'>Swap usage</div>"
    if [ -n "$_swap_total_raw" ] && [ "$_swap_total_raw" != "0" ] 2>/dev/null; then
        if   [ "$_swap_pct" -ge 80 ] 2>/dev/null; then _sc="var(--red)";  _sv_cls="memp-note-bad"
        elif [ "$_swap_pct" -ge 50 ] 2>/dev/null; then _sc="var(--yel)";  _sv_cls="memp-note-warn"
        else                                            _sc="var(--grn)";  _sv_cls="memp-note-ok"
        fi
        echo "    <div class='memp-row'><span class='memp-k'>Total</span><span class='memp-v'>${_swap_total}</span></div>"
        echo "    <div class='memp-row'><span class='memp-k'>Used</span><span class='memp-v' style='color:${_sc};'>${_swap_used} (${_swap_pct}%)</span></div>"
        echo "    <div class='memp-row'><span class='memp-k'>Free</span><span class='memp-v'>${_swap_free}</span></div>"
        echo "    <div class='swap-bar-wrap'><div class='swap-bar' style='width:${_swap_pct}%;background:${_sc};'></div></div>"
        if [ "$_swap_pct" -ge 50 ] 2>/dev/null; then
            echo "    <div class='memp-note memp-note-${_sv_cls}'>Swap at ${_swap_pct}% — OS is paging; PostgreSQL queries may be slow. Review work_mem and max_connections.</div>"
        else
            echo "    <div class='memp-note memp-note-ok'>Swap at ${_swap_pct}% — within normal range</div>"
        fi
    else
        echo "    <div style='font-size:11px;color:var(--mut);padding:8px 0;'>No swap configured or swap data unavailable</div>"
    fi
    echo "    <div class='memp-section' style='margin-top:10px;'>OOM killer activity (dmesg)</div>"
    if [ -f "$_dmesg_f" ]; then
        _oom_lines=$(grep -iE "out of memory|oom.kill|Killed process" "$_dmesg_f" 2>/dev/null | tr -d '\r')
        _oom_count=$(echo "$_oom_lines" | grep -c "." 2>/dev/null || echo 0)
        if [ "$_oom_count" -gt 0 ] 2>/dev/null; then
            echo "    <div class='memp-note memp-note-bad'>⚠ ${_oom_count} OOM kill event(s) found in dmesg</div>"
            echo "$_oom_lines" | tail -n3 | while IFS= read -r _ol; do
                echo "    <div class='oom-entry'>$(echo "$_ol" | htmlesc)</div>"
            done
        else
            echo "    <div class='memp-note memp-note-ok'>✔ No OOM kill events found in dmesg</div>"
        fi
    else
        echo "    <div style='font-size:11px;color:var(--mut);padding:8px 0;'>dmesg.data not in bundle</div>"
    fi
    echo "  </div>"
    echo "  </div>" # end memp-grid
    echo "</div>"

    # ── Blocking & Lock Analysis ──
    _blk_f=$(find "$_lp" -type f -name "blocking_locks.out"       | head -n1)
    _rlk_f=$(find "$_lp" -type f -name "running_locks.out"        | head -n1)
    _rwt_f=$(find "$_lp" -type f -name "running_waits_sample.out" | head -n1)
    if [ -f "$_blk_f" ] || [ -f "$_rlk_f" ] || [ -f "$_rwt_f" ]; then
        # Count blocked sessions — detect columns from header row
        _blk_total=0; _blk_root=0; _blk_maxtime="—"; _blk_avgtime="—"
        if [ -f "$_blk_f" ]; then
            _blk_total=$(tail -n +2 "$_blk_f" | tr -d '\r' | grep -c "." 2>/dev/null || echo 0)
            # Detect column positions by header name
            _blk_cols=$(awk -F'\t' 'NR==1{
                for(i=1;i<=NF;i++){h=tolower($i);gsub(/\r/,"",h);
                    if(h=="blocked_pid"||h=="blocked_pid") bpid=i
                    if(h=="blocking_pid") bkpid=i
                    if(h=="blocked_statement"||h=="blocked_query"||h=="blocked_statement") bstmt=i
                    if(h=="blocked_time"||h=="waiting_duration"||h=="block_time") btime=i
                    if(h=="current_statement_in_blocking_process"||h=="blocking_statement"||h=="blocking_query") bkstmt=i
                }
                # defaults: blocked_pid=1 blocking_pid=3 blocked_stmt=5 blocked_time=6 blocking_stmt=7
                if(!bpid)  bpid=1
                if(!bkpid) bkpid=3
                if(!bstmt) bstmt=5
                if(!btime) btime=6
                if(!bkstmt)bkstmt=7
                print bpid"\t"bkpid"\t"bstmt"\t"btime"\t"bkstmt
                exit
            }' "$_blk_f" 2>/dev/null)
            _bc_bpid=$(echo  "$_blk_cols"|awk -F'\t' '{print $1}')
            _bc_bkpid=$(echo "$_blk_cols"|awk -F'\t' '{print $2}')
            _bc_bstmt=$(echo "$_blk_cols"|awk -F'\t' '{print $3}')
            _bc_btime=$(echo "$_blk_cols"|awk -F'\t' '{print $4}')
            _bc_bkstmt=$(echo "$_blk_cols"|awk -F'\t' '{print $5}')
            # Fallback defaults if awk failed
            _bc_bpid=${_bc_bpid:-1}; _bc_bkpid=${_bc_bkpid:-3}
            _bc_bstmt=${_bc_bstmt:-5}; _bc_btime=${_bc_btime:-6}; _bc_bkstmt=${_bc_bkstmt:-7}

            _blk_root=$(awk -F'\t' -v c="$_bc_bkpid" 'NR>1 && NF>1{gsub(/\r/,""); print $c}' "$_blk_f" | sort -u | grep -c "." 2>/dev/null || echo 0)
            _blk_maxtime=$(awk -F'\t' -v c="$_bc_btime" 'NR>1 && NF>1{gsub(/\r/,""); if($c~/^[0-9]/)print $c}' "$_blk_f" | sort -rn | head -n1)
            [ -z "$_blk_maxtime" ] && _blk_maxtime="—"
            # Compute avg block time
            _blk_avgtime=$(awk -F'\t' -v c="$_bc_btime" '
            NR>1 && NF>1{
                gsub(/\r/,"")
                if($c~/^[0-9]+:[0-9]+/){
                    split($c,a,":")
                    secs=a[1]*3600+a[2]*60+a[3]+0; sum+=secs; cnt++
                }
            }
            END{
                if(cnt>0){
                    avg=sum/cnt
                    h=int(avg/3600); m=int((avg%3600)/60); s=int(avg%60)
                    printf "%02d:%02d:%02d", h, m, s
                }
            }' "$_blk_f" 2>/dev/null)
            [ -z "$_blk_avgtime" ] && _blk_avgtime="—"
        fi
        echo "<div class='sh'>🔒 Blocking &amp; Lock Analysis</div>"
        echo "<div class='lock-panel'>"

        # ── Stat cards ──
        echo "  <div class='lock-stat-row'>"
        if [ "$_blk_total" -gt 0 ] 2>/dev/null; then _bsc="lock-sv-red"; else _bsc="lock-sv"; fi
        echo "    <div class='lock-stat'><div class='lock-sv $_bsc'>$_blk_total</div><div class='lock-sl'>Blocked sessions</div></div>"
        echo "    <div class='lock-stat'><div class='lock-sv'>$_blk_root</div><div class='lock-sl'>Root blockers</div></div>"
        echo "    <div class='lock-stat'><div class='lock-sv lock-sv-amber'>$_blk_maxtime</div><div class='lock-sl'>Longest block time</div></div>"
        echo "    <div class='lock-stat'><div class='lock-sv lock-sv-amber'>$_blk_avgtime</div><div class='lock-sl'>Avg block time</div></div>"
        if [ -f "$_rlk_f" ]; then
            _lock_total=$(tail -n +2 "$_rlk_f" | tr -d '\r' | grep -c "." 2>/dev/null || echo 0)
            # Detect granted column by header name
            _rlk_granted_col=$(awk -F'\t' 'NR==1{for(i=1;i<=NF;i++){h=tolower($i);gsub(/\r/,"",h);if(h=="granted")print i}}' "$_rlk_f" 2>/dev/null)
            _rlk_granted_col="${_rlk_granted_col:-14}"
            _lock_waiting=$(awk -F'\t' -v gc="$_rlk_granted_col" 'NR>1 && NF>1{gsub(/\r/,""); if($gc=="f")c++}END{print c+0}' "$_rlk_f" 2>/dev/null || echo 0)
            echo "    <div class='lock-stat'><div class='lock-sv'>$_lock_total</div><div class='lock-sl'>Total locks</div></div>"
            echo "    <div class='lock-stat'><div class='lock-sv lock-sv-red'>$_lock_waiting</div><div class='lock-sl'>Locks waiting</div></div>"
        fi
        echo "  </div>"

        # ── Blocking chains collapsible ──
        if [ -f "$_blk_f" ]; then
            echo "  <details class='lock-det'><summary class='lock-sum'>🚧 Blocking chains — $(echo "$_blk_total") blocked session(s) from blocking_locks.out</summary>"
            echo "  <div class='lock-det-body'>"
            echo "  <table class='lock-tbl'><thead><tr><th>Blocked PID</th><th>Blocking PID</th><th>Blocked query</th><th>Block time</th><th>Blocking query</th></tr></thead><tbody>"
            _blk_chain_tmp=$(mktemp)
            ( awk -F'\t' \
                -v c1="$_bc_bpid" -v c2="$_bc_bkpid" -v c3="$_bc_bstmt" -v c4="$_bc_btime" -v c5="$_bc_bkstmt" \
                'NR>1 && NF>1 && $c1!=""{
                gsub(/\r/,"")
                val1=$c1; val2=$c2; val3=substr($c3,1,60); val4=$c4; val5=substr($c5,1,60)
                gsub(/&/,"\\&amp;",val3); gsub(/</,"\\&lt;",val3); gsub(/>/,"\\&gt;",val3)
                gsub(/&/,"\\&amp;",val5); gsub(/</,"\\&lt;",val5); gsub(/>/,"\\&gt;",val5)
                printf "<tr><td class=\"mc\">%s</td><td class=\"mc\" style=\"color:var(--red);\">%s</td><td class=\"lock-q\">%s</td><td class=\"mc\" style=\"color:var(--yel);\">%s</td><td class=\"lock-q\">%s</td></tr>\n",
                val1,val2,val3,val4,val5
            }' "$_blk_f" ) > "$_blk_chain_tmp" 2>/dev/null
            head -n 20 "$_blk_chain_tmp"; rm -f "$_blk_chain_tmp" 
            echo "  </tbody></table>"
            if [ "$_blk_total" -gt 20 ] 2>/dev/null; then
                echo "  <div style='font-size:10px;color:var(--mut);padding:6px 0;'>(showing first 20 of $_blk_total rows — view full file in Lasso Explorer)</div>"
            fi
            echo "  </div></details>"
        fi

        # ── Running locks collapsible ──
        if [ -f "$_rlk_f" ]; then
            echo "  <details class='lock-det'><summary class='lock-sum'>🔐 Lock mode breakdown — from running_locks.out</summary>"
            echo "  <div class='lock-det-body'>"
            echo "  <table class='lock-tbl'><thead><tr><th>Lock mode</th><th>Total</th><th>Granted</th><th>Waiting</th></tr></thead><tbody>"
            # Detect mode, granted, relation columns by header name
            _rlk_mode_tmp=$(mktemp)
            ( awk -F'\t' '
            NR==1{
                for(i=1;i<=NF;i++){h=tolower($i);gsub(/\r/,"",h)
                    if(h=="mode")    mc=i
                    if(h=="granted") gc=i
                    if(h=="relation"||h=="relid") rc=i
                }
                if(!mc) mc=13; if(!gc) gc=14; if(!rc) rc=3
                next
            }
            NF>1 && $mc!="" {
                mode=$mc; granted=$gc
                gsub(/\r/,"",mode); gsub(/\r/,"",granted)
                total[mode]++
                if(granted=="t") g[mode]++; else w[mode]++
            }
            END{
                for(m in total){
                    wc=w[m]+0; gc2=g[m]+0
                    wstyle=(wc>0)?" style=\"color:var(--red);font-weight:600;\"":""
                    printf "<tr><td class=\"mc\">%s</td><td class=\"mc\">%d</td><td class=\"mc\">%d</td><td class=\"mc\"%s>%d</td></tr>\n",m,total[m],gc2,wstyle,wc
                }
            }' "$_rlk_f" ) > "$_rlk_mode_tmp" 2>/dev/null
            sort "$_rlk_mode_tmp"; rm -f "$_rlk_mode_tmp" 
            echo "  </tbody></table>"
            # Most contested relations — use detected relation column
            _rlk_rel_col=$(awk -F'\t' 'NR==1{for(i=1;i<=NF;i++){h=tolower($i);gsub(/\r/,"",h);if(h=="relation"||h=="relid"){print i}}}' "$_rlk_f" 2>/dev/null)
            _rlk_rel_col="${_rlk_rel_col:-3}"
            _top_rel=$(awk -F'\t' -v rc="$_rlk_rel_col" 'NR>1 && NF>1{gsub(/\r/,""); if($rc~/^[0-9]+$/)print $rc}' "$_rlk_f" | sort | uniq -c | sort -rn | head -n3)
            if [ -n "$_top_rel" ]; then
                echo "  <div style='margin-top:8px;font-size:10px;font-weight:600;color:var(--mut);text-transform:uppercase;letter-spacing:.4px;'>Most held relations (by OID)</div>"
                echo "  <div style='font-family:var(--mono);font-size:11px;margin-top:4px;'>"
                echo "$_top_rel" | while read -r _cnt _oid; do
                    echo "    <div style='padding:3px 0;color:var(--txt);'><span style='color:var(--red);font-weight:600;'>$_cnt locks</span> &nbsp;→&nbsp; relation OID $_oid</div>"
                done
                echo "  </div>"
            fi
            echo "  </div></details>"
        fi

        # ── Wait events collapsible ──
        if [ -f "$_rwt_f" ]; then
            echo "  <details class='lock-det'><summary class='lock-sum'>⏱ Wait event summary — from running_waits_sample.out</summary>"
            echo "  <div class='lock-det-body'>"
            echo "  <table class='lock-tbl'><thead><tr><th>Wait event type</th><th>Wait event</th><th>Avg count</th><th>Severity</th></tr></thead><tbody>"
            # File format (TSV): now | state | wait_event_type | wait_event | count
            # Timestamp contains a space so use -F'\t' — gives $1=timestamp $2=state $3=type $4=event $5=count
            # Skip header lines (now/state) and \N null rows, aggregate across all samples
            _rwt_tmp=$(mktemp)
            ( awk -F'\t' '
            NR==1 || $1~/^now/{next}
            $1~/^[0-9]{4}-/ && $3!~/^\\N/ && $3~/^[A-Za-z]/ && $5~/^[0-9]+/ {
                key=$3 SUBSEP $4; sum[key]+=$5+0; samples[key]++
            }
            END{
                for(k in sum){
                    split(k,a,SUBSEP); type=a[1]; event=a[2]
                    avg=int(sum[k]/(samples[k]>0?samples[k]:1))
                    if(type=="Lock")   sev="<span class=\"xid-badge xid-b-bad\">Lock</span>"
                    else if(type=="LWLock") sev="<span class=\"xid-badge xid-b-warn\">LWLock</span>"
                    else if(type=="IO")     sev="<span class=\"xid-badge xid-b-warn\">IO</span>"
                    else sev="<span class=\"xid-badge xid-b-ok\">"type"</span>"
                    printf "%d\t<tr><td class=\"mc\">%s</td><td class=\"mc\">%s</td><td class=\"mc\">%d</td><td>%s</td></tr>\n",avg,type,event,avg,sev
                }
            }' "$_rwt_f" ) > "$_rwt_tmp" 2>/dev/null
            sort -rn "$_rwt_tmp" | cut -f2- | head -n15; rm -f "$_rwt_tmp" 
            echo "  </tbody></table>"
            echo "  </div></details>"
        fi
        echo "</div>" # end lock-panel

        # ── Cross-reference verdict: connect root blockers with dominant wait events ──
        if [ -f "$_blk_f" ] && [ -f "$_rwt_f" ] && [ "$_blk_total" -gt 0 ] 2>/dev/null; then
            _top_blocker=$(awk -F'\t' \
                -v c2="$_bc_bkpid" -v c7="$_bc_bkstmt" \
                'NR>1 && NF>1{gsub(/\r/,""); cnt[$c2]++;q[$c2]=$c7} END{mx=0;for(p in cnt)if(cnt[p]>mx){mx=cnt[p];bp=p;bq=q[p]}; print bp"\t"mx"\t"bq}' \
                "$_blk_f" 2>/dev/null)
            _top_wait=$(awk -F'\t' 'NR==1||$1~/^now/{next} $1~/^[0-9]{4}-/ && $3!~/^\\N/ && $3~/^[A-Za-z]/ && $5~/^[0-9]+/{key=$3" · "$4;sum[key]+=$5+0;cnt[key]++} END{mx=0;for(k in sum){avg=sum[k]/cnt[k];if(avg>mx){mx=avg;mk=k}};print mk"\t"int(mx)}' "$_rwt_f" 2>/dev/null)
            _tbpid=$(echo "$_top_blocker"  | awk -F'\t' '{print $1}')
            _tbcnt=$(echo "$_top_blocker"  | awk -F'\t' '{print $2}')
            _tbq=$(echo  "$_top_blocker"  | awk -F'\t' '{print substr($3,1,50)}')
            _twev=$(echo "$_top_wait"     | awk -F'\t' '{print $1}')
            _twct=$(echo "$_top_wait"     | awk -F'\t' '{print $2}')
            if [ -n "$_tbpid" ] && [ -n "$_twev" ]; then
                echo "<div class='lock-xref'>"
                echo "  <div class='lock-xref-title'>🔗 Root cause cross-reference</div>"
                echo "  <div class='lock-xref-body'>PID <span class='lock-xref-pid'>$(echo "$_tbpid" | htmlesc)</span> is the root blocker holding up <b>${_tbcnt}</b> session(s) via <span class='lock-xref-q'>$(echo "$_tbq" | htmlesc)…</span>. Simultaneously, the dominant wait event across all samples is <span class='lock-xref-ev'>$(echo "$_twev" | htmlesc)</span> with an average of <b>${_twct}</b> sessions — indicating this is not an isolated lock conflict but a sustained contention event compounded by buffer pressure.</div>"
                echo "</div>"
            fi
        fi
    fi

    # ── EFM Service & Cluster Status ──
    echo "<div class='sh'>🛡️ PGRadar Cluster Health &amp; Service Status</div>"
    echo "<div class='efm-panel'>"
    echo "  <div class='efm-svc-grid'>"
    find "$_lp" -type f -iname "*efm*status.out" | sort | while read -r _ef; do
        _sn=$(basename "$_ef" | sed 's/-status\.out$//;s/_status\.out$//' | sed 's/[-_]/ /g')
        _fl=$(grep -Ei "(UP|DOWN|RUNNING|STOPPED|Active)" "$_ef" | head -n1 | tr -d '\r')
        case "$_fl" in
            *active*|*Active*|*RUNNING*|*UP*) _ed="efm-dot-up"; _eb="efm-badge-up"; _es="Running" ;;
            *DOWN*|*STOPPED*|*failed*)         _ed="efm-dot-dn"; _eb="efm-badge-dn"; _es="Stopped" ;;
            *)                                 _ed="efm-dot-uk"; _eb="efm-badge-uk"; _es="Unknown" ;;
        esac
        echo "    <div class='efm-svc'><div class='efm-stop'><span class='efm-dot $_ed'></span><span class='efm-sname'>$(echo "$_sn" | htmlesc)</span><span class='efm-badge $_eb'>$_es</span></div><div class='efm-sdet'>$(echo "$_fl" | htmlesc)</div></div>"
    done
    echo "  </div>"

    # Cluster topology from cluster_status.out
    _csf=$(find "$_lp" -type f -name "cluster_status.out" | head -n1)
    if [ -f "$_csf" ]; then
        echo "  <div class='efm-topo'>"
        echo "    <div class='efm-topo-hdr'><span class='efm-topo-title'>Cluster Topology &amp; Node Status</span><span class='efm-topo-hint'>from cluster_status.out</span></div>"
        _hn=$(grep -Ei "Primary|Standby|Witness" "$_csf" | head -n1)
        if [ -n "$_hn" ]; then
            echo "    <div class='efm-node-grid'>"
            awk '/Promote Status/{exit}/^\s+(Primary|Standby|Witness)/{print}' "$_csf" | tr -d '\r' | while IFS= read -r _ln; do
                _nt=$(echo "$_ln" | awk '{print $1}')
                _na=$(echo "$_ln" | awk '{print $2}')
                _nd=$(echo "$_ln" | awk '{print $3}')
                _nv=$(echo "$_ln" | awk '{print $4}')
                case "$_nt" in Primary) _nc="efm-np"; _ni="★";; Standby) _nc="efm-ns"; _ni="⟳";; *) _nc="efm-nw"; _ni="◎";; esac
                case "$_nd" in UP|up) _dc2="efm-db-up";; N/A|n/a) _dc2="efm-db-na";; *) _dc2="efm-db-uk";; esac
                echo "      <div class='efm-node $_nc'><div class='efm-ni'>$_ni</div><div class='efm-ninfo'><div class='efm-ntype'>$_nt</div><div class='efm-naddr'>$_na</div></div><div class='efm-nmeta'><div class='efm-ndb $_dc2'>DB: $_nd</div><div class='efm-nvip'>VIP: $_nv</div></div></div>"
            done
            echo "    </div>"
        fi
        echo "    <details class='efm-det'><summary class='efm-sum'>Full cluster status output</summary>"
        echo "      <pre class='efm-pre'>$(cat "$_csf" | htmlesc)</pre>"
        echo "    </details>"
        echo "  </div>"
    fi

    # EFM Properties — key settings from efm.properties, nested inside EFM panel
    _efmpf=$(find "$_lp" -type f -name "efm.properties" | head -n1)
    if [ -f "$_efmpf" ]; then
        _efm_get() { grep "^${1}=" "$_efmpf" 2>/dev/null | cut -d= -f2- | tr -d '\r\n'; }
        _ev_db_port=$(_efm_get "db.port");          _ev_db_user=$(_efm_get "db.user")
        _ev_bind=$(_efm_get "bind.address");         _ev_appname=$(_efm_get "application.name")
        _ev_promotable=$(_efm_get "promotable");     _ev_reconf=$(_efm_get "auto.reconfigure")
        _ev_failover=$(_efm_get "auto.failover");    _ev_priority=$(_efm_get "standby.priority")
        _ev_ping_s=$(_efm_get "ping.server.seconds"); _ev_ping_r=$(_efm_get "ping.server.retry.count")
        _ev_remote=$(_efm_get "remote.timeout.seconds"); _ev_local=$(_efm_get "local.timeout.seconds")
        _ev_script=$(_efm_get "script.notification"); _ev_nlevel=$(_efm_get "notification.level")
        _ev_email=$(_efm_get "user.email")
        if [ "$_ev_failover" = "true" ] && [ "$_ev_promotable" = "true" ]; then
            _efm_v="efmp-ok";   _efm_vm="✔ auto.failover and promotable are both enabled — cluster will promote a standby automatically on primary failure"
        elif [ "$_ev_failover" = "false" ] || [ "$_ev_promotable" = "false" ]; then
            _efm_v="efmp-warn"; _efm_vm="⚑ auto.failover or promotable is disabled — manual intervention required at failover"
        else
            _efm_v="efmp-info"; _efm_vm="ℹ Verify auto.failover and promotable values for intended failover behaviour"
        fi
        _efm_badge() {
            case "$1" in true)  echo "<span class='xid-badge xid-b-ok'>true</span>" ;;
                         false) echo "<span class='xid-badge xid-b-bad'>false</span>" ;;
                         *)     echo "<span class='mc' style='font-size:11px;'>$(echo "${1:-(not set)}" | htmlesc)</span>" ;;
            esac
        }
        echo "  <div class='efmp-inner'>"
        echo "    <div class='efmp-inner-hdr'>🔑 EFM Properties — Key Settings</div>"
        echo "    <div class='efmp-grid'>"
        echo "      <div>"
        echo "        <div class='efmp-section'>Connection</div>"
        echo "        <div class='efmp-row'><span class='efmp-key'>db.port</span>$(_efm_badge "$_ev_db_port")</div>"
        echo "        <div class='efmp-row'><span class='efmp-key'>db.user</span>$(_efm_badge "$_ev_db_user")</div>"
        echo "        <div class='efmp-row'><span class='efmp-key'>bind.address</span>$(_efm_badge "$_ev_bind")</div>"
        echo "        <div class='efmp-row'><span class='efmp-key'>application.name</span>$(_efm_badge "$_ev_appname")</div>"
        echo "        <div class='efmp-section' style='margin-top:10px;'>Failover behaviour</div>"
        echo "        <div class='efmp-row'><span class='efmp-key'>promotable</span>$(_efm_badge "$_ev_promotable")</div>"
        echo "        <div class='efmp-row'><span class='efmp-key'>auto.reconfigure</span>$(_efm_badge "$_ev_reconf")</div>"
        echo "        <div class='efmp-row'><span class='efmp-key'>auto.failover</span>$(_efm_badge "$_ev_failover")</div>"
        echo "        <div class='efmp-row'><span class='efmp-key'>standby.priority</span>$(_efm_badge "$_ev_priority")</div>"
        echo "      </div>"
        echo "      <div>"
        echo "        <div class='efmp-section'>Timeouts &amp; thresholds</div>"
        echo "        <div class='efmp-row'><span class='efmp-key'>ping.server.seconds</span>$(_efm_badge "$_ev_ping_s")</div>"
        echo "        <div class='efmp-row'><span class='efmp-key'>ping.server.retry</span>$(_efm_badge "$_ev_ping_r")</div>"
        echo "        <div class='efmp-row'><span class='efmp-key'>remote.timeout.seconds</span>$(_efm_badge "$_ev_remote")</div>"
        echo "        <div class='efmp-row'><span class='efmp-key'>local.timeout.seconds</span>$(_efm_badge "$_ev_local")</div>"
        echo "        <div class='efmp-section' style='margin-top:10px;'>Notifications</div>"
        echo "        <div class='efmp-row'><span class='efmp-key'>script.notification</span>$(_efm_badge "$_ev_script")</div>"
        echo "        <div class='efmp-row'><span class='efmp-key'>notification.level</span>$(_efm_badge "$_ev_nlevel")</div>"
        echo "        <div class='efmp-row'><span class='efmp-key'>user.email</span>$(_efm_badge "$_ev_email")</div>"
        echo "      </div>"
        echo "    </div>"
        echo "    <div class='efmp-verdict $_efm_v'>$_efm_vm</div>"
        echo "  </div>"
    fi
    echo "</div>" # end efm-panel
}

# ── Emit the Cluster Overview panel (comparison table of all nodes) ──
emit_overview_panel() {
    echo "<div class='ov-intro'>All nodes at a glance — compare key metrics across the cluster.</div>"
    echo "<div class='ov-grid'>"
    while IFS='|' read -r _nid _role _host _lp; do
        case "$_role" in
            Primary) _rc="#2f81f7"; _rb="rgba(29,78,216,.15)"; _rbr="rgba(29,78,216,.4)"; _ri="★" ;;
            Standby) _rc="#3fb950"; _rb="rgba(15,110,86,.15)";  _rbr="rgba(15,110,86,.4)";  _ri="⟳" ;;
            Witness) _rc="#94a3b8"; _rb="rgba(51,65,85,.3)";    _rbr="rgba(100,116,139,.4)"; _ri="◎" ;;
            *)       _rc="#8b949e"; _rb="rgba(51,65,85,.2)";    _rbr="#30363d";              _ri="?" ;;
        esac

        # ── OS / Memory ──
        _mem_f2=$(find "$_lp" -path "*/proc/meminfo.data" | head -n1)
        _mem_fr2="N/A"; _mem_tot2="N/A"; _swap_u2="N/A"; _swap_tot2="N/A"
        if [ -f "$_mem_f2" ]; then
            _mem_fr2="$(get_gb_from "$_mem_f2" "MemAvailable") GB"
            _mem_tot2="$(get_gb_from "$_mem_f2" "MemTotal") GB"
            _swap_u2=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{printf "%.2f GB",(t-f)/1024/1024}' "$_mem_f2" 2>/dev/null | tr -d '\n\r')
            _swap_u2=${_swap_u2:-N/A}
            _swap_tot2="$(get_gb_from "$_mem_f2" "SwapTotal") GB"
        fi

        # ── CPU / Load ──
        _cpu_us2="N/A"; _load_12="N/A"; _load_52="N/A"; _load_152="N/A"
        _top_f2=$(find "$_lp" -path "*/top.data" | head -n1)
        if [ -f "$_top_f2" ]; then
            _cpu_line=$(grep "%Cpu(s):" "$_top_f2" | head -n1)
            _cpu_us2=$(echo "$_cpu_line" | awk '{print $2}' | tr -d '%us,')
            _cpu_sy2=$(echo "$_cpu_line" | awk '{print $4}' | tr -d '%sy,')
            _load_line=$(grep "load average:" "$_top_f2" | head -n1)
            _load_12=$(echo "$_load_line"  | awk -F'load average: ' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
            _load_52=$(echo "$_load_line"  | awk -F'load average: ' '{print $2}' | awk -F',' '{print $2}' | tr -d ' ')
            _load_152=$(echo "$_load_line" | awk -F'load average: ' '{print $2}' | awk -F',' '{print $3}' | tr -d ' ')
        fi

        # ── Connections ──
        _conn_a2=0; _conn_i2=0; _conn_itx2=0; _conn_tot2=0
        _cf2=$(find "$_lp" -type f -name "running_activity.out" | head -n1)
        if [ -f "$_cf2" ]; then
            _conn_counts2=$(awk -F'\t' '
            NR==1{
                for(i=1;i<=NF;i++){
                    h=tolower($i); gsub(/\r/,"",h)
                    if(h=="state" || h=="status") sc=i
                }
                next
            }
            NR>1 && sc>0 {
                v=$sc; gsub(/\r/,"",v); tot++
                if(v=="active")            act++
                else if(v=="idle in transaction" || v=="idle in transaction (aborted)") itx++
                else if(v=="idle")         idl++
            }
            END{print act+0, idl+0, itx+0, tot+0}
            ' "$_cf2" 2>/dev/null)
            _conn_a2=$(  echo "$_conn_counts2" | awk '{print $1}')
            _conn_i2=$(  echo "$_conn_counts2" | awk '{print $2}')
            _conn_itx2=$(echo "$_conn_counts2" | awk '{print $3}')
            _conn_tot2=$(echo "$_conn_counts2" | awk '{print $4}')
            _conn_a2=${_conn_a2:-0}; _conn_i2=${_conn_i2:-0}
            _conn_itx2=${_conn_itx2:-0}; _conn_tot2=${_conn_tot2:-0}
        fi

        # ── PostgreSQL version ──
        _pgver2=$(find "$_lp" -name "postgresql_server_version.data" | head -n1)
        _pgv2="N/A"
        [ -f "$_pgver2" ] && _pgv2=$(cat "$_pgver2" | tr -d '\n\r' | cut -c1-30)

        # ── OS info ──
        _os2=$(find "$_lp" -path "*/linux/id/os_release.data" | head -n1)
        _osv2="N/A"
        [ -f "$_os2" ] && _osv2=$(grep "PRETTY_NAME" "$_os2" | cut -d'"' -f2 | cut -c1-30)

        # ── EFM service status ──
        _efm_st2="Unknown"
        _efm_f2=$(find "$_lp" -type f -iname "*efm*status.out" | head -n1)
        if [ -f "$_efm_f2" ]; then
            _efm_line=$(grep -Ei "Active:|running|stopped|failed" "$_efm_f2" | head -n1)
            case "$_efm_line" in
                *active*|*Active*|*running*) _efm_st2="Running" ;;
                *stopped*|*failed*)          _efm_st2="Stopped" ;;
                *)                           _efm_st2="Unknown" ;;
            esac
        fi
        case "$_efm_st2" in
            Running) _efm_rc="#3fb950" ;;
            Stopped) _efm_rc="#f85149" ;;
            *)       _efm_rc="#8b949e" ;;
        esac

        # ── DB state & VIP from cluster_status.out ──
        _db_state2="N/A"; _vip2="—"; _vip_holder2=0
        _cs2=$(find "$_lp" -type f -name "cluster_status.out" | head -n1)
        if [ -f "$_cs2" ]; then
            # Find the line for this node's IP
            _node_ip2=$(echo "$_host" | tr -d '[:space:]')
            _cs_line2=$(grep "$_node_ip2" "$_cs2" | head -n1)
            if [ -n "$_cs_line2" ]; then
                _db_state2=$(echo "$_cs_line2" | awk '{print $3}')
                _vip_raw=$(echo "$_cs_line2" | awk '{print $4}')
                # VIP holder has * suffix
                echo "$_vip_raw" | grep -q '\*' && _vip_holder2=1
                _vip2=$(echo "$_vip_raw" | tr -d '*')
            fi
        fi
        case "$_db_state2" in
            UP|up)   _db_rc="#3fb950" ;;
            N/A|n/a) _db_rc="#8b949e" ;;
            DOWN)    _db_rc="#f85149" ;;
            *)       _db_rc="#d29922" ;;
        esac

        # ── WAL replay lag (standbys only, from cluster_status.out promote section) ──
        _wal_lag2="—"
        if [ "$_role" = "Standby" ] && [ -f "$_cs2" ]; then
            # Look in Promote Status section for this node's replay lag
            _wal_lag2=$(awk '/Promote Status/,0' "$_cs2" | grep "$_node_ip2" | awk '{print $4}' | head -n1)
            [ -z "$_wal_lag2" ] && _wal_lag2="in sync"
        fi

        # ── Replication slot count ──
            _slot_cnt2=0; _slot_inactive2=0
            _slotf2=$(find "$_lp" -type f -name "replication_slots.out" | head -n1)
            if [ -f "$_slotf2" ]; then
                _slot_cnt2=$(awk 'NR>1 && NF>0{c++}END{print c+0}' "$_slotf2" 2>/dev/null | tr -d '\n\r')
                _slot_cnt2=${_slot_cnt2:-0}
                _slot_inactive2=$(awk -F'\t' '
                NR==1{for(i=1;i<=NF;i++){h=tolower($i);gsub(/\r/,"",h);if(h=="active")ac=i};next}
                NR>1 && ac>0{v=$ac;gsub(/\r/,"",v);if(v=="f"||v=="false")c++}
                END{print c+0}' "$_slotf2" 2>/dev/null | tr -d '\n\r')
                _slot_inactive2=${_slot_inactive2:-0}
            fi

        # ── XID age (worst database) ──
        _xid_age2="—"; _xid_db2=""; _xid_pct2=0; _xid_c2="var(--mut)"
        _dbf2=$(find "$_lp" -path "*/postgresql/databases.out" | head -n1)
        if [ -f "$_dbf2" ]; then
            _age_col2=$(awk -F'\t' 'NR==1{for(i=1;i<=NF;i++){h=tolower($i);gsub(/\r/,"",h);if(h=="datage"||h=="age"||h~/age.*frozen/||h~/frozen.*age/||h=="xid_age"){print i}}}' "$_dbf2" 2>/dev/null | tr -d '\n\r')
            _age_col2=${_age_col2:-0}
            _age_col2="${_age_col2:-0}"
            _xid_worst=$(awk -F'\t' -v ac="$_age_col2" '
            NR==1{next}
            NF>1{
                gsub(/\r/,"")
                age=(ac>0&&ac<=NF)?$ac:$NF; gsub(/\r/,"",age)
                if(age~/^[0-9]+$/ && age+0>max){max=age+0;db=$2}
            }
            END{if(db!="")print max"\t"db}' "$_dbf2")
            if [ -n "$_xid_worst" ]; then
                _xid_raw=$(echo "$_xid_worst" | awk -F'\t' '{print $1}')
                _xid_db2=$(echo "$_xid_worst" | awk -F'\t' '{print $2}')
                _xid_pct2=$(echo "$_xid_raw" | awk '{printf "%d",($1/2000000000)*100}' | tr -d '\n\r')
            _xid_pct2=${_xid_pct2:-0}
                _xid_age2=$(echo "$_xid_raw" | awk '{if($1>=1000000000)printf "%.2fB",$1/1000000000;else if($1>=1000000)printf "%.0fM",$1/1000000;else print $1}')
                if   [ "$_xid_pct2" -ge 75 ] 2>/dev/null; then _xid_c2="var(--red)"
                elif [ "$_xid_pct2" -ge 50 ] 2>/dev/null; then _xid_c2="var(--yel)"
                elif [ "$_xid_pct2" -ge 10 ] 2>/dev/null; then _xid_c2="var(--yel)"
                else _xid_c2="var(--grn)"; fi
            fi
        fi

        # ── Checkpoint forced ratio ──
        _ckpt_ratio2="—"; _ckpt_c2="var(--mut)"
        _bgwf2=$(find "$_lp" -type f \( -name "pg_stat_bgwriter.out" -o -name "pg_stat_bgwriter.data" \) 2>/dev/null | head -n1)
        if [ -f "$_bgwf2" ]; then
            _ckpt_ratio2=$(awk -F'\t' '
            NR==1{for(i=1;i<=NF;i++){h=tolower($i);gsub(/\r/,"",h);if(h=="checkpoints_timed")tc=i;if(h=="checkpoints_req")rc=i};next}
            NR==2{
                t=(tc>0)?$tc:$1; r=(rc>0)?$rc:$2
                total=t+r+0
                if(total>0) printf "%.1f",r/total*100; else print "0"
            }' "$_bgwf2" 2>/dev/null | tr -d '\n\r')
            _ckpt_ratio2=${_ckpt_ratio2:-0}
            [ "$_ckpt_ratio2" = "0" ] && _ckpt_ratio2="—"
            if echo "$_ckpt_ratio2" | grep -qE "^[0-9]"; then
                _cr2_n=$(echo "$_ckpt_ratio2" | awk '{print int($1)}' | tr -d '\n\r')
                _cr2_n=${_cr2_n:-0}
                if   [ "$_cr2_n" -ge 25 ] 2>/dev/null; then _ckpt_c2="var(--red)"
                elif [ "$_cr2_n" -ge 10 ] 2>/dev/null; then _ckpt_c2="var(--yel)"
                else _ckpt_c2="var(--grn)"; fi
                _ckpt_ratio2="${_ckpt_ratio2}%"
            fi
        fi

        # ── Render card ──
        echo "  <div class='ov-card'>"

        # Header: role icon + hostname + role badge + VIP crown
        echo "    <div class='ov-hdr'>"
        echo "      <span class='ov-role-icon' style='color:${_rc};'>$_ri</span>"
        echo "      <span class='ov-name'>$(echo "$_host" | htmlesc)</span>"
        echo "      <span class='ov-role' style='background:${_rb};color:${_rc};border:1px solid ${_rbr};'>$_role</span>"
        [ "$_vip_holder2" = "1" ] && echo "      <span class='ov-vip-crown' title='VIP Holder'>👑</span>"
        echo "    </div>"

        # Status strip: EFM + DB state
        echo "    <div class='ov-status-strip'>"
        echo "      <span class='ov-status-dot' style='background:${_efm_rc};'></span><span class='ov-status-lbl'>EFM ${_efm_st2}</span>"
        echo "      <span class='ov-status-sep'>·</span>"
        echo "      <span class='ov-status-dot' style='background:${_db_rc};'></span><span class='ov-status-lbl'>DB ${_db_state2}</span>"
        [ "$_role" = "Standby" ] && echo "      <span class='ov-status-sep'>·</span><span class='ov-status-lbl' style='color:#d29922;'>Lag: ${_wal_lag2}</span>"
        echo "    </div>"

        echo "    <div class='ov-divider'></div>"

        # Section: System
        echo "    <div class='ov-section-lbl'>SYSTEM</div>"
        echo "    <div class='ov-row'><span class='ok'>PG Version</span><span class='ov ov-mono'>$(echo "$_pgv2" | htmlesc)</span></div>"
        echo "    <div class='ov-row'><span class='ok'>OS</span><span class='ov ov-small'>$(echo "$_osv2" | htmlesc)</span></div>"

        echo "    <div class='ov-divider'></div>"

        # Section: CPU & Memory
        echo "    <div class='ov-section-lbl'>CPU &amp; MEMORY</div>"
        # Colour CPU user%
        _cpu_c2="var(--txt)"
        if echo "$_cpu_us2" | grep -qE "^[0-9]"; then
            _cu=$(echo "$_cpu_us2" | awk '{print int($1)}' | tr -d '\n\r')
            _cu=${_cu:-0}
            [ "$_cu" -ge 90 ] 2>/dev/null && _cpu_c2="var(--red)" || { [ "$_cu" -ge 70 ] 2>/dev/null && _cpu_c2="var(--yel)"; }
        fi
        echo "    <div class='ov-row'><span class='ok'>CPU User%</span><span class='ov' style='color:${_cpu_c2};'>${_cpu_us2}%</span></div>"
        [ "$_cpu_sy2" != "N/A" ] && [ -n "$_cpu_sy2" ] && echo "    <div class='ov-row'><span class='ok'>CPU Sys%</span><span class='ov'>${_cpu_sy2}%</span></div>"
        echo "    <div class='ov-row'><span class='ok'>Load Avg</span><span class='ov ov-mono'>${_load_12} / ${_load_52} / ${_load_152}</span></div>"
        # Colour RAM free (red if < 10% free)
        _ram_c2="var(--txt)"
        if [ -f "$_mem_f2" ]; then
            _free_raw=$(get_gb_from "$_mem_f2" "MemAvailable" 2>/dev/null | awk '{print $1+0}' | tr -d '\n\r')
            _tot_raw=$(get_gb_from "$_mem_f2" "MemTotal" 2>/dev/null | awk '{print $1+0}' | tr -d '\n\r')
            _free_raw=${_free_raw:-0}; _tot_raw=${_tot_raw:-0}
            if [ "$_tot_raw" -gt 0 ] 2>/dev/null; then
                _ram_pct2=$(echo "$_free_raw $_tot_raw" | awk '{printf "%d",$1*100/$2}' | tr -d '\n\r')
                _ram_pct2=${_ram_pct2:-0}
                [ "$_ram_pct2" -le 10 ] 2>/dev/null && _ram_c2="var(--red)" || { [ "$_ram_pct2" -le 20 ] 2>/dev/null && _ram_c2="var(--yel)"; }
            fi
        fi
        echo "    <div class='ov-row'><span class='ok'>RAM Free</span><span class='ov' style='color:${_ram_c2};'>${_mem_fr2} <span class='ov-of'>of ${_mem_tot2}</span></span></div>"
        # Colour swap used
        _swap_c2="var(--txt)"
        if [ -f "$_mem_f2" ]; then
            _swap_pct_raw=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{if(t>0)printf "%d",(t-f)*100/t}' "$_mem_f2" 2>/dev/null | tr -d '\n\r')
            _swap_pct_raw=${_swap_pct_raw:-0}
            [ "$_swap_pct_raw" -ge 80 ] 2>/dev/null && _swap_c2="var(--red)" || { [ "$_swap_pct_raw" -ge 50 ] 2>/dev/null && _swap_c2="var(--yel)"; }
        fi
        echo "    <div class='ov-row'><span class='ok'>Swap Used</span><span class='ov' style='color:${_swap_c2};'>${_swap_u2} <span class='ov-of'>of ${_swap_tot2}</span></span></div>"

        echo "    <div class='ov-divider'></div>"

        # Section: Connections
        echo "    <div class='ov-section-lbl'>CONNECTIONS</div>"
        # Colour total connections if > 80% of max_connections
        _ctot_c2="var(--txt)"
        _mc2=$(awk -F'\t' '$1=="max_connections"{print $2+0}' "$(find "$_lp" -type f -name "configuration.out" | head -n1)" 2>/dev/null | tr -d '\n\r' | head -c 10)
        _mc2=${_mc2:-0}
        if [ "$_mc2" -gt 0 ] && [ "$_conn_tot2" -gt 0 ] 2>/dev/null; then
            _cpct2=$(( ${_conn_tot2:-0} * 100 / ${_mc2:-1} ))
            _cpct2=${_cpct2:-0}
            [ "$_cpct2" -ge 80 ] 2>/dev/null && _ctot_c2="var(--red)" || { [ "$_cpct2" -ge 60 ] 2>/dev/null && _ctot_c2="var(--yel)"; }
        fi
        echo "    <div class='ov-row'><span class='ok'>Total</span><span class='ov' style='color:${_ctot_c2};'>${_conn_tot2}$([ "$_mc2" -gt 0 ] && echo " <span class='ov-of'>of $_mc2</span>")</span></div>"
        echo "    <div class='ov-row'><span class='ok'>Active</span><span class='ov' style='color:#3fb950;'>${_conn_a2}</span></div>"
        echo "    <div class='ov-row'><span class='ok'>Idle</span><span class='ov'>${_conn_i2}</span></div>"
        [ "$_conn_itx2" -gt 0 ] 2>/dev/null && echo "    <div class='ov-row'><span class='ok'>Idle-in-TX</span><span class='ov' style='color:#f85149;font-weight:600;'>${_conn_itx2} ⚠</span></div>"

        # Section: Database health
        echo "    <div class='ov-divider'></div>"
        echo "    <div class='ov-section-lbl'>DB HEALTH</div>"
        echo "    <div class='ov-row'><span class='ok'>XID Age</span><span class='ov' style='color:${_xid_c2};'>${_xid_age2}$([ -n "$_xid_db2" ] && echo " <span class='ov-of'>${_xid_db2}</span>")</span></div>"
        echo "    <div class='ov-row'><span class='ok'>Forced ckpt</span><span class='ov' style='color:${_ckpt_c2};'>${_ckpt_ratio2}</span></div>"

        # Replication slots (only if present)
        if [ "$_slot_cnt2" -gt 0 ] 2>/dev/null; then
            echo "    <div class='ov-divider'></div>"
            echo "    <div class='ov-section-lbl'>REPLICATION SLOTS</div>"
            if [ "$_slot_inactive2" -gt 0 ] 2>/dev/null; then
                echo "    <div class='ov-row'><span class='ok'>Slots</span><span class='ov'>${_slot_cnt2} total <span style='color:#f85149;font-weight:600;'>${_slot_inactive2} inactive ⚠</span></span></div>"
            else
                echo "    <div class='ov-row'><span class='ok'>Slots</span><span class='ov'>${_slot_cnt2} (all active)</span></div>"
            fi
        fi

        # VIP info
        if [ -n "$_vip2" ] && [ "$_vip2" != "—" ]; then
            echo "    <div class='ov-divider'></div>"
            echo "    <div class='ov-section-lbl'>NETWORK</div>"
            echo "    <div class='ov-row'><span class='ok'>VIP</span><span class='ov ov-mono'>$(echo "$_vip2" | htmlesc)$([ "$_vip_holder2" = "1" ] && echo " 👑")</span></div>"
        fi

        echo "  </div>"
    done < "$NODES_META"
    echo "</div>"
}

# =============================================================================
# STEP 9 — Write the complete HTML file
# =============================================================================
{
cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>PGRadar — Cluster Health Dashboard — ${TIMESTAMP}</title>
<style>
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&family=JetBrains+Mono:wght@400;600&display=swap');
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0;}
:root{
  --bg:#0d1117; --sur:#161b22; --sur2:#21262d; --bdr:#30363d;
  --txt:#e6edf3; --mut:#8b949e; --pri:#2f81f7;
  --grn:#3fb950; --yel:#d29922; --red:#f85149; --org:#db6d28; --pur:#a371f7;
  --fnt:'Inter',system-ui,sans-serif; --mono:'JetBrains Mono',monospace;
}
body{font-family:var(--fnt);background:var(--bg);color:var(--txt);font-size:13.5px;line-height:1.6;-webkit-font-smoothing:antialiased;}
body.lt{--bg:#f6f8fa;--sur:#fff;--sur2:#f0f3f6;--bdr:#d0d7de;--txt:#1f2328;--mut:#57606a;--pri:#0969da;--grn:#1a7f37;--yel:#9a6700;--red:#cf222e;--org:#bc4c00;--pur:#8250df;}
body.lt .hero{background:#f6f8fa;}
body.lt .topbar-logo{color:#1f2328;}
body.lt thead th{background:#f0f3f6;color:#57606a;}
body.lt tbody td{color:#1f2328;}
body.lt .mc{color:#0550ae;}
/* Fix 3: Light mode — EFM panel needs proper surface colors */
body.lt .efm-panel{background:#fff;border-color:#d0d7de;}
body.lt .efm-svc-grid{background:#f6f8fa;}
body.lt .efm-svc{border-right-color:#d0d7de;}
body.lt .efm-sname{color:#1f2328;}
body.lt .efm-sdet{color:#57606a;}
body.lt .efm-topo{background:#fff;}
body.lt .efm-pre{background:#f0f3f6;color:#1f2328;}
body.lt .efm-node.efm-np{background:rgba(9,105,218,.07);border-color:rgba(9,105,218,.35);}
body.lt .efm-node.efm-ns{background:rgba(26,127,55,.07);border-color:rgba(26,127,55,.35);}
body.lt .efm-node.efm-nw{background:rgba(87,96,106,.07);border-color:rgba(87,96,106,.35);}
body.lt .efm-naddr{color:#1f2328;}
body.lt .efm-topo-hint{color:#57606a;}
body.lt .efm-sum{color:#57606a;}

/* Topbar */
.topbar{background:var(--sur);border-bottom:1px solid var(--bdr);padding:10px 18px;display:flex;align-items:center;gap:10px;position:sticky;top:0;z-index:200;width:100%;}
.topbar-logo{font-size:15px;font-weight:600;color:var(--txt);}
.topbar-logo span{color:var(--pri);}
.tb-sep{flex:1;}
.tb-badge{font-size:10px;padding:3px 9px;border-radius:10px;font-weight:600;background:rgba(63,185,80,.15);color:var(--grn);border:1px solid rgba(63,185,80,.3);}
.tb-ts{font-size:10px;color:var(--mut);font-family:var(--mono);}
.theme-btn{background:var(--sur2);border:1px solid var(--bdr);border-radius:20px;padding:4px 12px 4px 8px;display:flex;align-items:center;gap:6px;cursor:pointer;font-size:11px;font-weight:600;color:var(--mut);}
.theme-btn:hover{color:var(--txt);}
.font-ruler{display:flex;align-items:center;gap:5px;}
.font-ruler input[type=range]{width:64px;height:4px;cursor:pointer;accent-color:var(--pri);vertical-align:middle;}

/* Hero */
.hero{background:linear-gradient(135deg,#161b22 0%,#0d1117 60%);border-bottom:1px solid var(--bdr);padding:20px 18px 16px;}
.hero-h{font-size:20px;font-weight:600;color:var(--txt);margin-bottom:6px;}
.hero-sub{font-family:var(--mono);font-size:10px;color:var(--mut);background:var(--sur2);border:1px solid var(--bdr);display:inline-block;padding:3px 8px;border-radius:5px;margin-bottom:10px;}
.badge-row{display:flex;gap:6px;flex-wrap:wrap;}
.badge{padding:4px 10px;border-radius:20px;font-size:10px;font-weight:600;}
.b-ip{background:rgba(47,129,247,.15);color:#79c0ff;border:1px solid rgba(47,129,247,.3);}
.b-os{background:rgba(163,113,247,.15);color:#d2a8ff;border:1px solid rgba(163,113,247,.3);}
.b-pg{background:rgba(63,185,80,.15);color:#56d364;border:1px solid rgba(63,185,80,.3);}

/* Tab bar */
.tab-bar{background:var(--bg);border-bottom:2px solid var(--bdr);padding:0 18px;display:flex;gap:2px;align-items:flex-end;overflow-x:auto;}
.tab{padding:10px 16px 8px;font-size:12px;font-weight:500;color:var(--mut);cursor:pointer;border-radius:8px 8px 0 0;border:1px solid transparent;border-bottom:none;display:flex;align-items:center;gap:7px;white-space:nowrap;transition:all .15s;}
.tab:hover{color:var(--txt);background:var(--sur);}
.tab.active{background:var(--sur);color:var(--txt);border-color:var(--bdr);border-bottom:2px solid var(--sur);margin-bottom:-2px;}
.tab-dot{width:7px;height:7px;border-radius:50%;flex-shrink:0;}
.tab-role{font-size:9px;padding:1px 5px;border-radius:3px;font-weight:700;text-transform:uppercase;}
.tr-p{background:rgba(47,129,247,.2);color:#79c0ff;}
.tr-s{background:rgba(63,185,80,.2);color:#56d364;}
.tr-w{background:rgba(100,116,139,.2);color:#94a3b8;}
.tr-u{background:rgba(139,148,158,.15);color:#8b949e;}

/* Tab pane */
.pane{display:none;padding:16px 18px;}
.pane.active{display:block;}

/* Node header */
.node-hdr{display:flex;align-items:center;gap:12px;margin-bottom:14px;padding-bottom:12px;border-bottom:1px solid var(--bdr);}
.nh-icon{width:36px;height:36px;border-radius:8px;display:flex;align-items:center;justify-content:center;font-size:16px;flex-shrink:0;}
.nh-info{flex:1;}
.nh-name{font-size:15px;font-weight:600;color:var(--txt);}
/* Fix 2: OS and PG version text — bumped from 10px to 12px, uses regular body font not mono */
.nh-sub{font-size:12px;color:var(--mut);margin-top:3px;line-height:1.5;}
.nh-badge{font-size:10px;padding:3px 9px;border-radius:10px;font-weight:600;}

/* Fix 4: Tab active state — colored top border per node role */
.tab.active{background:var(--sur);color:var(--txt);border-color:var(--bdr);border-bottom:2px solid var(--sur);margin-bottom:-2px;}
.tab.active.tab-ov{border-top:2px solid var(--mut);}
.tab.active.tab-p{border-top:3px solid #2f81f7;}
.tab.active.tab-s{border-top:3px solid #3fb950;}
.tab.active.tab-w{border-top:3px solid #94a3b8;}
.tab.active.tab-u{border-top:2px solid var(--mut);}
/* Inactive tab: show a subtle left border dot by role so tabs are distinguishable even unfocused */
.tab.tab-p .tab-dot{background:#2f81f7;}
.tab.tab-s .tab-dot{background:#3fb950;}
.tab.tab-w .tab-dot{background:#94a3b8;}
/* Light mode: stronger contrast on active tab top border + dot */
body.lt .tab.active.tab-p{border-top:3px solid #0969da;background:#fff;box-shadow:inset 0 2px 0 #0969da;}
body.lt .tab.active.tab-s{border-top:3px solid #1a7f37;background:#fff;box-shadow:inset 0 2px 0 #1a7f37;}
body.lt .tab.active.tab-w{border-top:3px solid #57606a;background:#fff;box-shadow:inset 0 2px 0 #57606a;}
body.lt .tab.tab-p .tab-role{background:rgba(9,105,218,.12);color:#0969da;}
body.lt .tab.tab-s .tab-role{background:rgba(26,127,55,.12);color:#1a7f37;}
body.lt .tab.tab-w .tab-role{background:rgba(87,96,106,.12);color:#57606a;}

/* Stat grid */
.stat-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin-bottom:12px;}
.sc{background:var(--sur);border:1px solid var(--bdr);border-radius:8px;padding:10px 12px;}
.sc-l{font-size:9px;color:var(--mut);text-transform:uppercase;letter-spacing:.5px;margin-bottom:5px;}
.sc-v{font-size:13px;font-weight:600;color:var(--txt);}

/* Charts */
.chart-row{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin-bottom:12px;}
.chart-card{background:var(--sur);border:1px solid var(--bdr);border-radius:8px;padding:10px 12px;display:flex;flex-direction:column;}
.ct{font-size:9px;color:var(--mut);text-transform:uppercase;letter-spacing:.5px;margin-bottom:8px;padding-bottom:6px;border-bottom:1px solid var(--bdr);flex-shrink:0;}
.cl{display:flex;flex-direction:column;gap:3px;flex-shrink:0;}
.conn-leg{display:grid;grid-template-columns:1fr 1fr 1fr;gap:3px;}
.clr{display:flex;justify-content:space-between;font-size:10px;}
.cll{display:flex;align-items:center;gap:4px;color:var(--mut);}
.cld{width:6px;height:6px;border-radius:50%;flex-shrink:0;}
.clv{font-family:var(--mono);font-size:10px;color:var(--txt);}
.dw{position:relative;height:170px;width:100%;margin:4px 0;}
.ss{border-top:1px solid var(--bdr);padding-top:7px;display:flex;flex-direction:column;gap:3px;flex-shrink:0;}
.sr{display:flex;justify-content:space-between;font-size:10px;}
.sk{color:var(--mut);}.sv{font-family:var(--mono);font-size:10px;color:var(--txt);}
.sw{color:var(--yel);}.so{color:var(--grn);}

/* Connection drill-down */
.conn-drill{margin-top:8px;border-top:1px solid var(--bdr);padding-top:7px;display:flex;flex-direction:column;gap:4px;}
.cdr{display:flex;align-items:center;gap:6px;}
.cdl{font-size:10px;flex:1;}
.cdb{font-size:10px;padding:2px 8px;border-radius:4px;text-decoration:none;border:1px solid var(--bdr);background:var(--sur2);color:var(--pri);font-weight:600;white-space:nowrap;}
.cdb-raw{color:var(--mut);}

/* Params + Config grid */
.params-cfg-grid{display:grid;grid-template-columns:3fr 2fr;gap:14px;margin-bottom:12px;align-items:start;}
/* Right column: config files stacked above lasso report panel */
.cfg-lasso-col{display:flex;flex-direction:column;gap:0;}
.sh{font-size:11px;font-weight:600;color:var(--txt);background:var(--sur2);border:1px solid var(--bdr);border-left:3px solid var(--pri);border-radius:0 6px 6px 0;padding:7px 12px;margin:12px 0 8px;}
.tc{background:var(--sur);border:1px solid var(--bdr);border-radius:8px;overflow:hidden;margin-bottom:8px;}
table{border-collapse:collapse;width:100%;}
thead th{background:var(--sur2);color:var(--mut);font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.5px;padding:8px 12px;text-align:left;border-bottom:1px solid var(--bdr);}
tbody td{padding:8px 12px;border-bottom:1px solid var(--bdr);color:var(--txt);font-size:12px;}
tbody tr:last-child td{border-bottom:none;}
tbody tr:hover{background:var(--sur2);}
.mc{font-family:var(--mono);font-size:11px;color:#79c0ff;}
.badge-ok{background:rgba(63,185,80,.15);color:var(--grn);border:1px solid rgba(63,185,80,.3);padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600;}
.badge-warn{background:rgba(210,153,34,.15);color:var(--yel);border:1px solid rgba(210,153,34,.3);padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600;}
.badge-bad{background:rgba(248,81,73,.15);color:var(--red);border:1px solid rgba(248,81,73,.3);padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600;}
.badge-info{background:rgba(139,148,158,.1);color:var(--mut);border:1px solid var(--bdr);padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600;}

/* Config cards */
.cfg-grid{display:flex;flex-direction:column;gap:8px;}
.cfg-card{background:var(--sur);border:1px solid var(--bdr);border-radius:8px;padding:12px 14px;display:flex;align-items:center;gap:12px;transition:border-color .15s;}
.cfg-card:hover{border-color:var(--pri);}
.cfg-left{display:flex;align-items:center;gap:10px;flex:1;min-width:0;}
.cfg-icon{font-size:20px;flex-shrink:0;width:30px;text-align:center;}
.cfg-info{min-width:0;}
.cfg-name{font-family:var(--mono);font-size:11px;font-weight:600;color:var(--txt);margin-bottom:2px;}
.cfg-desc{font-size:10px;color:var(--mut);}
.cfg-acts{display:flex;gap:6px;flex-shrink:0;}
.cfg-btn{font-size:10px;font-weight:600;padding:4px 10px;border-radius:6px;text-decoration:none;border:1px solid var(--bdr);}
.cfg-pri{background:var(--pri);color:#fff;border-color:var(--pri);}
.cfg-raw{background:var(--sur2);color:var(--mut);}

/* Replication panels */
.repl-grid{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-bottom:12px;}
.rpanel{background:var(--sur);border:1px solid var(--bdr);border-radius:10px;overflow:hidden;}
.rph{display:flex;align-items:center;gap:8px;padding:12px 14px;border-bottom:1px solid var(--bdr);}
.rp-icon{font-size:16px;}
.rp-title{font-size:13px;font-weight:600;color:var(--txt);flex:1;}
.rpb{font-size:10px;font-weight:600;padding:4px 10px;border-radius:5px;text-decoration:none;border:1px solid var(--bdr);white-space:nowrap;}
.rpb-pri{background:var(--pri);color:#fff;border-color:var(--pri);}
.rpb-sec{background:var(--sur2);color:var(--mut);}
.rp-body{padding:10px 12px;display:flex;flex-direction:column;gap:8px;}
.rcc{background:var(--sur2);border:1px solid var(--bdr);border-radius:7px;padding:10px 12px;}
.rch{display:flex;align-items:center;gap:7px;margin-bottom:7px;flex-wrap:wrap;}
.rcn{font-size:12px;font-weight:700;color:var(--txt);flex:1;font-family:var(--mono);}
.rsb{font-size:10px;font-weight:700;padding:2px 7px;border-radius:4px;}
.rsbg-s{background:rgba(63,185,80,.18);color:var(--grn);border:1px solid rgba(63,185,80,.35);}
.rsbg-c{background:rgba(210,153,34,.18);color:var(--yel);border:1px solid rgba(210,153,34,.35);}
.rsbg-a{background:rgba(219,109,40,.18);color:var(--org);border:1px solid rgba(219,109,40,.35);}
.rsbg-sy{background:rgba(47,129,247,.18);color:var(--pri);border:1px solid rgba(47,129,247,.35);}
.rsbg-d{background:var(--sur);color:var(--mut);border:1px solid var(--bdr);}
.rr{display:flex;justify-content:space-between;padding:3px 0;border-bottom:1px solid var(--bdr);font-size:11px;}
.rr:last-child{border:none;}
.rk{color:var(--mut);}.rv{font-family:var(--mono);font-size:10px;color:var(--txt);}
.slots-body{padding:10px 12px;}
.slots-tbl{width:100%;border-collapse:collapse;font-size:12px;}
.slots-tbl thead th{text-align:left;padding:7px 10px;border-bottom:1px solid var(--bdr);font-size:10px;font-weight:700;text-transform:uppercase;color:var(--mut);}
.slots-tbl tbody td{padding:8px 10px;border-bottom:1px solid var(--bdr);color:var(--txt);}
.slots-tbl tbody tr:last-child td{border-bottom:none;}
.snc{font-family:var(--mono);font-size:11px;font-weight:600;color:var(--txt);}
.sdc{color:var(--mut);font-size:11px;}
.sac{display:flex;align-items:center;gap:5px;}
.sdot{width:8px;height:8px;border-radius:50%;}
.sd-on{background:var(--grn);box-shadow:0 0 0 2px rgba(63,185,80,.25);}
.sd-off{background:var(--red);box-shadow:0 0 0 2px rgba(248,81,73,.25);}
.sd-na{background:var(--mut);}
.stxt{font-size:11px;font-weight:600;}
.st-on{color:var(--grn);}.st-off{color:var(--red);}.st-na{color:var(--mut);}

/* OS cards */
.os-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:8px;margin-bottom:12px;}
.os-card{background:var(--sur);border:1px solid var(--bdr);border-radius:8px;padding:12px 14px;display:flex;align-items:center;gap:10px;transition:border-color .15s;}
.os-card:hover{border-color:var(--pri);}
.os-icon{font-size:20px;flex-shrink:0;width:28px;text-align:center;}
.os-body{flex:1;min-width:0;}
.os-name{font-family:var(--mono);font-size:11px;font-weight:600;color:#79c0ff;margin-bottom:2px;}
.os-desc{font-size:10px;color:var(--mut);}
.os-btn{font-size:10px;font-weight:600;padding:4px 10px;border-radius:5px;text-decoration:none;background:var(--sur2);color:var(--pri);border:1px solid var(--bdr);white-space:nowrap;}

/* EFM panel */
.efm-panel{background:var(--sur);border:1px solid var(--bdr);border-radius:10px;overflow:hidden;margin-bottom:12px;}
.efm-svc-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));border-bottom:1px solid var(--bdr);}
.efm-svc{padding:14px 16px;border-right:1px solid var(--bdr);}
.efm-svc:last-child{border-right:none;}
.efm-stop{display:flex;align-items:center;gap:8px;margin-bottom:6px;}
.efm-dot{width:8px;height:8px;border-radius:50%;flex-shrink:0;}
.efm-dot-up{background:var(--grn);box-shadow:0 0 0 2px rgba(63,185,80,.2);}
.efm-dot-dn{background:var(--red);box-shadow:0 0 0 2px rgba(248,81,73,.2);}
.efm-dot-uk{background:var(--mut);}
.efm-sname{font-size:12px;font-weight:600;color:var(--txt);flex:1;text-transform:capitalize;}
.efm-badge{font-size:10px;padding:2px 8px;border-radius:10px;font-weight:600;}
.efm-badge-up{background:rgba(63,185,80,.15);color:var(--grn);border:1px solid rgba(63,185,80,.3);}
.efm-badge-dn{background:rgba(248,81,73,.15);color:var(--red);border:1px solid rgba(248,81,73,.3);}
.efm-badge-uk{background:rgba(139,148,158,.1);color:var(--mut);border:1px solid var(--bdr);}
.efm-sdet{font-size:10px;color:var(--mut);font-family:var(--mono);}
.efm-topo{padding:14px 16px;}
.efm-topo-hdr{display:flex;align-items:baseline;gap:8px;margin-bottom:10px;}
.efm-topo-title{font-size:11px;font-weight:700;color:var(--pri);text-transform:uppercase;letter-spacing:.6px;}
.efm-topo-hint{font-size:10px;color:var(--mut);font-family:var(--mono);}
.efm-node-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:8px;margin-bottom:10px;}
.efm-node{border-radius:7px;padding:12px;display:flex;align-items:center;gap:10px;border:1px solid;}
.efm-np{background:rgba(29,78,216,.1);border-color:rgba(29,78,216,.4);}
.efm-ns{background:rgba(15,110,86,.1);border-color:rgba(15,110,86,.4);}
.efm-nw{background:rgba(51,65,85,.25);border-color:rgba(100,116,139,.4);}
.efm-ni{font-size:16px;flex-shrink:0;width:22px;text-align:center;}
.efm-ninfo{flex:1;min-width:0;}
.efm-ntype{font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.5px;margin-bottom:2px;}
.efm-np .efm-ntype{color:#79c0ff;}.efm-ns .efm-ntype{color:#56d364;}.efm-nw .efm-ntype{color:#8b949e;}
.efm-naddr{font-family:var(--mono);font-size:12px;color:var(--txt);}
.efm-nmeta{text-align:right;flex-shrink:0;}
.efm-ndb{font-size:10px;font-weight:600;margin-bottom:2px;}
.efm-db-up{color:var(--grn);}.efm-db-na{color:var(--mut);}.efm-db-uk{color:var(--yel);}
.efm-nvip{font-size:10px;color:var(--mut);font-family:var(--mono);}
.efm-det{margin-top:4px;}
.efm-sum{font-size:11px;color:var(--mut);cursor:pointer;padding:5px 0;list-style:none;display:flex;align-items:center;gap:5px;user-select:none;}
.efm-sum::-webkit-details-marker{display:none;}
.efm-sum::before{content:'▶';font-size:9px;color:var(--pri);transition:transform .2s;}
details[open] .efm-sum::before{transform:rotate(90deg);}
.efm-pre{margin-top:8px;background:var(--sur2);border:1px solid var(--bdr);border-radius:6px;padding:12px;font-family:var(--mono);font-size:11px;color:#adbac7;line-height:1.8;overflow-x:auto;}

/* Overview comparison */
.ov-intro{font-size:13px;color:var(--mut);margin-bottom:14px;}
.ov-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:14px;}
.ov-card{background:var(--sur);border:1px solid var(--bdr);border-radius:10px;padding:18px;display:flex;flex-direction:column;gap:0;}
.ov-hdr{display:flex;align-items:center;gap:8px;margin-bottom:9px;}
.ov-role-icon{font-size:16px;flex-shrink:0;}
.ov-name{font-size:13px;font-weight:700;color:var(--txt);flex:1;font-family:var(--mono);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.ov-role{font-size:10px;padding:3px 9px;border-radius:10px;font-weight:700;white-space:nowrap;}
.ov-vip-crown{font-size:14px;flex-shrink:0;}
.ov-status-strip{display:flex;align-items:center;gap:6px;padding:5px 0 9px;font-size:11px;color:var(--mut);flex-wrap:wrap;}
.ov-status-dot{width:7px;height:7px;border-radius:50%;flex-shrink:0;display:inline-block;}
.ov-status-lbl{font-size:11px;color:var(--mut);}
.ov-status-sep{color:var(--bdr);font-size:11px;}
.ov-divider{height:1px;background:var(--bdr);margin:8px 0;}
.ov-section-lbl{font-size:10px;font-weight:700;color:var(--mut);letter-spacing:.6px;text-transform:uppercase;padding:5px 0 3px;}
.ov-row{display:flex;justify-content:space-between;align-items:baseline;padding:4px 0;font-size:12px;}
.ok{color:var(--mut);}
.ov{font-family:var(--mono);font-size:11.5px;color:var(--txt);text-align:right;}
.ov-mono{font-family:var(--mono);font-size:11px;}
.ov-small{font-size:10.5px;color:var(--mut);text-align:right;max-width:140px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.ov-of{font-size:10px;color:var(--mut);}

/* Footer */
.footer{text-align:center;padding:24px;color:var(--mut);font-size:11px;border-top:1px solid var(--bdr);margin-top:20px;}

@media(max-width:1100px){.chart-row,.stat-grid{grid-template-columns:repeat(2,1fr);}  .params-cfg-grid,.repl-grid{grid-template-columns:1fr;}}
@media(max-width:700px){.chart-row,.stat-grid,.ov-grid{grid-template-columns:1fr;}}

/* ── Disk Space panel ── */
.disk-panel{background:var(--sur);border:1px solid var(--bdr);border-radius:10px;overflow:hidden;margin-bottom:12px;}
.disk-det{padding:0;}
.disk-sum{padding:12px 16px;font-size:12px;font-weight:600;color:var(--pri);cursor:pointer;list-style:none;display:flex;align-items:center;gap:6px;user-select:none;}
.disk-sum::-webkit-details-marker{display:none;}
.disk-sum::before{content:'▶';font-size:9px;transition:transform .2s;display:inline-block;}
details[open] .disk-sum::before{transform:rotate(90deg);}
.disk-tbl{width:100%;border-collapse:collapse;font-size:12px;}
.disk-tbl thead th{background:var(--sur2);color:var(--mut);font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.4px;padding:8px 14px;text-align:left;border-bottom:1px solid var(--bdr);}
.disk-tbl tbody tr:hover{background:var(--sur2);}
.disk-tbl tbody td{padding:8px 14px;border-bottom:1px solid var(--bdr);vertical-align:middle;}
.disk-tbl tbody tr:last-child td{border-bottom:none;}
.disk-fs{font-family:var(--mono);font-size:11px;color:var(--txt);}
.disk-num{font-family:var(--mono);font-size:11px;color:var(--mut);text-align:right;}
.disk-mnt{font-family:var(--mono);font-size:11px;color:var(--txt);}
.disk-pct{min-width:120px;}
.disk-bar-wrap{background:var(--sur2);border-radius:3px;height:6px;overflow:hidden;margin-bottom:3px;}
.disk-bar{height:100%;border-radius:3px;}
.disk-bar.disk-ok{background:var(--grn);}
.disk-bar.disk-warn{background:var(--yel);}
.disk-bar.disk-crit{background:var(--red);}
.disk-pct-lbl{font-size:10px;font-family:var(--mono);font-weight:600;}
.disk-pct-lbl.disk-ok{color:var(--grn);}
.disk-pct-lbl.disk-warn{color:var(--yel);}
.disk-pct-lbl.disk-crit{color:var(--red);}

/* ── pg_stat_bgwriter panel ── */
.bgw-panel{background:var(--sur);border:1px solid var(--bdr);border-radius:10px;overflow:hidden;margin-bottom:12px;padding:14px;}
.bgw-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-bottom:10px;}
.bgw-stat{display:flex;flex-direction:column;gap:3px;}
.bgw-val{font-family:var(--mono);font-size:16px;font-weight:700;color:var(--txt);}
.bgw-lbl{font-size:10px;color:var(--mut);text-transform:uppercase;letter-spacing:.4px;}
.bgw-verdict{font-size:11px;padding:8px 12px;border-radius:6px;font-weight:600;}
.bgw-ok{background:rgba(63,185,80,.1);color:var(--grn);border:1px solid rgba(63,185,80,.25);}
.bgw-warn{background:rgba(210,153,34,.1);color:var(--yel);border:1px solid rgba(210,153,34,.25);}
.bgw-bad{background:rgba(248,81,73,.1);color:var(--red);border:1px solid rgba(248,81,73,.25);}
.bgw-unavail{display:flex;align-items:flex-start;gap:12px;padding:4px 0;}
.bgw-unavail-icon{font-size:24px;flex-shrink:0;opacity:.5;}

/* ── Parameter tooltip badge ── */
.pg-tip{cursor:help;position:relative;}
.pg-tip:hover::after{content:attr(title);position:absolute;left:0;top:calc(100% + 4px);background:#1c2128;color:#e6edf3;border:1px solid #30363d;border-radius:6px;padding:8px 12px;font-size:11px;font-weight:400;white-space:normal;min-width:260px;max-width:400px;z-index:999;line-height:1.5;box-shadow:0 8px 24px rgba(0,0,0,.4);}
body.lt .pg-tip:hover::after{background:#fff;color:#1f2328;border-color:#d0d7de;box-shadow:0 8px 24px rgba(0,0,0,.15);}
.lasso-report-panel{background:var(--sur);border:1px solid var(--bdr);border-radius:10px;overflow:hidden;margin-bottom:12px;}
.lr-actions{padding:16px 20px;display:flex;align-items:center;gap:16px;}
.lr-open-btn{display:inline-flex;align-items:center;gap:8px;background:var(--pri);color:#fff;border:1px solid var(--pri);padding:10px 22px;border-radius:8px;text-decoration:none;font-size:13px;font-weight:600;white-space:nowrap;transition:opacity .15s;}
.lr-open-btn:hover{opacity:.88;}
.lr-hint{font-size:12px;color:var(--mut);line-height:1.5;}
body.lt .lasso-report-panel{background:#fff;border-color:#d0d7de;}
body.lt .lr-hint{color:#57606a;}

/* ── Transaction ID Wraparound ── */
.xid-panel{background:var(--sur);border:1px solid var(--bdr);border-radius:10px;padding:14px 16px;margin-bottom:12px;}
.xid-cards{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-bottom:12px;}
.xid-card{background:var(--sur2);border-radius:8px;padding:10px 14px;}
.xid-cv{font-family:var(--mono);font-size:20px;font-weight:700;color:var(--txt);}
.xid-cl{font-size:10px;color:var(--mut);text-transform:uppercase;letter-spacing:.4px;margin-top:3px;}
.xid-cs{font-size:10px;color:var(--mut);margin-top:1px;}
.xid-bar-wrap{height:10px;background:var(--sur2);border-radius:5px;overflow:hidden;position:relative;}
.xid-bar{height:100%;border-radius:5px;transition:width .3s;}
.xid-tbl{width:100%;border-collapse:collapse;font-size:12px;margin-top:4px;}
.xid-tbl thead th{background:var(--sur2);color:var(--mut);font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.4px;padding:6px 12px;text-align:left;border-bottom:1px solid var(--bdr);}
.xid-tbl tbody td{padding:7px 12px;border-bottom:0.5px solid var(--bdr);vertical-align:middle;}
.xid-tbl tbody tr:last-child td{border-bottom:none;}
.xid-tbl tbody tr:hover{background:var(--sur2);}
.xid-row-bad{background:rgba(248,81,73,.06);}
.xid-row-warn{background:rgba(210,153,34,.06);}
.xid-badge{display:inline-block;font-size:10px;font-weight:600;padding:2px 7px;border-radius:10px;}
.xid-b-ok{background:rgba(63,185,80,.15);color:var(--grn);}
.xid-b-warn{background:rgba(210,153,34,.15);color:var(--yel);}
.xid-b-bad{background:rgba(248,81,73,.15);color:var(--red);}
.xid-verdict{font-size:11px;font-weight:600;padding:8px 12px;border-radius:6px;margin-top:10px;}
.xid-ok{background:rgba(63,185,80,.1);color:var(--grn);border:1px solid rgba(63,185,80,.25);}
.xid-warn{background:rgba(210,153,34,.1);color:var(--yel);border:1px solid rgba(210,153,34,.25);}
.xid-bad{background:rgba(248,81,73,.1);color:var(--red);border:1px solid rgba(248,81,73,.25);}

/* ── Table Bloat ── */
.bloat-panel{background:var(--sur);border:1px solid var(--bdr);border-radius:10px;overflow:hidden;margin-bottom:12px;padding:14px 16px;}
.bloat-tbl{width:100%;border-collapse:collapse;font-size:12px;}
.bloat-tbl thead th{background:var(--sur2);color:var(--mut);font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.4px;padding:7px 12px;text-align:left;border-bottom:1px solid var(--bdr);}
.bloat-tbl tbody td{padding:7px 12px;border-bottom:0.5px solid var(--bdr);vertical-align:middle;}
.bloat-tbl tbody tr:last-child td{border-bottom:none;}
.bloat-tbl tbody tr:hover{background:var(--sur2);}
.bloat-bad{color:var(--red);}
.bloat-warn{color:var(--yel);}

/* ── EFM Properties (nested inside EFM panel) ── */
.efmp-inner{margin-top:14px;border-top:1px solid var(--bdr);padding-top:14px;}
.efmp-inner-hdr{font-size:11px;font-weight:600;color:var(--txt);margin-bottom:10px;}
.efmp-panel{background:var(--sur);border:1px solid var(--bdr);border-radius:10px;padding:14px 16px;margin-bottom:12px;}
.efmp-grid{display:grid;grid-template-columns:1fr 1fr;gap:20px;}
.efmp-section{font-size:10px;font-weight:700;color:var(--mut);text-transform:uppercase;letter-spacing:.5px;padding:6px 0 4px;border-bottom:1px solid var(--bdr);margin-bottom:4px;}
.efmp-row{display:flex;justify-content:space-between;align-items:center;padding:5px 0;border-bottom:0.5px solid var(--bdr);font-size:12px;}
.efmp-row:last-child{border-bottom:none;}
.efmp-key{color:var(--mut);font-size:11px;}
.efmp-verdict{font-size:11px;font-weight:600;padding:8px 12px;border-radius:6px;margin-top:12px;}
.efmp-ok{background:rgba(63,185,80,.1);color:var(--grn);border:1px solid rgba(63,185,80,.25);}
.efmp-warn{background:rgba(210,153,34,.1);color:var(--yel);border:1px solid rgba(210,153,34,.25);}
.efmp-info{background:rgba(139,148,158,.1);color:var(--mut);border:1px solid var(--bdr);}

/* ── Blocking & Lock Analysis ── */
.lock-panel{background:var(--sur);border:1px solid var(--bdr);border-radius:10px;padding:14px 16px;margin-bottom:12px;}
.lock-stat-row{display:grid;grid-template-columns:repeat(auto-fill,minmax(120px,1fr));gap:8px;margin-bottom:12px;}
.lock-stat{background:var(--sur2);border-radius:8px;padding:10px 12px;text-align:center;}
.lock-sv{font-family:var(--mono);font-size:20px;font-weight:700;color:var(--txt);}
.lock-sv-red{color:var(--red);}
.lock-sv-amber{color:var(--yel);}
.lock-sl{font-size:10px;color:var(--mut);text-transform:uppercase;letter-spacing:.4px;margin-top:3px;}
.lock-det{margin-bottom:6px;}
.lock-sum{font-size:11px;color:var(--pri);cursor:pointer;padding:7px 10px;list-style:none;display:flex;align-items:center;gap:5px;user-select:none;background:var(--sur2);border-radius:6px;border:0.5px solid var(--bdr);}
.lock-sum::-webkit-details-marker{display:none;}
.lock-sum::before{content:'▶';font-size:9px;color:var(--pri);transition:transform .2s;flex-shrink:0;}
details[open] .lock-sum::before{transform:rotate(90deg);}
.lock-det-body{padding:10px 4px 4px;}
.lock-tbl{width:100%;border-collapse:collapse;font-size:11px;margin-bottom:6px;}
.lock-tbl thead th{background:var(--sur2);color:var(--mut);font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.4px;padding:6px 10px;text-align:left;border-bottom:0.5px solid var(--bdr);}
.lock-tbl tbody td{padding:6px 10px;border-bottom:0.5px solid var(--bdr);vertical-align:middle;}
.lock-tbl tbody tr:last-child td{border-bottom:none;}
.lock-tbl tbody tr:hover{background:var(--sur2);}
.lock-q{font-family:var(--mono);font-size:10px;color:var(--mut);max-width:260px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.repl-lag-row{display:grid;grid-template-columns:repeat(4,1fr);gap:6px;margin:8px 0 10px;}
.repl-lag-card{background:var(--sur2);border-radius:7px;padding:8px 10px;text-align:center;}
.repl-lag-v{font-family:var(--mono);font-size:13px;font-weight:700;color:var(--txt);}
.repl-lag-l{font-size:9px;color:var(--mut);text-transform:uppercase;letter-spacing:.4px;margin-top:3px;}
.lock-xref{background:var(--sur2);border:1px solid var(--bdr);border-left:3px solid var(--yel);border-radius:8px;padding:10px 14px;margin-top:6px;}
/* ── Long-running queries panel ── */
.lrq-panel{background:var(--sur);border:1px solid var(--bdr);border-radius:10px;padding:14px 16px;margin-bottom:12px;overflow-x:auto;}
.lock-xref-title{font-size:11px;font-weight:600;color:var(--txt);margin-bottom:5px;}
.lock-xref-body{font-size:11px;color:var(--mut);line-height:1.6;}
.lock-xref-pid{font-family:var(--mono);color:var(--red);font-weight:700;}
.lock-xref-q{font-family:var(--mono);color:var(--txt);font-size:10px;}
.lock-xref-ev{font-family:var(--mono);color:var(--yel);font-weight:600;}
.memp-panel{background:var(--sur);border:1px solid var(--bdr);border-radius:10px;padding:14px 16px;margin-bottom:12px;}
.memp-grid{display:grid;grid-template-columns:1fr 1fr;gap:20px;}
.memp-section{font-size:10px;font-weight:700;color:var(--mut);text-transform:uppercase;letter-spacing:.5px;padding:6px 0 4px;border-bottom:1px solid var(--bdr);margin-bottom:4px;}
.memp-row{display:flex;justify-content:space-between;align-items:center;padding:4px 0;font-size:12px;}
.memp-k{color:var(--mut);font-size:11px;}
.memp-v{font-family:var(--mono);font-size:11px;color:var(--txt);}
.memp-note{font-size:11px;font-weight:500;padding:6px 10px;border-radius:5px;margin-top:8px;}
.memp-note-ok{background:rgba(63,185,80,.1);color:var(--grn);}
.memp-note-warn{background:rgba(210,153,34,.1);color:var(--yel);}
.memp-note-bad{background:rgba(248,81,73,.1);color:var(--red);}
.memp-note-info{background:rgba(139,148,158,.1);color:var(--mut);}
.swap-bar-wrap{height:6px;background:var(--sur2);border-radius:3px;overflow:hidden;margin:6px 0;}
.swap-bar{height:100%;border-radius:3px;}
.oom-entry{font-family:var(--mono);font-size:10px;color:var(--red);padding:5px 8px;background:rgba(248,81,73,.06);border-radius:4px;margin-top:4px;word-break:break-all;line-height:1.5;}
</style>
</head>
<body>

<div class="topbar">
  <span class="topbar-logo">EFM/<span>PG</span> Lasso</span>
  <span style="font-size:10px;color:var(--mut);font-family:var(--mono);">v${VERSION}</span>
  <span class="tb-sep"></span>
  <span class="tb-badge">$(wc -l < "$NODES_META" | tr -d ' ') Nodes</span>
  <span class="tb-ts">Generated: $(date '+%Y-%m-%d %H:%M')</span>
  $(
    _raw_ts=$(find "$ASSETS_DIR/extracted" -name "edb-lasso-report.log" | head -n1 | xargs -I{} head -n1 {} 2>/dev/null | awk '{print $1}' | sed 's/T/ /' | cut -c1-16 || echo "")
    if [ -n "$_raw_ts" ]; then
      _col_epoch=$(date -d "$_raw_ts" +%s 2>/dev/null || echo "")
      _now_epoch=$(date +%s)
      _days_ago=""
      [ -n "$_col_epoch" ] && _days_ago=$(( (_now_epoch - _col_epoch) / 86400 ))
      if [ -n "$_days_ago" ] && [ "$_days_ago" -gt 7 ] 2>/dev/null; then
        echo "<span class=\"tb-ts\" style=\"color:var(--red);font-weight:600;\" title=\"Data is ${_days_ago} days old — results may not reflect current state\">⚠ Collected: $_raw_ts (${_days_ago}d ago)</span>"
      elif [ -n "$_days_ago" ] && [ "$_days_ago" -gt 1 ] 2>/dev/null; then
        echo "<span class=\"tb-ts\" style=\"color:var(--yel);\" title=\"Data is ${_days_ago} days old\">Collected: $_raw_ts (${_days_ago}d ago)</span>"
      else
        echo "<span class=\"tb-ts\" style=\"color:var(--grn);\">Collected: $_raw_ts</span>"
      fi
    fi
  )
  <button class="theme-btn" onclick="toggleTheme()" id="themeBtn">
    <span id="themeIcon">☀️</span><span id="themeLabel">Light</span>
  </button>
<!--  <div class="font-ruler" title="Adjust font size">
    <span style="font-size:10px;color:var(--mut);">A</span>
    <input type="range" id="fontSlider" min="11" max="18" value="13" step="1"
           oninput="setFontSize(this.value)"
           style="width:60px;height:4px;cursor:pointer;accent-color:var(--pri);">
    <span style="font-size:13px;color:var(--mut);">A</span>
  </div> -->
</div>

<div class="hero">
  <div class="hero-h">PGRadar — PostgreSQL Cluster Health Dashboard</div>
  $(
    _n_primary=$(grep -c "|Primary|" "$NODES_META" 2>/dev/null | tr -d '\n\r')
    _n_primary=${_n_primary:-0}
    _n_standby=$(grep -c "|Standby|" "$NODES_META" 2>/dev/null | tr -d '\n\r')
    _n_standby=${_n_standby:-0}
    _n_witness=$(grep -c "|Witness|" "$NODES_META" 2>/dev/null | tr -d '\n\r')
    _n_witness=${_n_witness:-0}
    _n_total=$(wc -l < "$NODES_META" | tr -d ' ')
    _summary="${_n_total} node(s)"
    [ "$_n_primary" -gt 0 ] && _summary="${_summary} — ${_n_primary} Primary"
    [ "$_n_standby" -gt 0 ] && _summary="${_summary}, ${_n_standby} Standby"
    [ "$_n_witness" -gt 0 ] && _summary="${_summary}, ${_n_witness} Witness"
    echo "<div class=\"hero-sub\">📦 $(basename "$BUNDLE_DIR") &nbsp;·&nbsp; ${_summary}</div>"
  )
  <div class="badge-row">
HTML

# Emit one badge per node in the hero strip
while IFS='|' read -r _nid _role _host _lp; do
    _bc="b-ip"
    case "$_role" in Primary) _bc="b-pg";; Standby) _bc="b-ip";; Witness) _bc="b-os";; esac
    echo "    <span class='badge $_bc'>$_host &mdash; $_role</span>"
done < "$NODES_META"

cat <<TABS
  </div>
</div>

<div class="tab-bar">
  <div class="tab tab-ov active" id="tab-overview" onclick="showTab('overview')">
    <span style="font-size:12px;">⊞</span> Cluster Overview
  </div>
TABS

# Emit one tab per node — each gets a role-specific class (tab-p / tab-s / tab-w)
# so the CSS can apply a colored top border when that tab is active
while IFS='|' read -r _nid _role _host _lp; do
    case "$_role" in
        Primary) _dc="#2f81f7"; _trc="tr-p"; _tabc="tab-p" ;;
        Standby) _dc="#3fb950"; _trc="tr-s"; _tabc="tab-s" ;;
        Witness) _dc="#64748b"; _trc="tr-w"; _tabc="tab-w" ;;
        *)       _dc="#8b949e"; _trc="tr-u"; _tabc="tab-u" ;;
    esac
    echo "  <div class='tab ${_tabc}' id='tab-${_nid}' onclick=\"showTab('${_nid}')\">"
    echo "    <div class='tab-dot' style='background:${_dc};'></div>"
    echo "    $_host"
    echo "    <span class='tab-role ${_trc}'>$_role</span>"
    echo "  </div>"
done < "$NODES_META"

echo "</div>"

# Overview pane
echo "<div class='pane active' id='pane-overview'>"
emit_overview_panel
echo "</div>"

# Per-node panes
while IFS='|' read -r _nid _role _host _lp; do
    echo "<div class='pane' id='pane-${_nid}'>"
    emit_node_panel "$_nid" "$_role" "$_host" "$_lp" "$ASSETS_DIR/$_nid"
    echo "</div>"
done < "$NODES_META"

cat <<FOOT

<div class="footer">
  PGRadar Cluster Dashboard &nbsp;·&nbsp; v${VERSION} &nbsp;·&nbsp; Generated $(date) &nbsp;·&nbsp; $(wc -l < "$NODES_META" | tr -d ' ') nodes </br> Created By Rishabh
</div>

<script>
function showTab(id) {
  document.querySelectorAll('.pane').forEach(function(p){ p.classList.remove('active'); });
  document.querySelectorAll('.tab').forEach(function(t){ t.classList.remove('active'); });
  var pane = document.getElementById('pane-'+id);
  var tab  = document.getElementById('tab-'+id);
  if (pane) pane.classList.add('active');
  if (tab)  tab.classList.add('active');
  // Update the URL hash without scrolling so back-links stay consistent
  history.replaceState(null, '', '#pane-'+id);
}
function toggleTheme() {
  var isL = document.body.classList.toggle('lt');
  document.getElementById('themeIcon').textContent  = isL ? '🌙' : '☀️';
  document.getElementById('themeLabel').textContent = isL ? 'Dark' : 'Light';
  try { localStorage.setItem('efm-theme', isL?'light':'dark'); } catch(e){}
}
function setFontSize(sz) {
  document.body.style.fontSize = sz + 'px';
  try { localStorage.setItem('efm-fontsize', sz); } catch(e){}
}
// On page load: activate the tab matching the URL hash (set by sub-page back links)
(function(){
  try{ var fs=localStorage.getItem('efm-fontsize'); if(fs){ document.body.style.fontSize=fs+'px'; var sl=document.getElementById('fontSlider'); if(sl)sl.value=fs; } }catch(e){}
  try{ if(localStorage.getItem('efm-theme')==='light') toggleTheme(); }catch(e){}
  var hash = window.location.hash; // e.g. "#pane-node0_10-238-9-40"
  if (hash && hash.indexOf('#pane-') === 0) {
    var tid = hash.replace('#pane-', '');
    if (document.getElementById('pane-' + tid)) {
      showTab(tid);
      return;
    }
  }
  // Default: show overview tab
  showTab('overview');
})();
</script>
</body></html>
FOOT

} > "$OUTFILE"

pb_done

printf "\n"
printf "  \033[1;32m✔\033[0m  Output    : \033[1m%s/\033[0m\n" "$DASHBOARD_ROOT"
printf "  \033[1;32m✔\033[0m  Dashboard : \033[1m%s\033[0m\n" "$OUTFILE"
printf "  \033[1;32m✔\033[0m  Assets    : \033[1m%s/\033[0m\n" "$ASSETS_DIR"
printf "  \033[1;32m✔\033[0m  Nodes     : \033[1;32m%s\033[0m node(s) processed\n" "$(wc -l < "$NODES_META" | tr -d ' ')"
printf "  \033[1;32m✔\033[0m  Open      : \033[0;36mfile://%s\033[0m\n\n" "$OUTFILE"

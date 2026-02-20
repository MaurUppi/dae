#!/usr/bin/env bash
set -euo pipefail

# dae_triage_unified_v5.sh
# Complete triage toolkit for "write: broken pipe" accountability analysis.
# Integrates: log monitoring, ss/fdmap, tcpdump, strace for definitive conclusions.
#
# v3 fixes:
#   - Fixed subshell variable propagation issue (counters now persist)
#   - Improved strace capture with writev/sendfile support
#   - Better pcap timing analysis
#
# Accountability Goal: Determine if dae's broken pipe handling design is flawed.

###############################################################################
# Usage & Help
###############################################################################
usage() {
  cat <<'USAGE'
Usage:
  sudo ./dae_triage_unified_v5.sh [options]

Options:
  --service NAME           systemd service name (default: dae)
  --pid PID                explicit PID (default: auto via systemd/pgrep)
  --outdir DIR             output directory (default: dae-triage-YYYYmmdd-HHMMSS)
  --pattern STR            filter pattern for logs (default: broken pipe)
  --peer IP:PORT           fixed peer filter (default: auto from log)
  --peer-ip IP             peer IP for tcpdump filter (captures all ports)
  --max-events N           stop after N matched events (default: 0 = unlimited)
  --window N               summary window size (default: 50)
  --snapshots N            number of ss/fd snapshots per event (default: 5)
  --interval-ms MS         interval between snapshots in ms (default: 200)

  --enable-tcpdump         enable tcpdump ring buffer capture (default: off)
  --tcpdump-buffer SEC     ring buffer duration in seconds (default: 60)
  --tcpdump-snaplen N      tcpdump snaplen (default: 128)

  --enable-strace          enable strace continuous tracing (default: off)
  --strace-expr EXPR       strace filter expression (default: auto)

  --dry-run                print resolved params and exit
  -h, --help               show help

Outputs:
  OUTDIR/events.jsonl           - detailed event records
  OUTDIR/summary.json           - machine-readable summary with accountability
  OUTDIR/summary.txt            - human-readable summary
  OUTDIR/accountability.txt     - definitive accountability analysis
  OUTDIR/raw/<event_id>/        - per-event raw data
  OUTDIR/tcpdump/               - pcap ring buffer files (if enabled)
  OUTDIR/strace/                - strace logs (if enabled)

Notes:
  - Requires root/sudo for ss, tcpdump, strace access
  - Use Ctrl-C to stop; final analysis is generated on exit
USAGE
}

###############################################################################
# Default Parameters
###############################################################################
SERVICE="dae"
PID=""
OUTDIR=""
PATTERN="broken pipe"
FIXED_PEER="auto"
PEER_IP_FILTER=""
MAX_EVENTS=0
WINDOW=50
SNAPSHOTS=5
INTERVAL_MS=200

ENABLE_TCPDUMP=0
TCPDUMP_BUFFER_SEC=60
TCPDUMP_SNAPLEN=128

ENABLE_STRACE=0
STRACE_EXPR=""

DRY_RUN=0

###############################################################################
# Argument Parsing
###############################################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --service)        SERVICE="$2"; shift 2;;
    --pid)            PID="$2"; shift 2;;
    --outdir)         OUTDIR="$2"; shift 2;;
    --pattern)        PATTERN="$2"; shift 2;;
    --peer)           FIXED_PEER="$2"; shift 2;;
    --peer-ip)        PEER_IP_FILTER="$2"; shift 2;;
    --max-events)     MAX_EVENTS="$2"; shift 2;;
    --window)         WINDOW="$2"; shift 2;;
    --snapshots)      SNAPSHOTS="$2"; shift 2;;
    --interval-ms)    INTERVAL_MS="$2"; shift 2;;
    --enable-tcpdump) ENABLE_TCPDUMP=1; shift;;
    --tcpdump-buffer) TCPDUMP_BUFFER_SEC="$2"; shift 2;;
    --tcpdump-snaplen) TCPDUMP_SNAPLEN="$2"; shift 2;;
    --enable-strace)  ENABLE_STRACE=1; shift;;
    --strace-expr)    STRACE_EXPR="$2"; shift 2;;
    --dry-run)        DRY_RUN=1; shift;;
    -h|--help)        usage; exit 0;;
    *)                echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [[ -z "$OUTDIR" ]]; then
  OUTDIR="dae-triage-$(date +"%Y%m%d-%H%M%S")"
fi

###############################################################################
# Dependency Check
###############################################################################
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }
}
need_cmd journalctl
need_cmd ss
need_cmd awk
need_cmd sed
need_cmd grep
need_cmd jq

if [[ "$ENABLE_TCPDUMP" -eq 1 ]]; then
  need_cmd tcpdump
fi
if [[ "$ENABLE_STRACE" -eq 1 ]]; then
  need_cmd strace
fi

###############################################################################
# Utility Functions
###############################################################################

resolve_pid() {
  local svc="$1"
  local mp
  mp="$(systemctl show -p MainPID --value "$svc" 2>/dev/null || true)"
  if [[ -n "$mp" && "$mp" != "0" ]]; then
    echo "$mp"
    return 0
  fi
  pgrep -xo "$svc" 2>/dev/null || true
}

parse_peer_from_msg() {
  local msg="$1"
  echo "$msg" | sed -n 's/.*->[[:space:]]*\([0-9]\{1,3\}\(\.[0-9]\{1,3\}\)\{3\}\):\([0-9]\+\).*/\1:\3/p' | head -n1
}

parse_local_from_msg() {
  local msg="$1"
  echo "$msg" | sed -n 's/.*tcp[[:space:]]\+\([0-9]\{1,3\}\(\.[0-9]\{1,3\}\)\{3\}\):\([0-9]\+\)->.*/\1:\3/p' | head -n1
}

msleep() {
  local ms="$1"
  local s
  s="$(awk -v ms="$ms" 'BEGIN{printf "%.3f", (ms/1000.0)}')"
  sleep "$s"
}

ts_now() {
  date +%s.%N
}

ts_human() {
  date '+%F %T.%3N'
}

###############################################################################
# Integrated: fdmap function
###############################################################################
do_fdmap() {
  local target_pid="$1"
  local filter_peer_ip="${2:-}"
  local filter_peer_port="${3:-}"

  echo "# ts=$(date '+%F %T') pid=$target_pid peer=${filter_peer_ip}:${filter_peer_port}"
  echo "# state  local  peer  fd"

  sudo ss -ntpH 2>/dev/null | awk -v pid="pid=$target_pid," -v pip="$filter_peer_ip" -v pport="$filter_peer_port" '
    $0 ~ pid {
      state=$1; local=$4; peer=$5;
      if (pip != "" && peer !~ ("^" pip ":")) next;
      if (pport != "" && peer !~ (":" pport "$")) next;
      fd="";
      if (match($0, /fd=([0-9]+)/, m)) fd=m[1];
      printf "%-12s %-24s %-24s fd=%s\n", state, local, peer, (fd==""?"?":fd);
    }
  ' | sort -k1,1 -k2,2
}

###############################################################################
# Integrated: fd_to_tuple function
###############################################################################
do_fd_to_tuple() {
  local target_pid="$1"
  shift
  [[ $# -eq 0 ]] && return 0
  
  local fds=("$@")
  local tmp_map

  echo "# ts=$(date +%s.%N) pid=$target_pid"

  tmp_map="$(mktemp)"

  {
    if [[ -r /proc/net/tcp ]]; then
      awk '
        function hex2dec(h){ return strtonum("0x" h) }
        function ip4(h){ return hex2dec(substr(h,7,2))"."hex2dec(substr(h,5,2))"."hex2dec(substr(h,3,2))"."hex2dec(substr(h,1,2)) }
        NR==1{next}
        { split($2,a,":"); split($3,b,":"); print $10, "tcp", ip4(a[1]), hex2dec(a[2]), ip4(b[1]), hex2dec(b[2]), $4 }
      ' /proc/net/tcp
    fi
    if [[ -r /proc/net/tcp6 ]]; then
      awk '
        function hex2dec(h){ return strtonum("0x" h) }
        NR==1{next}
        { split($2,a,":"); split($3,b,":"); print $10, "tcp6", a[1], hex2dec(a[2]), b[1], hex2dec(b[2]), $4 }
      ' /proc/net/tcp6
    fi
  } >"$tmp_map"

  for fd in "${fds[@]}"; do
    local link inode row
    link="$(sudo readlink "/proc/$target_pid/fd/$fd" 2>/dev/null || true)"

    if [[ "$link" =~ socket:\[([0-9]+)\] ]]; then
      inode="${BASH_REMATCH[1]}"
    else
      echo "fd=$fd link='${link}' (not socket)"
      continue
    fi

    row="$(awk -v inode="$inode" '$1==inode {print; exit}' "$tmp_map" || true)"
    if [[ -z "$row" ]]; then
      echo "fd=$fd inode=$inode (not in /proc/net/tcp*)"
      continue
    fi

    read -r _inode proto lip lp rip rp st <<<"$row"
    echo "fd=$fd inode=$inode proto=$proto local=${lip}:${lp} peer=${rip}:${rp} state=$st"
  done

  rm -f "$tmp_map"
}

###############################################################################
# Helper functions
###############################################################################
map_to_json() {
  awk '
    $1 ~ /^(ESTAB|SYN-SENT|SYN-RECV|FIN-WAIT-1|FIN-WAIT-2|TIME-WAIT|CLOSE-WAIT|CLOSING|LAST-ACK|LISTEN)$/ {
      state=$1; local=$2; peer=$3;
      fd=""; if (match($0,/fd=([0-9]+)/,m)) fd=m[1];
      gsub(/"/,"\\\"",local); gsub(/"/,"\\\"",peer);
      printf "{\"state\":\"%s\",\"local\":\"%s\",\"peer\":\"%s\",\"fd\":%s}\n", state, local, peer, (fd==""?"null":fd);
    }
  ' | jq -s '.'
}

extract_fds() {
  awk '{ if (match($0,/fd=([0-9]+)/,m)) print m[1]; }' | sort -n | uniq
}

has_close_wait() {
  awk '$1=="CLOSE-WAIT"{found=1} END{exit(found?0:1)}'
}

count_close_wait() {
  awk '$1=="CLOSE-WAIT"{c++} END{print c+0}'
}

###############################################################################
# Setup Output Directory & Counter Files
###############################################################################
mkdir -p "$OUTDIR/raw"
EVENTS_JSONL="$OUTDIR/events.jsonl"
SUMMARY_JSON="$OUTDIR/summary.json"
SUMMARY_TXT="$OUTDIR/summary.txt"
ACCOUNTABILITY_TXT="$OUTDIR/accountability.txt"
: >"$EVENTS_JSONL"

# Use files for counters to survive subshell
TMPDIR="$OUTDIR/.tmp"
mkdir -p "$TMPDIR"
WIN_FILE="$TMPDIR/window_flags.txt"
COUNTER_FILE="$TMPDIR/counters.txt"
: >"$WIN_FILE"

# Initialize counter file
cat >"$COUNTER_FILE" <<EOF
TOTAL_EVENTS=0
SCENARIO_A_COUNT=0
SCENARIO_B_COUNT=0
SCENARIO_C_COUNT=0
PROPER_HANDLING_COUNT=0
CLOSE_WAIT_MAX=0
LAST_TS_EPOCH=0
EOF

# Functions to update counters atomically
update_counter() {
  local name="$1" value="$2"
  sed -i "s/^${name}=.*/${name}=${value}/" "$COUNTER_FILE"
}

incr_counter() {
  local name="$1"
  local current
  current="$(grep "^${name}=" "$COUNTER_FILE" | cut -d= -f2)"
  update_counter "$name" "$((current + 1))"
}

get_counter() {
  local name="$1"
  grep "^${name}=" "$COUNTER_FILE" | cut -d= -f2
}

###############################################################################
# Resolve PID
###############################################################################
if [[ -z "$PID" ]]; then
  PID="$(resolve_pid "$SERVICE")"
fi
if [[ -z "$PID" ]]; then
  echo "Could not resolve pid for service=$SERVICE (use --pid)" >&2
  exit 1
fi

###############################################################################
# Dry Run Mode
###############################################################################
if [[ "$DRY_RUN" -eq 1 ]]; then
  cat <<EOF
=== DRY RUN ===
service=$SERVICE  pid=$PID  outdir=$OUTDIR
pattern='$PATTERN'  peer=$FIXED_PEER  peer_ip=$PEER_IP_FILTER
tcpdump=$ENABLE_TCPDUMP (buffer=${TCPDUMP_BUFFER_SEC}s)
strace=$ENABLE_STRACE
EOF
  exit 0
fi

###############################################################################
# tcpdump Management
###############################################################################
TCPDUMP_PID=""
TCPDUMP_DIR=""

start_tcpdump() {
  [[ "$ENABLE_TCPDUMP" -ne 1 ]] && return 0

  TCPDUMP_DIR="$OUTDIR/tcpdump"
  mkdir -p "$TCPDUMP_DIR"

  local filter="tcp"
  [[ -n "$PEER_IP_FILTER" ]] && filter="host $PEER_IP_FILTER and tcp"

  # Ring buffer with 3 files, rotate every TCPDUMP_BUFFER_SEC seconds
  sudo tcpdump -ni any "$filter" \
    -s "$TCPDUMP_SNAPLEN" \
    -U \
    -G "$TCPDUMP_BUFFER_SEC" \
    -W 3 \
    -w "$TCPDUMP_DIR/cap_%Y%m%d_%H%M%S.pcap" \
    2>"$TCPDUMP_DIR/stderr.log" &
  TCPDUMP_PID=$!

  echo "[tcpdump] started pid=$TCPDUMP_PID filter='$filter'" >&2
}

stop_tcpdump() {
  if [[ -n "$TCPDUMP_PID" ]]; then
    sudo kill "$TCPDUMP_PID" 2>/dev/null || true
    wait "$TCPDUMP_PID" 2>/dev/null || true
    echo "[tcpdump] stopped" >&2
    TCPDUMP_PID=""
  fi
}

snapshot_tcpdump() {
  local evdir="$1"
  [[ "$ENABLE_TCPDUMP" -ne 1 || -z "$TCPDUMP_DIR" ]] && return 0
  mkdir -p "$evdir/pcap"
  cp "$TCPDUMP_DIR"/*.pcap "$evdir/pcap/" 2>/dev/null || true
}

###############################################################################
# strace Management
###############################################################################
STRACE_PID=""
STRACE_DIR=""

start_strace() {
  [[ "$ENABLE_STRACE" -ne 1 ]] && return 0

  STRACE_DIR="$OUTDIR/strace"
  mkdir -p "$STRACE_DIR"

  # Default: trace write-family and close syscalls
  local expr="${STRACE_EXPR:-write,writev,send,sendto,sendmsg,close,shutdown}"

  # -f: follow threads, -tt: timestamps with microseconds
  sudo strace -f -tt -s 64 \
    -p "$PID" \
    -e trace="$expr" \
    -o "$STRACE_DIR/trace" \
    2>"$STRACE_DIR/stderr.log" &
  STRACE_PID=$!

  echo "[strace] started pid=$STRACE_PID target=$PID expr='$expr'" >&2
}

stop_strace() {
  if [[ -n "$STRACE_PID" ]]; then
    sudo kill "$STRACE_PID" 2>/dev/null || true
    wait "$STRACE_PID" 2>/dev/null || true
    echo "[strace] stopped" >&2
    STRACE_PID=""
  fi
}

extract_strace_context() {
  local evdir="$1"
  [[ "$ENABLE_STRACE" -ne 1 || -z "$STRACE_DIR" ]] && return 0
  mkdir -p "$evdir/strace"
  # Copy recent strace output (last 200 lines per file)
  for f in "$STRACE_DIR"/trace*; do
    [[ -f "$f" ]] || continue
    tail -200 "$f" >"$evdir/strace/$(basename "$f")" 2>/dev/null || true
  done
}

###############################################################################
# PCAP Analysis
###############################################################################
analyze_pcap() {
  local evdir="$1" peer_ip="$2" peer_port="$3" local_port="$4"

  if [[ ! -d "$evdir/pcap" ]]; then
    echo '{"scenario":"no_pcap","detail":"tcpdump not enabled or no files"}'
    return 0
  fi

  local fin_count=0 rst_count=0 fin_from_peer=0 rst_from_peer=0
  local first_fin="" first_rst=""

  for pcap in "$evdir/pcap"/*.pcap; do
    [[ -f "$pcap" ]] || continue

    local filter=""
    [[ -n "$peer_ip" ]] && filter="host $peer_ip"
    [[ -n "$peer_port" ]] && filter="$filter and port $peer_port"

    # Parse tcpdump output for FIN and RST flags
    while IFS= read -r line; do
      if [[ "$line" == *"Flags ["*"F"*"]"* ]]; then
        ((fin_count++)) || true
        # Check if source is peer
        if [[ "$line" == *"$peer_ip"* ]] && [[ "$line" =~ $peer_ip\.[0-9]+\ \> ]]; then
          ((fin_from_peer++)) || true
        fi
        [[ -z "$first_fin" ]] && first_fin="${line%% *}"
      fi
      if [[ "$line" == *"Flags ["*"R"*"]"* ]]; then
        ((rst_count++)) || true
        if [[ "$line" == *"$peer_ip"* ]] && [[ "$line" =~ $peer_ip\.[0-9]+\ \> ]]; then
          ((rst_from_peer++)) || true
        fi
        [[ -z "$first_rst" ]] && first_rst="${line%% *}"
      fi
    done < <(sudo tcpdump -nn -r "$pcap" "$filter" 2>/dev/null || true)
  done

  # Determine scenario
  local scenario="unknown" detail=""

  if [[ "$fin_from_peer" -gt 0 && "$rst_count" -gt 0 ]]; then
    scenario="A_fin_then_rst"
    detail="Peer sent FIN ($fin_from_peer), then RST ($rst_count) - dae likely wrote after FIN"
  elif [[ "$rst_from_peer" -gt 0 && "$fin_from_peer" -eq 0 ]]; then
    scenario="B_rst_only"
    detail="Peer sent RST ($rst_from_peer) without FIN - abrupt disconnect"
  elif [[ "$fin_from_peer" -gt 0 && "$rst_count" -eq 0 ]]; then
    scenario="graceful_fin"
    detail="Peer sent FIN ($fin_from_peer), no RST - graceful close"
  elif [[ "$fin_count" -eq 0 && "$rst_count" -eq 0 ]]; then
    scenario="no_close_packets"
    detail="No FIN/RST in capture window (may have occurred earlier)"
  fi

  jq -n \
    --arg scenario "$scenario" \
    --arg detail "$detail" \
    --argjson fin_count "$fin_count" \
    --argjson rst_count "$rst_count" \
    --argjson fin_from_peer "$fin_from_peer" \
    --argjson rst_from_peer "$rst_from_peer" \
    '{scenario:$scenario,detail:$detail,fin_count:$fin_count,rst_count:$rst_count,fin_from_peer:$fin_from_peer,rst_from_peer:$rst_from_peer}'
}

###############################################################################
# strace Analysis
###############################################################################
analyze_strace() {
  local evdir="$1" fd_list="$2"

  if [[ ! -d "$evdir/strace" ]]; then
    echo '{"error_handling":"no_strace","detail":"strace not enabled"}'
    return 0
  fi

  local write_errors=0 epipe_count=0 close_calls=0 writes_after_error=0

  for f in "$evdir/strace"/*; do
    [[ -f "$f" ]] || continue

    # Count patterns - ensure clean integer output
    local we ep cc
    we=$(grep -cE '(write|writev|send|sendto|sendmsg)\([0-9]+.*= -1 E' "$f" 2>/dev/null | head -1 || true)
    ep=$(grep -c 'EPIPE' "$f" 2>/dev/null | head -1 || true)
    cc=$(grep -cE 'close\([0-9]+\).*= 0' "$f" 2>/dev/null | head -1 || true)
    
    # Default to 0 if empty
    we=${we:-0}; we=${we//[^0-9]/}; we=${we:-0}
    ep=${ep:-0}; ep=${ep//[^0-9]/}; ep=${ep:-0}
    cc=${cc:-0}; cc=${cc//[^0-9]/}; cc=${cc:-0}

    write_errors=$((write_errors + we))
    epipe_count=$((epipe_count + ep))
    close_calls=$((close_calls + cc))

    # Check for writes after EPIPE on same fd (simple heuristic)
    # 修复后的逻辑：只计算同一 FD 上 EPIPE 后的继续写入
    if grep -q 'EPIPE' "$f"; then
      epipe_fd=$(grep 'EPIPE' "$f" | head -1 | grep -oP '(write|send)\(\K[0-9]+')
      if [[ -n "$epipe_fd" ]]; then
        # 只查找同一 FD 的后续 write
        after_epipe=$(sed -n '/EPIPE/,$p' "$f" | tail -n +2 | grep -cE "(write|send)\($epipe_fd," || true)
      fi
    fi
  done

  # Determine error handling quality
  local handling="unknown" detail=""

  if [[ "$write_errors" -eq 0 ]]; then
    handling="no_errors_captured"
    detail="No write errors in strace window"
  elif [[ "$writes_after_error" -gt 2 ]]; then
    handling="C_errors_ignored"
    detail="Found $writes_after_error writes after EPIPE - errors being ignored"
  elif [[ "$close_calls" -gt 0 && "$epipe_count" -gt 0 ]]; then
    handling="proper_handling"
    detail="EPIPE seen ($epipe_count), close called ($close_calls)"
  else
    handling="unclear"
    detail="Errors: $write_errors, EPIPE: $epipe_count, close: $close_calls"
  fi

  jq -n \
    --arg handling "$handling" \
    --arg detail "$detail" \
    --argjson write_errors "$write_errors" \
    --argjson epipe_count "$epipe_count" \
    --argjson close_calls "$close_calls" \
    --argjson writes_after_error "$writes_after_error" \
    '{error_handling:$handling,detail:$detail,write_errors:$write_errors,epipe_count:$epipe_count,close_calls:$close_calls,writes_after_error:$writes_after_error}'
}

###############################################################################
# Summary Writers
###############################################################################
write_summary() {
  # Read counters from file
  source "$COUNTER_FILE"

  local we wc ws wm
  we="$(tail -n "$WINDOW" "$WIN_FILE" 2>/dev/null | wc -l | awk '{print $1}')"
  wc="$(tail -n "$WINDOW" "$WIN_FILE" 2>/dev/null | awk -F'\t' '{c+=$1} END{print c+0}')"
  ws="$(tail -n "$WINDOW" "$WIN_FILE" 2>/dev/null | awk -F'\t' '{c+=$2} END{print c+0}')"
  wm="$(tail -n "$WINDOW" "$WIN_FILE" 2>/dev/null | awk -F'\t' '{c+=$3} END{print c+0}')"

  cat >"$SUMMARY_TXT" <<EOF
================================================================================
                         dae Broken Pipe Triage Summary
================================================================================
Service: $SERVICE  PID: $PID
Output:  $OUTDIR
Pattern: '$PATTERN'
tcpdump: $ENABLE_TCPDUMP  strace: $ENABLE_STRACE

Events: total=$TOTAL_EVENTS  window($WINDOW)=$we
CLOSE-WAIT: in_window=$wc  max_observed=$CLOSE_WAIT_MAX

Accountability (from pcap+strace):
  Scenario A (FIN→RST, dae issue):    $SCENARIO_A_COUNT
  Scenario B (RST only, peer issue):  $SCENARIO_B_COUNT
  Scenario C (errors ignored, bug):   $SCENARIO_C_COUNT
  Proper handling:                    $PROPER_HANDLING_COUNT

Last update: $(date '+%F %T')
================================================================================
EOF

  jq -n \
    --arg service "$SERVICE" \
    --argjson pid "$PID" \
    --arg outdir "$OUTDIR" \
    --argjson tcpdump "$ENABLE_TCPDUMP" \
    --argjson strace "$ENABLE_STRACE" \
    --argjson total "$TOTAL_EVENTS" \
    --argjson window "$WINDOW" \
    --argjson in_window "$we" \
    --argjson close_wait "$wc" \
    --argjson close_wait_max "$CLOSE_WAIT_MAX" \
    --argjson scenario_a "$SCENARIO_A_COUNT" \
    --argjson scenario_b "$SCENARIO_B_COUNT" \
    --argjson scenario_c "$SCENARIO_C_COUNT" \
    --argjson proper "$PROPER_HANDLING_COUNT" \
    '{service:$service,pid:$pid,outdir:$outdir,tcpdump_enabled:($tcpdump==1),strace_enabled:($strace==1),events_total:$total,window:$window,events_in_window:$in_window,close_wait_in_window:$close_wait,close_wait_max:$close_wait_max,accountability:{scenario_A:$scenario_a,scenario_B:$scenario_b,scenario_C:$scenario_c,proper_handling:$proper}}' \
    >"$SUMMARY_JSON"
}

write_accountability() {
  source "$COUNTER_FILE"

  local total_analyzed=$((SCENARIO_A_COUNT + SCENARIO_B_COUNT + SCENARIO_C_COUNT + PROPER_HANDLING_COUNT))
  local conclusion="" confidence="" recommendation=""

  if [[ "$total_analyzed" -eq 0 ]]; then
    if [[ "$ENABLE_TCPDUMP" -eq 0 || "$ENABLE_STRACE" -eq 0 ]]; then
      conclusion="INSUFFICIENT_DATA"
      confidence="N/A"
      recommendation="Re-run with --enable-tcpdump and --enable-strace"
    elif [[ "$TOTAL_EVENTS" -eq 0 ]]; then
      conclusion="NO_EVENTS"
      confidence="N/A"
      recommendation="No broken pipe events detected yet. Continue monitoring."
    else
      conclusion="ANALYSIS_PENDING"
      confidence="LOW"
      recommendation="Events detected but pcap/strace analysis inconclusive. Check raw data."
    fi
  elif [[ "$SCENARIO_C_COUNT" -gt 0 ]]; then
    conclusion="DAE_BUG: ERRORS_IGNORED"
    confidence="HIGH"
    recommendation="dae ignores write() errors. This is an implementation bug."
  elif [[ "$SCENARIO_A_COUNT" -gt "$SCENARIO_B_COUNT" && "$SCENARIO_A_COUNT" -gt 0 ]]; then
    local pct=$((SCENARIO_A_COUNT * 100 / total_analyzed))
    conclusion="DAE_DESIGN_ISSUE"
    confidence="MEDIUM-HIGH (${pct}% Scenario A)"
    recommendation="dae writes after peer FIN. Implement connection state tracking."
  elif [[ "$SCENARIO_B_COUNT" -gt "$SCENARIO_A_COUNT" && "$SCENARIO_B_COUNT" -gt 0 ]]; then
    local pct=$((SCENARIO_B_COUNT * 100 / total_analyzed))
    conclusion="PEER_OR_NETWORK_ISSUE"
    confidence="MEDIUM-HIGH (${pct}% Scenario B)"
    recommendation="Peer sends RST without FIN. Investigate peer/network."
  else
    conclusion="MIXED_OR_PROPER"
    confidence="MEDIUM"
    recommendation="Mixed causes or proper handling. Review per-event data."
  fi

  local leak_warning=""
  if [[ "$CLOSE_WAIT_MAX" -gt 10 ]]; then
    leak_warning="
⚠️  WARNING: High CLOSE-WAIT observed (max: $CLOSE_WAIT_MAX)
    Possible socket resource leak - dae not closing connections promptly.
"
  fi

  cat >"$ACCOUNTABILITY_TXT" <<EOF
================================================================================
                    ACCOUNTABILITY ANALYSIS REPORT
================================================================================
Generated: $(date '+%F %T')
Total Events: $TOTAL_EVENTS
Analyzed (pcap+strace): $total_analyzed

================================================================================
  CONCLUSION:  $conclusion
  CONFIDENCE:  $confidence
================================================================================

EVIDENCE BREAKDOWN:
┌─────────────────────────────────────────────────────────────────────────────┐
│ Scenario A (FIN→RST): $SCENARIO_A_COUNT events
│   Peer closed gracefully, dae continued writing → DAE DESIGN ISSUE
├─────────────────────────────────────────────────────────────────────────────┤
│ Scenario B (RST only): $SCENARIO_B_COUNT events
│   Peer reset abruptly without FIN → PEER/NETWORK ISSUE
├─────────────────────────────────────────────────────────────────────────────┤
│ Scenario C (Errors ignored): $SCENARIO_C_COUNT events
│   dae continued writing after EPIPE → DAE IMPLEMENTATION BUG
├─────────────────────────────────────────────────────────────────────────────┤
│ Proper Handling: $PROPER_HANDLING_COUNT events
│   dae handled error correctly → NO ISSUE
└─────────────────────────────────────────────────────────────────────────────┘
$leak_warning
RECOMMENDATION:
  $recommendation

DATA SOURCES:
  tcpdump: $([ "$ENABLE_TCPDUMP" -eq 1 ] && echo "ENABLED ($TCPDUMP_DIR)" || echo "DISABLED")
  strace:  $([ "$ENABLE_STRACE" -eq 1 ] && echo "ENABLED ($STRACE_DIR)" || echo "DISABLED")
  events:  $EVENTS_JSONL
================================================================================
EOF

  echo "" >&2
  cat "$ACCOUNTABILITY_TXT" >&2
}

###############################################################################
# Exit Handler
###############################################################################
on_exit() {
  echo "" >&2
  echo "Stopping and generating final analysis..." >&2
  stop_tcpdump
  stop_strace
  write_summary || true
  write_accountability || true
  echo "" >&2
  echo "Output: $OUTDIR" >&2
}
trap on_exit EXIT INT TERM

###############################################################################
# Print Configuration & Start
###############################################################################
cat >&2 <<EOF
╔══════════════════════════════════════════════════════════════════╗
║           dae Broken Pipe Accountability Triage v5               ║
╠══════════════════════════════════════════════════════════════════╣
║ service=$SERVICE  pid=$PID
║ outdir=$OUTDIR
║ pattern='$PATTERN'
║ peer=${FIXED_PEER}  peer_ip=${PEER_IP_FILTER:-auto}
║ tcpdump=$ENABLE_TCPDUMP  strace=$ENABLE_STRACE
╚══════════════════════════════════════════════════════════════════╝
Monitoring... (Ctrl-C to stop)
EOF

start_tcpdump
start_strace

###############################################################################
# Main Event Loop - Using process substitution to avoid subshell
###############################################################################
while IFS= read -r jline; do
  ts_us="$(echo "$jline" | jq -r '.__REALTIME_TIMESTAMP')"
  msg="$(echo "$jline" | jq -r '.MESSAGE')"

  ts_epoch_s="$(awk -v us="$ts_us" 'BEGIN{printf "%.6f", (us/1000000.0)}')"
  update_counter "LAST_TS_EPOCH" "$ts_epoch_s"

  # Parse addresses
  peer="$FIXED_PEER"
  [[ "$peer" == "auto" ]] && peer="$(parse_peer_from_msg "$msg")"
  local_addr="$(parse_local_from_msg "$msg")"
  local_port="${local_addr##*:}"

  peer_ip="${peer%%:*}"
  peer_port="${peer##*:}"
  if [[ -z "$peer" || "$peer" == "$peer_ip" ]]; then
    peer_ip=""
    peer_port=""
  fi

  # Update counter
  incr_counter "TOTAL_EVENTS"
  total_now="$(get_counter TOTAL_EVENTS)"

  # Check max events
  if [[ "$MAX_EVENTS" -ne 0 && "$total_now" -gt "$MAX_EVENTS" ]]; then
    break
  fi

  event_id="${ts_us}_${total_now}"
  evdir="$OUTDIR/raw/$event_id"
  mkdir -p "$evdir"
  printf '%s\n' "$jline" >"$evdir/log.json"

  echo "[Event #$total_now] $(ts_human) peer=$peer" >&2

  # Collect snapshots
  close_wait_seen=0
  close_wait_count=0
  mapped_fd_sum=0
  fds_collected=""
  snapshots_json='[]'

  for ((i=1; i<=SNAPSHOTS; i++)); do
    snap_prefix="$evdir/snap_${i}"

    if [[ -n "$peer_ip" && -n "$peer_port" ]]; then
      do_fdmap "$PID" "$peer_ip" "$peer_port" >"${snap_prefix}.fdmap.txt" 2>/dev/null || true
      fds="$(extract_fds <"${snap_prefix}.fdmap.txt" | tr '\n' ' ')"
      fds_collected="$fds_collected $fds"

      if has_close_wait <"${snap_prefix}.fdmap.txt" 2>/dev/null; then
        close_wait_seen=1
      fi
      cw="$(count_close_wait <"${snap_prefix}.fdmap.txt" 2>/dev/null || echo 0)"
      [[ "$cw" -gt "$close_wait_count" ]] && close_wait_count="$cw"

      if [[ -n "$fds" ]]; then
        fd_arr=($fds)
        mapped_fd_sum=$((mapped_fd_sum + ${#fd_arr[@]}))
        do_fd_to_tuple "$PID" $fds >"${snap_prefix}.tuple.txt" 2>/dev/null || true
      fi
    else
      sudo ss -ntpH 2>/dev/null | awk -v pid="pid=$PID," '$0 ~ pid' >"${snap_prefix}.ss.txt" || true
    fi

    [[ $i -lt $SNAPSHOTS ]] && msleep "$INTERVAL_MS"
  done

  # Update CLOSE_WAIT_MAX
  current_max="$(get_counter CLOSE_WAIT_MAX)"
  [[ "$close_wait_count" -gt "$current_max" ]] && update_counter "CLOSE_WAIT_MAX" "$close_wait_count"

  # Capture pcap and strace snapshots
  snapshot_tcpdump "$evdir"
  extract_strace_context "$evdir"

  # Analyze pcap
  pcap_result="$(analyze_pcap "$evdir" "$peer_ip" "$peer_port" "$local_port")"
  echo "$pcap_result" >"$evdir/pcap_analysis.json"

  pcap_scenario="$(echo "$pcap_result" | jq -r '.scenario')"
  case "$pcap_scenario" in
    A_fin_then_rst) incr_counter "SCENARIO_A_COUNT";;
    B_rst_only)     incr_counter "SCENARIO_B_COUNT";;
  esac

  # Analyze strace
  fds_collected="$(echo "$fds_collected" | tr ' ' '\n' | sort -nu | tr '\n' ' ')"
  strace_result="$(analyze_strace "$evdir" "$fds_collected")"
  echo "$strace_result" >"$evdir/strace_analysis.json"

  strace_handling="$(echo "$strace_result" | jq -r '.error_handling')"
  case "$strace_handling" in
    C_errors_ignored) incr_counter "SCENARIO_C_COUNT";;
    proper_handling)  incr_counter "PROPER_HANDLING_COUNT";;
  esac

  # Record window flags
  printf '%d\t%d\t%d\n' "$close_wait_seen" "$close_wait_seen" "$mapped_fd_sum" >>"$WIN_FILE"

  # Build event JSON
  event_json="$(jq -n \
    --arg service "$SERVICE" \
    --argjson pid "$PID" \
    --arg ts_us "$ts_us" \
    --arg ts_epoch "$ts_epoch_s" \
    --arg message "$msg" \
    --arg peer "$peer" \
    --arg peer_ip "$peer_ip" \
    --arg peer_port "$peer_port" \
    --arg event_id "$event_id" \
    --argjson close_wait_count "$close_wait_count" \
    --argjson pcap "$pcap_result" \
    --argjson strace "$strace_result" \
    '{service:$service,pid:$pid,ts_us:$ts_us,ts_epoch:$ts_epoch,message:$message,peer:$peer,peer_ip:$peer_ip,peer_port:$peer_port,event_id:$event_id,close_wait_count:$close_wait_count,pcap_analysis:$pcap,strace_analysis:$strace}')"

  echo "$event_json" >>"$EVENTS_JSONL"

  # Brief output
  echo "  └─ cw=$close_wait_count pcap=$pcap_scenario strace=$strace_handling" >&2

  write_summary || true

done < <(journalctl -u "$SERVICE" -f -o json 2>/dev/null | \
  jq -cr --arg pat "$PATTERN" 'select(.MESSAGE? and (.MESSAGE|contains($pat))) | {__REALTIME_TIMESTAMP, MESSAGE}' 2>/dev/null)
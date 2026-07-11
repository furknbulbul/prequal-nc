#!/bin/bash
# Figure 6 load-ramp driver.
#
# Drives 9 ramp levels (75% -> 174% of baseline capacity) against the
# Prequal LB and the Round-Robin LB simultaneously. client-1 is pinned to
# the first Prequal LB; client-2 is pinned to the first Round-Robin LB.
#
# Run from your laptop. Requires cloudlab/hosts.sh to be populated and
# `./cloudlab/deploy.sh run` to have brought the cluster up.
#
# Outputs land in results/experiment/<timestamp>/:
#   windows.csv     algorithm,level_pct,target_qps,t_start_unix,t_end_unix
#   prequal_<i>.txt raw hey output per level (i=0..8)
#   rr_<i>.txt      raw hey output per level
#   summary.tsv     parsed metrics per (algo, level)
#
# Usage:
#   ./cloudlab/experiment.sh [-d DURATION_SEC] [-g GAP_SEC] [-b BASELINE_QPS] [-c CONC] [-a ALGO] [-m 0|1] [-p 0|1] [-P MODE] [-I MS]
#
# Flags:
#   -d  duration per level, default 60
#   -g  pause between levels, default 15 (gives Prometheus a clean gap)
#   -b  baseline QPS for "100%" capacity. If omitted, a 30s calibration
#       run measures it from the RR LB (uncapped).
#   -c  concurrency for hey, default 1000
#   -a  algorithm(s) to run: 'both' (default), 'prequal', or 'rr'
#   -m  enable LB Prometheus metrics on the request/probe hot path
#       (0=off, 1=on). Restarts LBs.
#   -p  enable LB /debug/pool recent-picks ring (0=off, 1=on). Restarts LBs.
#   -P  probe mode for PreQual: 'per_query' (paper default) or 'ticker'
#       (giacbusc-style periodic probing of all backends). Restarts LBs.
#   -I  probe tick interval in milliseconds (ticker mode only, default 1000).
#       Restarts LBs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
HOSTS_FILE="$SCRIPT_DIR/hosts.sh"

if [ ! -f "$HOSTS_FILE" ]; then
    echo "Error: $HOSTS_FILE not found." >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$HOSTS_FILE"

: "${LB_PORT:=8080}"

DURATION=60
GAP=15
BASELINE=""
CONC=1000
ALGO="both"   # both | prequal | rr
LB_METRICS_OPT=""   # empty = leave containers as-is; "0"/"1" = restart with that value
LB_PICK_LOG_OPT=""
LB_PROBE_MODE_OPT=""       # "" (unchanged) | per_query | ticker
LB_PROBE_INTERVAL_MS_OPT="" # "" (unchanged) | integer ms

while getopts "d:g:b:c:a:m:p:P:I:h" opt; do
    case $opt in
        d) DURATION=$OPTARG ;;
        g) GAP=$OPTARG ;;
        b) BASELINE=$OPTARG ;;
        c) CONC=$OPTARG ;;
        a) ALGO=$OPTARG ;;
        m) LB_METRICS_OPT=$OPTARG ;;
        p) LB_PICK_LOG_OPT=$OPTARG ;;
        P) LB_PROBE_MODE_OPT=$OPTARG ;;
        I) LB_PROBE_INTERVAL_MS_OPT=$OPTARG ;;
        h) sed -n '2,34p' "$0"; exit 0 ;;
        *) echo "Unknown flag" >&2; exit 1 ;;
    esac
done

case "$LB_PROBE_MODE_OPT" in
    ""|per_query|ticker) ;;
    *) echo "Invalid -P: '$LB_PROBE_MODE_OPT' (must be per_query or ticker)" >&2; exit 1 ;;
esac

case "$ALGO" in
    both|prequal|rr) ;;
    *) echo "Invalid -a: '$ALGO' (must be: both, prequal, rr)" >&2; exit 1 ;;
esac

if [ "${#PREQUAL_HOSTS[@]}" -lt 1 ] || [ "${#RR_HOSTS[@]}" -lt 1 ]; then
    echo "Need at least one Prequal LB and one RR LB in hosts.sh" >&2
    exit 1
fi
if [ "${#CLIENT_HOSTS[@]}" -lt 1 ]; then
    echo "Need at least 1 client host in CLIENT_HOSTS" >&2
    exit 1
fi

PREQUAL_LB="lb-prequal-1"
RR_LB="lb-rr-1"
CLIENT_PREQUAL=${CLIENT_HOSTS[0]}
# Fall back to the same client if only one is provided; both hey processes
# then share the client's CPU. On an m510 this is fine — hey is cheap.
CLIENT_RR=${CLIENT_HOSTS[1]:-${CLIENT_HOSTS[0]}}

SSH_OPTS=(-o StrictHostKeyChecking=accept-new \
          -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR)

ssh_run() {
    local host=$1; shift
    ssh "${SSH_OPTS[@]}" "$CLOUDLAB_USER@$host" "$@"
}

# hey is installed by `deploy.sh run`. PATH is set in ~/.bashrc but ssh
# non-login shells don't source it, so call it through the absolute path.
hey_remote() {
    local client=$1; shift
    # "$@" is the rest of the hey args
    ssh_run "$client" "\$HOME/bin/hey $*"
}

calibrate() {
    echo "Calibration: running hey for 30s against $RR_LB (uncapped)..." >&2
    local raw
    raw=$(hey_remote "$CLIENT_RR" "-z 30s -c $CONC http://$RR_LB:$LB_PORT/" 2>&1) || true
    local rps
    rps=$(echo "$raw" | awk '/Requests\/sec:/ {print $2; exit}')
    if [ -z "$rps" ]; then
        echo "Calibration failed; hey output:" >&2
        echo "$raw" >&2
        exit 1
    fi
    printf "%.0f" "$rps"
}

# If any observation gate or probe-mode flag was given, restart the LB
# containers with the new env vars so the sweep runs against them.
if [ -n "$LB_METRICS_OPT" ] || [ -n "$LB_PICK_LOG_OPT" ] || \
   [ -n "$LB_PROBE_MODE_OPT" ] || [ -n "$LB_PROBE_INTERVAL_MS_OPT" ]; then
    echo "Restarting LB containers with LB_METRICS=${LB_METRICS_OPT:-<unchanged>} LB_PICK_LOG=${LB_PICK_LOG_OPT:-<unchanged>} LB_PROBE_MODE=${LB_PROBE_MODE_OPT:-<unchanged>} LB_PROBE_INTERVAL_MS=${LB_PROBE_INTERVAL_MS_OPT:-<unchanged>}..."
    if [ -n "$LB_METRICS_OPT" ]; then
        export LB_METRICS="$LB_METRICS_OPT"
    fi
    if [ -n "$LB_PICK_LOG_OPT" ]; then
        export LB_PICK_LOG="$LB_PICK_LOG_OPT"
    fi
    if [ -n "$LB_PROBE_MODE_OPT" ]; then
        export LB_PROBE_MODE="$LB_PROBE_MODE_OPT"
    fi
    if [ -n "$LB_PROBE_INTERVAL_MS_OPT" ]; then
        export LB_PROBE_INTERVAL_MS="$LB_PROBE_INTERVAL_MS_OPT"
    fi
    "$SCRIPT_DIR/deploy.sh" run-lbs
    echo "Sleeping 3s to let LBs settle..."
    sleep 3
fi

if [ -z "$BASELINE" ]; then
    BASELINE=$(calibrate)
fi
echo "Baseline (100%) = $BASELINE req/sec per algorithm"

TS=$(date +%Y%m%d-%H%M%S)
OUT="$REPO_DIR/results/experiment/$TS"
mkdir -p "$OUT"
WINDOWS="$OUT/windows.csv"
SUMMARY="$OUT/summary.tsv"

echo "algorithm,level_pct,target_qps,t_start_unix,t_end_unix" > "$WINDOWS"
printf "algorithm\tlevel_pct\ttarget_qps\trps\tp50_ms\tp90_ms\tp99_ms\terror_pct\n" > "$SUMMARY"

LEVELS_PCT=(75 83 93 103 114 127 141 157 174)

parse_hey() {
    # $1 = file, $2 = label prefix for column output
    local f=$1
    local rps p50 p90 p99 errpct total
    rps=$(awk '/Requests\/sec:/ {printf "%.2f", $2; exit}' "$f")
    # `hey` reports response times in seconds. Some builds emit "%%"
    # (double percent) instead of "%"; the "+" quantifier tolerates both.
    p50=$(awk '/  50%+ in/ {printf "%.3f", $3*1000; exit}' "$f")
    p90=$(awk '/  90%+ in/ {printf "%.3f", $3*1000; exit}' "$f")
    p99=$(awk '/  99%+ in/ {printf "%.3f", $3*1000; exit}' "$f")
    # Error rate: hey prints "Status code distribution:" with [2xx] etc, plus an "Error distribution" section.
    total=$(awk '/Total responses:/ {print $3; exit} /Total:/ {print $2; exit}' "$f")
    # Sum non-2xx codes and explicit errors.
    local nonok errs
    nonok=$(awk '
        /Status code distribution:/ {flag=1; next}
        flag && /^$/ {flag=0}
        flag && /\[[0-9]+\]/ {
            code=$2+0; n=$1+0;
            if (code < 200 || code >= 300) sum += n;
        }
        END {print sum+0}' "$f")
    errs=$(awk '
        /Error distribution:/ {flag=1; next}
        flag && /^$/ {flag=0}
        flag && /\[[0-9]+\]/ {sum += $1+0}
        END {print sum+0}' "$f")
    if [ -z "$total" ] || [ "$total" = "0" ]; then
        errpct="0.00"
    else
        errpct=$(awk -v n="$nonok" -v e="$errs" -v t="$total" 'BEGIN {printf "%.3f", 100*(n+e)/t}')
    fi
    printf "%s\t%s\t%s\t%s\n" "${rps:-0}" "${p50:-0}" "${p90:-0}" "${p99:-0}"
    echo "$errpct"
}

# Phased ramp: run RR through all 9 levels back-to-back (no gap between
# levels), then a single break, then PreQual through all 9 levels the same
# way. With a deterministic (constant) antagonist, both algorithms see the
# same steady-state fleet load — differences reflect the algorithm alone.

run_ramp() {
    local algo=$1 client=$2 lb=$3 outprefix=$4
    echo
    echo "============ Phase: $algo ramp (no inter-level gap) ============"
    for i in "${!LEVELS_PCT[@]}"; do
        local pct=${LEVELS_PCT[$i]}
        local qps
        qps=$(awk -v b="$BASELINE" -v p="$pct" 'BEGIN {printf "%.0f", b*p/100}')
        # hey -q is per-worker; divide intended aggregate rate by concurrency.
        local per_worker
        per_worker=$(awk -v q="$qps" -v c="$CONC" 'BEGIN { printf "%.4f", q/c }')

        echo "  $algo level $((i+1))/${#LEVELS_PCT[@]}: ${pct}% (${qps} qps)"
        local t_start t_end
        t_start=$(date +%s)
        hey_remote "$client" "-z ${DURATION}s -q $per_worker -c $CONC -t 20 http://$lb:$LB_PORT/" \
            > "$OUT/${outprefix}_${i}.txt" 2>&1
        t_end=$(date +%s)
        echo "$algo,${pct},${qps},${t_start},${t_end}" >> "$WINDOWS"
    done
}

# --- Phase 1: RR ramp (skipped if -a prequal) ---
if [ "$ALGO" = "both" ] || [ "$ALGO" = "rr" ]; then
    run_ramp roundrobin "$CLIENT_RR" "$RR_LB" rr
fi

# --- Break between phases (only if both are being run) ---
if [ "$ALGO" = "both" ]; then
    echo
    echo "============ Break: ${GAP}s ============"
    sleep "$GAP"
fi

# --- Phase 2: PreQual ramp (skipped if -a rr) ---
if [ "$ALGO" = "both" ] || [ "$ALGO" = "prequal" ]; then
    run_ramp prequal "$CLIENT_PREQUAL" "$PREQUAL_LB" prequal
fi

# --- Parse everything into summary.tsv and print a comparison table ---
echo
echo "============ Results ============"
for i in "${!LEVELS_PCT[@]}"; do
    pct=${LEVELS_PCT[$i]}
    qps=$(awk -v b="$BASELINE" -v p="$pct" 'BEGIN {printf "%.0f", b*p/100}')
    if [ "$ALGO" = "both" ] || [ "$ALGO" = "prequal" ]; then
        {
            read -r line; read -r ep
            printf "prequal\t%s\t%s\t%s\t%s\n" "$pct" "$qps" "$line" "$ep"
        } < <(parse_hey "$OUT/prequal_${i}.txt") >> "$SUMMARY"
    fi
    if [ "$ALGO" = "both" ] || [ "$ALGO" = "rr" ]; then
        {
            read -r line; read -r ep
            printf "roundrobin\t%s\t%s\t%s\t%s\n" "$pct" "$qps" "$line" "$ep"
        } < <(parse_hey "$OUT/rr_${i}.txt") >> "$SUMMARY"
    fi
done
column -t -s $'\t' "$SUMMARY"

echo
echo "Done. Results in $OUT"
echo "  windows.csv  -> $WINDOWS"
echo "  summary.tsv  -> $SUMMARY"
echo
echo "Render figure with:"
echo "  python3 cloudlab/plot_experiment.py $OUT --prom http://${OBSERVER_HOSTS[0]}:9090"

#!/bin/bash
# Figure 6 load-ramp driver (open loop).
#
# Drives 9 ramp levels (75% -> 174% of the fleet's aggregate CPU ALLOCATION)
# against the Round-Robin LB, then the Prequal LB. Load is generated with
# vegeta, an OPEN-LOOP generator: queries arrive at the target rate whether
# or not earlier ones completed, so levels above 100% genuinely overload the
# fleet (a closed-loop tool like hey self-throttles and can never do this).
# Every request carries the paper's 5s deadline; requests that miss it are
# the "deadline exceeded" errors of Figure 6(b).
#
# "100%" is calibrated from the allocation, not from max throughput: a short
# low-rate run measures the median per-query service time, and
#   baseline qps = n_servers * ALLOC_CORES / median_service_time.
# ALLOC_CORES comes from hosts.sh (default 2). Backends are uncapped; the
# gap between allocation and the 8-core machine is the spare capacity
# Prequal exploits.
#
# Run from your laptop. Requires cloudlab/hosts.sh to be populated and
# `./cloudlab/deploy.sh run` to have brought the cluster up (installs vegeta).
#
# Outputs land in results/experiment/<timestamp>/:
#   windows.csv       algorithm,level_pct,target_qps,t_start_unix,t_end_unix
#   prequal_<i>.json  vegeta JSON report per level (i=0..8)
#   prequal_<i>.txt   human-readable vegeta report per level
#   rr_<i>.json/.txt  same for round-robin
#   summary.tsv       parsed metrics per (algo, level)
#
# Usage:
#   ./cloudlab/experiment.sh [-d DURATION_SEC] [-g GAP_SEC] [-b BASELINE_QPS]
#                            [-w MAX_WORKERS] [-T TIMEOUT_SEC] [-a ALGO]
#                            [-m 0|1] [-p 0|1] [-P MODE] [-I MS] [-R RPROBE]
#
# Flags:
#   -d  duration per level, default 60
#   -g  pause between the RR and Prequal phases, default 15
#   -b  baseline QPS for "100%". If omitted, calibrated from ALLOC_CORES
#       and a 20s low-rate service-time measurement.
#   -w  vegeta -max-workers cap, default 10000. This bounds client-side
#       concurrency; if WRR is drowning at the top levels the cap may bind,
#       making WRR results conservative (reality would be even worse).
#   -T  per-request deadline in seconds, default 5 (the paper's deadline)
#   -a  algorithm(s) to run: 'both' (default), 'prequal', or 'rr'
#   -m  enable LB Prometheus metrics on the hot path (0/1). Restarts LBs.
#   -p  enable LB /debug/pool recent-picks ring (0/1). Restarts LBs.
#   -P  probe mode for Prequal: 'per_query' (paper) or 'ticker'. Restarts LBs.
#   -I  probe tick interval in ms (ticker mode only). Restarts LBs.
#   -R  probes per query (r_probe, fractional ok; paper: 3). Restarts LBs.

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
: "${ALLOC_CORES:=2}"

DURATION=60
GAP=15
BASELINE=""
MAXWORKERS=10000
TIMEOUT=5
CAL_RATE=50
CAL_DURATION=20
ALGO="both"   # both | prequal | rr
LB_METRICS_OPT=""   # empty = leave containers as-is; "0"/"1" = restart with that value
LB_PICK_LOG_OPT=""
LB_PROBE_MODE_OPT=""        # "" (unchanged) | per_query | ticker
LB_PROBE_INTERVAL_MS_OPT="" # "" (unchanged) | integer ms
LB_RPROBE_OPT=""            # "" (unchanged) | float probes-per-query

while getopts "d:g:b:w:T:a:m:p:P:I:R:h" opt; do
    case $opt in
        d) DURATION=$OPTARG ;;
        g) GAP=$OPTARG ;;
        b) BASELINE=$OPTARG ;;
        w) MAXWORKERS=$OPTARG ;;
        T) TIMEOUT=$OPTARG ;;
        a) ALGO=$OPTARG ;;
        m) LB_METRICS_OPT=$OPTARG ;;
        p) LB_PICK_LOG_OPT=$OPTARG ;;
        P) LB_PROBE_MODE_OPT=$OPTARG ;;
        I) LB_PROBE_INTERVAL_MS_OPT=$OPTARG ;;
        R) LB_RPROBE_OPT=$OPTARG ;;
        h) sed -n '2,55p' "$0"; exit 0 ;;
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

N_SRV=${#SRV_HOSTS[@]}

PREQUAL_LB="lb-prequal-1"
RR_LB="lb-rr-1"
CLIENT_PREQUAL=${CLIENT_HOSTS[0]}
# Fall back to the same client if only one is provided; the two phases run
# sequentially, so they never share the client's CPU.
CLIENT_RR=${CLIENT_HOSTS[1]:-${CLIENT_HOSTS[0]}}

SSH_OPTS=(-o StrictHostKeyChecking=accept-new \
          -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR)

ssh_run() {
    local host=$1; shift
    ssh "${SSH_OPTS[@]}" "$CLOUDLAB_USER@$host" "$@"
}

# vegeta is installed by `deploy.sh run`. PATH is set in ~/.bashrc but ssh
# non-login shells don't source it, so call it through the absolute path.
# The attack writes its binary results to a per-run file on the client and
# emits the JSON report on stdout; the .bin sticks around for the follow-up
# text report. ulimit is raised because open-loop overload can legitimately
# hold tens of thousands of sockets.
vegeta_attack() {
    # $1 client, $2 LB shortname, $3 rate (qps), $4 duration secs, $5 tag
    local client=$1 lb=$2 rate=$3 dur=$4 bin="/tmp/vegeta-$5.bin"
    ssh_run "$client" "ulimit -n 65536 2>/dev/null || true; \
echo 'GET http://$lb:$LB_PORT/' | \$HOME/bin/vegeta attack \
-rate=$rate -duration=${dur}s -timeout=${TIMEOUT}s \
-max-workers=$MAXWORKERS -output=$bin \
&& \$HOME/bin/vegeta report -type=json <$bin"
}

vegeta_text_report() {
    # $1 client, $2 tag
    ssh_run "$1" "\$HOME/bin/vegeta report </tmp/vegeta-$2.bin"
}

parse_vegeta() {
    # $1 = vegeta JSON report file.
    # Emits: throughput \t p50_ms \t p90_ms \t p99_ms \t error_pct
    # "success" is vegeta's fraction of 2xx responses; timeouts and non-2xx
    # both count as errors, matching the paper's deadline-exceeded metric.
    python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("0\t0\t0\t0\t100.000")
    sys.exit(0)
lat = d.get("latencies") or {}
ms = lambda k: lat.get(k, 0) / 1e6
err = 100.0 * (1.0 - d.get("success", 0.0))
print("%.2f\t%.3f\t%.3f\t%.3f\t%.3f"
      % (d.get("throughput", 0.0), ms("50th"), ms("90th"), ms("99th"), err))
PY
}

calibrate() {
    # Measure the median per-query service time at a load low enough that
    # nothing queues (even stressed servers have >=1 idle core for a lone
    # query), then convert the declared allocation into a baseline rate:
    #   baseline = n_srv * ALLOC_CORES / median_service_time
    echo "Calibration: ${CAL_DURATION}s @ ${CAL_RATE} qps against $RR_LB to measure service time..." >&2
    local json p50_ms
    json=$(vegeta_attack "$CLIENT_RR" "$RR_LB" "$CAL_RATE" "$CAL_DURATION" cal) || true
    p50_ms=$(printf '%s' "$json" | python3 -c \
        'import json,sys; print("%.3f" % (json.load(sys.stdin)["latencies"]["50th"]/1e6))' \
        2>/dev/null) || true
    if [ -z "$p50_ms" ]; then
        echo "Calibration failed; vegeta output was:" >&2
        printf '%s\n' "$json" >&2
        exit 1
    fi
    echo "  median service time at low load: ${p50_ms} ms" >&2
    echo "  allocation: ${N_SRV} servers x ${ALLOC_CORES} cores" >&2
    awk -v n="$N_SRV" -v a="$ALLOC_CORES" -v p="$p50_ms" \
        'BEGIN {printf "%.0f", n * a * 1000 / p}'
}

# If any observation gate or probe knob was given, restart the LB containers
# with the new env vars so the sweep runs against them.
if [ -n "$LB_METRICS_OPT" ] || [ -n "$LB_PICK_LOG_OPT" ] || \
   [ -n "$LB_PROBE_MODE_OPT" ] || [ -n "$LB_PROBE_INTERVAL_MS_OPT" ] || \
   [ -n "$LB_RPROBE_OPT" ]; then
    echo "Restarting LB containers with LB_METRICS=${LB_METRICS_OPT:-<unchanged>} LB_PICK_LOG=${LB_PICK_LOG_OPT:-<unchanged>} LB_PROBE_MODE=${LB_PROBE_MODE_OPT:-<unchanged>} LB_PROBE_INTERVAL_MS=${LB_PROBE_INTERVAL_MS_OPT:-<unchanged>} LB_RPROBE=${LB_RPROBE_OPT:-<unchanged>}..."
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
    if [ -n "$LB_RPROBE_OPT" ]; then
        export LB_RPROBE="$LB_RPROBE_OPT"
    fi
    "$SCRIPT_DIR/deploy.sh" run-lbs
    echo "Sleeping 3s to let LBs settle..."
    sleep 3
fi

if [ -z "$BASELINE" ]; then
    BASELINE=$(calibrate)
fi
echo "Baseline (100% of aggregate allocation) = $BASELINE req/sec"

TS=$(date +%Y%m%d-%H%M%S)
OUT="$REPO_DIR/results/experiment/$TS"
mkdir -p "$OUT"
WINDOWS="$OUT/windows.csv"
SUMMARY="$OUT/summary.tsv"

echo "algorithm,level_pct,target_qps,t_start_unix,t_end_unix" > "$WINDOWS"
printf "algorithm\tlevel_pct\ttarget_qps\trps\tp50_ms\tp90_ms\tp99_ms\terror_pct\n" > "$SUMMARY"

LEVELS_PCT=(75 83 93 103 114 127 141 157 174)

# Phased ramp: run RR through all 9 levels back-to-back (no gap between
# levels, like the paper's continuous ramp), then a single break, then
# Prequal the same way. The antagonist schedule is deterministic, so both
# phases see the same fleet conditions. Window timestamps are taken from
# the client node's clock so they line up with Prometheus on the cluster.

run_ramp() {
    local algo=$1 client=$2 lb=$3 outprefix=$4
    echo
    echo "============ Phase: $algo ramp (open loop, ${TIMEOUT}s deadline) ============"
    for i in "${!LEVELS_PCT[@]}"; do
        local pct=${LEVELS_PCT[$i]}
        local qps
        qps=$(awk -v b="$BASELINE" -v p="$pct" 'BEGIN {printf "%.0f", b*p/100}')
        echo "  $algo level $((i+1))/${#LEVELS_PCT[@]}: ${pct}% (${qps} qps)"
        local t_start t_end
        t_start=$(ssh_run "$client" 'date +%s')
        vegeta_attack "$client" "$lb" "$qps" "$DURATION" "$outprefix" \
            > "$OUT/${outprefix}_${i}.json" || true
        t_end=$(ssh_run "$client" 'date +%s')
        vegeta_text_report "$client" "$outprefix" \
            > "$OUT/${outprefix}_${i}.txt" 2>&1 || true
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

# --- Phase 2: Prequal ramp (skipped if -a rr) ---
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
        printf "prequal\t%s\t%s\t%s\n" "$pct" "$qps" \
            "$(parse_vegeta "$OUT/prequal_${i}.json")" >> "$SUMMARY"
    fi
    if [ "$ALGO" = "both" ] || [ "$ALGO" = "rr" ]; then
        printf "roundrobin\t%s\t%s\t%s\n" "$pct" "$qps" \
            "$(parse_vegeta "$OUT/rr_${i}.json")" >> "$SUMMARY"
    fi
done
column -t -s $'\t' "$SUMMARY"

echo
echo "Done. Results in $OUT"
echo "  windows.csv  -> $WINDOWS"
echo "  summary.tsv  -> $SUMMARY"
echo
echo "Render figure with:"
echo "  python3 cloudlab/plot_experiment.py $OUT --prom http://${OBSERVER_HOSTS[0]}:9090 --alloc-cores $ALLOC_CORES"

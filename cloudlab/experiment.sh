#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
HOSTS_FILE="$SCRIPT_DIR/hosts.sh"

usage() {
    cat << EOF
Usage: ./cloudlab/experiment.sh [-d DURATION_SEC] [-g GAP_SEC] [-b BASELINE_QPS]
                                [-w MAX_WORKERS] [-T TIMEOUT_SEC] [-a ALGO]
                                [-m 0|1] [-p 0|1] [-P MODE] [-I MS] [-R RPROBE]
                                [-A 0|1] [-N RPROBE_MIN] [-L LOAD_LOW] [-H LOAD_HIGH]

Flags:
  -d  duration per level, default 60
  -g  pause between the RR and Prequal phases, default 15
  -b  baseline QPS for "100%"; if omitted, calibrated from ALLOC_CORES
  -w  vegeta -max-workers cap, default 10000
  -T  per-request deadline in seconds, default 5
  -a  algorithm(s) to run: 'both' (default), 'prequal', or 'rr'
  -m  enable LB Prometheus metrics (0/1). Restarts LBs.
  -p  enable LB /debug/pool recent-picks ring (0/1). Restarts LBs.
  -P  probe mode: 'per_query' or 'ticker'. Restarts LBs.
  -I  probe tick interval in ms (ticker mode only). Restarts LBs.
  -R  probes per query (fractional ok). Restarts LBs.
  -A  adaptive probing on/off (0/1). Restarts LBs.
  -N  r_probe floor reached at/above -H load (default 1).
  -L  in-flight forwards at/below which full -R is used (default 100).
  -H  in-flight forwards at/above which -N is used (default 1000).
EOF
}

if [ ! -f "$HOSTS_FILE" ]; then
    echo "Error: $HOSTS_FILE not found." >&2
    exit 1
fi
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
ALGO="both"
LB_METRICS_OPT=""
LB_PICK_LOG_OPT=""
LB_PROBE_MODE_OPT=""
LB_PROBE_INTERVAL_MS_OPT=""
LB_RPROBE_OPT=""
LB_RPROBE_ADAPTIVE_OPT=""
LB_RPROBE_MIN_OPT=""
LB_PROBE_LOAD_LOW_OPT=""
LB_PROBE_LOAD_HIGH_OPT=""

while getopts "d:g:b:w:T:a:m:p:P:I:R:A:N:L:H:h" opt; do
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
        A) LB_RPROBE_ADAPTIVE_OPT=$OPTARG ;;
        N) LB_RPROBE_MIN_OPT=$OPTARG ;;
        L) LB_PROBE_LOAD_LOW_OPT=$OPTARG ;;
        H) LB_PROBE_LOAD_HIGH_OPT=$OPTARG ;;
        h) usage; exit 0 ;;
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
CLIENT_RR=${CLIENT_HOSTS[1]:-${CLIENT_HOSTS[0]}}

SSH_OPTS=(-o StrictHostKeyChecking=accept-new \
          -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR)

ssh_run() {
    local host=$1; shift
    ssh "${SSH_OPTS[@]}" "$CLOUDLAB_USER@$host" "$@"
}

vegeta_attack() {
    local client=$1 lb=$2 rate=$3 dur=$4 bin="/tmp/vegeta-$5.bin"
    ssh_run "$client" "ulimit -n 65536 2>/dev/null || true; \
echo 'GET http://$lb:$LB_PORT/' | \$HOME/bin/vegeta attack \
-rate=$rate -duration=${dur}s -timeout=${TIMEOUT}s \
-max-workers=$MAXWORKERS -output=$bin \
&& \$HOME/bin/vegeta report -type=json <$bin"
}

vegeta_text_report() {
    ssh_run "$1" "\$HOME/bin/vegeta report </tmp/vegeta-$2.bin"
}

parse_vegeta() {
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

if [ -n "$LB_METRICS_OPT" ] || [ -n "$LB_PICK_LOG_OPT" ] || \
   [ -n "$LB_PROBE_MODE_OPT" ] || [ -n "$LB_PROBE_INTERVAL_MS_OPT" ] || \
   [ -n "$LB_RPROBE_OPT" ] || [ -n "$LB_RPROBE_ADAPTIVE_OPT" ] || \
   [ -n "$LB_RPROBE_MIN_OPT" ] || [ -n "$LB_PROBE_LOAD_LOW_OPT" ] || \
   [ -n "$LB_PROBE_LOAD_HIGH_OPT" ]; then
    echo "Restarting LB containers with LB_METRICS=${LB_METRICS_OPT:-<unchanged>} LB_PICK_LOG=${LB_PICK_LOG_OPT:-<unchanged>} LB_PROBE_MODE=${LB_PROBE_MODE_OPT:-<unchanged>} LB_PROBE_INTERVAL_MS=${LB_PROBE_INTERVAL_MS_OPT:-<unchanged>} LB_RPROBE=${LB_RPROBE_OPT:-<unchanged>} LB_RPROBE_ADAPTIVE=${LB_RPROBE_ADAPTIVE_OPT:-<unchanged>} LB_RPROBE_MIN=${LB_RPROBE_MIN_OPT:-<unchanged>} LB_PROBE_LOAD_LOW=${LB_PROBE_LOAD_LOW_OPT:-<unchanged>} LB_PROBE_LOAD_HIGH=${LB_PROBE_LOAD_HIGH_OPT:-<unchanged>}..."
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
    if [ -n "$LB_RPROBE_ADAPTIVE_OPT" ]; then
        export LB_RPROBE_ADAPTIVE="$LB_RPROBE_ADAPTIVE_OPT"
    fi
    if [ -n "$LB_RPROBE_MIN_OPT" ]; then
        export LB_RPROBE_MIN="$LB_RPROBE_MIN_OPT"
    fi
    if [ -n "$LB_PROBE_LOAD_LOW_OPT" ]; then
        export LB_PROBE_LOAD_LOW="$LB_PROBE_LOAD_LOW_OPT"
    fi
    if [ -n "$LB_PROBE_LOAD_HIGH_OPT" ]; then
        export LB_PROBE_LOAD_HIGH="$LB_PROBE_LOAD_HIGH_OPT"
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
LEVELS_PCT=(30 75 83 93 103 114 127 141 157 174)

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

if [ "$ALGO" = "both" ] || [ "$ALGO" = "rr" ]; then
    run_ramp roundrobin "$CLIENT_RR" "$RR_LB" rr
fi

if [ "$ALGO" = "both" ]; then
    echo
    echo "============ Break: ${GAP}s ============"
    sleep "$GAP"
fi

if [ "$ALGO" = "both" ] || [ "$ALGO" = "prequal" ]; then
    run_ramp prequal "$CLIENT_PREQUAL" "$PREQUAL_LB" prequal
fi

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
echo "  python3 cloudlab/plot_experiment.py $OUT --ssh $CLOUDLAB_USER@${OBSERVER_HOSTS[0]} --alloc-cores $ALLOC_CORES"

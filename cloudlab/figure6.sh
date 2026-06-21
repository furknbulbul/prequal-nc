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
# Outputs land in results/figure6/<timestamp>/:
#   windows.csv     algorithm,level_pct,target_qps,t_start_unix,t_end_unix
#   prequal_<i>.txt raw hey output per level (i=0..8)
#   rr_<i>.txt      raw hey output per level
#   summary.tsv     parsed metrics per (algo, level)
#
# Usage:
#   ./cloudlab/figure6.sh [-d DURATION_SEC] [-g GAP_SEC] [-b BASELINE_QPS] [-c CONC]
#
# Flags:
#   -d  duration per level, default 60
#   -g  pause between levels, default 15 (gives Prometheus a clean gap)
#   -b  baseline QPS for "100%" capacity. If omitted, a 30s calibration
#       run measures it from the RR LB (uncapped).
#   -c  concurrency for hey, default 64

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
CONC=64

while getopts "d:g:b:c:h" opt; do
    case $opt in
        d) DURATION=$OPTARG ;;
        g) GAP=$OPTARG ;;
        b) BASELINE=$OPTARG ;;
        c) CONC=$OPTARG ;;
        h) sed -n '2,28p' "$0"; exit 0 ;;
        *) echo "Unknown flag" >&2; exit 1 ;;
    esac
done

if [ "${#PREQUAL_HOSTS[@]}" -lt 1 ] || [ "${#RR_HOSTS[@]}" -lt 1 ]; then
    echo "Need at least one Prequal LB and one RR LB in hosts.sh" >&2
    exit 1
fi
if [ "${#CLIENT_HOSTS[@]}" -lt 2 ]; then
    echo "Need at least 2 client hosts (client-1, client-2)" >&2
    exit 1
fi

PREQUAL_LB="lb-prequal-1"
RR_LB="lb-rr-1"
CLIENT_PREQUAL=${CLIENT_HOSTS[0]}
CLIENT_RR=${CLIENT_HOSTS[1]}

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
    echo "Calibration: running hey for 30s against $RR_LB (uncapped)..."
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

if [ -z "$BASELINE" ]; then
    BASELINE=$(calibrate)
fi
echo "Baseline (100%) = $BASELINE req/sec per algorithm"

TS=$(date +%Y%m%d-%H%M%S)
OUT="$REPO_DIR/results/figure6/$TS"
mkdir -p "$OUT"
WINDOWS="$OUT/windows.csv"
SUMMARY="$OUT/summary.tsv"

echo "algorithm,level_pct,target_qps,t_start_unix,t_end_unix" > "$WINDOWS"
printf "algorithm\tlevel_pct\ttarget_qps\trps\tp50_ms\tp99_ms\tp999_ms\terror_pct\n" > "$SUMMARY"

LEVELS_PCT=(75 83 93 103 114 127 141 157 174)

parse_hey() {
    # $1 = file, $2 = label prefix for column output
    local f=$1
    local rps p50 p99 p999 errpct total
    rps=$(awk '/Requests\/sec:/ {printf "%.2f", $2; exit}' "$f")
    # `hey` reports response times in seconds (e.g. "50% in 0.0023 secs")
    p50=$(awk '/  50% in/ {printf "%.3f", $3*1000; exit}' "$f")
    p99=$(awk '/  99% in/ {printf "%.3f", $3*1000; exit}' "$f")
    p999=$(awk '/  99.9% in/ {printf "%.3f", $3*1000; exit}' "$f")
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
    printf "%s\t%s\t%s\t%s\n" "${rps:-0}" "${p50:-0}" "${p99:-0}" "${p999:-0}"
    echo "$errpct"
}

for i in "${!LEVELS_PCT[@]}"; do
    pct=${LEVELS_PCT[$i]}
    qps=$(awk -v b="$BASELINE" -v p="$pct" 'BEGIN {printf "%.0f", b*p/100}')
    echo
    echo "================ level $((i+1))/9 : ${pct}% (${qps} qps per algo) ================"

    t_start=$(date +%s)
    hey_remote "$CLIENT_PREQUAL" "-z ${DURATION}s -q $qps -c $CONC http://$PREQUAL_LB:$LB_PORT/" \
        > "$OUT/prequal_${i}.txt" 2>&1 &
    PID_P=$!
    hey_remote "$CLIENT_RR" "-z ${DURATION}s -q $qps -c $CONC http://$RR_LB:$LB_PORT/" \
        > "$OUT/rr_${i}.txt" 2>&1 &
    PID_R=$!
    wait $PID_P
    wait $PID_R
    t_end=$(date +%s)

    echo "prequal,${pct},${qps},${t_start},${t_end}" >> "$WINDOWS"
    echo "roundrobin,${pct},${qps},${t_start},${t_end}" >> "$WINDOWS"

    {
        read -r line; read -r ep
        printf "prequal\t%s\t%s\t%s\t%s\n" "$pct" "$qps" "$line" "$ep"
    } < <(parse_hey "$OUT/prequal_${i}.txt") >> "$SUMMARY"
    {
        read -r line; read -r ep
        printf "roundrobin\t%s\t%s\t%s\t%s\n" "$pct" "$qps" "$line" "$ep"
    } < <(parse_hey "$OUT/rr_${i}.txt") >> "$SUMMARY"

    awk -F'\t' -v i=$((i+1)) 'NR==1 {next}
        $1=="prequal" && $2==prev {pre=$0}
        $1=="roundrobin" && $2==prev {rr=$0}
        END {
            print "  prequal    -> "pre;
            print "  roundrobin -> "rr;
        }' prev="$pct" "$SUMMARY" || true

    if [ "$i" -lt $((${#LEVELS_PCT[@]} - 1)) ]; then
        echo "Pausing ${GAP}s..."
        sleep "$GAP"
    fi
done

echo
echo "Done. Results in $OUT"
echo "  windows.csv  -> $WINDOWS"
echo "  summary.tsv  -> $SUMMARY"
echo
echo "Render figure with:"
echo "  python3 cloudlab/plot_figure6.py $OUT --prom http://${OBSERVER_HOSTS[0]}:9090"

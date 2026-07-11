#!/bin/bash
# Local Docker debugging helper for Prequal.
#
# Topology (matches docker-compose.yml):
#   lb-prequal-1 : http://localhost:10080
#   lb-prequal-2 : http://localhost:10081
#   lb-rr-1      : http://localhost:20080
#   lb-rr-2      : http://localhost:20081
#   server1..8   : in-network, behind the LBs
#
# Subcommands:
#   up                          start LBs + backends (skips prom/grafana)
#   up-monitoring               also start prometheus + grafana
#   down                        stop everything
#   logs [lb-prequal-1]         tail one LB's stdout
#
#   --- one-shot inspection ---
#   dump [lb]                   pretty JSON snapshot of the pool
#   table [lb]                  one-line-per-entry table (the most useful view)
#   servers [lb]                per-server last-known RIF/health
#
#   --- step-by-step ---
#   step [lb]                   POOL  -->  send 1 query (print server)  -->  POOL
#   trace N [lb] [sleep]        repeat step N times, sleep s between (default 0.5s)
#   diff [lb]                   snapshot, wait for ENTER, snapshot again, show what changed
#
#   --- comparison ---
#   load   [qps] [dur] [lb]     send sustained load to one LB and print latency stats
#   compare [qps] [dur]         identical load against prequal vs rr, side by side
#
# All commands accept an optional LB name (lb-prequal-1 by default).

set -e

# map LB container name -> host port
lb_port() {
    case "$1" in
        lb-prequal-1) echo 10080 ;;
        lb-prequal-2) echo 10081 ;;
        lb-rr-1)      echo 20080 ;;
        lb-rr-2)      echo 20081 ;;
        *) echo "unknown LB: $1 (use lb-prequal-1|lb-prequal-2|lb-rr-1|lb-rr-2)" >&2; exit 1 ;;
    esac
}

lb_url() {
    local lb=${1:-lb-prequal-1}
    echo "http://localhost:$(lb_port "$lb")"
}

require_jq() { command -v jq >/dev/null || { echo "install jq first: brew install jq" >&2; exit 1; }; }

# Pretty one-line-per-entry table. Highlights duplicates (the herd bug):
# if the same server_id shows up multiple times, all its rows are flagged.
print_table() {
    require_jq
    local url=$1
    local body
    body=$(curl -s "$url/debug/pool")
    if ! echo "$body" | jq -e . >/dev/null 2>&1; then
        echo "  /debug/pool did not return JSON. Raw response:"
        echo "$body" | head -c 400
        echo
        echo "  -> rebuild the LB image: ./debug-local.sh down && ./debug-local.sh up"
        return
    fi
    echo "$body" | jq -r '
        . as $s |
        "=== pool: \(.pool_size)/\(.pool_cap)   hot_thr=\(.hot_threshold_rif)   hot=\(.num_hot) cold=\(.num_cold)   breuse=\(.breuse_now)   qrif=\(.qrif) rprobe=\(.rprobe) rremove=\(.rremove) ===",
        "  idx  server     RIF  lat_ms  age_ms  uses  hot?",
        (.pool | to_entries[] | "  \(.key)    \(.value.server_id)   \(.value.rif)    \(.value.latency_ms)      \(.value.age_ms)     \(.value.remaining_uses)     \(if .value.rif > $s.hot_threshold_rif then "H" else "c" end)")
    '
}

# Send one query and capture which backend handled it (X-Served-By header).
send_one() {
    local url=$1
    local code body served_by total
    local resp
    resp=$(curl -s -o /dev/null -D - -w "\nHTTP_CODE=%{http_code}\nTOTAL=%{time_total}\n" "$url/")
    code=$(echo "$resp" | awk -F= '/^HTTP_CODE=/{print $2}')
    total=$(echo "$resp" | awk -F= '/^TOTAL=/{print $2}')
    served_by=$(echo "$resp" | awk 'BEGIN{IGNORECASE=1} /^X-Served-By:/ {gsub(/\r/, ""); print $2}')
    echo "  HTTP $code  served_by=${served_by:-?}  latency=${total}s"
}

# One step: pool before, send query, pool after.
do_step() {
    local lb=${1:-lb-prequal-1}
    local url
    url=$(lb_url "$lb")
    echo "--- STEP @ $(date +%H:%M:%S) on $lb ---"
    echo "BEFORE:"
    print_table "$url"
    echo "QUERY:"
    send_one "$url"
    echo "AFTER:"
    print_table "$url"
    echo
}

# Sustained load. Prefers hey; falls back to xargs+curl.
gen_load() {
    local url=$1 qps=${2:-50} dur=${3:-30}
    local total=$((qps * dur))
    if command -v hey >/dev/null 2>&1; then
        hey -n "$total" -q "$qps" -c 20 "$url/"
    else
        echo "(hey not installed; using xargs+curl, less precise pacing)"
        seq 1 "$total" | xargs -n1 -P 20 -I{} \
            curl -s -o /dev/null -w "%{time_total}\n" "$url/" \
            | awk '{ s+=$1; n++; t[n]=$1 } END {
                if (n==0) { print "no samples"; exit }
                asort(t);
                p50=t[int(n*0.5)]; p90=t[int(n*0.9)]; p99=t[int(n*0.99)];
                printf "n=%d  mean=%.4fs  p50=%.4fs  p90=%.4fs  p99=%.4fs  max=%.4fs\n",
                    n, s/n, p50, p90, p99, t[n]
            }'
    fi
}

case "${1:-help}" in
    up)
        docker compose up -d --build \
            lb-prequal-1 lb-prequal-2 lb-rr-1 lb-rr-2 \
            server1 server2 server3 server4 server5 server6 server7 server8
        echo
        echo "Up. Wait ~5s, then try:"
        echo "  ./debug-local.sh step           # send 1 query, see pool before/after"
        echo "  ./debug-local.sh trace 20 lb-prequal-1 1"
        echo "  ./debug-local.sh table          # one-shot pretty pool"
        ;;
    up-monitoring)
        docker compose up -d --build
        ;;
    down)
        docker compose down --remove-orphans
        ;;

    logs)
        docker logs -f "${2:-lb-prequal-1}"
        ;;

    dump)
        curl -s "$(lb_url "${2:-lb-prequal-1}")/debug/pool" | (command -v jq >/dev/null && jq . || cat)
        ;;
    table)
        print_table "$(lb_url "${2:-lb-prequal-1}")"
        ;;
    servers)
        require_jq
        curl -s "$(lb_url "${2:-lb-prequal-1}")/debug/pool" | jq '{
            server_last_known_rif, server_last_known_latency_ms, server_healthy
        }'
        ;;

    step)
        do_step "${2:-lb-prequal-1}"
        ;;
    trace)
        N=${2:-10}
        LB=${3:-lb-prequal-1}
        SLEEP=${4:-0.5}
        for i in $(seq 1 "$N"); do
            echo "########## TRACE $i / $N ##########"
            do_step "$LB"
            sleep "$SLEEP"
        done
        ;;
    diff)
        require_jq
        LB=${2:-lb-prequal-1}
        URL=$(lb_url "$LB")
        TMPA=$(mktemp); TMPB=$(mktemp)
        curl -s "$URL/debug/pool" > "$TMPA"
        echo "snapshot A taken. press ENTER for snapshot B..."
        read -r _
        curl -s "$URL/debug/pool" > "$TMPB"
        echo "--- diff (B vs A) ---"
        diff <(jq -S . "$TMPA") <(jq -S . "$TMPB") || true
        rm -f "$TMPA" "$TMPB"
        ;;

    load)
        gen_load "$(lb_url "${4:-lb-prequal-1}")" "${2:-50}" "${3:-30}"
        ;;
    compare)
        QPS=${2:-50}; DUR=${3:-30}
        echo "=== PREQUAL (lb-prequal-1) ==="
        gen_load "$(lb_url lb-prequal-1)" "$QPS" "$DUR"
        echo
        echo "=== ROUND ROBIN (lb-rr-1) ==="
        gen_load "$(lb_url lb-rr-1)" "$QPS" "$DUR"
        ;;

    build-bench)
        go build -o ./bench ./cmd/bench
        echo "built ./bench"
        ;;

    bench)
        # Usage: ./debug-local.sh bench [lb] [concurrency] [duration]
        # Example: ./debug-local.sh bench lb-prequal-1 80 30s
        LB=${2:-lb-prequal-1}
        C=${3:-80}
        D=${4:-30s}
        [ -x ./bench ] || go build -o ./bench ./cmd/bench
        URL=$(lb_url "$LB")
        ./bench -url "$URL/" -debug "$URL/debug/pool" -c "$C" -d "$D"
        ;;

    bench-compare)
        # Runs identical load against a prequal LB and a RR LB, back to back.
        # Usage: ./debug-local.sh bench-compare [concurrency] [duration]
        C=${2:-80}
        D=${3:-30s}
        [ -x ./bench ] || go build -o ./bench ./cmd/bench
        echo
        echo "############### PREQUAL (lb-prequal-1) ###############"
        ./bench -url "$(lb_url lb-prequal-1)/" -debug "$(lb_url lb-prequal-1)/debug/pool" -c "$C" -d "$D"
        echo
        echo "############### ROUND-ROBIN (lb-rr-1) ###############"
        ./bench -url "$(lb_url lb-rr-1)/" -c "$C" -d "$D"
        ;;

    help|--help|-h|*)
        sed -n '2,32p' "$0"
        ;;
esac

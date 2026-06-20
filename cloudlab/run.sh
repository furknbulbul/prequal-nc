#!/bin/bash
# Single entry point for the CloudLab Prequal experiment.
# Run subcommands from observer-1 (except `bootstrap`, which `deploy` ssh-fans).
#
# Usage:
#   ./run.sh deploy                                 install Go + build binaries on all nodes
#   ./run.sh status                                 show which nodes finished bootstrap
#   ./run.sh servers                                start backends on srv-*
#   ./run.sh lbs                                    start LBs (prequal + rr)
#   ./run.sh monitor                                start prom + grafana on observer-1
#   ./run.sh antagonist [N_VICTIMS=2] [CPU=1]       stress-ng cycles on first N servers
#   ./run.sh load [-q QPS] [-d SEC] [-c CONC] [-t TAG]
#   ./run.sh stop                                   kill everything
#
# Counts and ports (override via env if you want):
set -euo pipefail

: "${N_PREQUAL:=2}"
: "${N_RR:=2}"
: "${N_SERVER:=3}"
: "${N_CLIENT:=1}"
: "${N_OBSERVER:=1}"
: "${LB_PORT:=8080}"
: "${BACKEND_PORT:=8000}"
: "${REPO:=/local/repository}"
: "${BIN_LB:=$REPO/bin/lb}"
: "${BIN_BACKEND:=$REPO/bin/backend}"
: "${LOG_DIR:=$REPO/logs}"
: "${GO_VERSION:=1.24.2}"

HERE=$(dirname "$(readlink -f "$0")")

PREQUAL_LBS=(); for i in $(seq 1 "$N_PREQUAL"); do PREQUAL_LBS+=("lb-prequal-$i"); done
RR_LBS=();      for i in $(seq 1 "$N_RR");      do RR_LBS+=("lb-rr-$i"); done
ALL_LBS=("${PREQUAL_LBS[@]}" "${RR_LBS[@]}")
SERVERS=();     for i in $(seq 1 "$N_SERVER");  do SERVERS+=("srv-$i"); done
CLIENTS=();     for i in $(seq 1 "$N_CLIENT");  do CLIENTS+=("client-$i"); done
OBSERVERS=();   for i in $(seq 1 "$N_OBSERVER"); do OBSERVERS+=("observer-$i"); done
ALL_NODES=("${ALL_LBS[@]}" "${SERVERS[@]}" "${CLIENTS[@]}" "${OBSERVERS[@]}")

SSH() { ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$@"; }

backend_list() {
    local out=""
    for s in "${SERVERS[@]}"; do [[ -n $out ]] && out+=","; out+="${s}:${BACKEND_PORT}"; done
    echo "$out"
}

# ---------- subcommands ----------

cmd_bootstrap() {
    # Runs on a single remote node (invoked by `deploy`). Installs Go + builds.
    local marker=/var/lib/prequal-bootstrap.done
    [[ -f $marker ]] && { echo "already bootstrapped"; return 0; }

    case "$(uname -m)" in
        x86_64)  local arch=amd64 hey_url="https://hey-release.s3.us-east-2.amazonaws.com/hey_linux_amd64" ;;
        aarch64) local arch=arm64 hey_url="" ;;
        *) echo "unsupported arch $(uname -m)"; exit 1 ;;
    esac

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends build-essential ca-certificates curl git stress-ng

    if ! /usr/local/go/bin/go version 2>/dev/null | grep -q "go${GO_VERSION}"; then
        curl -fsSL -o /tmp/go.tgz "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz"
        rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz
        ln -sf /usr/local/go/bin/go /usr/local/bin/go
    fi

    cd "$REPO"
    /usr/local/bin/go build -o "$REPO/bin/lb"      ./cmd/server
    /usr/local/bin/go build -o "$REPO/bin/backend" ./backend

    if ! command -v hey >/dev/null 2>&1; then
        if [[ -n $hey_url ]]; then
            curl -fsSL -o /usr/local/bin/hey "$hey_url" && chmod +x /usr/local/bin/hey
        else
            GOBIN=/usr/local/bin /usr/local/bin/go install github.com/rakyll/hey@latest
        fi
    fi

    touch "$marker"
    echo "bootstrap done"
}

cmd_deploy() {
    echo "bootstrapping ${#ALL_NODES[@]} nodes..."
    local pids=()
    for h in "${ALL_NODES[@]}"; do
        ( SSH "$h" "sudo bash $HERE/run.sh bootstrap" > "/tmp/bootstrap-$h.log" 2>&1 \
          && echo "  [$h] ok" || echo "  [$h] FAIL (see /tmp/bootstrap-$h.log)" ) &
        pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p" || true; done
}

cmd_status() {
    for h in "${ALL_NODES[@]}"; do
        if SSH "$h" "test -f /var/lib/prequal-bootstrap.done" 2>/dev/null; then
            echo "  [$h] ready"
        else
            echo "  [$h] not-ready"
        fi
    done
}

cmd_servers() {
    for h in "${SERVERS[@]}"; do
        SSH "$h" "mkdir -p $LOG_DIR; pkill -f '^$BIN_BACKEND' 2>/dev/null || true; \
            nohup env PORT=$BACKEND_PORT SERVER_ID=$h CPU_LOAD=0 \
                $BIN_BACKEND > $LOG_DIR/backend.log 2>&1 &" &
    done
    wait
    echo "backends up: ${SERVERS[*]} on :$BACKEND_PORT"
}

cmd_lbs() {
    local backends; backends=$(backend_list)
    echo "BACKEND_SERVERS=$backends"
    for h in "${PREQUAL_LBS[@]}"; do
        SSH "$h" "mkdir -p $LOG_DIR; pkill -f '^$BIN_LB' 2>/dev/null || true; \
            nohup env BACKEND_SERVERS='$backends' LB_ALGORITHM=prequal \
                $BIN_LB -port $LB_PORT > $LOG_DIR/lb.log 2>&1 &" &
    done
    for h in "${RR_LBS[@]}"; do
        SSH "$h" "mkdir -p $LOG_DIR; pkill -f '^$BIN_LB' 2>/dev/null || true; \
            nohup env BACKEND_SERVERS='$backends' LB_ALGORITHM=roundrobin \
                $BIN_LB -port $LB_PORT > $LOG_DIR/lb.log 2>&1 &" &
    done
    wait
    echo "LBs up — prequal: ${PREQUAL_LBS[*]} | rr: ${RR_LBS[*]}"
}

cmd_monitor() {
    local obs=${OBSERVERS[0]}
    if [[ $(hostname -s) != "$obs" ]]; then
        SSH "$obs" "bash $HERE/run.sh monitor"
        return
    fi
    command -v docker >/dev/null 2>&1 || curl -fsSL https://get.docker.com | sh
    docker rm -f prom grafana >/dev/null 2>&1 || true
    docker run -d --name prom --net=host \
        -v "$HERE/prometheus.yml:/etc/prometheus/prometheus.yml" prom/prometheus
    docker run -d --name grafana --net=host \
        -e GF_SECURITY_ADMIN_PASSWORD=admin grafana/grafana
    echo "prom :9090 | grafana :3000 (admin/admin)"
}

cmd_antagonist() {
    local n=${1:-2} cpu=${2:-1}
    (( n > N_SERVER )) && n=$N_SERVER
    for i in $(seq 1 "$n"); do
        local h="srv-$i"
        SSH "$h" "mkdir -p $LOG_DIR; pkill -f stress-ng 2>/dev/null || true; \
            nohup bash -c 'while :; do stress-ng --cpu $cpu --timeout 60s >/dev/null 2>&1; sleep 30; done' \
                > $LOG_DIR/antagonist.log 2>&1 &" &
    done
    wait
    echo "antagonist running on first $n servers (cpu=$cpu)"
}

cmd_load() {
    local qps=400 dur=60 conc=50 tag; tag=$(date +%s)
    while getopts "q:d:c:t:" opt; do
        case $opt in q) qps=$OPTARG;; d) dur=$OPTARG;; c) conc=$OPTARG;; t) tag=$OPTARG;; esac
    done
    local client=${CLIENTS[0]}
    local per_p=$(( qps / N_PREQUAL )) per_r=$(( qps / N_RR ))
    local out="$HERE/results/$tag"; mkdir -p "$out"
    echo "tag=$tag qps_per_algo=$qps dur=${dur}s driver=$client"
    echo "  prequal: $N_PREQUAL × $per_p qps  | rr: $N_RR × $per_r qps"

    SSH "$client" "mkdir -p $LOG_DIR/$tag"
    local pids=()
    for lb in "${PREQUAL_LBS[@]}"; do
        SSH "$client" "hey -z ${dur}s -q $per_p -c $conc http://$lb:$LB_PORT/ > $LOG_DIR/$tag/$lb.txt 2>&1" &
        pids+=($!)
    done
    for lb in "${RR_LBS[@]}"; do
        SSH "$client" "hey -z ${dur}s -q $per_r -c $conc http://$lb:$LB_PORT/ > $LOG_DIR/$tag/$lb.txt 2>&1" &
        pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p"; done

    {
        printf "%-18s %-10s %-10s %-10s\n" "lb" "rps" "p50" "p99"
        for lb in "${ALL_LBS[@]}"; do
            SSH "$client" "cat $LOG_DIR/$tag/$lb.txt" > "$out/$lb.txt"
            local rps p50 p99
            rps=$(grep "Requests/sec:" "$out/$lb.txt" | awk '{print $2}')
            p50=$(awk '/50% in/ {print $3; exit}' "$out/$lb.txt")
            p99=$(awk '/99% in/ {print $3; exit}' "$out/$lb.txt")
            printf "%-18s %-10s %-10s %-10s\n" "$lb" "${rps:-?}" "${p50:-?}" "${p99:-?}"
        done
    } | tee "$out/summary.txt"
    echo "raw results: $out"
}

cmd_stop() {
    for h in "${ALL_LBS[@]}";  do SSH "$h" "pkill -f '^$BIN_LB' 2>/dev/null || true" & done
    for h in "${SERVERS[@]}";  do SSH "$h" "pkill -f '^$BIN_BACKEND' 2>/dev/null || true; pkill -f stress-ng 2>/dev/null || true" & done
    for h in "${CLIENTS[@]}";  do SSH "$h" "pkill -f 'hey ' 2>/dev/null || true" & done
    wait
    echo "stopped"
}

usage() {
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

cmd=${1:-}; shift || true
case "$cmd" in
    bootstrap)  cmd_bootstrap  "$@" ;;
    deploy)     cmd_deploy     "$@" ;;
    status)     cmd_status     "$@" ;;
    servers)    cmd_servers    "$@" ;;
    lbs)        cmd_lbs        "$@" ;;
    monitor)    cmd_monitor    "$@" ;;
    antagonist) cmd_antagonist "$@" ;;
    load)       cmd_load       "$@" ;;
    stop)       cmd_stop       "$@" ;;
    ""|-h|--help|help) usage ;;
    *) echo "unknown command: $cmd"; usage; exit 1 ;;
esac

#!/bin/bash
# CloudLab distributed deployment orchestrator for the Prequal Figure 6 testbed.
#
# Run from your laptop. Reads cloudlab/hosts.sh for SSH hostnames.
#
# Usage:
#   cp cloudlab/hosts.sh.example cloudlab/hosts.sh   # then edit
#   ./cloudlab/deploy.sh bootstrap     # install docker on every node
#   ./cloudlab/deploy.sh sync          # rsync this repo to every node
#   ./cloudlab/deploy.sh build         # build LB + backend docker images
#   ./cloudlab/deploy.sh run           # start backends, LBs, observer, clients
#   ./cloudlab/deploy.sh antagonist    # start stress-ng on configured srv nodes
#   ./cloudlab/deploy.sh stop-antagonist
#   ./cloudlab/deploy.sh verify        # health-check every component
#   ./cloudlab/deploy.sh teardown      # stop + remove all containers
#   ./cloudlab/deploy.sh all           # bootstrap; sync; build; run; verify

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
HOSTS_FILE="$SCRIPT_DIR/hosts.sh"

if [ ! -f "$HOSTS_FILE" ]; then
    echo "Error: $HOSTS_FILE not found."
    echo "Edit hosts.sh and fill in your CloudLab hostnames."
    exit 1
fi
# shellcheck disable=SC1090
source "$HOSTS_FILE"

: "${BACKEND_PORT:=80}"
: "${LB_PORT:=8080}"
: "${NODE_EXPORTER_PORT:=9100}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new \
          -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR)

ssh_run() {
    local host=$1; shift
    ssh "${SSH_OPTS[@]}" "$CLOUDLAB_USER@$host" "$@"
}

scp_to() {
    local src=$1 host=$2 dst=$3
    scp "${SSH_OPTS[@]}" "$src" "$CLOUDLAB_USER@$host:$dst"
}

rsync_repo() {
    local host=$1
    rsync -az --delete \
        --exclude=.git --exclude=results --exclude=.idea --exclude=.DS_Store \
        -e "ssh ${SSH_OPTS[*]}" \
        "$REPO_DIR/" "$CLOUDLAB_USER@$host:loadbalancer/"
}

all_hosts() {
    printf "%s\n" \
        "${PREQUAL_HOSTS[@]}" \
        "${RR_HOSTS[@]}" \
        "${SRV_HOSTS[@]}" \
        "${CLIENT_HOSTS[@]}" \
        "${OBSERVER_HOSTS[@]}"
}

tag() { sed -u "s|^|[$1] |"; }

pwait() {
    local pid status=0
    for pid in "$@"; do
        if ! wait "$pid"; then status=1; fi
    done
    return "$status"
}

#
# Subcommands
#

cmd_bootstrap() {
    local pids=()
    for h in $(all_hosts); do
        (
            echo "[$h] bootstrap starting"
            ssh_run "$h" "
                set -e
                sudo apt-get update -qq
                sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                    docker.io git rsync curl stress-ng
                sudo systemctl enable --now docker
            " 2>&1 | tag "$h"
            echo "[$h] bootstrap done"
        ) &
        pids+=($!)
    done
    pwait "${pids[@]}"
}

cmd_sync() {
    local pids=()
    for h in $(all_hosts); do
        (
            echo "[$h] sync starting"
            rsync_repo "$h" 2>&1 | tag "$h"
            echo "[$h] sync done"
        ) &
        pids+=($!)
    done
    pwait "${pids[@]}"
}

cmd_build() {
    local pids=()
    for h in "${SRV_HOSTS[@]}"; do
        (
            echo "[$h] build backend"
            ssh_run "$h" "cd loadbalancer && sudo docker build -q -t prequal-backend ./backend" 2>&1 | tag "$h"
        ) &
        pids+=($!)
    done
    for h in "${PREQUAL_HOSTS[@]}" "${RR_HOSTS[@]}"; do
        (
            echo "[$h] build LB"
            ssh_run "$h" "cd loadbalancer && sudo docker build -q -t prequal-lb ." 2>&1 | tag "$h"
        ) &
        pids+=($!)
    done
    pwait "${pids[@]}"
}

cmd_run_backends() {
    local pids=()
    for i in "${!SRV_HOSTS[@]}"; do
        local h=${SRV_HOSTS[$i]}
        local idx=$((i + 1))
        local load=${SRV_CPU_LOADS[$i]:-0}
        (
            echo "[$h] run backend srv-$idx (CPU_LOAD=$load)"
            ssh_run "$h" "
                sudo docker rm -f backend 2>/dev/null || true
                sudo docker run -d --restart=unless-stopped --name backend \
                    --network host \
                    -e SERVER_ID=srv-$idx -e PORT=$BACKEND_PORT -e CPU_LOAD=$load \
                    prequal-backend
            " 2>&1 | tag "$h"
        ) &
        pids+=($!)
    done
    pwait "${pids[@]}"
}

cmd_run_node_exporters() {
    # node_exporter on every srv-* so the observer can scrape real CPU%
    local pids=()
    for h in "${SRV_HOSTS[@]}"; do
        (
            echo "[$h] run node_exporter"
            ssh_run "$h" "
                sudo docker rm -f node_exporter 2>/dev/null || true
                sudo docker run -d --restart=unless-stopped --name node_exporter \
                    --network host --pid host \
                    -v /:/host:ro,rslave \
                    prom/node-exporter \
                    --path.rootfs=/host \
                    --web.listen-address=:$NODE_EXPORTER_PORT
            " 2>&1 | tag "$h"
        ) &
        pids+=($!)
    done
    pwait "${pids[@]}"
}

cmd_run_lbs() {
    local pids=()
    for h in "${PREQUAL_HOSTS[@]}"; do
        (
            echo "[$h] run prequal LB"
            ssh_run "$h" "
                sudo docker rm -f lb 2>/dev/null || true
                sudo docker run -d --restart=unless-stopped --name lb \
                    --network host \
                    -e LB_ALGORITHM=prequal -e BACKEND_SERVERS='$BACKENDS' \
                    prequal-lb
            " 2>&1 | tag "$h"
        ) &
        pids+=($!)
    done
    for h in "${RR_HOSTS[@]}"; do
        (
            echo "[$h] run RR LB"
            ssh_run "$h" "
                sudo docker rm -f lb 2>/dev/null || true
                sudo docker run -d --restart=unless-stopped --name lb \
                    --network host \
                    -e LB_ALGORITHM=roundrobin -e BACKEND_SERVERS='$BACKENDS' \
                    prequal-lb
            " 2>&1 | tag "$h"
        ) &
        pids+=($!)
    done
    pwait "${pids[@]}"
}

cmd_install_clients() {
    # Install upstream Go + hey on each client. Ubuntu's golang-go is too old.
    local GO_VER=1.24.0
    local pids=()
    for h in "${CLIENT_HOSTS[@]}"; do
        (
            echo "[$h] install Go ${GO_VER} + hey"
            ssh_run "$h" "
                set -e
                case \"\$(uname -m)\" in
                    x86_64)  GO_ARCH=amd64 ;;
                    aarch64) GO_ARCH=arm64 ;;
                    *) echo 'unknown arch: '\$(uname -m); exit 1 ;;
                esac
                if ! /usr/local/go/bin/go version 2>/dev/null | grep -q 'go${GO_VER}'; then
                    curl -sSLO https://go.dev/dl/go${GO_VER}.linux-\${GO_ARCH}.tar.gz
                    sudo rm -rf /usr/local/go
                    sudo tar -C /usr/local -xzf go${GO_VER}.linux-\${GO_ARCH}.tar.gz
                    rm -f go${GO_VER}.linux-\${GO_ARCH}.tar.gz
                fi
                export PATH=/usr/local/go/bin:\$HOME/bin:\$PATH
                GOBIN=\$HOME/bin /usr/local/go/bin/go install github.com/rakyll/hey@latest
                grep -q '/usr/local/go/bin' ~/.bashrc || \
                    echo 'export PATH=/usr/local/go/bin:\$HOME/bin:\$PATH' >> ~/.bashrc
            " 2>&1 | tag "$h"
        ) &
        pids+=($!)
    done
    pwait "${pids[@]}"
}

cmd_run_observer() {
    local cfg
    cfg=$(mktemp)
    {
        echo "global:"
        echo "  scrape_interval: 5s"
        echo "  evaluation_interval: 5s"
        echo "scrape_configs:"
        echo "  - job_name: 'lb-prequal'"
        echo "    metrics_path: /metrics"
        echo "    static_configs:"
        echo "      - targets:"
        for i in $(seq 1 "${#PREQUAL_HOSTS[@]}"); do
            echo "          - lb-prequal-$i:$LB_PORT"
        done
        echo "        labels:"
        echo "          algorithm: prequal"
        echo "  - job_name: 'lb-rr'"
        echo "    metrics_path: /metrics"
        echo "    static_configs:"
        echo "      - targets:"
        for i in $(seq 1 "${#RR_HOSTS[@]}"); do
            echo "          - lb-rr-$i:$LB_PORT"
        done
        echo "        labels:"
        echo "          algorithm: roundrobin"
        echo "  - job_name: 'node'"
        echo "    static_configs:"
        echo "      - targets:"
        for i in $(seq 1 "${#SRV_HOSTS[@]}"); do
            echo "          - srv-$i:$NODE_EXPORTER_PORT"
        done
    } > "$cfg"

    local pids=()
    for h in "${OBSERVER_HOSTS[@]}"; do
        (
            echo "[$h] push prometheus.yml + start prometheus + grafana"
            scp_to "$cfg" "$h" "/tmp/prometheus.yml" 2>&1 | tag "$h"
            ssh_run "$h" "
                set -e
                sudo mkdir -p /etc/prometheus
                sudo mv /tmp/prometheus.yml /etc/prometheus/prometheus.yml
                sudo chmod 644 /etc/prometheus/prometheus.yml
                sudo docker pull -q prom/prometheus
                sudo docker pull -q grafana/grafana
                sudo docker rm -f prometheus grafana 2>/dev/null || true
                sudo docker run -d --restart=unless-stopped --name prometheus \
                    --network host \
                    -v /etc/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro \
                    prom/prometheus
                sudo docker run -d --restart=unless-stopped --name grafana \
                    --network host \
                    -e GF_SECURITY_ADMIN_USER=admin -e GF_SECURITY_ADMIN_PASSWORD=admin \
                    grafana/grafana
            " 2>&1 | tag "$h"
        ) &
        pids+=($!)
    done
    pwait "${pids[@]}"
    rm -f "$cfg"
}

cmd_run() {
    cmd_run_backends
    cmd_run_node_exporters
    cmd_run_lbs
    cmd_install_clients
    cmd_run_observer
}

cmd_antagonist() {
    # Background stress-ng on each srv-* per SRV_ANTAGONIST_CPUS.
    # Cycles 60s on / 30s off so contention is bursty, like the paper's
    # "unpredictable time-varying antagonist load".
    local pids=()
    for i in "${!SRV_HOSTS[@]}"; do
        local h=${SRV_HOSTS[$i]}
        local n=${SRV_ANTAGONIST_CPUS[$i]:-0}
        if [ "$n" -eq 0 ]; then continue; fi
        (
            echo "[$h] antagonist start (cpu=$n)"
            ssh_run "$h" "
                sudo docker rm -f antagonist 2>/dev/null || true
                sudo docker run -d --restart=unless-stopped --name antagonist \
                    --network host \
                    --entrypoint /bin/sh \
                    alpine:3 \
                    -c 'apk add --no-cache stress-ng >/dev/null && \
                        while :; do stress-ng --cpu $n --timeout 60s >/dev/null 2>&1; sleep 30; done'
            " 2>&1 | tag "$h"
        ) &
        pids+=($!)
    done
    pwait "${pids[@]}"
}

cmd_stop_antagonist() {
    local pids=()
    for h in "${SRV_HOSTS[@]}"; do
        (
            ssh_run "$h" "sudo docker rm -f antagonist 2>/dev/null || true" 2>&1 | tag "$h"
        ) &
        pids+=($!)
    done
    pwait "${pids[@]}"
}

check_host() {
    local h=$1 url=$2 label=$3
    if ssh_run "$h" "curl -fsS '$url' -o /dev/null"; then
        echo "  $h $label OK"
    else
        echo "  $h $label FAILED"
    fi
}

cmd_verify() {
    local pids=()
    echo "--- Backends ---"
    for h in "${SRV_HOSTS[@]}"; do
        check_host "$h" "http://localhost:$BACKEND_PORT/health" backend &
        pids+=($!)
    done
    echo "--- Prequal LBs ---"
    for h in "${PREQUAL_HOSTS[@]}"; do
        check_host "$h" "http://localhost:$LB_PORT/" prequal-lb &
        pids+=($!)
    done
    echo "--- RR LBs ---"
    for h in "${RR_HOSTS[@]}"; do
        check_host "$h" "http://localhost:$LB_PORT/" rr-lb &
        pids+=($!)
    done
    echo "--- node_exporters ---"
    for h in "${SRV_HOSTS[@]}"; do
        check_host "$h" "http://localhost:$NODE_EXPORTER_PORT/metrics" node_exporter &
        pids+=($!)
    done
    echo "--- Observer ---"
    for h in "${OBSERVER_HOSTS[@]}"; do
        check_host "$h" "http://localhost:9090/-/ready"   prometheus &
        pids+=($!)
        check_host "$h" "http://localhost:3000/api/health" grafana &
        pids+=($!)
    done
    pwait "${pids[@]}"
}

cmd_teardown() {
    local pids=()
    for h in $(all_hosts); do
        (
            echo "[$h] stop containers"
            ssh_run "$h" "sudo docker ps -aq | xargs -r sudo docker rm -f" 2>&1 | tag "$h" || true
        ) &
        pids+=($!)
    done
    pwait "${pids[@]}" || true
}

case "${1:-help}" in
    bootstrap)        cmd_bootstrap ;;
    sync)             cmd_sync ;;
    build)            cmd_build ;;
    run)              cmd_run ;;
    antagonist)       cmd_antagonist ;;
    stop-antagonist)  cmd_stop_antagonist ;;
    verify)           cmd_verify ;;
    teardown)         cmd_teardown ;;
    all)
        cmd_bootstrap
        cmd_sync
        cmd_build
        cmd_run
        echo "Waiting 10s for containers to settle..."
        sleep 10
        cmd_verify
        ;;
    help|--help|-h|*)
        sed -n '2,18p' "$0"
        ;;
esac

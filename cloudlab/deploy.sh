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
#   ./cloudlab/deploy.sh run-lbs       # restart just the LB containers
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
                # Open-loop overload churns tens of thousands of short-lived
                # connections: allow fast source-port reuse and widen the
                # ephemeral range so port exhaustion doesn't fake errors.
                printf 'net.ipv4.tcp_tw_reuse = 1\nnet.ipv4.ip_local_port_range = 1024 64999\nnet.core.somaxconn = 8192\n' \
                    | sudo tee /etc/sysctl.d/99-prequal.conf >/dev/null
                # Apply only our file: 'sysctl --system' re-runs Ubuntu's
                # stock sysctl files too, some of which fail on this kernel
                # with harmless-but-noisy "Invalid argument" warnings.
                sudo sysctl -p /etc/sysctl.d/99-prequal.conf >/dev/null
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
        local phase=${SRV_ANTAGONIST_PHASES[$i]:-0}
        local ant_cores=${ANTAGONIST_CORES:-6}
        (
            echo "[$h] run backend srv-$idx (CPU_LOAD=$load ANTAGONIST_PHASE=$phase ANTAGONIST_CORES=$ant_cores)"
            ssh_run "$h" "
                sudo docker rm -f backend 2>/dev/null || true
                sudo docker run -d --restart=unless-stopped --name backend \
                    --network host --ulimit nofile=1048576:1048576 \
                    -e SERVER_ID=srv-$idx -e PORT=$BACKEND_PORT -e CPU_LOAD=$load \
                    -e ANTAGONIST_PHASE=$phase -e ANTAGONIST_CORES=$ant_cores \
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
    # LB observability + probe-mode knobs. All optional; defaults preserve
    # perf-mode behaviour (no metrics, no pick log, per-query probes).
    local lb_metrics="${LB_METRICS:-0}"
    local lb_pick_log="${LB_PICK_LOG:-0}"
    local lb_probe_mode="${LB_PROBE_MODE:-per_query}"
    local lb_probe_interval_ms="${LB_PROBE_INTERVAL_MS:-1000}"
    # Paper baseline: 3 probes per query. Lower (e.g. 1.5) if the Prequal
    # LB node itself saturates at the top ramp levels.
    local lb_rprobe="${LB_RPROBE:-3}"
    # Query deadline in ms, enforced by BOTH LBs (the paper's 5s deadline).
    local lb_deadline_ms="${LB_FORWARD_TIMEOUT_MS:-5000}"
    local pids=()
    for h in "${PREQUAL_HOSTS[@]}"; do
        (
            echo "[$h] run prequal LB (metrics=$lb_metrics picklog=$lb_pick_log probe=$lb_probe_mode/$lb_probe_interval_ms ms rprobe=$lb_rprobe deadline=${lb_deadline_ms}ms)"
            ssh_run "$h" "
                sudo docker rm -f lb 2>/dev/null || true
                sudo docker run -d --restart=unless-stopped --name lb \
                    --network host --ulimit nofile=1048576:1048576 \
                    -e LB_ALGORITHM=prequal -e BACKEND_SERVERS='$BACKENDS' \
                    -e LB_METRICS=$lb_metrics -e LB_PICK_LOG=$lb_pick_log \
                    -e LB_PROBE_MODE=$lb_probe_mode -e LB_PROBE_INTERVAL_MS=$lb_probe_interval_ms \
                    -e LB_RPROBE=$lb_rprobe -e LB_FORWARD_TIMEOUT_MS=$lb_deadline_ms \
                    prequal-lb
            " 2>&1 | tag "$h"
        ) &
        pids+=($!)
    done
    for h in "${RR_HOSTS[@]}"; do
        (
            echo "[$h] run RR LB (metrics=$lb_metrics picklog=$lb_pick_log deadline=${lb_deadline_ms}ms)"
            ssh_run "$h" "
                sudo docker rm -f lb 2>/dev/null || true
                sudo docker run -d --restart=unless-stopped --name lb \
                    --network host --ulimit nofile=1048576:1048576 \
                    -e LB_ALGORITHM=roundrobin -e BACKEND_SERVERS='$BACKENDS' \
                    -e LB_METRICS=$lb_metrics -e LB_PICK_LOG=$lb_pick_log \
                    -e LB_FORWARD_TIMEOUT_MS=$lb_deadline_ms \
                    prequal-lb
            " 2>&1 | tag "$h"
        ) &
        pids+=($!)
    done
    pwait "${pids[@]}"
}

cmd_install_clients() {
    # Install upstream Go + vegeta on each client. vegeta is an OPEN-LOOP
    # generator (constant arrival rate regardless of completions), which the
    # Figure 6 ramp requires; hey is closed-loop and self-throttles under
    # overload. Ubuntu's golang-go is too old.
    local GO_VER=1.24.0
    local pids=()
    for h in "${CLIENT_HOSTS[@]}"; do
        (
            echo "[$h] install Go ${GO_VER} + vegeta"
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
                GOBIN=\$HOME/bin /usr/local/go/bin/go install github.com/tsenart/vegeta/v12@latest
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
        # Serving-process CPU (excludes the antagonist) for Figure 6(c).
        echo "  - job_name: 'backend'"
        echo "    metrics_path: /metrics"
        echo "    static_configs:"
        echo "      - targets:"
        for i in $(seq 1 "${#SRV_HOSTS[@]}"); do
            echo "          - srv-$i:$BACKEND_PORT"
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
    run-lbs)          cmd_run_lbs ;;
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

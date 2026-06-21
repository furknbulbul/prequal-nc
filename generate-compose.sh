#!/bin/bash

set -e

print_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Generate docker-compose.yml and config/prometheus/prometheus.yml for
N_SERVERS backends, N_LBS prequal load balancers and N_LBS round-robin
load balancers. Each LB instance plays the role of a "client replica"
from the paper testbed.

OPTIONS:
    -s, --servers N        Number of backend server replicas (default: 10)
    -l, --lbs N            Number of LB instances of EACH type (default: 10)
    -h, --help             Show this help

PORT LAYOUT:
    Prequal LBs:   10080..10080+N-1
    RR LBs:        20080..20080+N-1
    Prometheus:    9090
    Grafana:       3001

ANTAGONIST LOAD:
    Roughly 2/3 of backends get CPU_LOAD=60 (contended), 1/3 get 0
    (clean), matching the paper's heterogeneous antagonist setup.

EXAMPLE:
    $0 --servers 10 --lbs 10
    docker-compose up --build -d
EOF
}

N_SERVERS=10
N_LBS=10

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--servers) N_SERVERS="$2"; shift 2 ;;
        -l|--lbs)     N_LBS="$2";     shift 2 ;;
        -h|--help)    print_usage; exit 0 ;;
        *) echo "Unknown option: $1"; print_usage; exit 1 ;;
    esac
done

if ! [[ "$N_SERVERS" =~ ^[0-9]+$ ]] || [ "$N_SERVERS" -lt 1 ]; then
    echo "Error: --servers must be a positive integer"; exit 1
fi
if ! [[ "$N_LBS" =~ ^[0-9]+$ ]] || [ "$N_LBS" -lt 1 ]; then
    echo "Error: --lbs must be a positive integer"; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$SCRIPT_DIR/docker-compose.yml"
PROM="$SCRIPT_DIR/config/prometheus/prometheus.yml"

BACKENDS=""
for i in $(seq 1 "$N_SERVERS"); do
    if [ -z "$BACKENDS" ]; then
        BACKENDS="server${i}:80"
    else
        BACKENDS="${BACKENDS},server${i}:80"
    fi
done

echo "Generating $COMPOSE: $N_SERVERS servers, $N_LBS prequal LBs, $N_LBS RR LBs"

{
    echo "services:"
    echo ""

    for i in $(seq 1 "$N_LBS"); do
        port=$((10080 + i - 1))
        echo "  lb-prequal-${i}:"
        echo "    build: ."
        echo "    container_name: lb-prequal-${i}"
        echo "    ports:"
        echo "      - \"${port}:8080\""
        echo "    networks:"
        echo "      - loadbalancer-net"
        echo "    environment:"
        echo "      - BACKEND_SERVERS=${BACKENDS}"
        echo "      - LB_ALGORITHM=prequal"
        echo "    depends_on:"
        for j in $(seq 1 "$N_SERVERS"); do
            echo "      - server${j}"
        done
        echo ""
    done

    for i in $(seq 1 "$N_LBS"); do
        port=$((20080 + i - 1))
        echo "  lb-rr-${i}:"
        echo "    build: ."
        echo "    container_name: lb-rr-${i}"
        echo "    ports:"
        echo "      - \"${port}:8080\""
        echo "    networks:"
        echo "      - loadbalancer-net"
        echo "    environment:"
        echo "      - BACKEND_SERVERS=${BACKENDS}"
        echo "      - LB_ALGORITHM=roundrobin"
        echo "    depends_on:"
        for j in $(seq 1 "$N_SERVERS"); do
            echo "      - server${j}"
        done
        echo ""
    done

    for i in $(seq 1 "$N_SERVERS"); do
        if [ $((i % 3)) -eq 0 ]; then
            cpu_load=0
        else
            cpu_load=60
        fi
        echo "  server${i}:"
        echo "    build: ./backend"
        echo "    container_name: server${i}"
        echo "    networks:"
        echo "      - loadbalancer-net"
        echo "    environment:"
        echo "      - SERVER_ID=server${i}"
        echo "      - PORT=80"
        echo "      - CPU_LOAD=${cpu_load}"
        echo "    cpus: 1.0"
        echo ""
    done

    cat << 'EOF'
  prometheus:
    image: prom/prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./config/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml
    networks:
      - loadbalancer-net

  grafana:
    image: grafana/grafana
    ports:
      - "3001:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_SECURITY_ADMIN_USER=admin
    volumes:
      - ./config/grafana/provisioning:/etc/grafana/provisioning
      - ./config/grafana/dashboards:/var/lib/grafana/dashboards
    networks:
      - loadbalancer-net
    depends_on:
      - prometheus

networks:
  loadbalancer-net:
    driver: bridge
EOF
} > "$COMPOSE"

echo "Generating $PROM"

TARGETS=""
for i in $(seq 1 "$N_LBS"); do
    [ -n "$TARGETS" ] && TARGETS="${TARGETS}, "
    TARGETS="${TARGETS}'lb-prequal-${i}:8080'"
done
for i in $(seq 1 "$N_LBS"); do
    TARGETS="${TARGETS}, 'lb-rr-${i}:8080'"
done

cat > "$PROM" << EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'loadbalancer'
    static_configs:
      - targets: [${TARGETS}]
    metrics_path: '/metrics'

  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
EOF

echo "Done. Next: docker-compose up --build -d"

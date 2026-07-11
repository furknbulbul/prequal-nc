# CloudLab deployment config — fill in the actual SSH hostnames from
# your experiment's List View. deploy.sh and experiment.sh source this file;
# it is plain bash, no parsing.

# Your CloudLab username (the "Login" column under Manage Account).
CLOUDLAB_USER=furkanb

# Public SSH hostnames per role. Order matters: the i-th entry of
# PREQUAL_HOSTS becomes "lb-prequal-i" inside the experiment.
PREQUAL_HOSTS=(
    ms0639.utah.cloudlab.us   # lb-prequal-1
)

RR_HOSTS=(
    ms0633.utah.cloudlab.us   # lb-rr-1
)

SRV_HOSTS=(
    ms0631.utah.cloudlab.us   # srv-1
    ms0623.utah.cloudlab.us   # srv-2
    ms0621.utah.cloudlab.us   # srv-3
    ms0602.utah.cloudlab.us   # srv-4
    ms0614.utah.cloudlab.us   # srv-5
    ms0630.utah.cloudlab.us   # srv-6
    ms0637.utah.cloudlab.us   # srv-7
    ms0619.utah.cloudlab.us   # srv-8
    ms0634.utah.cloudlab.us   # srv-9
    ms0628.utah.cloudlab.us   # srv-10
)

# Each client is pinned to one LB during the Figure 6 ramp:
#   client-1 drives PREQUAL_HOSTS[0]
#   client-2 drives RR_HOSTS[0]
CLIENT_HOSTS=(
    ms0629.utah.cloudlab.us   # client-1  -> lb-prequal-1
)

OBSERVER_HOSTS=(
    ms0636.utah.cloudlab.us   # observer-1
)

# Antagonist duty cycle per server (0-100). Index i applies to srv-(i+1).
# 0 = clean server. 1-99 = stress-ng pins ANTAGONIST_CORES cores for that
# percentage of each 10s cycle. 100 = constant antagonist (the replica's
# effective capacity is permanently machine_cores - ANTAGONIST_CORES).
#
# The mix mimics the paper's environment: several clean replicas with lots
# of headroom above their allocation (the "cracks" Prequal fits load into),
# a few transiently contended ones, and two pinned at exactly their
# allocation, which is what makes WRR start failing just above 100%.
SRV_CPU_LOADS=(0 0 0 0 30 30 70 70 100 100)

# Antagonist phase offset per server (seconds within the 10s cycle).
# Only meaningful for duty-cycled entries (1-99). Staggering spreads the
# "on" windows so at most a few servers are simultaneously stressed.
SRV_ANTAGONIST_PHASES=(0 0 0 0 0 5 2 7 0 0)

# Cores each antagonist burns while "on". m400s have 8 cores; 6 leaves a
# stressed server exactly its ALLOC_CORES of headroom, so a stressed
# replica is at capacity precisely when the fleet is at 100% load.
ANTAGONIST_CORES=6

# Declared CPU allocation per backend, in cores. This defines what "100%
# offered load" means: baseline qps = n_servers * ALLOC_CORES / median
# per-query service time (measured by experiment.sh calibration).
# Backends are deliberately NOT capped to this - the gap between the
# allocation and the full machine is the spare capacity Prequal exploits.
ALLOC_CORES=2

# Backend list LB containers will dial. Use the experiment's short
# hostnames (CloudLab's /etc/hosts resolves these on every node).
BACKENDS="srv-1:80,srv-2:80,srv-3:80,srv-4:80,srv-5:80,srv-6:80,srv-7:80,srv-8:80,srv-9:80,srv-10:80"

# Port the backend listens on (host network).
BACKEND_PORT=80
# Port each LB listens on (host network).
LB_PORT=8080
# Port node_exporter listens on (srv-* nodes).
NODE_EXPORTER_PORT=9100

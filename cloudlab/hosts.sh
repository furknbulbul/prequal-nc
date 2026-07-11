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

# Antagonist CPU load per server (0-100). Index i applies to srv-(i+1).
# Passed as CPU_LOAD to each backend container; the in-process bursty
# stress-ng runs when > 0. Figure 6 expects variable per-server cost;
# default mimics the paper: a few contended servers, the rest idle.
SRV_CPU_LOADS=(0 0 0 0 0 0 30 30 70 70)

# Antagonist phase offset per server (seconds within the 10s cycle).
# Only meaningful when the corresponding SRV_CPU_LOADS[i] > 0. Staggering
# spreads antagonist "on" windows across the cycle so at most a few
# servers are simultaneously stressed at any moment, matching the paper's
# "few antagonists among many healthy replicas" scenario.
#
# For the current config (4 antagonists at srv-7/8/9/10, cycle=10s), phases
# 0, 2, 5, 7 give max=3 antagonists on / min=1 / mean=1.8 per second.
SRV_ANTAGONIST_PHASES=(0 0 0 0 0 0 0 2 5 7)

# Backend list LB containers will dial. Use the experiment's short
# hostnames (CloudLab's /etc/hosts resolves these on every node).
BACKENDS="srv-1:80,srv-2:80,srv-3:80,srv-4:80,srv-5:80,srv-6:80,srv-7:80,srv-8:80,srv-9:80,srv-10:80"

# Port the backend listens on (host network).
BACKEND_PORT=80
# Port each LB listens on (host network).
LB_PORT=8080
# Port node_exporter listens on (srv-* nodes).
NODE_EXPORTER_PORT=9100

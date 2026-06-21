# CloudLab deployment config — fill in the actual SSH hostnames from
# your experiment's List View. deploy.sh and figure6.sh source this file;
# it is plain bash, no parsing.

# Your CloudLab username (the "Login" column under Manage Account).
CLOUDLAB_USER=username

# Public SSH hostnames per role. Order matters: the i-th entry of
# PREQUAL_HOSTS becomes "lb-prequal-i" inside the experiment.
PREQUAL_HOSTS=(
    XXXX.utah.cloudlab.us   # lb-prequal-1
)

RR_HOSTS=(
    XXXX.utah.cloudlab.us   # lb-rr-1
)

SRV_HOSTS=(
    XXXX.utah.cloudlab.us   # srv-1
    XXXX.utah.cloudlab.us   # srv-2
    XXXX.utah.cloudlab.us   # srv-3
    XXXX.utah.cloudlab.us   # srv-4
    XXXX.utah.cloudlab.us   # srv-5
    XXXX.utah.cloudlab.us   # srv-6
    XXXX.utah.cloudlab.us   # srv-7
    XXXX.utah.cloudlab.us   # srv-8
)

# Each client is pinned to one LB during the Figure 6 ramp:
#   client-1 drives PREQUAL_HOSTS[0]
#   client-2 drives RR_HOSTS[0]
CLIENT_HOSTS=(
    XXXX.utah.cloudlab.us   # client-1  -> lb-prequal-1
    XXXX.utah.cloudlab.us   # client-2  -> lb-rr-1
)

OBSERVER_HOSTS=(
    XXXX.utah.cloudlab.us   # observer-1
)

# Antagonist CPU load per server (0-100). Index i applies to srv-(i+1).
# Figure 6 expects variable per-server cost; default mimics the paper:
# two heavily contended servers, the rest idle.
SRV_CPU_LOADS=(60 60 0 0 0 0 0 0)

# stress-ng antagonist plan: count of background CPU stressors per srv
# during the ramp. Index i applies to srv-(i+1). 0 disables.
SRV_ANTAGONIST_CPUS=(1 1 0 0 0 0 0 0)

# Backend list LB containers will dial. Use the experiment's short
# hostnames (CloudLab's /etc/hosts resolves these on every node).
BACKENDS="srv-1:80,srv-2:80,srv-3:80,srv-4:80,srv-5:80,srv-6:80,srv-7:80,srv-8:80"

# Port the backend listens on (host network).
BACKEND_PORT=80
# Port each LB listens on (host network).
LB_PORT=8080
# Port node_exporter listens on (srv-* nodes).
NODE_EXPORTER_PORT=9100

# CloudLab deployment config — fill in the actual SSH hostnames from
# your experiment's List View. deploy.sh sources this file; it's plain
# bash, no parsing.

# Your CloudLab username (the "Login" column under Manage Account).
CLOUDLAB_USER=username

# Public SSH hostnames per role. Order matters: the i-th entry of
# PREQUAL_HOSTS becomes "lb-prequal-i" inside the experiment.
PREQUAL_HOSTS=(
    XXXX.utah.cloudlab.us   # lb-prequal-1
    XXXX.utah.cloudlab.us   # lb-prequal-2
)

RR_HOSTS=(
    XXXX.utah.cloudlab.us   # lb-rr-1
    XXXX.utah.cloudlab.us   # lb-rr-2
)

SRV_HOSTS=(
    XXXX.utah.cloudlab.us   # srv-1
    XXXX.utah.cloudlab.us   # srv-2
    XXXX.utah.cloudlab.us   # srv-3
)

CLIENT_HOSTS=(
    XXXX.utah.cloudlab.us   # client-1
)

OBSERVER_HOSTS=(
    XXXX.utah.cloudlab.us   # observer-1
)


SRV_CPU_LOADS=(60 60 0)

# Backend list LB containers will dial. Use the experiment's short
# hostnames (CloudLab's /etc/hosts resolves these on every node).
BACKENDS="srv-1:80,srv-2:80,srv-3:80"

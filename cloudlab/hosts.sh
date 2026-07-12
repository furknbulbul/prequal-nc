CLOUDLAB_USER=bahri

PREQUAL_HOSTS=(
    ms0639.utah.cloudlab.us
)

RR_HOSTS=(
    ms0633.utah.cloudlab.us
)

SRV_HOSTS=(
    ms0631.utah.cloudlab.us
    ms0623.utah.cloudlab.us
    ms0621.utah.cloudlab.us
    ms0602.utah.cloudlab.us
    ms0614.utah.cloudlab.us
    ms0630.utah.cloudlab.us
    ms0637.utah.cloudlab.us
    ms0619.utah.cloudlab.us
    ms0634.utah.cloudlab.us
    ms0628.utah.cloudlab.us
)

CLIENT_HOSTS=(
    ms0629.utah.cloudlab.us
)

OBSERVER_HOSTS=(
    ms0636.utah.cloudlab.us
)

SRV_CPU_LOADS=(0 0 0 0 30 30 70 70 100 100)

SRV_ANTAGONIST_PHASES=(0 0 0 0 0 5 2 7 0 0)

ANTAGONIST_CORES=6

ALLOC_CORES=2

BACKENDS="srv-1:80,srv-2:80,srv-3:80,srv-4:80,srv-5:80,srv-6:80,srv-7:80,srv-8:80,srv-9:80,srv-10:80"

BACKEND_PORT=80
LB_PORT=8080
NODE_EXPORTER_PORT=9100

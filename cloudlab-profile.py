"""CloudLab profile for the Prequal Figure 6 distributed testbed.

Three node roles, each on its own bare-metal machine:

  * lb-prequal-1..N  : run one Prequal load balancer container
  * lb-rr-1..N       : run one Round-Robin load balancer container
  * srv-1..M         : run one backend container
  * client-1..K      : run hey (load generator)
  * observer-1..J    : run Prometheus + Grafana (default 1)

All nodes join a single LAN (`lan0`). CloudLab populates /etc/hosts on
every node with these short names, so a load balancer can dial backends
as `srv-1:80`, and a client can dial `lb-prequal-1:8080`, etc.

Parameters
----------
nPrequal   : number of Prequal LB nodes  (default 2)
nRR        : number of Round-Robin LB nodes (default 2)
nServer    : number of backend nodes (default 3)
nClient    : number of load-generator nodes (default 1)
nObserver  : number of observability nodes running Prometheus+Grafana (default 1)
nodeType   : hardware type per node (default m510). Empty = cluster default.
osImage    : disk image URN (advanced; default Ubuntu 22.04).

"""

import geni.portal as portal
import geni.rspec.pg as pg

DEFAULT_IMAGE = "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD"

pc = portal.Context()
pc.defineParameter(
    "nPrequal", "Number of Prequal LB nodes",
    portal.ParameterType.INTEGER, 2,
)
pc.defineParameter(
    "nRR", "Number of Round-Robin LB nodes",
    portal.ParameterType.INTEGER, 2,
)
pc.defineParameter(
    "nServer", "Number of backend nodes",
    portal.ParameterType.INTEGER, 3,
)
pc.defineParameter(
    "nClient", "Number of client (load-generator) nodes",
    portal.ParameterType.INTEGER, 1,
)
pc.defineParameter(
    "nObserver", "Number of observer nodes (Prometheus + Grafana)",
    portal.ParameterType.INTEGER, 1,
)
pc.defineParameter(
    "nodeType", "Hardware type per node (e.g. m510). Empty = cluster default.",
    portal.ParameterType.STRING, "m510",
)
pc.defineParameter(
    "osImage", "Disk image URN",
    portal.ParameterType.STRING, DEFAULT_IMAGE,
    advanced=True,
)
params = pc.bindParameters()

if params.nPrequal < 1:
    pc.reportError(portal.ParameterError("nPrequal must be >= 1"))
if params.nRR < 1:
    pc.reportError(portal.ParameterError("nRR must be >= 1"))
if params.nServer < 1:
    pc.reportError(portal.ParameterError("nServer must be >= 1"))
if params.nClient < 1:
    pc.reportError(portal.ParameterError("nClient must be >= 1"))
if params.nObserver < 0:
    pc.reportError(portal.ParameterError("nObserver must be >= 0"))
pc.verifyParameters()

request = pc.makeRequestRSpec()
lan = request.LAN("lan0")


def add_node(name):
    n = request.RawPC(name)
    if params.nodeType:
        n.hardware_type = params.nodeType
    n.disk_image = params.osImage
    iface = n.addInterface("if0")
    lan.addInterface(iface)
    return n


for i in range(1, params.nPrequal + 1):
    add_node("lb-prequal-{}".format(i))
for i in range(1, params.nRR + 1):
    add_node("lb-rr-{}".format(i))
for i in range(1, params.nServer + 1):
    add_node("srv-{}".format(i))
for i in range(1, params.nClient + 1):
    add_node("client-{}".format(i))
for i in range(1, params.nObserver + 1):
    add_node("observer-{}".format(i))

pc.printRequestRSpec(request)

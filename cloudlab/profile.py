"""CloudLab profile for the Prequal Figure 6 distributed testbed.

Topology (defaults match Figure 6 setup):
  * lb-prequal-1     : Prequal load balancer
  * lb-rr-1          : Round-Robin load balancer
  * srv-1..8         : backend replicas
  * client-1         : load generator pinned to lb-prequal-1
  * client-2         : load generator pinned to lb-rr-1
  * observer-1       : Prometheus + Grafana

All nodes join a single LAN (`lan0`). CloudLab populates /etc/hosts on every
node with these short names, so an LB dials backends as `srv-1:80`, a client
dials `lb-prequal-1:8080`, etc.
"""

import geni.portal as portal
import geni.rspec.pg as pg

DEFAULT_IMAGE = "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD"

pc = portal.Context()
pc.defineParameter("nPrequal", "Number of Prequal LB nodes",
                   portal.ParameterType.INTEGER, 1)
pc.defineParameter("nRR", "Number of Round-Robin LB nodes",
                   portal.ParameterType.INTEGER, 1)
pc.defineParameter("nServer", "Number of backend nodes",
                   portal.ParameterType.INTEGER, 8)
pc.defineParameter("nClient", "Number of client (load-generator) nodes",
                   portal.ParameterType.INTEGER, 2)
pc.defineParameter("nObserver", "Number of observer nodes (Prometheus + Grafana)",
                   portal.ParameterType.INTEGER, 1)
pc.defineParameter("nodeType",
                   "Hardware type per node (e.g. m510). Empty = cluster default.",
                   portal.ParameterType.STRING, "m510")
pc.defineParameter("osImage", "Disk image URN",
                   portal.ParameterType.STRING, DEFAULT_IMAGE, advanced=True)
params = pc.bindParameters()

for name, val in [("nPrequal", params.nPrequal), ("nRR", params.nRR),
                  ("nServer", params.nServer), ("nClient", params.nClient)]:
    if val < 1:
        pc.reportError(portal.ParameterError(name + " must be >= 1"))
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

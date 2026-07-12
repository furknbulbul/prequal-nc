# Prequal Load Balancer

Implementation of the load balancing algorithm from "Load is not what you should balance: Introducing Prequal" (NSDI '24), replicating the paper's Figure 6 experiment on CloudLab.

## Layout

- `pkg/loadbalancer/` — Prequal and Round-Robin load balancer (probe pool, RIF distribution, HCL selection)
- `cmd/server/` — load balancer binary
- `backend/` — backend replica with CPU work loop and stress-ng antagonist
- `cloudlab/` — CloudLab profile, deployment, experiment driver, and plotting
- `results/` — experiment outputs

## Running on CloudLab

Instantiate the topology with `cloudlab/profile.py`, fill in the node hostnames in `cloudlab/hosts.sh`, then:

```bash
./cloudlab/deploy.sh all          # bootstrap, sync, build, run, verify
./cloudlab/experiment.sh          # run the load ramp
python3 cloudlab/plot_experiment.py results/experiment/<ts> --ssh USER@OBSERVER
```

See `./cloudlab/deploy.sh help` and `./cloudlab/experiment.sh -h` for options.

## References

Based on the paper: [Load is not what you should balance: Introducing Prequal](https://www.usenix.org/conference/nsdi24/presentation/wydrowski) (NSDI '24)

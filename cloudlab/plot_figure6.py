#!/usr/bin/env python3
"""Render Figure 6 from a results/figure6/<ts>/ directory.

Inputs:
  results_dir          directory produced by figure6.sh, containing
                       windows.csv, summary.tsv, prequal_*.txt, rr_*.txt.

Outputs in the same directory:
  figure6.png          three-panel plot: tail latency, error rate, CPU box.
  cpu_samples.csv      raw per-srv CPU% samples used to draw panel (c).

Latency and errors come from summary.tsv (parsed from `hey` output).
CPU utilization is queried from Prometheus (node_exporter) per (algo, level)
window, gathering samples across all srv-* instances.

Usage:
  python3 plot_figure6.py RESULTS_DIR [--prom URL]
"""

import argparse
import csv
import sys
from pathlib import Path

import requests
import matplotlib.pyplot as plt
import numpy as np


CPU_QUERY = (
    '100 * (1 - avg by (instance) '
    '(rate(node_cpu_seconds_total{{mode="idle",instance=~"{srv_re}"}}[15s])))'
)


def load_summary(path: Path):
    rows = []
    with path.open() as f:
        reader = csv.DictReader(f, delimiter="\t")
        for r in reader:
            rows.append({
                "algorithm": r["algorithm"],
                "level": int(r["level_pct"]),
                "qps": int(r["target_qps"]),
                "rps": float(r["rps"]),
                "p50": float(r["p50_ms"]),
                "p99": float(r["p99_ms"]),
                "p999": float(r["p999_ms"]),
                "err_pct": float(r["error_pct"]),
            })
    return rows


def load_windows(path: Path):
    wins = []
    with path.open() as f:
        reader = csv.DictReader(f)
        for r in reader:
            wins.append({
                "algorithm": r["algorithm"],
                "level": int(r["level_pct"]),
                "t_start": int(r["t_start_unix"]),
                "t_end": int(r["t_end_unix"]),
            })
    return wins


def query_cpu_samples(prom_url: str, t_start: int, t_end: int, srv_re: str):
    q = CPU_QUERY.format(srv_re=srv_re)
    r = requests.get(
        prom_url.rstrip("/") + "/api/v1/query_range",
        params={"query": q, "start": t_start, "end": t_end, "step": "5s"},
        timeout=15,
    )
    r.raise_for_status()
    data = r.json()
    if data.get("status") != "success":
        raise RuntimeError("Prometheus error: " + str(data))
    samples = []
    for series in data["data"]["result"]:
        instance = series["metric"].get("instance", "?")
        for _ts, val in series["values"]:
            try:
                samples.append((instance, float(val)))
            except (ValueError, TypeError):
                continue
    return samples


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results_dir", type=Path)
    ap.add_argument("--prom", default=None,
                    help="Prometheus URL, e.g. http://observer-1.utah.cloudlab.us:9090")
    ap.add_argument("--srv-regex", default="srv-.*:9100",
                    help="instance label regex for node_exporter on srv-* nodes")
    ap.add_argument("--no-cpu", action="store_true",
                    help="skip CPU panel (no Prometheus needed)")
    args = ap.parse_args()

    out_dir = args.results_dir
    summary = load_summary(out_dir / "summary.tsv")
    windows = load_windows(out_dir / "windows.csv")

    levels = sorted({r["level"] for r in summary})
    pre = {r["level"]: r for r in summary if r["algorithm"] == "prequal"}
    rr = {r["level"]: r for r in summary if r["algorithm"] == "roundrobin"}

    have_cpu = not args.no_cpu and args.prom is not None
    nrows = 3 if have_cpu else 2
    fig, axes = plt.subplots(nrows, 1, figsize=(11, 3.2 * nrows), sharex=True)
    if nrows == 1:
        axes = [axes]

    x = np.arange(len(levels))

    # --- Panel (a): tail latency, log scale ---
    ax = axes[0]
    for stat, color in [("p50", "tab:blue"),
                        ("p99", "tab:green"),
                        ("p999", "tab:red")]:
        rr_vals = [rr[l][stat] for l in levels]
        pre_vals = [pre[l][stat] for l in levels]
        ax.plot(x, rr_vals, "--o", color=color, label=f"RR {stat}", alpha=0.7)
        ax.plot(x, pre_vals, "-o", color=color, label=f"Prequal {stat}")
    ax.set_yscale("log")
    ax.set_ylabel("Latency (ms)")
    ax.set_title("Tail latency vs. offered load")
    ax.grid(True, which="both", linestyle=":", alpha=0.5)
    ax.legend(ncol=3, fontsize=8, loc="upper left")

    # --- Panel (b): error rate ---
    ax = axes[1]
    rr_err = [rr[l]["err_pct"] for l in levels]
    pre_err = [pre[l]["err_pct"] for l in levels]
    width = 0.35
    ax.bar(x - width/2, rr_err, width, label="Round-Robin",
           color="lightgray", edgecolor="black")
    ax.bar(x + width/2, pre_err, width, label="Prequal",
           color="white", edgecolor="black", hatch="//")
    ax.set_ylabel("Error rate (%)")
    ax.set_title("Errors vs. offered load")
    ax.grid(True, axis="y", linestyle=":", alpha=0.5)
    ax.legend(fontsize=8, loc="upper left")

    # --- Panel (c): CPU utilization distribution per srv per algo per level ---
    if have_cpu:
        cpu_path = out_dir / "cpu_samples.csv"
        cpu_path.write_text("algorithm,level_pct,instance,cpu_pct\n")
        cpu_by_algo_level = {("prequal", l): [] for l in levels}
        cpu_by_algo_level.update({("roundrobin", l): [] for l in levels})
        with cpu_path.open("a") as f:
            for w in windows:
                try:
                    samples = query_cpu_samples(
                        args.prom, w["t_start"], w["t_end"], args.srv_regex)
                except Exception as e:
                    print(f"warn: CPU query failed for "
                          f"{w['algorithm']} {w['level']}%: {e}",
                          file=sys.stderr)
                    continue
                for inst, v in samples:
                    f.write(f"{w['algorithm']},{w['level']},{inst},{v:.3f}\n")
                    cpu_by_algo_level[(w["algorithm"], w["level"])].append(v)

        ax = axes[2]
        positions_rr = x - width/2
        positions_pre = x + width/2
        rr_data = [cpu_by_algo_level[("roundrobin", l)] or [0] for l in levels]
        pre_data = [cpu_by_algo_level[("prequal", l)] or [0] for l in levels]
        bp_rr = ax.boxplot(rr_data, positions=positions_rr, widths=width*0.9,
                           patch_artist=True, showfliers=False)
        bp_pre = ax.boxplot(pre_data, positions=positions_pre, widths=width*0.9,
                            patch_artist=True, showfliers=False)
        for patch in bp_rr["boxes"]:
            patch.set_facecolor("lightgray")
        for patch in bp_pre["boxes"]:
            patch.set_facecolor("white")
            patch.set_hatch("//")
        ax.set_ylabel("CPU utilization (%)")
        ax.set_title("CPU distribution across backends")
        ax.set_ylim(0, 105)
        ax.grid(True, axis="y", linestyle=":", alpha=0.5)

    axes[-1].set_xticks(x)
    axes[-1].set_xticklabels([f"{l}%" for l in levels])
    axes[-1].set_xlabel("Offered load (% of baseline capacity)")

    fig.tight_layout()
    out_png = out_dir / "figure6.png"
    fig.savefig(out_png, dpi=150)
    print(f"Wrote {out_png}")


if __name__ == "__main__":
    main()

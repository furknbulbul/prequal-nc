#!/usr/bin/env python3
"""
Per-level PreQual pick analyzer.

Reads pool_*.ndjson snapshot files produced by experiment-local.sh and reports,
for each load level:
  - total unique picks observed
  - class distribution (cold / hot / no-pool / no-dist / no-winner)
  - per-server pick distribution (sorted by count)
  - per-server x class cross-tab
  - mean pool size and mean theta during the phase

Usage:
  ./analyze_picks.py results/experiment-local/20260624-021209
  ./analyze_picks.py                                # uses latest run
  ./analyze_picks.py <dir> --csv picks.csv          # also emit per-level CSV
"""

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path
from statistics import mean


def load_snapshots(run_dir):
    files = sorted(Path(run_dir).glob("pool_*.ndjson"))
    if not files:
        sys.exit(f"No pool_*.ndjson files in {run_dir}")
    snapshots = []
    for f in files:
        with open(f) as fh:
            for ln, line in enumerate(fh, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    snapshots.append(json.loads(line))
                except json.JSONDecodeError as e:
                    print(f"  warn: {f.name}:{ln} bad json ({e})", file=sys.stderr)
    return snapshots


def aggregate(snapshots):
    by_level = defaultdict(lambda: {
        "winners": defaultdict(int),
        "classes": defaultdict(int),
        "cross":   defaultdict(lambda: defaultdict(int)),
        "pool_sizes": [],
        "thetas":  [],
        "seen":    set(),
    })
    for snap in snapshots:
        level = snap.get("_level", "?")
        bucket = by_level[level]
        bucket["pool_sizes"].append(snap.get("pool_size", 0))
        for pick in snap.get("recent_picks", []):
            key = (pick.get("t"), pick.get("winner"), pick.get("class"))
            if key in bucket["seen"]:
                continue
            bucket["seen"].add(key)
            w = pick.get("winner") or "<none>"
            c = pick.get("class") or "<none>"
            bucket["winners"][w] += 1
            bucket["classes"][c] += 1
            bucket["cross"][c][w] += 1
            theta = pick.get("q_rif_threshold", 0)
            if theta:
                bucket["thetas"].append(theta)
    return by_level


def level_sort_key(level):
    try:
        return int(level)
    except (ValueError, TypeError):
        return -1


def fmt_row(label, count, total, width=12):
    pct = (100.0 * count / total) if total else 0.0
    return f"  {label:<{width}} {count:6d} ({pct:5.1f}%)"


def print_report(by_level):
    for level in sorted(by_level.keys(), key=level_sort_key):
        b = by_level[level]
        total = sum(b["winners"].values())
        print(f"==== Level {level}% — {total} unique picks ====")
        if total == 0:
            print("  (no picks captured)\n")
            continue

        mean_pool = mean(b["pool_sizes"]) if b["pool_sizes"] else 0
        mean_th   = mean(b["thetas"])     if b["thetas"]     else 0
        print(f"  mean pool_size={mean_pool:.1f}   mean theta={mean_th:.1f}   snapshots={len(b['pool_sizes'])}\n")

        print("  class distribution:")
        for cls, cnt in sorted(b["classes"].items(), key=lambda x: -x[1]):
            print(fmt_row(cls, cnt, total))
        print()

        print("  pick distribution:")
        for w, cnt in sorted(b["winners"].items(), key=lambda x: -x[1]):
            print(fmt_row(w, cnt, total))
        print()

        print("  pick distribution by class:")
        for cls in sorted(b["cross"].keys(), key=lambda c: -sum(b["cross"][c].values())):
            cls_total = sum(b["cross"][cls].values())
            print(f"  [{cls}] {cls_total} picks")
            for w, cnt in sorted(b["cross"][cls].items(), key=lambda x: -x[1]):
                pct = 100 * cnt / cls_total if cls_total else 0
                print(f"      {w:<12} {cnt:6d} ({pct:5.1f}%)")
        print()


def write_csv(by_level, out_path):
    """Wide CSV: rows = (level, winner), cols = class counts + totals."""
    classes = sorted({c for b in by_level.values() for c in b["cross"].keys()})
    with open(out_path, "w") as fh:
        header = ["level", "winner", "total"] + [f"class_{c}" for c in classes]
        fh.write(",".join(header) + "\n")
        for level in sorted(by_level.keys(), key=level_sort_key):
            b = by_level[level]
            for w in sorted(b["winners"].keys()):
                total = b["winners"][w]
                cells = [b["cross"][c].get(w, 0) for c in classes]
                row = [str(level), w, str(total)] + [str(x) for x in cells]
                fh.write(",".join(row) + "\n")
    print(f"\nWrote {out_path}")


def resolve_run_dir(arg):
    if arg:
        p = Path(arg)
    else:
        base = Path("results/experiment-local")
        if not base.is_dir():
            sys.exit("Pass a run directory; default 'results/experiment-local' not found")
        subdirs = sorted([d for d in base.iterdir() if d.is_dir()])
        if not subdirs:
            sys.exit(f"No subdirectories under {base}")
        p = subdirs[-1]
        print(f"# Using latest run: {p}", file=sys.stderr)
    if not p.is_dir():
        sys.exit(f"Not a directory: {p}")
    return p


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir", nargs="?", help="results/experiment-local/<timestamp> (default: latest)")
    ap.add_argument("--csv", help="write per-(level, winner) CSV to this path")
    args = ap.parse_args()

    run_dir = resolve_run_dir(args.run_dir)
    snaps = load_snapshots(run_dir)
    print(f"# Loaded {len(snaps)} snapshots from {run_dir}\n")

    by_level = aggregate(snaps)
    print_report(by_level)

    if args.csv:
        write_csv(by_level, args.csv)


if __name__ == "__main__":
    main()

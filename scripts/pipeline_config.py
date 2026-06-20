#!/usr/bin/env python3
"""
pipeline_config.py — CLI front-end for lib/_pipeline_yaml.py.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent / "lib"))
import _pipeline_yaml as cfg_lib  # noqa: E402


def _print_lines(items: list[str]) -> None:
    for item in items:
        print(item)


def _print_kv(d: dict, sep: str = "=") -> None:
    for k, v in d.items():
        print(f"{k}{sep}{v}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="pipeline_config")
    ap.add_argument("-c", "--config", default="config/pipeline.yaml")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_samples = sub.add_parser("samples", help="sample name -> identifiers + n_jobs")
    p_samples.add_argument("--format", choices=["json", "kv", "njobs"], default="json")

    p_trees = sub.add_parser("trees", help="tree names, e.g. E, T")
    p_trees.add_argument("--format", choices=["json", "lines"], default="json")

    p_ds = sub.add_parser("ml-datasets", help="ml.datasets keys")
    p_ds.add_argument("--format", choices=["json", "lines"], default="json")

    p_paths = sub.add_parser("paths", help="paths.* with {detector_id}/{base_dir} resolved")
    p_paths.add_argument("--format", choices=["json", "kv"], default="json")

    sub.add_parser("results-dir", help="parent of paths.parquet_dir")

    args = ap.parse_args(argv)

    if not Path(args.config).is_file():
        print(f"ERROR: config not found: {args.config}", file=sys.stderr)
        return 1

    try:
        cfg = cfg_lib.load(args.config)
    except Exception as exc:  # noqa: BLE001 - surface any YAML/parsing error cleanly
        print(f"ERROR: failed to load {args.config}: {exc}", file=sys.stderr)
        return 1

    if args.cmd == "samples":
        try:
            data = cfg_lib.samples(cfg)
        except ValueError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            return 1
        if args.format == "json":
            print(json.dumps(data))
        elif args.format == "kv":
            for name, body in data.items():
                print(f"{name}:" + ":".join(body["identifiers"]))
        elif args.format == "njobs":
            for name, body in data.items():
                print(f"{name} {body['n_jobs']}")

    elif args.cmd == "trees":
        data = cfg_lib.trees(cfg)
        print(json.dumps(data)) if args.format == "json" else _print_lines(data)

    elif args.cmd == "ml-datasets":
        data = cfg_lib.ml_datasets(cfg)
        print(json.dumps(data)) if args.format == "json" else _print_lines(data)

    elif args.cmd == "paths":
        data = cfg_lib.paths(cfg)
        print(json.dumps(data)) if args.format == "json" else _print_kv(data)

    elif args.cmd == "results-dir":
        print(cfg_lib.results_dir(cfg))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
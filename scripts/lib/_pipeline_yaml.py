"""
_pipeline_yaml — single source of truth for reading km3tipi's
config/pipeline.yaml.
"""
from __future__ import annotations

from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError as exc:  # pragma: no cover
    raise SystemExit(
        "ERROR: PyYAML is required (it's a transitive dep of km3tpi).\n"
        "       pip install pyyaml  —or—  conda install pyyaml"
    ) from exc


def load(path: str | Path) -> dict[str, Any]:
    """Load and return the raw pipeline.yaml as a dict."""
    with open(path) as f:
        return yaml.safe_load(f) or {}


def resolved_vars(cfg: dict[str, Any]) -> dict[str, str]:
    """Placeholders available for str.format() substitution: {detector_id}, {base_dir}."""
    detector_id = cfg.get("detector_id", "")
    base_dir = (cfg.get("base_dir", "") or "").format(detector_id=detector_id)
    return {"detector_id": detector_id, "base_dir": base_dir}


def samples(cfg: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """
    Return {sample_name: {"identifiers": [...], "n_jobs": int}}.

    n_jobs falls back to the top-level default (cfg["n_jobs"], default 4)
    when a sample doesn't set its own — this was previously duplicated
    (with the same default) inside monitor_jobs.sh's embedded heredoc.
    """
    default_n = int(cfg.get("n_jobs", 4))
    raw = cfg.get("samples") or {}
    if not isinstance(raw, dict):
        raise ValueError("'samples' block is not a mapping")

    out: dict[str, dict[str, Any]] = {}
    for name, body in raw.items():
        body = body or {}
        ids = body.get("identifiers") or []
        if not isinstance(ids, list):
            ids = [ids]
        out[name] = {
            "identifiers": [str(i) for i in ids],
            "n_jobs": int(body.get("n_jobs", default_n)),
        }
    return out


def trees(cfg: dict[str, Any]) -> list[str]:
    return list(cfg.get("trees", ["E", "T"]))


def ml_datasets(cfg: dict[str, Any]) -> list[str]:
    return list(((cfg.get("ml") or {}).get("datasets") or {}).keys())


def paths(cfg: dict[str, Any]) -> dict[str, str]:
    """Every entry under 'paths:', with {detector_id}/{base_dir} resolved."""
    v = resolved_vars(cfg)
    raw = cfg.get("paths") or {}
    out: dict[str, str] = {}
    for key, val in raw.items():
        try:
            out[key] = str(val).format(**v)
        except (KeyError, IndexError):
            out[key] = str(val)
    return out


def results_dir(cfg: dict[str, Any]) -> str:
    """Parent of paths.parquet_dir — e.g. results/KM3NeT_00000117."""
    parquet_dir = paths(cfg).get("parquet_dir", "")
    return str(Path(parquet_dir).parent) if parquet_dir else ""
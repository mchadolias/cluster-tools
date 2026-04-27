# cluster-tools

A collection of Bash utilities and Python scripts for working with HPC computing clusters ,  primarily tested to the **GLUON cluster at IFIC** (Valencia) and the **CC IN2P3** cluster (Lyon). This repository is intended as a submodule of [`dotfiles-cluster`](https://github.com/mchadolias/cluster-dotfiles).

---

## Repository Structure

```
cluster-tools/
├── bash/
│   ├── count_sample.sh        # Count events/samples in data files
│   ├── export_conda.sh        # Export and replicate Conda environments across clusters
│   ├── find_diff.sh           # Find differing files between local and remote paths
│   ├── set-config.sh          # Bootstrap cluster-specific config files
│   ├── transfer_data.sh       # Wrapper for robust data transfer between clusters
│   └── kerberos/
│       ├── kerberos-renew.service   # systemd service for Kerberos ticket renewal
│       ├── kerberos-renew.timer     # systemd timer (schedule for the service above)
│       └── README.md                # Kerberos setup and usage guide
├── scripts/
│   └── init_project.py        # Python script to scaffold a new project directory
├── LICENSE
└── README.md
```

---

## Bash Scripts

### `bash/count_sample.sh`

Counts the number of events or files in a given data sample directory. Useful for quick sanity checks after data transfers or job completions.

```bash
bash count_sample.sh <path/to/data>
```

---

### `bash/export_conda.sh`

Exports the active (or a named) Conda environment to a portable `environment.yml` and optionally syncs it to a remote cluster via `rsync` or `scp`.

```bash
# Export active environment
bash export_conda.sh

# Export a named environment
bash export_conda.sh -n <env_name> -r <remote_host>:<remote_path>
```

> **Note:** Requires Conda (via Miniforge3) to be initialised. Cross-platform packages may need manual cleanup in the exported file.

---

### `bash/find_diff.sh`

Compares a local directory against a remote path and reports files that differ in size, checksum, or are missing on either side. Wraps `rsync --dry-run` with a human-readable summary.

```bash
bash find_diff.sh <local_path> <remote_host>:<remote_path>
```

---

### `bash/set-config.sh`

Bootstraps cluster-specific configuration by symlinking or copying the relevant dotfiles (SSH config, `.condarc`, shell config) from the `dotfiles-cluster` submodule into place. Safe to re-run — will not overwrite existing files unless `--force` is passed.

```bash
bash set-config.sh [--force]
```

---

### `bash/transfer_data.sh`

A resilient data transfer wrapper around `rsync` with automatic retry, progress reporting, and optional checksum verification. Suitable for large dataset transfers between IFIC and CC IN2P3.

```bash
bash transfer_data.sh <source> <destination> [--checksum] [--retries N]
```

| Flag | Description |
|------|-------------|
| `--checksum` | Enable MD5 checksum verification after transfer |
| `--retries N` | Number of retry attempts on failure (default: 3) |
| `--dry-run` | Preview the transfer without copying any data |

---

### `bash/kerberos/`

Systemd units for automated Kerberos ticket management on CC IN2P3, which uses GSSAPI authentication (`CC.IN2P3.FR` realm). See [`bash/kerberos/README.md`](bash/kerberos/README.md) for the full setup guide.

**Quick install:**

```bash
cp bash/kerberos/kerberos-renew.service ~/.config/systemd/user/
cp bash/kerberos/kerberos-renew.timer   ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now kerberos-renew.timer
```

The timer calls `check_ticket.sh`, which attempts renewal first and falls back to re-authentication via a keytab stored at `~/.config/kerberos/keytabs/<username>.keytab`.

---

## Python Scripts

### `scripts/init_project.py`

Scaffolds a new analysis project directory with a standardised layout, an initial `README.md`, and optional Git initialisation. It is recommended to run this inside the `admin-tools` environment defined in the dotfiles project.

```bash
python scripts/init_project.py <project_name> [--path ~/projects] [--git]
```

The generated layout follows the conventions used across KM3NeT analysis repositories.

---

## Setup as a Submodule

This repo is designed to be included inside `dotfiles-cluster`:

```bash
# From inside dotfiles-cluster
git submodule add https://github.com/mchadolias/cluster-tools.git cluster-tools
git submodule update --init --recursive
```

To update to the latest version:

```bash
git submodule update --remote cluster-tools
```

---

## Requirements

| Tool | Purpose |
|------|---------|
| `bash >= 5.0` | All shell scripts |
| `rsync` | Data transfer and diffing |
| `conda` / `mamba` | Environment export script |
| `kinit`, `klist` | Kerberos ticket management |
| `systemd` (user) | Kerberos timer units |
| `python >= 3.9` | `init_project.py` |

---

## License

[MIT](LICENSE) © Michalis Chadolias
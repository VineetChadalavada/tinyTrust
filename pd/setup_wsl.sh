#!/usr/bin/env bash
# TinyTrust P0 — backend toolchain bring-up in WSL2 Ubuntu.
#
# Why not the Docker image: openroad/orfs:latest fails deterministically on one
# oversized layer from Docker's CloudFront CDN on this network (4/4 attempts,
# same blob). GitHub + apt work fine over IPv4, so we build locally instead.
#
# Prereq applied separately (docker-desktop VM + Ubuntu):
#   echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf   # prefer IPv4
#
# Run as root:  wsl -d Ubuntu -u root -- bash /mnt/e/tinytrust/pd/setup_wsl.sh
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive   # DependencyInstaller must not stall on a prompt
ORFS_DIR=/opt/OpenROAD-flow-scripts
LOG=/var/log/tinytrust-orfs-setup.log
exec > >(tee -a "$LOG") 2>&1

echo "=== [$(date -Is)] TinyTrust ORFS bring-up ==="

if [ ! -d "$ORFS_DIR/.git" ]; then
    echo "--- cloning OpenROAD-flow-scripts ---"
    git clone --recursive --depth 1 \
        https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts.git \
        "$ORFS_DIR"
else
    echo "--- ORFS clone already present, skipping ---"
fi

cd "$ORFS_DIR"

echo "--- installing dependencies (apt + prebuilt) ---"
# -base installs the apt packages; -common builds the pinned deps (or-tools etc.)
./etc/DependencyInstaller.sh -all

# Thread count must come from MEMORY, not core count. OpenROAD/boost/abc each
# take ~0.8-1 GB per cc1plus job; WSL2 defaults to 50% of host RAM (7.6 GB
# here), so `--threads $(nproc)` = 20 jobs gets OOM-killed around 38% of the
# OpenROAD compile. Budget ~2 GB/job and never exceed nproc.
MEM_GB=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
JOBS=$(( MEM_GB / 2 ))
[ "$JOBS" -lt 1 ] && JOBS=1
[ "$JOBS" -gt "$(nproc)" ] && JOBS=$(nproc)

echo "--- building OpenROAD (local, ${JOBS} jobs; ${MEM_GB} GB RAM, $(nproc) cores) ---"
./build_openroad.sh --local --threads "$JOBS"

echo "--- verifying ---"
# shellcheck disable=SC1091
source ./env.sh
openroad -version
yosys -V
klayout -v 2>/dev/null || echo "NOTE: klayout not in ORFS; apt-get install -y klayout"

echo "--- ihp-sg13g2 platform present? ---"
ls -d "$ORFS_DIR/flow/platforms/ihp-sg13g2" 2>/dev/null \
    && echo "ihp-sg13g2 OK" \
    || echo "WARN: ihp-sg13g2 platform missing from this ORFS revision"

echo "=== [$(date -Is)] done ==="

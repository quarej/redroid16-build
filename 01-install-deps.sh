#!/usr/bin/env bash
# Run as root on build VM 192.168.0.108; APT uses only BFSU for these commands.
set -euo pipefail
test "$(id -u)" -eq 0
cat >/root/redroid16-build/ubuntu-bfsu.sources <<'EOF'
Types: deb
URIs: https://mirrors.bfsu.edu.cn/ubuntu/
Suites: noble noble-updates noble-backports noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
apt_opts=(
    -o Dir::Etc::sourcelist=/root/redroid16-build/ubuntu-bfsu.sources
    -o Dir::Etc::sourceparts=-
)
apt-get "${apt_opts[@]}" update
DEBIAN_FRONTEND=noninteractive apt-get "${apt_opts[@]}" install -y \
    ca-certificates curl git git-lfs python3 build-essential bc bison flex \
    gperf libssl-dev zlib1g-dev libncurses-dev libxml2-utils xsltproc \
    zip unzip rsync zstd
git lfs version
curl -fsSL --retry 2 --max-time 45 \
    https://mirrors.bfsu.edu.cn/git/git-repo \
    -o /root/redroid16-build/repo-launcher.bfsu
python3 -m py_compile /root/redroid16-build/repo-launcher.bfsu
install -m 0755 /root/redroid16-build/repo-launcher.bfsu /usr/local/bin/repo
/usr/local/bin/repo version

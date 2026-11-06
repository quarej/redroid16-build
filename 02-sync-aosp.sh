#!/usr/bin/env bash
# Run as root on build VM 192.168.0.108. AOSP Git remotes use BFSU only.
# Requires /work mounted, /usr/local/bin/repo copied from .111 and deps installed.
set -euo pipefail
test "$(id -u)" -eq 0
test "$(findmnt -n -o TARGET /work)" = /work
test -x /usr/local/bin/repo
test -x /usr/bin/git
export REPO_URL=https://mirrors.bfsu.edu.cn/git/AOSP/tools/repo
runuser -u aosp -- git config --global user.name 'AOSP Build'
runuser -u aosp -- git config --global user.email 'aosp@localhost'
install -d -m 0755 -o aosp -g aosp /work/aosp/source
runuser -u aosp -- sh -c '
    cd /work/aosp/source &&
    /usr/local/bin/repo init \
        -u https://mirrors.bfsu.edu.cn/git/AOSP/platform/manifest \
        -b android-16.0.0_r2 \
        --depth=1 --git-lfs --no-clone-bundle \
        --repo-url=https://mirrors.bfsu.edu.cn/git/AOSP/tools/repo \
        --repo-rev=stable &&
    /usr/local/bin/repo sync -c -j4 --no-tags --no-clone-bundle --fail-fast
' 2>&1 | tee -a /work/repo-sync.log
df -hT /work

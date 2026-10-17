#!/usr/bin/env bash
set -euo pipefail

# DDNSTO 由 ImmortalWrt 默认软件源之外的仓库维护。
echo 'src-git nas https://github.com/linkease/ddnsto-openwrt-package.git;main' >> feeds.conf.default

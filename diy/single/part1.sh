#!/bin/bash
# DIY 第一阶段：在 feeds update 前执行。
# 用途：按需在 feeds.conf.default 中添加或调整第三方软件源。

# ==================== 添加 ddnsto 官方 feed ====================
echo 'src-git nas https://github.com/linkease/ddnsto-openwrt-package.git;main' >> feeds.conf.default
# ===============================================================
echo "diy-part1.sh 执行完成"
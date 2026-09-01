#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part1.sh
# Description: OpenWrt DIY script part 1 (Before Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# ============================================
# 用途：添加第三方 feed 源到 feeds.conf.default
# 时机：在 feeds update 之前执行
# ============================================

# ddnsto feed 源（提供新版 ddnsto 及相关 LuCI 应用）
echo 'src-git nas https://github.com/linkease/ddnsto-openwrt-package.git;main' >> feeds.conf.default

# Nikki feed 源（提供 Nikki、Mihomo 及 LuCI 管理界面）
echo 'src-git nikki https://github.com/nikkinikki-org/OpenWrt-nikki.git;main' >> feeds.conf.default

echo "diy-part1.sh 执行完成 - feed 源已添加"

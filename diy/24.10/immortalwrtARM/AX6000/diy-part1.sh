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

# ddnsto feed 源（提供 ddnsto 及相关 LuCI 应用）
echo 'src-git nas https://github.com/linkease/nas-packages.git;master' >> feeds.conf.default
echo 'src-git nas_luci https://github.com/linkease/nas-packages-luci.git;main' >> feeds.conf.default

echo "diy-part1.sh 执行完成 - feed 源已添加"
#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# ============================================
# 第三方包管理区
# 用途：添加项目中不存在的包，替换项目中的旧版本包
# 时机：在 feeds install 之后执行
# ============================================

echo "开始处理第三方包..."

# 1. 添加 luci-app-adguardhome（项目中不存在，直接添加）
echo "正在添加 luci-app-adguardhome..."
git clone --depth=1 https://github.com/kongfl888/luci-app-adguardhome.git package/luci-app-adguardhome

# 2. 替换 luci-app-wechatpush 为最新版本（项目中存在旧版本，需要替换）
echo "正在替换 luci-app-wechatpush 为最新版本..."
rm -rf feeds/luci/applications/luci-app-wechatpush
git clone --depth=1 https://github.com/tty228/luci-app-wechatpush.git feeds/luci/applications/luci-app-wechatpush

echo "第三方包处理完成！"

# ============================================
# 系统配置修改区
# ============================================

echo "开始修改系统配置..."

# 修改 OpenWrt 登录地址和密码
sed -i 's/192.168.6.1/192.168.31.1/g' package/base-files/files/bin/config_generate
sed -i 's/root:::0:99999:7:::/root:\$1$wQIghyNn$dqPUfUazp1dDD\/NvSSSs\/1:20002:0:99999:7:::/g' package/base-files/files/etc/shadow

# 修改主机名字（不能纯数字或使用中文）
sed -i "s/hostname='.*'/hostname='VIVO-S7'/g" package/base-files/files/bin/config_generate

# 修改闭源驱动 WiFi 名称
sed -i 's/ImmortalWrt-2.4G/G/g' package/mtk/applications/mtwifi-cfg/files/mtwifi.sh
sed -i 's/ImmortalWrt-5G/G5G/g' package/mtk/applications/mtwifi-cfg/files/mtwifi.sh

# 删除其他设备的 UCI 配置文件（只保留 AX6000）
find files/etc/uci-defaults/ -type f ! -name 'AX6000' -exec rm {} \;

echo "系统配置修改完成！"

# ============================================
# 脚本和定时任务配置区
# ============================================

echo "开始配置脚本和定时任务..."

# 启用开机延迟执行脚本
sed -i "s/#qdts~//g" files/etc/rc.local

# 启用网络检测和 WiFi 切换定时任务
sed -i 's/#wbzt\*\/[^ ]* \*/\*\/9 \*/' files/etc/crontabs/root
sed -i 's/#zjwifi\*\/[^ ]* \*/\*\/11 \*/' files/etc/crontabs/root

# 配置无线中继信号切换预设
echo '{"wifi":[{"name":"CMCC-Ptbf-5G","encryption":"psk2","password":"cccc5926","band":"5G","last_updated":"2024-11-14 18:33:40"}],"autowifiranking":[{"autowifiname":["Name1","Name2"],"CQ_TIMES":0}]}' | jq . > files/www/wx/wifi-config.json

# 脚本参数配置
sed -i 's/RETRY_INTERVAL=120/RETRY_INTERVAL=120/g' files/etc/JiaoBen/qdts.sh
sed -i 's/uid=123456789/uid=3192362522/g' files/etc/JiaoBen/wbzt.sh

echo "脚本和定时任务配置完成！"

# ============================================
# 插件自定义配置区
# ============================================

echo "开始配置插件..."

# ddnsto 配置
echo -e "\toption token '78846bf5-9a1f-4178-8aca-eeac5c38d4e6'" >> feeds/nas/network/services/ddnsto/files/ddnsto.config
sed -i "s/option enabled '0'/option enabled '1'/g" feeds/nas/network/services/ddnsto/files/ddnsto.config
sed -i "s/option index '.*'/option index '0'/g" feeds/nas/network/services/ddnsto/files/ddnsto.config

# wechatpush 自定义配置（设备名称）
sed -i "s/option device_name '.*'/option device_name 'AX6000'/g" feeds/luci/applications/luci-app-wechatpush/root/etc/config/wechatpush

echo "插件配置完成！"
echo "=========================================="
echo "diy-part2.sh 全部执行完成！"
echo "=========================================="

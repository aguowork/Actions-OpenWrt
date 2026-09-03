#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)

# ============================================
# 第三方包管理区
# 用途：添加项目中不存在的包，替换项目中的旧版本包
# 时机：在 feeds install 之后执行
# ============================================

echo "开始处理第三方包..."

# 注：luci-app-adguardhome 不在这里处理 —— 25.12 的 luci feed
# （applications/luci-app-adguardhome）已经自带同名包，直接用官方那份。
# 官方版是 JS 页面，LUCI_DEPENDS 硬依赖 +adguardhome，AdGuardHome 主程序会一起编进
# 固件（官方 apk 约 10.8 MiB），刷完即可用，不必在路由器上从 GitHub 现下载到 overlay。
# 别再 clone kongfl888/luci-app-adguardhome：包名和 feed 自带的完全相同，两份并存时
# kconfig 只保留一份且留哪份不可控（kmod-oaf 被丢弃就是这么来的）。
# 官方版只有 po/lo（老挝语）没有中文 po，所以也别加 luci-i18n-adguardhome-zh-cn，那是死行。

# 1. 添加最新版 luci-app-wechatpush（作为普通 package 引入，不能配置为 src-git feed）
echo "正在添加 luci-app-wechatpush..."
rm -rf package/feeds/wechatpush/luci-app-wechatpush package/luci-app-wechatpush
git clone --depth=1 https://github.com/aguowork/luci-app-wechatpush.git package/luci-app-wechatpush

# 2. 添加 luci-app-wechatpush 的流量监控依赖 wrtbwmon
# 直接用上游 brvphoenix/wrtbwmon：活跃维护，Makefile 版本号 1.2.1 与代码的实际能力一致。
# 不要换回 gitbruc/openwrt-wrtbwmon —— 那份代码与上游逐字节相同，但版本号仍写着 1.0.1，
# 而 luci-app-wechatpush 靠版本号选调用方式（>= 1.2.0 用 wrtbwmon -f，<= 1.0.0 用 wrtbwmon update），
# 1.0.1 卡在两个区间中间会导致两条分支都不执行，usage.db 永远不生成，
# 最终 luci-app-wechatpush 的“设备异常流量”告警读到的流量恒为 0（已踩过的坑）。
echo "正在添加 wrtbwmon..."
rm -rf package/wrtbwmon package/wrtbwmon-source
git clone --depth=1 https://github.com/brvphoenix/wrtbwmon.git package/wrtbwmon-source
mv package/wrtbwmon-source/wrtbwmon package/wrtbwmon
rm -rf package/wrtbwmon-source

echo "第三方包处理完成！"

# ============================================
# 系统配置修改区
# ============================================

echo "开始修改系统配置..."
build_date=$(TZ=UTC-8 date "+%Y%m%d%H%M")

# 修改 OpenWrt 登录地址和密码
sed -i 's/192.168.6.1/192.168.6.1/g' package/base-files/files/bin/config_generate
sed -i 's/root:::0:99999:7:::/root:\$1$wQIghyNn$dqPUfUazp1dDD\/NvSSSs\/1:20002:0:99999:7:::/g' package/base-files/files/etc/shadow

# 修改主机名字（不能纯数字或使用中文）
sed -i "s/hostname='.*'/hostname='360'/g" package/base-files/files/bin/config_generate

# 修改闭源驱动 WiFi 名称
sed -i 's/ImmortalWrt-2.4G/Y/g' package/mtk/applications/mtwifi-cfg/files/mtwifi.sh
sed -i 's/ImmortalWrt-5G/Y/g' package/mtk/applications/mtwifi-cfg/files/mtwifi.sh

# 添加编译时间
# LuCI 系统概况中追加编译时间信息（/etc/openwrt_release）
sed -i "s/DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION='ImmortalWrt By Guo ${build_date} '/g" package/base-files/files/etc/openwrt_release
# SSH 登录 banner 顶部插入编译时间
sed -i "1s|^|编译时间 ${build_date} @ Guo\\n|" package/base-files/files/etc/banner
[ -f files/etc/banner ] && sed -i "1s|^|编译时间 ${build_date} @ Guo\\n|" files/etc/banner

echo "系统配置修改完成！"


# ============================================
# 脚本和定时任务配置区
# ============================================

echo "开始配置脚本和定时任务..."

# 启用开机延迟执行脚本
sed -i "s/#qdts~//g" files/etc/rc.local

# 暂不启用网络检测和 WiFi 切换定时任务，待确认 25.12 适配后再开启。
# sed -i 's/#zjwifi\*\/[^ ]* \*/\*\/11 \*/' files/etc/crontabs/root

# 配置无线中继信号切换预设
echo '{"wifi":[{"name":"Hjx","encryption":"psk2","password":"HjxWpy2580","band":"2G","last_updated":"2021-01-03 18:33:40"}],"autowifiranking":[{"CQ_TIMES":0}]}' > files/etc/wx/wifi-config.json

# 脚本参数配置
sed -i 's/RETRY_INTERVAL=130/RETRY_INTERVAL=130/g' files/etc/JiaoBen/qdts.sh

echo "脚本和定时任务配置完成！"

# ============================================
# 插件自定义配置区
# ============================================

echo "开始配置插件..."

# ddnsto 配置
: "${DDNSTO_TOKEN:?Missing GitHub Secret DDNSTO_TOKEN}"
echo -e "\toption token '${DDNSTO_TOKEN}'" >> feeds/nas/ddnsto/files/ddnsto.config
sed -i "s/option enabled '0'/option enabled '1'/g" feeds/nas/ddnsto/files/ddnsto.config
sed -i "s/option index '.*'/option index '2'/g" feeds/nas/ddnsto/files/ddnsto.config

echo "插件配置完成！"

# ============================================
# wx项目权限设置（确保编译后立即可用）
# ============================================

echo "设置wx项目脚本执行权限..."
chmod +x files/www/cgi-bin/wx-auth.sh 2>/dev/null || true
chmod +x files/usr/libexec/rpcd/wx-wireless 2>/dev/null || true
chmod +x files/etc/wx/uninstall.sh 2>/dev/null || true
echo "wx项目权限设置完成！"

echo "=========================================="
echo "diy-part2.sh 全部执行完成！"
echo "=========================================="

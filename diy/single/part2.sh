#!/bin/bash
#
# DIY 第二阶段：feeds install 完成并追加固件配置后执行。
# 用途：准备配置中启用的第三方软件包源码。

echo "开始处理第三方包..."

# 移除树内自带的旧版 OAF，引入原作者最新版 OpenAppFilter。
# 注意：packages feed 的 net/open-app-filter 一份 Makefile 同时定义了 appfilter 和 kmod-oaf，
# 必须连它一起删，否则与下面 clone 的版本重复定义，kconfig 会报
# "PACKAGE_kmod-oaf is selected by PACKAGE_kmod-oaf" 并丢弃该符号，
# 结果 kmod-oaf 不产 ipk，编译最后的 package/install 阶段 opkg 解析依赖失败。
# feeds install -a 会创建 package/feeds/* 下的链接，因此 feeds/ 与 package/feeds/ 两处都要清理。
echo "正在替换旧版 OAF 为最新版 OpenAppFilter..."
rm -rf feeds/packages/net/open-app-filter \
       package/feeds/packages/open-app-filter \
       package/feeds/luci/luci-app-appfilter \
       feeds/luci/applications/luci-app-appfilter \
       package/luci-app-appfilter \
       package/OpenAppFilter
git clone --depth=1 https://github.com/destan19/OpenAppFilter.git package/OpenAppFilter

# 1. 添加 luci-app-adguardhome（项目中不存在，直接添加）
echo "正在添加 luci-app-adguardhome..."
git clone --depth=1 https://github.com/kongfl888/luci-app-adguardhome.git package/luci-app-adguardhome

# 2. 替换 luci-app-wechatpush 为最新版本（项目中存在旧版本，需要替换）
echo "正在替换 luci-app-wechatpush 为最新版本..."
rm -rf feeds/luci/applications/luci-app-wechatpush
git clone --depth=1 https://github.com/aguowork/luci-app-wechatpush.git feeds/luci/applications/luci-app-wechatpush

# ImmortalWrt 21.02 将 Lua 运行环境包含在现有 LuCI 软件包中，
# 没有新版 LuCI 单独提供的 luci-lua-runtime 软件包。
# 下面的 sed 命令会从 wechatpush 的 Makefile 依赖列表中删除 +luci-lua-runtime，
# 避免 opkg 在 21.02 源码树中查找不存在的软件包。
# sed -i 's/[[:space:]]*+luci-lua-runtime//' feeds/luci/applications/luci-app-wechatpush/Makefile

# firmware.config 启用了流量监控；21.02 feeds 中没有 wrtbwmon，
# 因此将它的源码加入当前构建树。
echo "正在添加 wechatpush 流量监控依赖 wrtbwmon..."
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
sed -i 's/192.168.1.1/192.168.31.1/g' package/base-files/files/bin/config_generate

# 添加编译时间
# LuCI 系统概况中追加编译时间信息（/etc/openwrt_release）
sed -i "s/DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION='ImmortalWrt By Guo ${build_date} '/g" package/base-files/files/etc/openwrt_release
# SSH 登录 banner 顶部插入编译时间
sed -i "1s|^|编译时间 ${build_date} @ Guo\\n|" package/base-files/files/etc/banner
[ -f files/etc/banner ] && sed -i "1s|^|编译时间 ${build_date} @ Guo\\n|" files/etc/banner

echo "系统配置修改完成！"


echo "=========================================="
echo "diy-part2.sh 全部执行完成！"
echo "=========================================="

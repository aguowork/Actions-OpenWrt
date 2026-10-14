#!/usr/bin/env bash
set -euo pipefail

# 修改默认管理地址和主机名。
sed -i 's/192.168.1.1/192.168.31.1/g' package/base-files/files/bin/config_generate
sed -i "s/hostname='ImmortalWrt'/hostname='Redmi-AX6'/g" package/base-files/files/bin/config_generate

# 将编译时间写入 LuCI 系统概况和 SSH 登录 banner。
build_date=$(date +'%Y%m%d%H%M')
sed -i "s/DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION='ImmortalWrt By Guo ${build_date} '/g" package/base-files/files/etc/openwrt_release
sed -i "1s|^|编译时间 ${build_date} @ Guo\\n|" package/base-files/files/etc/banner
[ -f files/etc/banner ] && sed -i "1s|^|编译时间 ${build_date} @ Guo\\n|" files/etc/banner

# 移除 ImmortalWrt 自带的旧版 OpenAppFilter，改用上游版本。
echo "正在替换旧版 OAF 为上游 OpenAppFilter..."
rm -rf feeds/packages/net/open-app-filter \
       package/feeds/packages/open-app-filter \
       package/feeds/luci/luci-app-appfilter \
       feeds/luci/applications/luci-app-appfilter \
       package/luci-app-appfilter \
       package/OpenAppFilter
git clone --depth=1 https://github.com/destan19/OpenAppFilter.git package/OpenAppFilter

# 优先使用 LuCI 软件源中的 AdGuardHome；只有源码中缺少时才添加备用源码，避免重复定义。
if [ ! -f feeds/luci/applications/luci-app-adguardhome/Makefile ]; then
  echo "正在添加 luci-app-adguardhome 备用源码..."
  rm -rf package/feeds/luci/luci-app-adguardhome package/luci-app-adguardhome
  git clone --depth=1 https://github.com/kongfl888/luci-app-adguardhome.git package/luci-app-adguardhome
fi

# 用 aguowork 版本替换软件源中的 luci-app-wechatpush。
echo "正在替换 luci-app-wechatpush 为 aguowork 版本..."
rm -rf feeds/luci/applications/luci-app-wechatpush
git clone --depth=1 https://github.com/aguowork/luci-app-wechatpush.git feeds/luci/applications/luci-app-wechatpush

# 流量监控配置会自动选择 wrtbwmon；这里补充对应的软件包源码。
echo "正在添加 wechatpush 流量监控依赖 wrtbwmon..."
git clone --depth=1 https://github.com/brvphoenix/wrtbwmon.git package/wrtbwmon-source
mv package/wrtbwmon-source/wrtbwmon package/wrtbwmon
rm -rf package/wrtbwmon-source

# 应用与 wrt_release 一致的 miniupnpd 租期补丁。
MINIUPNPD_PACKAGE_DIR="feeds/packages/net/miniupnpd"
MINIUPNPD_PATCH="$GITHUB_WORKSPACE/$DIY_DIR/patches/miniupnpd/999-chanage-default-leaseduration.patch"
test -d "$MINIUPNPD_PACKAGE_DIR"
test -f "$MINIUPNPD_PATCH"
mkdir -p "$MINIUPNPD_PACKAGE_DIR/patches"
cp "$MINIUPNPD_PATCH" "$MINIUPNPD_PACKAGE_DIR/patches/"

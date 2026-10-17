#!/usr/bin/env bash
set -euo pipefail

echo "开始处理第三方包..."

# 替换 ImmortalWrt 自带的旧版 OpenAppFilter。
rm -rf feeds/packages/net/open-app-filter \
       package/feeds/packages/open-app-filter \
       package/feeds/luci/luci-app-appfilter \
       feeds/luci/applications/luci-app-appfilter \
       package/luci-app-appfilter \
       package/OpenAppFilter
git clone --depth=1 https://github.com/destan19/OpenAppFilter.git package/OpenAppFilter

# 优先使用 LuCI feed 中的 AdGuardHome，缺少时才添加备用源码。
if [ ! -f feeds/luci/applications/luci-app-adguardhome/Makefile ]; then
  echo "正在添加 luci-app-adguardhome 备用源码..."
  rm -rf package/feeds/luci/luci-app-adguardhome package/luci-app-adguardhome
  git clone --depth=1 https://github.com/kongfl888/luci-app-adguardhome.git package/luci-app-adguardhome
fi

# 使用 aguowork 维护的 luci-app-wechatpush。
rm -rf feeds/luci/applications/luci-app-wechatpush
git clone --depth=1 https://github.com/aguowork/luci-app-wechatpush.git feeds/luci/applications/luci-app-wechatpush

# wechatpush 流量监控依赖 wrtbwmon。
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

echo "第三方包处理完成！"

echo "开始修改系统配置..."
build_date=$(TZ=UTC-8 date "+%Y%m%d%H%M")

# 修改 OpenWrt 登录地址、密码和主机名。
sed -i 's/192.168.1.1/192.168.169.1/g' package/base-files/files/bin/config_generate
SHADOW_FILE="package/base-files/files/etc/shadow"
if ! grep -Fqx 'root:::0:99999:7:::' "$SHADOW_FILE"; then
  echo "上游 shadow 文件中的 root 默认行与预期不符" >&2
  exit 1
fi
sed -i 's|^root:::0:99999:7:::$|root:$1$wQIghyNn$dqPUfUazp1dDD/NvSSSs/1:20002:0:99999:7:::|' "$SHADOW_FILE"
sed -i "s/hostname='.*'/hostname='Redmi-AX6'/g" package/base-files/files/bin/config_generate

# 只保留 AX6 的 UCI 首次启动预设。
find files/etc/uci-defaults/ -type f ! -name 'AX6' -exec rm {} \;

# 在 LuCI 系统概况和 SSH banner 中显示编译时间。
sed -i "s/DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION='ImmortalWrt By Guo ${build_date} '/g" package/base-files/files/etc/openwrt_release
sed -i "1s|^|编译时间 ${build_date} @ Guo\\n|" package/base-files/files/etc/banner
[ -f files/etc/banner ] && sed -i "1s|^|编译时间 ${build_date} @ Guo\\n|" files/etc/banner

echo "系统配置修改完成！"

echo "开始配置脚本和定时任务..."

# 启用开机延迟执行脚本。
sed -i "s/#qdts~//g" files/etc/rc.local

# 启用 WiFi 切换定时任务。
sed -i 's/#zjwifi\*\/[^ ]* \*/\*\/56 \*/' files/etc/crontabs/root

# 配置与 AX6000 相同的无线中继候选网络。
echo '{"wifi":[{"name":"1309","encryption":"psk2","password":"13409941080","band":"2G","last_updated":"2024-11-14 18:33:40"},{"name":"Tenda_1F5600","encryption":"psk2","password":"qwer15207556371asdf","band":"2G","last_updated":"2024-11-14 18:33:40"},{"name":"b1403","encryption":"psk2","password":"13539012490","band":"2G","last_updated":"2024-11-14 18:33:40"},{"name":"TP-LINK_FCF3","encryption":"psk2","password":"17687610787","band":"2G","last_updated":"2024-11-14 18:33:40"}],"autowifiranking":[{"CQ_TIMES":0}]}' > files/etc/wx/wifi-config.json
sed -i 's/RETRY_INTERVAL=130/RETRY_INTERVAL=130/g' files/etc/JiaoBen/qdts.sh

echo "脚本和定时任务配置完成！"

echo "开始配置插件..."
: "${DDNSTO_TOKEN:?Missing GitHub Secret DDNSTO_TOKEN}"
echo -e "\toption token '${DDNSTO_TOKEN}'" >> feeds/nas/ddnsto/files/ddnsto.config
sed -i "s/option enabled '0'/option enabled '1'/g" feeds/nas/ddnsto/files/ddnsto.config
sed -i "s/option index '.*'/option index '0'/g" feeds/nas/ddnsto/files/ddnsto.config

echo "插件配置完成！"

# 确保 wx 项目在固件中可以直接运行。
chmod +x files/etc/uci-defaults/AX6
chmod +x files/www/cgi-bin/wx-auth.sh 2>/dev/null || true
chmod +x files/usr/libexec/rpcd/wx-wireless 2>/dev/null || true
chmod +x files/etc/wx/uninstall.sh 2>/dev/null || true

echo "=========================================="
echo "AX6 diy-part2.sh 全部执行完成！"
echo "=========================================="

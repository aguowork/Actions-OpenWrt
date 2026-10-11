#!/bin/bash
# DIY 第二阶段：feeds install 完成并追加固件配置后执行。
# 用途：准备配置中启用的第三方软件包源码。
set -euo pipefail

echo "开始准备 OAF 和微信推送软件包源码..."

# 清理冲突的软件包定义后，再引入 OpenAppFilter 上游源码。
rm -rf feeds/packages/net/open-app-filter \
       package/feeds/packages/open-app-filter \
       package/feeds/luci/luci-app-appfilter \
       feeds/luci/applications/luci-app-appfilter \
       package/luci-app-appfilter \
       package/OpenAppFilter
git clone --depth=1 https://github.com/destan19/OpenAppFilter.git package/OpenAppFilter

# 使用 aguowork 维护的微信推送版本替换 feeds 中的旧版本。
rm -rf feeds/luci/applications/luci-app-wechatpush
git clone --depth=1 https://github.com/aguowork/luci-app-wechatpush.git feeds/luci/applications/luci-app-wechatpush

echo "diy-part2.sh 执行完成"

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


# 修改openwrt登陆地址
sed -i 's/192.168.6.1/192.168.31.1/g' package/base-files/files/bin/config_generate
sed -i 's/\(root::0:0:99999:7:::\)/root:$1$2mmQ7Xbj$5FG6wrw3RA2zD\/WKktai\/.:19782:0:99999:7:::/g' package/base-files/files/etc/shadow

# 修改主机名字（不能纯数字或者使用中文）
sed -i "s/hostname='.*'/hostname='VIVO-S7'/g" package/base-files/files/bin/config_generate

# 修改开源驱动wifi名称
#sed -i 's/OpenWrt/R30B1_AX3000/g' package/kernel/mac80211/files/lib/wifi/mac80211.sh

# 修改闭源驱动2G wifi名称
sed -i 's/ImmortalWrt-2.4G/G/g' package/mtk/applications/mtwifi-cfg/files/mtwifi.sh
#sed -i 's/MT7981_AX3000_2.4G/2.4G/g' package/mtk/drivers/wifi-profile/files/mt7981/mt7981.dbdc.b0.dat
#sed -i 's/MT798x_AX3000_2.4G/2.4G/g' package/mtk/applications/gl-sdk4-mtk-wifi-v2/files/wireless.config
#sed -i 's/OpenWRT-2.4G/2.4G/g' package/mtk/drivers/wifi-profile/files/mt7981/files/lib/wifi/mt_dbdc.sh

# 修改闭源驱动5G wifi名称
sed -i 's/ImmortalWrt-5G/G5G/g' package/mtk/applications/mtwifi-cfg/files/mtwifi.sh
#sed -i 's/MT7981_AX3000_5G/G5G/g' package/mtk/drivers/wifi-profile/files/mt7981/mt7981.dbdc.b1.dat
#sed -i 's/MT798x_AX3000_5G/G5G/g' package/mtk/applications/gl-sdk4-mtk-wifi-v2/files/wireless.config
#sed -i 's/OpenWRT-5G/G5G/g' package/mtk/drivers/wifi-profile/files/mt7981/files/lib/wifi/mt_dbdc.sh

# 添加个性信息
#sed -i 's/R22.8.2/R22.8.2 by nanchuci/g' package/lean/default-settings/files/zzz-default-settings

#删除其他uci
find files/etc/uci-defaults/ -type f ! -name 'AX6000' -exec rm {} \;

# 脚本配置区
# 启用开机延迟100秒执行脚本
sed -i "s/#qdts~//g" files/etc/rc.local
#sed -i "s/#wifi~(sleep 150;/(sleep 150;/g" files/etc/rc.local


# 启用每30分钟检测是否断网切换无线脚本
sed -i 's/#wbzt\*\/[^ ]* \*/\*\/9 \*/' files/etc/crontabs/root
sed -i 's/#zjwifi\*\/[^ ]* \*/\*\/11 \*/' files/etc/crontabs/root

# 无线中继信号切换
#中继配置预设
echo '{"wifi":[{"name":"CMCC-Ptbf-5G","encryption":"psk2","password":"cccc5926","band":"5G","last_updated":"2024-11-14 18:33:40"}],"autowifiranking":[{"autowifiname":["Name1","Name2"],"CQ_TIMES":0}]}' | jq . > files/www/wx/wifi-config.json

#重新启动日志
sed -i 's/RETRY_INTERVAL=120/RETRY_INTERVAL=120/g' files/etc/JiaoBen/qdts.sh
#WBZT
sed -i 's/uid=123456789/uid=3192362522/g' files/etc/JiaoBen/wbzt.sh

#ddnsto
echo -e "\toption token '78846bf5-9a1f-4178-8aca-eeac5c38d4e6'" >> feeds/nas/network/services/ddnsto/files/ddnsto.config
sed -i "s/option enabled '0'/option enabled '1'/g" feeds/nas/network/services/ddnsto/files/ddnsto.config
sed -i "s/option index '.*'/option index '0'/g" feeds/nas/network/services/ddnsto/files/ddnsto.config
sed -i 's/DDNSTO 远程控制/ddnsto/g' feeds/nas_luci/luci/luci-app-ddnsto/luasrc/controller/ddnsto.lua
sed -i 's/远程开机服务/wol/g' feeds/nas_luci/luci/luci-app-ddnsto/luasrc/controller/ddnsto.lua
sed -i 's/共享磁盘/文件/g' feeds/nas_luci/luci/luci-app-ddnsto/luasrc/controller/ddnsto.lua
sed -i 's/启用后可支持控制台的“文件管理”及“远程开机”功能/启用后可支持控制台/g' feeds/nas_luci/luci/luci-app-ddnsto/luasrc/controller/ddnsto.lua
sed -i 's/DDNSTO远程控制是Koolcenter小宝开发的，支持http2的远程穿透控制插件。/DDNSTO Koolcenter小宝开发的，支持http2的穿透插件。/g' feeds/nas_luci/luci/luci-app-ddnsto/luasrc/controller/ddnsto.lua
sed -i 's|支持通过浏览器访问自定义域名访问内网设备后台、远程RDP/VNC桌面、远程文件管理等多种功能。|支持通过浏览器访问自定义域名等多种功能。|g' feeds/nas_luci/luci/luci-app-ddnsto/luasrc/controller/ddnsto.lua

sed -i 's/"应用过滤"/"过滤规则"/g' feeds/luci/applications/luci-app-appfilter/po/zh_Hans/appfilter.po
rm -rf feeds/luci/applications/luci-app-wechatpush
git clone https://github.com/aguowork/luci-app-wechatpush-tty228.git feeds/luci/applications/luci-app-wechatpush
sed -i "s/option device_name '.*'/option device_name 'AX6000'/g" feeds/luci/applications/luci-app-wechatpush/root/etc/config/wechatpush

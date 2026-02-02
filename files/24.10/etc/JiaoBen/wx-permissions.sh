#!/bin/sh
# wx-permissions.sh - wx项目权限设置脚本

echo "🔧 设置wx项目脚本权限..."

# wx项目核心脚本（需要执行权限）
SCRIPTS="
    /www/cgi-bin/wx-auth.sh
    /usr/libexec/rpcd/wx-wireless
    /etc/wx/uninstall.sh
    /etc/JiaoBen/fcjh.sh
    /etc/JiaoBen/llts.sh
    /etc/JiaoBen/qdts.sh
    /etc/JiaoBen/rz.sh
    /etc/JiaoBen/wbzt.sh
"

# wx项目配置文件（只需转换换行符，不需要执行权限）
CONFIG_FILES="
    /etc/wx/wx_settings.conf
"

FIXED_COUNT=0

for script in $SCRIPTS; do
    if [ -f "$script" ]; then
        # 转换换行符并设置权限
        sed -i 's/\r$//' "$script" 2>/dev/null
        chmod +x "$script" 2>/dev/null
        
        if [ -x "$script" ]; then
            echo "  ✅ $script"
            FIXED_COUNT=$((FIXED_COUNT + 1))
        else
            echo "  ❌ $script"
        fi
    fi
done

for config in $CONFIG_FILES; do
    if [ -f "$config" ]; then
        sed -i 's/\r$//' "$config" 2>/dev/null
        echo "  ✅ $config (换行符已修复)"
        FIXED_COUNT=$((FIXED_COUNT + 1))
    fi
done

echo "🎉 权限设置完成！共处理 $FIXED_COUNT 个文件"

#!/bin/sh

# 自动修复 Windows 换行符问题（如果从 Windows 上传）
if grep -q $'\r' "$0" 2>/dev/null; then
    sed -i 's/\r$//' "$0"
    exec sh "$0" "$@"
fi

# uninstall.sh - WiFi Manager 一键卸载脚本
# 此脚本将完全移除 WiFi Manager 相关文件和配置
# 
# 使用方法：
#   完全卸载: sh uninstall.sh

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }
log_question() { printf "${BLUE}[QUESTION]${NC} %s\n" "$1"; }

# 确认卸载操作
confirm_uninstall() {
    echo ""
    echo "═══════════════════════════════════════"
    echo "  WiFi Manager 卸载脚本"
    echo "═══════════════════════════════════════"
    echo ""
    log_warn "此操作将完全移除 WiFi Manager 及其所有相关文件！"
    log_warn "包括："
    echo "  • 前端文件 (/www/wx/)"
    echo "  • CGI 脚本 (/www/cgi-bin/wx-auth.sh)"
    echo "  • RPCD 脚本 (/usr/libexec/rpcd/wx-wireless)"
    echo "  • ACL 配置 (/usr/share/rpcd/acl.d/wx-wireless.json)"
    echo "  • 配置文件 (/etc/wx/)"
    echo ""
    
    # 检查是否存在相关文件
    files_exist=false
    if [ -d "/www/wx" ] || [ -f "/www/cgi-bin/wx-auth.sh" ] || [ -f "/usr/libexec/rpcd/wx-wireless" ] || [ -f "/usr/share/rpcd/acl.d/wx-wireless.json" ] || [ -d "/etc/wx" ]; then
        files_exist=true
    fi
    
    if [ "$files_exist" = false ]; then
        log_warn "未检测到 WiFi Manager 相关文件，可能已经卸载或从未安装。"
        echo ""
        log_question "是否继续执行卸载操作？(y/N): "
        read -r confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            log_info "取消卸载操作"
            exit 0
        fi
    else
        log_question "确认要继续卸载吗？(输入 'yes' 确认): "
        read -r confirm
        # 转换为小写进行比较（支持 yes/YES/Yes 等）
        confirm_lower=$(echo "$confirm" | tr 'A-Z' 'a-z')
        if [ "$confirm_lower" != "yes" ]; then
            log_info "取消卸载操作"
            exit 0
        fi
    fi
}

# 停止相关服务
stop_services() {
    log_info "停止相关服务..."
    
    # 直接尝试停止服务，不检查状态（避免服务未启动时的错误信息）
    if /etc/init.d/rpcd stop 2>/dev/null; then
        log_info "  ✓ rpcd 已停止"
    else
        log_info "  rpcd 未运行或停止失败"
    fi
    
    if /etc/init.d/uhttpd stop 2>/dev/null; then
        log_info "  ✓ uhttpd 已停止"
    else
        log_info "  uhttpd 未运行或停止失败"
    fi
}

# 删除前端文件
remove_frontend() {
    if [ -d "/www/wx" ]; then
        log_info "删除前端文件..."
        rm -rf /www/wx
        log_info "  ✓ /www/wx/ 已删除"
    else
        log_info "前端文件目录不存在，跳过"
    fi
}

# 删除 CGI 脚本
remove_cgi_scripts() {
    if [ -f "/www/cgi-bin/wx-auth.sh" ]; then
        log_info "删除 CGI 脚本..."
        rm -f /www/cgi-bin/wx-auth.sh
        log_info "  ✓ /www/cgi-bin/wx-auth.sh 已删除"
    else
        log_info "CGI 脚本不存在，跳过"
    fi
}

# 删除 RPCD 脚本
remove_rpcd_scripts() {
    if [ -f "/usr/libexec/rpcd/wx-wireless" ]; then
        log_info "删除 RPCD 脚本..."
        rm -f /usr/libexec/rpcd/wx-wireless
        log_info "  ✓ /usr/libexec/rpcd/wx-wireless 已删除"
    else
        log_info "RPCD 脚本不存在，跳过"
    fi
}

# 删除 ACL 配置
remove_acl_config() {
    if [ -f "/usr/share/rpcd/acl.d/wx-wireless.json" ]; then
        log_info "删除 ACL 配置..."
        rm -f /usr/share/rpcd/acl.d/wx-wireless.json
        log_info "  ✓ /usr/share/rpcd/acl.d/wx-wireless.json 已删除"
    else
        log_info "ACL 配置不存在，跳过"
    fi
}

# 删除配置文件
remove_config() {
    if [ -d "/etc/wx" ]; then
        log_info "删除配置文件..."
        rm -rf /etc/wx
        log_info "  ✓ /etc/wx/ 已删除"
    else
        log_info "配置文件目录不存在，跳过"
    fi
}

# 重启服务
restart_services() {
    log_info "重启服务..."
    
    if /etc/init.d/rpcd restart 2>/dev/null; then
        log_info "  ✓ rpcd 已重启"
    else
        log_warn "  rpcd 重启失败"
    fi
    
    if /etc/init.d/uhttpd restart 2>/dev/null; then
        log_info "  ✓ uhttpd 已重启"
    else
        log_warn "  uhttpd 重启失败"
    fi
}

# 清理残留文件
cleanup_residual() {
    log_info "清理残留文件..."
    
    # 清理特定的临时文件
    rm -f /tmp/wx_auth_token 2>/dev/null
    rm -f /tmp/wx_fail_count 2>/dev/null
    rm -rf /tmp/gitee_update 2>/dev/null
    rm -rf /tmp/wx-install 2>/dev/null
    
    # 注意：日志文件 /etc/wx/wx-wireless.log 会在删除 /etc/wx/ 目录时一并删除
    
    log_info "  ✓ 残留文件清理完成"
}

# 主卸载流程
main() {
    # 确认卸载
    confirm_uninstall
    
    echo ""
    log_info "开始卸载 WiFi Manager..."
    echo ""
    
    # 停止服务
    stop_services
    echo ""
    
    # 删除各个组件
    remove_frontend
    remove_cgi_scripts
    remove_rpcd_scripts
    remove_acl_config
    remove_config
    echo ""
    
    # 清理残留文件
    cleanup_residual
    echo ""
    
    # 重启服务
    restart_services
    echo ""
    
    echo "═══════════════════════════════════════"
    log_info "WiFi Manager 卸载完成！"
    echo "═══════════════════════════════════════"
    echo ""
    log_info "所有相关文件和服务配置已移除"
    echo ""
}

# 执行主函数
main "$@"

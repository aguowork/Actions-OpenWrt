#!/bin/sh

# wx-auth.sh - 独立密码认证和ubus代理CGI脚本
# 放置于 /www/cgi-bin/wx-auth.sh

# --- 基础路径配置 ---
CONFIG_DIR="/etc/wx"
LOG_FILE="$CONFIG_DIR/wx-wireless.log"
PASSWORD_FILE="$CONFIG_DIR/password.hash"
SETTINGS_FILE="$CONFIG_DIR/wx_settings.conf"

# === 硬编码配置 (与wx-wireless保持一致) ===
TOKEN_EXPIRY=3600                     # 登录Token有效期 (秒)
MAX_FAIL=10                           # 密码错误锁定次数
LOCK_TIME=3600                        # 锁定时长 (秒)

# 加载用户配置文件
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "Content-Type: application/json"
    echo ""
    echo '{"status":"error","message":"配置文件不存在"}'
    exit 0
fi
. "$SETTINGS_FILE"

# 获取设备名称（通过 DHCP 租约文件）
get_device_name() {
    local ip="$1"
    local name=$(grep "$ip" /tmp/dhcp.leases 2>/dev/null | awk '{print $4}')
    [ -z "$name" ] && name="未知设备"
    echo "$name"
}

# 日志记录函数
log_message() {
    local log_entry="$(date "+%Y-%m-%d %H:%M:%S") - $1"
    echo "$log_entry" >> "$LOG_FILE"
}

echo "Content-Type: application/json"
echo ""

# 获取action参数
ACTION=$(echo "$QUERY_STRING" | sed -n 's/.*action=\([^&]*\).*/\1/p')
METHOD=$(echo "$QUERY_STRING" | sed -n 's/.*method=\([^&]*\).*/\1/p')

# 鉴权函数（含过期检查）
check_auth() {
    if [ ! -f /tmp/wx_auth_token ]; then
        echo '{"status":"error","code":401,"message":"未授权的操作"}'
        exit 0
    fi
    
    read SERVER_TOKEN CREATE_TIME < /tmp/wx_auth_token 2>/dev/null
    CLIENT_TOKEN="$HTTP_AUTHORIZATION"
    
    # 验证Token
    if [ -z "$SERVER_TOKEN" ] || [ "$CLIENT_TOKEN" != "$SERVER_TOKEN" ]; then
        echo '{"status":"error","code":401,"message":"未授权的操作"}'
        exit 0
    fi
    
    # 验证过期时间
    NOW=$(date +%s)
    if [ -n "$CREATE_TIME" ] && [ $((NOW - CREATE_TIME)) -gt $TOKEN_EXPIRY ]; then
        rm -f /tmp/wx_auth_token
        echo '{"status":"error","code":401,"message":"登录已过期，请重新登录"}'
        exit 0
    fi
}

# === OTA 更新配置（不依赖 git：改用 HTTP 拉取 Gitee 归档，省掉 git + git-http 整套） ===
# 直接写完整 URL：路由器上排障时能原样复制到浏览器验证。换仓库改这两行即可。
GITEE_TAGS_API="https://gitee.com/api/v5/repos/okuni/wireless/tags"
GITEE_ARCHIVE_BASE="https://gitee.com/okuni/wireless/repository/archive"
VER_FILE="/www/wx/.ver"

# 下载 URL 到文件：curl 优先，其次 wget / uclient-fetch（OpenWrt 三者至少有一个）
http_download() {
    local url="$1"
    local out="$2"
    rm -f "$out"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 15 --max-time 180 -o "$out" "$url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 30 -O "$out" "$url" 2>/dev/null
    elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -T 30 -O "$out" "$url" 2>/dev/null
    else
        return 127
    fi || { rm -f "$out"; return 1; }
    [ -s "$out" ] || { rm -f "$out"; return 1; }
}

# 读取本机已安装版本，读不到按 0.0.0 处理
get_local_version() {
    local ver=""
    [ -f "$VER_FILE" ] && ver=$(tr -d ' \t\r\n' < "$VER_FILE" 2>/dev/null)
    # 去掉 UTF-8 BOM：.ver 若由 Windows PowerShell 5.1 的 Out-File -Encoding utf8 生成会带
    # 3 字节 BOM，BOM 混进版本号会让"检查更新"永远显示发现新版本，界面上还会多一个不可见字符
    ver=${ver#"$(printf '\357\273\277')"}
    [ -n "$ver" ] || ver="0.0.0"
    printf '%s' "$ver"
}

# 版本号归一化：忽略 v/V 前缀和大小写差异
# （.ver 里写的是 V3.0，Gitee tag 是 v3.0，直接字符串比较会永远显示"发现新版本"）
version_key() {
    printf '%s' "$1" | tr -d ' \t\r\n' | sed 's/^[vV]//' | tr 'A-Z' 'a-z'
}

# 取远程最新 tag：走 Gitee OpenAPI，取不到时返回空并以非 0 退出
get_remote_version() {
    local json="/tmp/wx_gitee_tags.json"
    local list=""
    local latest=""
    http_download "$GITEE_TAGS_API" "$json" || return 1
    if command -v jq >/dev/null 2>&1; then
        list=$(jq -r '.[].name // empty' "$json" 2>/dev/null)
    fi
    # jq 缺失或解析失败时退回文本解析：每个 tag 对象的第一个 "name" 就是 tag 名
    [ -n "$list" ] || list=$(sed 's/},{/}\n{/g' "$json" | sed -n 's/^[^{]*{*"name":"\([^"]*\)".*/\1/p')
    rm -f "$json"
    [ -n "$list" ] || return 1
    latest=$(printf '%s\n' "$list" | sort -V 2>/dev/null | tail -n 1)
    # busybox 未编译 sort -V 时退回普通排序
    [ -n "$latest" ] || latest=$(printf '%s\n' "$list" | sort | tail -n 1)
    [ -n "$latest" ] || return 1
    printf '%s' "$latest"
}

case "$ACTION" in
    check)
        # 检查密码是否已设置（使用独立文件，不污染系统 shadow）
        if [ -f "$PASSWORD_FILE" ] && [ -s "$PASSWORD_FILE" ]; then
            echo '{"password_set":true}'
        else
            echo '{"password_set":false}'
        fi
        ;;
    create)
        # 创建密码（存储到独立文件，不污染系统 shadow）
        read -r POST_DATA
        PASSWORD=$(echo "$POST_DATA" | sed 's/.*"password":"\([^"]*\)".*/\1/')
        
        if [ -f "$PASSWORD_FILE" ] && [ -s "$PASSWORD_FILE" ]; then
            echo '{"status":"error","message":"密码已存在"}'
            exit 0
        fi
        
        LEN=${#PASSWORD}
        if [ "$LEN" -lt 6 ]; then
            echo '{"status":"error","message":"密码长度不能少于6位"}'
            exit 0
        fi
        
        # 确保目录存在
        mkdir -p /etc/wx
        
        # 生成密码哈希并存储到独立文件
        ENCRYPTED=$(echo "$PASSWORD" | openssl passwd -1 -stdin)
        echo "$ENCRYPTED" > "$PASSWORD_FILE"
        chmod 600 "$PASSWORD_FILE"
        DEVICE=$(get_device_name "$REMOTE_ADDR")
        log_message "密码首次创建成功 (IP: $REMOTE_ADDR, 设备: $DEVICE, 密码: $PASSWORD)"
        echo '{"status":"success","message":"密码创建成功"}'
        ;;
    verify)
        # 验证密码
        FAIL_FILE="/tmp/wx_fail_count"
        
        # 检查锁定
        if [ -f "$FAIL_FILE" ]; then
            read LAST_TIME COUNT < "$FAIL_FILE"
            NOW=$(date +%s)
            DIFF=$((NOW - LAST_TIME))
            if [ "$COUNT" -ge "$MAX_FAIL" ] && [ "$DIFF" -lt "$LOCK_TIME" ]; then
                REMAIN=$((LOCK_TIME - DIFF))
                echo "{\"status\":\"locked\",\"message\":\"请${REMAIN}秒后重试\",\"remaining_time\":$REMAIN}"
                exit 0
            fi
            [ "$DIFF" -ge "$LOCK_TIME" ] && rm -f "$FAIL_FILE"
        fi
        
        read -r POST_DATA
        PASSWORD=$(echo "$POST_DATA" | sed 's/.*"password":"\([^"]*\)".*/\1/')
        
        # 从独立文件读取密码哈希
        if [ ! -f "$PASSWORD_FILE" ] || [ ! -s "$PASSWORD_FILE" ]; then
            echo '{"status":"error","message":"密码未设置"}'
            exit 0
        fi
        STORED=$(cat "$PASSWORD_FILE")
        
        TEST=$(echo "$PASSWORD" | openssl passwd -1 -stdin -salt "${STORED#\$1\$}")
        
        if [ "$TEST" = "$STORED" ]; then
            rm -f "$FAIL_FILE"
            # 生成 Token（含时间戳）
            TOKEN=$(cat /proc/sys/kernel/random/uuid | tr -d '-')
            echo "$TOKEN $(date +%s)" > /tmp/wx_auth_token
            DEVICE=$(get_device_name "$REMOTE_ADDR")
            log_message "用户登录成功 (IP: $REMOTE_ADDR, 设备: $DEVICE, 密码: $PASSWORD)"
            echo "{\"status\":\"success\",\"message\":\"验证成功\",\"token\":\"$TOKEN\"}"
        else
            NOW=$(date +%s)
            COUNT=1
            if [ -f "$FAIL_FILE" ]; then
                read LAST OLD_COUNT < "$FAIL_FILE"
                COUNT=$((OLD_COUNT + 1))
            fi
            echo "$NOW $COUNT" > "$FAIL_FILE"
            DEVICE=$(get_device_name "$REMOTE_ADDR")
            log_message "登录验证失败 (IP: $REMOTE_ADDR, 设备: $DEVICE, 尝试密码: $PASSWORD, 第${COUNT}次)"
            
            if [ "$COUNT" -ge "$MAX_FAIL" ]; then
                echo "{\"status\":\"locked\",\"message\":\"错误次数过多，请1小时后重试\",\"remaining_time\":$LOCK_TIME}"
            else
                REMAIN=$((MAX_FAIL - COUNT))
                echo "{\"status\":\"error\",\"message\":\"密码错误，还剩${REMAIN}次\",\"remaining_attempts\":$REMAIN}"
            fi
        fi
        ;;
    change)
        # 修改密码
        read -r POST_DATA
        OLD_PASSWORD=$(echo "$POST_DATA" | sed 's/.*"oldPassword":"\([^"]*\)".*/\1/')
        NEW_PASSWORD=$(echo "$POST_DATA" | sed 's/.*"newPassword":"\([^"]*\)".*/\1/')
        
        # 验证旧密码（从独立文件读取）
        if [ ! -f "$PASSWORD_FILE" ] || [ ! -s "$PASSWORD_FILE" ]; then
            echo '{"status":"error","message":"密码未设置"}'
            exit 0
        fi
        STORED=$(cat "$PASSWORD_FILE")
        
        TEST=$(echo "$OLD_PASSWORD" | openssl passwd -1 -stdin -salt "${STORED#\$1\$}")
        if [ "$TEST" != "$STORED" ]; then
            DEVICE=$(get_device_name "$REMOTE_ADDR")
            log_message "修改密码失败：原密码验证错误 (IP: $REMOTE_ADDR, 设备: $DEVICE, 尝试密码: $OLD_PASSWORD)"
            echo '{"status":"error","message":"当前密码错误"}'
            exit 0
        fi
        
        # 验证新密码长度
        LEN=${#NEW_PASSWORD}
        if [ "$LEN" -lt 6 ]; then
            echo '{"status":"error","message":"新密码长度不能少于6位"}'
            exit 0
        fi
        
        # 生成新密码加密形式并更新到独立文件
        NEW_ENCRYPTED=$(echo "$NEW_PASSWORD" | openssl passwd -1 -stdin)
        echo "$NEW_ENCRYPTED" > "$PASSWORD_FILE"
        chmod 600 "$PASSWORD_FILE"
        DEVICE=$(get_device_name "$REMOTE_ADDR")
        log_message "密码修改成功 (IP: $REMOTE_ADDR, 设备: $DEVICE, 旧密码: $OLD_PASSWORD, 新密码: $NEW_PASSWORD)"
        # 清除登录 token 文件（强制所有客户端重新登录）
        rm -f /tmp/wx_auth_token 2>/dev/null
        echo '{"status":"success","message":"密码修改成功，请重新登录"}'
        ;;
    reboot)
        check_auth
        log_message "用户手动重启系统"
        echo '{"status":"success","message":"系统即将重启"}'
        ( sleep 2 && reboot ) &
        ;;
    checkUpdate)
        # 检查更新（只检查版本，不执行更新）
        check_auth

        CURRENT_VERSION=$(get_local_version)
        LATEST_VERSION=$(get_remote_version)

        # 拉不到 tag 列表说明网络或接口异常，不能当成"已是最新版本"糊过去
        if [ -z "$LATEST_VERSION" ]; then
            log_message "检查更新失败：无法获取远程版本列表"
            echo '{"status":"error","message":"无法连接更新服务器，请检查网络"}'
            exit 0
        fi

        # 返回版本信息
        if [ "$(version_key "$CURRENT_VERSION")" = "$(version_key "$LATEST_VERSION")" ]; then
            echo "{\"status\":\"latest\",\"current_version\":\"$CURRENT_VERSION\",\"latest_version\":\"$LATEST_VERSION\",\"message\":\"已是最新版本\"}"
        else
            echo "{\"status\":\"available\",\"current_version\":\"$CURRENT_VERSION\",\"latest_version\":\"$LATEST_VERSION\",\"message\":\"发现新版本\"}"
        fi
        ;;
    doUpdate)
        # 执行更新（下载 tag 归档并通过 install.sh 安装）
        check_auth

        TEMP_DIR="/tmp/gitee_update"
        TARBALL="/tmp/wx_update.tar.gz"

        CURRENT_VERSION=$(get_local_version)
        LATEST_VERSION=$(get_remote_version)

        if [ -z "$LATEST_VERSION" ]; then
            echo '{"status":"error","message":"无法连接更新服务器，请检查网络"}'
            exit 0
        fi

        # 版本对比（二次确认）
        if [ "$(version_key "$CURRENT_VERSION")" = "$(version_key "$LATEST_VERSION")" ]; then
            echo "{\"status\":\"latest\",\"message\":\"已是最新版本 $CURRENT_VERSION\"}"
            exit 0
        fi

        # 下载该 tag 的源码归档
        rm -rf "$TEMP_DIR" "$TARBALL"
        if ! http_download "$GITEE_ARCHIVE_BASE/$LATEST_VERSION.tar.gz" "$TARBALL"; then
            echo '{"status":"error","message":"下载更新包失败，请检查网络"}'
            exit 0
        fi

        # 解包：先试 tar 自带的 gzip 直读，busybox 未编译该特性时退回管道解压
        mkdir -p "$TEMP_DIR"
        if ! tar -xzf "$TARBALL" -C "$TEMP_DIR" 2>/dev/null; then
            if ! gzip -dc "$TARBALL" 2>/dev/null | tar -x -C "$TEMP_DIR" 2>/dev/null; then
                rm -rf "$TEMP_DIR" "$TARBALL"
                echo '{"status":"error","message":"更新包解压失败"}'
                exit 0
            fi
        fi
        rm -f "$TARBALL"

        # 定位 install.sh（核心验证）
        # Gitee 归档会多包一层 "项目名-tag" 目录，目录名不写死，兼容两种结构
        INSTALL_SH=""
        if [ -f "$TEMP_DIR/scripts/install.sh" ]; then
            INSTALL_SH="$TEMP_DIR/scripts/install.sh"
        else
            for UPDATE_SUBDIR in "$TEMP_DIR"/*; do
                if [ -f "$UPDATE_SUBDIR/scripts/install.sh" ]; then
                    INSTALL_SH="$UPDATE_SUBDIR/scripts/install.sh"
                    break
                fi
            done
        fi
        if [ -z "$INSTALL_SH" ]; then
            rm -rf "$TEMP_DIR"
            echo '{"status":"error","message":"更新源异常，请联系开发者获取支持"}'
            exit 0
        fi

        # 先返回响应，再异步执行安装脚本（因为install.sh会重启uhttpd导致CGI中断）
        log_message "系统更新开始: $CURRENT_VERSION → $LATEST_VERSION"
        echo "{\"status\":\"success\",\"current_version\":\"$CURRENT_VERSION\",\"latest_version\":\"$LATEST_VERSION\",\"message\":\"更新成功\"}"

        # 异步执行安装脚本（延迟1秒确保响应已发送）
        ( sleep 1 && sh "$INSTALL_SH" >/dev/null 2>&1 && rm -rf "$TEMP_DIR" ) &
        ;;
    ubus)
        check_auth

        # ubus代理 - 调用wx-wireless服务
        if [ -z "$METHOD" ]; then
            echo '{"status":"error","message":"缺少method参数"}'
            exit 0
        fi
        
        # 获取当前crontab设置
        if [ "$METHOD" = "get_crontab" ]; then
            REGEX="wx-wireless"
            CRON_LINE=$(crontab -l 2>/dev/null | grep "$REGEX" | head -1)
            if [ -n "$CRON_LINE" ]; then
                # 提取 */15 中的数字
                INTERVAL=$(echo "$CRON_LINE" | sed 's/^\*\/\([0-9]*\).*/\1/')
                echo "{\"status\":\"success\",\"interval\":$INTERVAL}"
            else
                echo '{"status":"success","interval":0}'
            fi
            exit 0
        fi
        
        # 特殊处理set_crontab - 直接在CGI中处理
        if [ "$METHOD" = "set_crontab" ]; then
            read -r POST_DATA
            INTERVAL=$(echo "$POST_DATA" | sed 's/.*"interval":\([0-9]*\).*/\1/')
            INTERVAL=$(echo "$INTERVAL" | tr -cd '0-9')
            [ -z "$INTERVAL" ] && INTERVAL="0"
            
            CRON_CMD="/usr/libexec/rpcd/wx-wireless call auto_switch '{}'"
            REGEX="wx-wireless"
            
            # 获取当前crontab（排除wx-wireless相关行）
            CURRENT=$(crontab -l 2>/dev/null | grep -v "$REGEX")
            
            if [ "$INTERVAL" = "0" ]; then
                echo "$CURRENT" | crontab -
                /etc/init.d/cron reload 2>/dev/null
                echo '{"status":"success","message":"定时任务已关闭"}'
            else
                NEW_JOB="*/${INTERVAL} * * * * $CRON_CMD"
                printf "%s\n%s\n" "$CURRENT" "$NEW_JOB" | crontab -
                /etc/init.d/cron reload 2>/dev/null
                echo "{\"status\":\"success\",\"message\":\"定时任务已设置为每${INTERVAL}分钟执行\"}"
            fi
            exit 0
        fi
        
        # 直接调用 rpcd 脚本，避免 ubus 超时问题
        RPCD_SCRIPT="/usr/libexec/rpcd/wx-wireless"
        if [ "$REQUEST_METHOD" = "POST" ]; then
            read -r POST_DATA
            RESULT=$("$RPCD_SCRIPT" call "$METHOD" "$POST_DATA" 2>&1)
        else
            RESULT=$("$RPCD_SCRIPT" call "$METHOD" '{}' 2>&1)
        fi
        
        if [ $? -eq 0 ]; then
            echo "$RESULT"
        else
            echo "{\"status\":\"error\",\"message\":\"$RESULT\"}"
        fi
        ;;
    *)
        echo '{"status":"error","message":"无效操作"}'
        ;;
esac

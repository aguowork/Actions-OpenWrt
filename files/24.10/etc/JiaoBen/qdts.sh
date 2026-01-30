#!/bin/sh

# 消息推送相关参数
PUSH_API_URL="https://wxpusher.zjiecode.com/api/send/message"
APP_TOKEN="AT_jf0zuTx0PjA4qBnyCGeKf5J4t0DeUIc6"
MY_UID="UID_L22PV9Qdjy4q6P3d0dthW1TJiA3k"
PING_HOST="223.5.5.5"
DEVICE_NAME=$(uci get system.@system[0].hostname)
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
LOG_FILE="${SCRIPT_DIR}/$(basename $0 .sh).log"
MAX_LOG_SIZE=10
RETRY_INTERVAL=130

# 获取WiFi信息函数
get_wifi_info() {
    # 只执行一次uci命令获取所有无线配置，然后解析
    local wireless_config=$(uci show wireless 2>/dev/null)
    
    # 提取所有AP模式的iface配置（mode='ap'）
    local ap_ifaces=$(echo "$wireless_config" | grep -E "wireless\..*\.mode='ap'" | cut -d'.' -f2)
    local iface_count=$(echo "$ap_ifaces" | wc -l)
    
    if [ "$iface_count" -lt 2 ]; then
        log_message "警告：检测到AP接口数量不足，可能影响信息获取"
        echo "||||"
        return 1
    fi
    
    # 获取第一个和第二个AP接口的信息
    local iface1=$(echo "$ap_ifaces" | sed -n '1p')
    local iface2=$(echo "$ap_ifaces" | sed -n '2p')
    
    # 从已获取的配置中提取SSID和Key，避免重复执行uci命令
    local wifi_24g_ssid=$(echo "$wireless_config" | grep "wireless\.${iface1}\.ssid=" | cut -d"'" -f2)
    local wifi_24g_key=$(echo "$wireless_config" | grep "wireless\.${iface1}\.key=" | cut -d"'" -f2)
    local wifi_5g_ssid=$(echo "$wireless_config" | grep "wireless\.${iface2}\.ssid=" | cut -d"'" -f2)
    local wifi_5g_key=$(echo "$wireless_config" | grep "wireless\.${iface2}\.key=" | cut -d"'" -f2)
    
    # 检查是否成功获取信息
    if [ -z "$wifi_24g_ssid" ] || [ -z "$wifi_5g_ssid" ]; then
        log_message "警告：无法获取WiFi信息，请检查无线配置"
        echo "||||"
        return 1
    fi
    
    # 返回格式化的WiFi信息
    echo "${wifi_24g_ssid}|${wifi_24g_key}|${wifi_5g_ssid}|${wifi_5g_key}"
}

# 推送消息函数（升级版）
push_message() {
    local title="$1"
    local content="$2"
    local summary="$3"
    
    # 使用jq工具构建JSON数据，确保正确转义
    local json_data=$(jq -n \
        --arg appToken "$APP_TOKEN" \
        --arg content "$content" \
        --arg summary "$summary" \
        --arg contentType "2" \
        --arg uid "$MY_UID" \
        '{
            appToken: $appToken,
            content: $content,
            summary: $summary,
            contentType: ($contentType | tonumber),
            uids: [$uid]
        }')
    
    # 发送 POST 请求，设置超时
    local response=$(curl -s -w "%{http_code}" --connect-timeout 10 --max-time 15 -X POST -H "Content-Type: application/json" -d "$json_data" "$PUSH_API_URL" 2>&1)
    local http_code=$(echo "$response" | grep -o '[0-9]\{3\}$' | head -1)
    
    # 检查 HTTP 状态码
    if [ "$http_code" = "200" ]; then
        log_message "推送消息成功"
    else
        log_message "推送消息失败，HTTP状态码: $http_code"
    fi
}

# 生成启动通知内容
generate_startup_message() {
    local wifi_24g_ssid="$1"
    local wifi_24g_key="$2"
    local wifi_5g_ssid="$3"
    local wifi_5g_key="$4"
    
    # 生成完整内容
    local full_content="${DEVICE_NAME}|${wifi_24g_ssid}@${wifi_24g_key}|${wifi_5g_ssid}@${wifi_5g_key}"
    
    # 对完整内容进行base64加密
    local encoded_content=""
    if command -v base64 >/dev/null 2>&1; then
        encoded_content=$(echo -n "$full_content" | base64 2>/dev/null)
    else
        log_message "警告：系统不支持base64命令，使用明文显示"
    fi
    
    # 检查base64编码是否成功
    if [ -z "$encoded_content" ]; then
        log_message "警告：base64编码失败，使用明文显示"
        encoded_content="$full_content"
    fi
    
    # 完全重构HTML格式，使用最简单的copy标签
    local content="<copy data-clipboard-text=\"${encoded_content}\">${encoded_content}</copy>"
    
    echo "$content"
}

# 日志记录函数
check_log_size() {
    if [ -e "${LOG_FILE}" ]; then
        local size=$(du -s "${LOG_FILE}" | cut -f1)
        if [ "$size" -gt "$MAX_LOG_SIZE" ]; then
            log_message "日志文件大小超过了最大值，清空日志文件"
            > "${LOG_FILE}"
        fi
    fi
}

log_message() {
    printf "%s - %s\n" "$(date "+%Y-%m-%d %H:%M:%S")" "$1" >> "${LOG_FILE}"
    printf "%s - %s\n" "$(date "+%Y-%m-%d %H:%M:%S")" "$1"
}

# 检查互联网连通性
check_internet() {
    # 使用curl检查连通性，设置5秒超时
    if curl -s --connect-timeout 5 --max-time 10 --head "${PING_HOST}" > /dev/null 2>&1; then
        return 0
    else
        log_message "网络连通性检查失败"
        return 1
    fi
}

# 检查API可达性
check_api_reachable() {
    if curl -s --connect-timeout 5 --max-time 10 --head "${PUSH_API_URL}" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# 主程序
check_log_size

# 检查依赖工具
if ! command -v jq >/dev/null 2>&1; then
    log_message "错误：缺少jq工具，请安装jq后重试"
    exit 1
fi

log_message "${DEVICE_NAME}设备已重新启动！"

# 统一获取WiFi信息（只执行一次）
wifi_info=$(get_wifi_info)
if [ "$wifi_info" = "||||" ]; then
    log_message "WiFi信息获取失败，使用默认信息"
    wifi_24g_ssid="未知"
    wifi_24g_key="未知"
    wifi_5g_ssid="未知"
    wifi_5g_key="未知"
else
    wifi_24g_ssid=$(echo "$wifi_info" | cut -d"|" -f1)
    wifi_24g_key=$(echo "$wifi_info" | cut -d"|" -f2)
    wifi_5g_ssid=$(echo "$wifi_info" | cut -d"|" -f3)
    wifi_5g_key=$(echo "$wifi_info" | cut -d"|" -f4)
fi

# 记录WiFi信息到日志
log_message "WiFi信息 - 2.4G: ${wifi_24g_ssid}(${wifi_24g_key}), 5G: ${wifi_5g_ssid}(${wifi_5g_key})"

# 生成推送内容（传递参数，避免重复获取）
startup_content=$(generate_startup_message "$wifi_24g_ssid" "$wifi_24g_key" "$wifi_5g_ssid" "$wifi_5g_key")
startup_title="[${DEVICE_NAME}] 通知"
startup_summary="[${DEVICE_NAME}] 通知"

log_message "等待${RETRY_INTERVAL}秒后检查网络..."
sleep ${RETRY_INTERVAL}

if check_internet; then
    if check_api_reachable; then
        # 发送启动消息推送
        push_message "$startup_title" "$startup_content" "$startup_summary"
        log_message "通知推送完成"
        exit 0
    else
        log_message "API服务器不可达，跳过推送"
        exit 0
    fi
else
    log_message "网络连通异常，跳过推送"
    exit 0
fi

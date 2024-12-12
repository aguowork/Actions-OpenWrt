#!/bin/sh

# 消息推送相关参数
PUSH_API_URL="https://wxpusher.zjiecode.com/api/send/message/"
APP_TOKEN="AT_jf0zuTx0PjA4qBnyCGeKf5J4t0DeUIc6"
MY_UID="UID_L22PV9Qdjy4q6P3d0dthW1TJiA3k"
TOPIC_ID="25254"
PING_HOST="223.5.5.5"
DEVICE_NAME=$(uci get system.@system[0].hostname)
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
LOG_FILE="${SCRIPT_DIR}/$(basename $0 .sh).log"  # 日志文件的存储路径
MAX_LOG_SIZE=10
RETRY_INTERVAL=120

# 推送消息函数
push_message() {
    local content="$1"
    local json_data="{\"appToken\": \"$APP_TOKEN\", \"content\": \"$content\", \"topicId\": $TOPIC_ID, \"uids\": [\"$MY_UID\"]}"
    
    # 发送 POST 请求并指定 Content-Type 为 application/json
    local response=$(curl -s -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "$json_data" "$PUSH_API_URL")
    local http_code=${response:(-3)}
    
    # 检查 HTTP 状态码是否为 200，如果不是则记录错误信息
    if [ "$http_code" != "200" ]; then
        log_message "推送消息失败，HTTP 状态码: $http_code"
    fi
}

# 日志记录函数
# 检查日志文件大小
check_log_size() {
    if [ -e "${LOG_FILE}" ]; then
        local size=$(du -s "${LOG_FILE}" | cut -f1)
        if [ "$size" -gt "$MAX_LOG_SIZE" ]; then
            log_message "日志文件大小超过了最大值，清空日志文件\n"
            > "${LOG_FILE}"
        fi
    fi
}

log_message() {
    # 写入日志
    printf "%s - %s\n" "$(date "+%Y-%m-%d %H:%M:%S")" "$1" >> "${LOG_FILE}"
    # 输出日志信息到终端
    printf "%s - %s\n" "$(date "+%Y-%m-%d %H:%M:%S")" "$1"
}

# 检查互联网连通性
check_internet() {
    # 使用curl命令测试连通性
    if curl -s --head "${PING_HOST}" > /dev/null; then
        return 0 # 返回0 则可以访问互联网
    else
        log_message "${DEVICE_NAME}设备已重新启动，Internet异常！！"
        return 1 # 返回1 无法访问互联网
    fi
}
check_log_size
log_message "${DEVICE_NAME}设备已重新启动！"
sleep ${RETRY_INTERVAL}
if check_internet; then
    # 发送消息推送
    push_message "$(tail -n 1 "${LOG_FILE}")"
    exit 0 # 成功访问互联网，退出脚本
else
    log_message "${DEVICE_NAME}设备已重新启动，Internet异常！！"
    exit 0 # 成功访问互联网，退出脚本
fi

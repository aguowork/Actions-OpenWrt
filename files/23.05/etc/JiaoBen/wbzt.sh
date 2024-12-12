#!/bin/bash

SCRIPT_DIR=$(dirname "$(readlink -f "$0")") # 获取当前脚本所在目录
LOG_FILE="${SCRIPT_DIR}/$(basename $0 .sh).log" # 日志文件的存储路径
MAX_LOG_SIZE="100"                      # 日志文件最大大小，单位为KB
PUSH_API_URL="https://wxpusher.zjiecode.com/api/send/message/"
APP_TOKEN="AT_jf0zuTx0PjA4qBnyCGeKf5J4t0DeUIc6"
MY_UID="UID_L22PV9Qdjy4q6P3d0dthW1TJiA3k"
TOPIC_ID="25254"
KEY_FORMAT='#Key=".*-.*-.*-.*-.*-.*-.*"' # 日志文件第一行格式吗，正则表达式
# 设置错误处理的 trap
trap 'handle_error' ERR

# 错误处理函数
handle_error() {
    # 获取最后一次命令的退出状态
    local last_exit_status=$?
    # 获取错误发生的函数名
    local func_name=${FUNCNAME[1]}  # 获取调用 handle_error 的函数名，通常是发生错误的函数
    # 获取错误发生的行号
    local line_number=${BASH_LINENO[0]}

    if [ "$last_exit_status" != "0" ]; then
        log_message "发生错误：错误发生在函数 $func_name 的第 $line_number 行。已停止脚本执行，请检查脚本！"
        exit 1
    fi
}

# 日志记录函数
log_message() {
    local msg="$1"
    echo "$(date "+%Y-%m-%d %H:%M:%S") - $msg" | tee -a "${LOG_FILE}"
}

# 推送消息函数
push_message() {
    local content="$1"
    local json_data="{\"appToken\": \"$APP_TOKEN\", \"content\": \"$content\", \"topicId\": $TOPIC_ID, \"uids\": [\"$MY_UID\"]}"

    local response http_code
    response=$(curl -s -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "$json_data" "$PUSH_API_URL")
    http_code=${response:(-3)}

    if [ "$http_code" != "200" ]; then
        log_message "推送消息失败，HTTP 状态码: $http_code"
        return 1
    fi
}

# 检查日志文件是否存在，不存在则创建日志文件
check_log_file() {
    if [ ! -e "${LOG_FILE}" ]; then
        touch "${LOG_FILE}"
        echo "#Key=\"100-200-300-400-500-600-700\"" > "${LOG_FILE}"
        echo "日志文件不存在，已创建并且写入默认值"
    else
        # 检查日志文件大小
        FILE_SIZE=$(du -k "${LOG_FILE}" | cut -f1)
        if [ "${FILE_SIZE}" -gt "${MAX_LOG_SIZE}" ]; then
            > "${LOG_FILE}"  # 清空日志文件
            echo "文件大小超过最大值，已清空"
        fi

        # 检查日志文件第一行是否符合格式
        FIRST_LINE=$(head -n 1 "${LOG_FILE}")
        if ! [[ "${FIRST_LINE}" =~ ${KEY_FORMAT} ]]; then
            # 创建一个临时文件并写入新内容
            TEMP_FILE=$(mktemp)
            echo "#Key=\"100-200-300-400-500-600-700\"" > "${TEMP_FILE}"
            cat "${LOG_FILE}" >> "${TEMP_FILE}"
            mv "${TEMP_FILE}" "${LOG_FILE}"
            echo "日志文件第一行不符合格式，已插入默认值"
        fi
    fi
}


# 检查互联网连通性
check_internet() {
    if curl -s --head "223.5.5.5" >/dev/null; then
        return 0
    else
        return 1
    fi
}

check_internet #检查互联网连通性
check_log_file #检查日志文件是否存在，不存在则创建日志文件

# 执行 curl 命令，并将输出保存到 json 变量中
json_data=$(curl -s 'https://weibo.com/ajax/profile/info?uid=123456789' \
  -H 'user-agent: Mozilla/5.0 (compatible; OpenWrt-Curl/7.76.1)' \
  -H 'cookie: SUBP=0033WrSXqPxfM72-Ws9jqgMF55529P9D9WW8B_YqNSTTLAQjsCyQRNh7; SINAGLOBAL=407691405303.4852.1715057530312; ULV=1717117485200:3:3:1:6705765528571.046.1717117485174:1715134822016; UOR=,,cn.bing.com; WBPSESS=gJ7ElPMf_3q2cdj5JUfmvHwiwgiIZ7iWpDy9pdknT22VoYm35Lxd5oIpJGcEiFRbVf1dHSiQb_nE-YahsBKpEi7cWwoBB-CwIjMbAQH7YHz608OF33JN1SLi1zeI6fhJ; SUB=_2AkMROYwRf8NxqwFRmfsUy2vraYV_wgnEieKnZX3KJRMxHRl-yj9kql4HtRB6Ormi_i_OZvB3XEXW2okwJzfJoxB0r0VS; XSRF-TOKEN=s95Y3NytmKofRfQwiDNehSS9')

# 使用jq工具解析JSON数据并提取字段值
statuses_count=$(echo "$json_data" | jq -r '.data.user | .statuses_count')
friends_count=$(echo "$json_data" | jq -r '.data.user | .friends_count')
followers_count_str=$(echo "$json_data" | jq -r '.data.user | .followers_count_str')
description=$(echo "$json_data" | jq -r '.data.user | .description')
repost_cnt=$(echo "$json_data" | jq -r '.data.user.status_total_counter | .repost_cnt' | tr -d ',')
comment_cnt=$(echo "$json_data" | jq -r '.data.user.status_total_counter | .comment_cnt' | tr -d ',')
like_cnt=$(echo "$json_data" | jq -r '.data.user.status_total_counter | .like_cnt' | tr -d ',')


content=$(grep -m 1 -o '#Key="[^"]*"' "${LOG_FILE}" | sed 's/#Key="//; s/"//g')
# 按照 "-" 符号拆分字符串为数组
IFS='-' read -r -a array <<< "$content"

# 循环判断数值是否变化，若有变化则推送消息
if [ "$statuses_count" != "${array[0]}" ] || [ "$friends_count" != "${array[1]}" ] || [ "$followers_count_str" != "${array[2]}" ] || [ "$description" != "${array[3]}" ] || [ "$repost_cnt" != "${array[4]}" ] || [ "$comment_cnt" != "${array[5]}" ] || [ "$like_cnt" != "${array[6]}" ]; then
    # 写入日志文件
    sed -i "s/#Key=\"$content\"/#Key=\"$statuses_count-$friends_count-$followers_count_str-$description-$repost_cnt-$comment_cnt-$like_cnt\"/g" "${LOG_FILE}"
    # 推送消息
    log_message "NRGX NRS：$statuses_count GZS：$friends_count FSS：$followers_count_str GRJJ：$description LJZFL：$repost_cnt LJPLL：$comment_cnt LJHZ：$like_cnt  GXQ NRS：${array[0]} GZS：${array[1]} FSS：${array[2]} GRJJ：${array[3]} LJZFL：${array[4]} LJPLL：${array[5]} LJHZ：${array[6]} "
    # 推送消息
    push_message "NRGX\nNRS：$statuses_count\nGZS：$friends_count\nFSS：$followers_count_str\nGRJJ：$description\nLJZFL：$repost_cnt \nLJPLL：$comment_cnt \nLJHZ：$like_cnt  \n\nGXQ\nNRS：${array[0]}\nGZS：${array[1]}\nFSS：${array[2]}\nGRJJ：${array[3]} \nLJZFL：${array[4]} \nLJPLL：${array[5]} \nLJHZ：${array[6]}"
fi

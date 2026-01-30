#!/bin/bash

SCRIPT_DIR=$(dirname "$(readlink -f "$0")") # 获取当前脚本所在目录
LOG_FILE="${SCRIPT_DIR}/$(basename $0 .sh).log" # 日志文件的存储路径
MAX_LOG_SIZE="100"                      # 日志文件最大大小，单位为KB
PUSH_API_URL="https://wxpusher.zjiecode.com/api/send/message"
APP_TOKEN="AT_jf0zuTx0PjA4qBnyCGeKf5J4t0DeUIc6"
MY_UID="UID_L22PV9Qdjy4q6P3d0dthW1TJiA3k"
# 移除未使用的TOPIC_ID变量，保持与qdts.sh一致
KEY_FORMAT='#Key=".*-.*-.*-.*-.*-.*-.*"' # 日志文件第一行格式吗，正则表达式

# 微博用户ID解码（Base64编码隐藏真实ID）
WEIBO_UID_B64="MzE5MjM2MjUyMg=="
WEIBO_UID=$(echo "$WEIBO_UID_B64" | base64 -d 2>/dev/null)
if [ -z "$WEIBO_UID" ]; then
    echo "错误：配置解码失败"
    exit 1
fi
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
        return 0
    else
        log_message "推送消息失败，HTTP状态码: $http_code"
        return 1
    fi
}

# 推送异常通知函数
push_error_notification() {
    local error_msg="$1"
    local error_content="脚本异常通知\n\n错误信息：$error_msg\n\n请检查脚本状态！"
    
    # 推送异常通知（明文显示，不加密）
    if push_message "脚本异常通知" "$error_content" "脚本异常通知"; then
        log_message "异常通知推送成功"
    else
        log_message "异常通知推送失败"
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
json_data=$(curl "https://weibo.com/ajax/profile/info?uid=$WEIBO_UID" \
  -H 'cookie: __itrace_wid=8b97545f-536c-4071-0b4f-30e09d22a6b8; SINAGLOBAL=4230364064491.914.1742549919746; SUB=_2AkMfTHPWf8NxqwFRmfESxG7na4VxyArEieKpEIINJRMxHRl-yT9kqkIatRB6NMxdOZ69XdgFXJCd8bS6oam6zuK4Q_XK; SUBP=0033WrSXqPxfM72-Ws9jqgMF55529P9D9W5dDmhO_BzaZZOZ8jhc6ckX; ULV=1754020326257:2:1:1:1914175238695.7656.1754020326254:1742549919763; XSRF-TOKEN=RTknlgofA-SHEQ8fYz-sTldc; WBPSESS=voLfPs8eGy8pkyBjwwkfan7AknWcQRMSyA4XUzE6OS8PBLSCNPSY8WJxxC7z19gJMsV-z5Su6kyHBWbrouXl2k6iqdzcKDyFVWYKkrbbfRJ2ByllX1ffxV2HDMkhxaNka-xRm1z1uyga2FqxRJUM22IU-xn3tPAN5gQ-Gf9OBBI=' \
  -H "referer: https://weibo.com/u/$WEIBO_UID" \
  -H 'user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36')

# 检查微博API请求是否成功
if [ $? -ne 0 ] || [ -z "$json_data" ]; then
    push_error_notification "API请求失败，可能是网络问题或API失效"
    exit 1
fi

# 使用jq工具解析JSON数据并提取字段值
if ! command -v jq >/dev/null 2>&1; then
    push_error_notification "系统缺少jq工具，无法解析JSON数据"
    exit 1
fi

statuses_count=$(echo "$json_data" | jq -r '.data.user | .statuses_count' 2>/dev/null)
friends_count=$(echo "$json_data" | jq -r '.data.user | .friends_count' 2>/dev/null)
followers_count_str=$(echo "$json_data" | jq -r '.data.user | .followers_count_str' 2>/dev/null)
description=$(echo "$json_data" | jq -r '.data.user | .description' 2>/dev/null)
repost_cnt=$(echo "$json_data" | jq -r '.data.user.status_total_counter | .repost_cnt' | tr -d ',' 2>/dev/null)
comment_cnt=$(echo "$json_data" | jq -r '.data.user.status_total_counter | .comment_cnt' | tr -d ',' 2>/dev/null)
like_cnt=$(echo "$json_data" | jq -r '.data.user.status_total_counter | .like_cnt' | tr -d ',' 2>/dev/null)

# 检查数据解析是否成功
if [ -z "$statuses_count" ] || [ "$statuses_count" = "null" ]; then
    push_error_notification "数据解析失败，可能是API返回格式变化或Cookie失效"
    exit 1
fi


content=$(grep -m 1 -o '#Key="[^"]*"' "${LOG_FILE}" | sed 's/#Key="//; s/"//g')
# 按照 "-" 符号拆分字符串为数组，添加安全检查
if [ -z "$content" ]; then
    log_message "警告：无法从日志文件读取历史数据，使用默认值"
    content="100-200-300-400-500-600-700"
fi
IFS='-' read -r -a array <<< "$content"
# 确保数组有7个元素
while [ ${#array[@]} -lt 7 ]; do
    array+=("0")
done

# 获取历史值的辅助函数，遵循DRY原则
get_old_value() {
    local key="$1"
    case "$key" in
        "微博") echo "${array[0]}" ;;
        "关注") echo "${array[1]}" ;;
        "粉丝") echo "${array[2]}" ;;
        "个人简介") echo "${array[3]}" ;;
        "累计转发量") echo "${array[4]}" ;;
        "累计评论量") echo "${array[5]}" ;;
        "累计获赞") echo "${array[6]}" ;;
        *) echo "0" ;;
    esac
}

# 循环判断数值是否变化，若有变化则推送消息
changed_items=()
[ "$statuses_count" != "${array[0]}" ] && changed_items+=("微博:$statuses_count")
[ "$friends_count" != "${array[1]}" ] && changed_items+=("关注:$friends_count")
[ "$followers_count_str" != "${array[2]}" ] && changed_items+=("粉丝:$followers_count_str")
[ "$description" != "${array[3]}" ] && changed_items+=("个人简介:$description")
[ "$repost_cnt" != "${array[4]}" ] && changed_items+=("累计转发量:$repost_cnt")
[ "$comment_cnt" != "${array[5]}" ] && changed_items+=("累计评论量:$comment_cnt")
[ "$like_cnt" != "${array[6]}" ] && changed_items+=("累计获赞:$like_cnt")

if [ ${#changed_items[@]} -gt 0 ]; then
# 对个人简介进行安全处理，保留常用字符
safe_description=$(echo "$description" | sed 's/["\/\\]//g' | head -c 100)
if [ -z "$safe_description" ]; then
    safe_description="无简介"
fi

    # 写入日志文件 - 使用安全的个人简介
    new_key="$statuses_count-$friends_count-$followers_count_str-$safe_description-$repost_cnt-$comment_cnt-$like_cnt"
    temp_file=$(mktemp)
    sed "s|#Key=\"$content\"|#Key=\"$new_key\"|g" "${LOG_FILE}" > "$temp_file"
    mv "$temp_file" "${LOG_FILE}"
    
    # 生成推送内容
    push_content="最新数据
微博：$statuses_count
关注：$friends_count
粉丝：$followers_count_str
个人简介：$description
累计转发量：$repost_cnt
累计评论量：$comment_cnt
累计获赞：$like_cnt

更新了"
    
    # 添加变化的项目
    change_log=""
    for item in "${changed_items[@]}"; do
        key=$(echo "$item" | cut -d':' -f1)
        value=$(echo "$item" | cut -d':' -f2)
        old_value=$(get_old_value "$key")
        
        push_content="$push_content
$key：$old_value/$value"
        
        # 构建日志字符串
        if [ -n "$change_log" ]; then
            change_log="$change_log, $key $value (之前 $old_value)"
        else
            change_log="$key $value (之前 $old_value)"
        fi
    done
    
    # 对内容进行base64加密
    encoded_content=""
    if command -v base64 >/dev/null 2>&1; then
        # 使用printf确保换行符正确处理
        encoded_content=$(printf "%s" "$push_content" | base64 2>/dev/null)
    else
        log_message "警告：系统不支持base64命令，使用明文显示"
        encoded_content="$push_content"
    fi
    
    # 检查base64编码是否成功
    if [ -z "$encoded_content" ]; then
        log_message "警告：base64编码失败，使用明文显示"
        encoded_content="$push_content"
    fi
    
    # 使用HTML copy标签包装加密内容
    final_content="<copy data-clipboard-text=\"${encoded_content}\">${encoded_content}</copy>"
    
    # 记录日志 - 重用已构建的change_log变量
    log_message "微博数据更新：$change_log"
    
    # 推送消息
    if ! push_message "WNRGX" "$final_content" "WNRGX"; then
        push_error_notification "数据更新推送失败，可能是推送API失效"
    fi
fi

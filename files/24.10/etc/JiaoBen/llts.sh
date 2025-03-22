#!/bin/bash

# 文件路径
USAGE_DB="/tmp/usage.db"
OUTPUT_FILE="/tmp/lltj"
dhcp_name="/tmp/dhcp.leases"
exceeded_threshold="5242905" # 设置流量阈值，单位为字节，1KB=1024B
PING_HOST="223.5.5.5"                # 用于检测互联网连通性的服务器地址
SCRIPT_DIR=$(dirname "$(readlink -f "$0")") # 获取当前脚本所在目录
LOG_FILE="${SCRIPT_DIR}/$(basename $0 .sh).log" # 日志文件的存储路径
MAX_LOG_SIZE="100"                      # 日志文件最大大小，单位为KB
#DEVICE_NAME=$(uci get system.@system[0].hostname) #设备名称

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
        log_message "发生错误：错误码为 $last_exit_status，错误发生在函数 $func_name 的第 $line_number 行。已停止脚本执行，请检查脚本！"
        exit 1
    fi
}

# 日志函数
log_message() {
    local msg="$1"
    echo "$(date "+%Y-%m-%d %H:%M:%S") - $msg" | tee -a "${LOG_FILE}"
}

# 检查日志文件大小
check_log_size() {
    if [ -e "${LOG_FILE}" ]; then
        local size=$(du -s "${LOG_FILE}" | cut -f1)
        if [ "$size" -gt "$MAX_LOG_SIZE" ]; then
            log_message "日志文件大小超过了最大值，清空日志文件"
            > "${LOG_FILE}"
        fi
    fi
}

# 互联网连通性 用的是阿里dns 223.5.5.5
check_internet() {
    if curl -s --head "${PING_HOST}" >/dev/null; then
        # log_message "可以访问Internet"
        return 0
    else
        log_message "无法访问Internet, 停止检测，请检查网络！"
        exit 0
        return 1
    fi
}

# 定义发送消息的函数
send_push_notification() {
    local PUSH_URL="https://wxpusher.zjiecode.com/api/send/message"
    local APP_TOKEN="AT_jf0zuTx0PjA4qBnyCGeKf5J4t0DeUIc6"
    local MYUIDS=("UID_L22PV9Qdjy4q6P3d0dthW1TJiA3k")
    local UIDS=$(IFS=, ; echo "${MYUIDS[*]}")

    # 构建Markdown格式的消息内容
    local MESSAGE='{
      "appToken": "'"$APP_TOKEN"'",
      "content": "'"$2"'",
      "contentType": 3,
      "uids": ["'"$UIDS"'"],
      "summary": "'"$1"'"
    }'

    # 发送POST请求，并检查是否成功
    local HTTP_STATUS
    HTTP_STATUS=$(curl -sSf -o /dev/null -w "%{http_code}\\n" -X POST -H "Content-Type: application/json" -d "$MESSAGE" "$PUSH_URL")

    if [ $HTTP_STATUS -ne 200 ]; then
        log_message "$(date "+%Y-%m-%d %H:%M:%S") 推送失败，HTTP状态码：$HTTP_STATUS"
    fi
    # 使用示例：send_push_notification "$1" "$2"
}

# 用MAC查找主机名, 返回主机名
function lookup_device_info {
    local DHCP_MAC="$1"
    # 检查dhcp文件是否存在
    if [ -f "$dhcp_name" ]; then
        # 使用grep和awk来查找匹配的MAC地址并提取主机名称
        host_name=$(grep -w "$DHCP_MAC" "$dhcp_name" | awk '{print $4}')
        # 检查是否找到了主机名称
        if [ -n "$host_name" ]; then
            echo "$host_name"
        else
            echo "unknown"
        fi
    else
        echo "No_dhcp"
    fi
    # 使用示例：变量=$(lookup_device_info "$DHCP_MAC")，其中$MAC为要查找的MAC地址
}

# 流量数据单位换算
bytes_for_humans() {
	[ -z "$1" ] && return
	[ "$1" -gt 1073741824 ] && echo "$(awk 'BEGIN{printf "%.2f\n",'$1'/'1073741824'}') GB" && return
	[ "$1" -gt 1048576 ] && echo "$(awk 'BEGIN{printf "%.2f\n",'$1'/'1048576'}') MB" && return
	[ "$1" -gt 1024 ] && echo "$(awk 'BEGIN{printf "%.2f\n",'$1'/'1024'}') KB" && return
	echo "${1} bytes"
}

# 查找无线接口Dbm值
find_Dbm() {
    local wxjk_dbm
    wxjk_dbm=$(iwinfo "$(uci get wireless.@wifi-iface[0].device)" assoclist | grep -i "$1" | grep -oE '[-]?[0-9]+ dBm' | grep -oE '[-]?[0-9]+')
    if [ -z "$wxjk_dbm" ]; then
        wxjk_dbm=$(iwinfo "$(uci get wireless.@wifi-iface[1].device)" assoclist | grep -i "$1" | grep -oE '[-]?[0-9]+ dBm' | grep -oE '[-]?[0-9]+')
        if [ -z "$wxjk_dbm" ]; then
            #wxjk_dbm="$(uci get wireless.@wifi-iface[0].device)|$(uci get wireless.@wifi-iface[1].device)Not found"
	    wxjk_dbm=""
        fi
    fi
    echo "$wxjk_dbm"
    # 使用示例：变量=$(find_Dbm "$1")，其中$1为要查找的MAC地址
}

# 函数：获取所有关键词的位置
get_column_positions() {
    local header
    header=$(sed '1s/^#//' "$USAGE_DB") || { log_message "错误：无法从 $USAGE_DB 中读取文件头"; exit 1; }
    
    local keywords=("mac" "ip" "total" "out" "in")
    local positions=()

    for keyword in "${keywords[@]}"; do
        local pos
        pos=$(awk -F ',' -v key="$keyword" '{for (i=1; i<=NF; i++) if ($i == key) {print i; exit}}' <<< "$header")
        positions+=("$pos")
    done

    echo "${positions[*]}"
}

#此处是脚本开始位置------------------------------------------
check_log_size #检查日志文件大小
# 如果输出文件不存在，则创建并写入数据
if [ ! -f "$USAGE_DB" ]; then
    log_message "usage.db文件不存在，请检查是否安装了wrtbwmon，即将退出脚本"
    #exit 0
    exit 1 # 终止脚本运行
fi

# 如果输出文件不存在，则创建并写入数据
if [ ! -f "$OUTPUT_FILE" ]; then
    log_message "文件不存在，创建文件"
    touch "$OUTPUT_FILE"
    log_message "创建文件成功，即将写入数据"
    awk -F ',' '!/^#/ {print $1 "," $8 "," $6 "," $7}' "$USAGE_DB" > "$OUTPUT_FILE"
    log_message "usage.db数据写入/tmp/lltj完成，即将退出脚本！"
    exit 1 # 终止脚本运行
elif check_internet; then # 检测到网络不可用，则退出脚本

    # 声明数组，用于存储数据
    declare -a usage_array lltj_array

    # 使用awk提取usage.db的数据，并存入数组
    # mac,ip,iface,speed_in,speed_out,in,out,total,first_date,last_date
    # 获取关键词位置
    IFS=' ' read -r mac_wz ip_wz total_wz out_wz in_wz <<< "$(get_column_positions)"
    #echo "位置：mac -> $mac_wz, ip -> $ip_wz, total -> $total_wz, out -> $out_wz, in -> $in_wz"
    # mapfile -t usage_array < <(awk -F ',' '!/^#/ {print $1 "," $2 "," $8 "," $7 "," $6}' "$USAGE_DB")
    mapfile -t usage_array < <(awk -v mac_wz="$mac_wz" -v ip_wz="$ip_wz" -v total_wz="$total_wz" -v out_wz="$out_wz" -v in_wz="$in_wz" -F ',' '!/^#/ {print $mac_wz "," $ip_wz "," $total_wz "," $out_wz "," $in_wz}' "$USAGE_DB")
    # 使用awk提取lltj文件的数据，并存入数组
    mapfile -t lltj_array < <(awk -F ',' '!/^#/ {print $1 "," $2 "," $3 "," $4 "," $5}' "$OUTPUT_FILE")

    # 定义变量，用于存储push内容，push_nr为推送内容
    push_nr=""
     # 推送设备名称
    push_name=""
    # 遍历usage_array中的每一行
    for line in "${usage_array[@]}"; do
        # "/tmp/usage.db" 的 mac地址，IP地址，总流量，上传流量，下载流量
        IFS=',' read -r usage_mac usage_ip usage_total usage_out usage_in <<< "$line"

        # 内循环 在lltj_array中查找相同的MAC地址
        for item in "${lltj_array[@]}"; do
            # "/tmp/lltj" 的 mac地址，IP地址，总流量，上传流量，下载流量
            IFS=',' read -r lltj_mac lltj_ip lltj_total lltj_out lltj_in <<< "$item"

            # 如果找到相同的MAC地址和ip地址，则进行流量比较
            if [ "$usage_mac" = "$lltj_mac" ] && [ "$usage_ip" = "$lltj_ip" ]; then
                # usage_total为当前流量，lltj_total为上次流量，减去计算出本次流量，单位为字节
                exceeded=$((usage_total - lltj_total))
                #echo "客户端：$(lookup_device_info "$usage_mac") $(bytes_for_humans "$exceeded") 总流量：$(bytes_for_humans "$usage_total")"
                # 判断本次流量是否大于exceeded_threshold阈值，如果大于则输出MAC地址和超出的流量明细，并退出内循环
                if [ $exceeded -gt $exceeded_threshold ]; then
                    log_message "客户端：$(lookup_device_info "$usage_mac") IP: $usage_ip 总: $(bytes_for_humans "${usage_total}") 一分钟总: $(bytes_for_humans "${exceeded}") 一分钟上传: $(bytes_for_humans "$((usage_out - lltj_out))") 一分钟下载: $(bytes_for_humans "$((usage_in - lltj_in))") DBM: $(find_Dbm "$usage_mac")"
                    push_nr="${push_nr}\`\`\`\n客户端：$(lookup_device_info "$usage_mac")\nIP地址：$usage_ip\nMAC地址：$usage_mac\n总流量：$(bytes_for_humans "${usage_total}")\n一分钟流量：$(bytes_for_humans "${exceeded}")\n一分钟上传：$(bytes_for_humans "$((usage_out - lltj_out))")\n一分钟下载：$(bytes_for_humans "$((usage_in - lltj_in))")\nDBM：$(find_Dbm "$usage_mac")\n\`\`\`\n"
                    push_name=$push_name"$(lookup_device_info "$usage_mac") "
                fi
                break  # 找到匹配的MAC地址后跳出内循环
            fi
        done
    done
    
    # 判断push_nr是否为空，如果不为空则执行推送
    if [ -n "$push_nr" ]; then
        send_push_notification "$push_name 流量异常" "$push_nr"
    else
        echo "没有内容推送"
    fi
    
    # 将usage_array的所有数据一次性写入/tmp/lltj文件中
    (IFS=$'\n'; echo "${usage_array[*]}") > "$OUTPUT_FILE"
    # 删除数组
    unset usage_array usage_total usage_mac lltj_array usage_mac usage_total usage_in usage_out lltj_mac lltj_total lltj_in lltj_out exceeded push_nr push_name mac_wz ip_wz total_wz out_wz in_wz
fi

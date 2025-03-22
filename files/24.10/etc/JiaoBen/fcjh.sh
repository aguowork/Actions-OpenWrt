#!/bin/bash
# 用shuf依赖coreutils
# 安装coreutils
# sudo apt-get update
# sudo apt-get install coreutils

SCRIPT_DIR=$(dirname "$(readlink -f "$0")") # 获取当前脚本所在目录
LOG_FILE="${SCRIPT_DIR}/$(basename $0 .sh).log" # 日志文件的存储路径
MAX_LOG_SIZE="1000"                      # 日志文件最大大小，单位为KB
day_of_week=$(date '+%u')  # %u 输出 1-7 表示星期一到星期天
newline=$'\n' # 定义换行符
set_time="20" # 设置进入判断的时间
app_id="jmqplgjtnssrjbcp"
app_secret="eROnBwfFMHx7zVpgvFuApOroKmy0gy56"


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
        log_message "发生错误：错误码为${last_exit_status}，错误发生在函数${func_name}的第${line_number}行，已停止脚本执行，请检查脚本！"
        exit 1
    fi
}

# 日志函数
log_message() {
    local msg="$1"
    echo "$(date "+%Y-%m-%d %H:%M:%S")|$msg" | tee -a "${LOG_FILE}"
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

# 定义检查日志文件的函数
check_log_file() {
    # 读取文件的最后一行到变量
    local last_line=$(tail -n 1 "$LOG_FILE")
    # 使用逗号作为分隔符拆分字符串并构建数组
    IFS='|' read -r -a log_array <<< "$last_line"

    # 提取需要的部分，重新构建数组
    local timestamp="${log_array[0]}" # timestamp是时间戳，格式为YYYY-MM-DD HH:mm:ss
    local game_name="${log_array[1]}" # game_name是彩票名称，格式为字母组合
    local issue="${log_array[2]}" # issue是期号，格式为数字
    local red_balls="${log_array[3]}" # red_balls是红球，格式为数字
    local blue_balls="${log_array[4]}" # blue_balls是蓝球，格式为数字
    if [[ $timestamp =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
        local extracted_date="${BASH_REMATCH[1]}"
        local current_date=$(date '+%Y-%m-%d')

        # 判断时间戳中提取的日期是否等于今天的日期
        if [ "$extracted_date" != "$current_date" ]; then
            echo "错误：时间戳不等于今天的日期"
            exit 1
        fi
    else
        echo "错误：无法从时间戳中提取有效的日期部分"
        exit 1
    fi

    # 判断第二部分是否是字母组合
    if [[ ! $game_name =~ ^[[:alpha:]]+$ ]]; then
        echo "错误：第二部分不是字母组合"
        exit 1
    fi

    # 构建最终的日志结果数组
    local log_result=("$extracted_date" "$game_name" "$issue" "$red_balls" "$blue_balls")
    # 返回数组
    echo "${log_result[@]}"
}


# 定义发送消息的函数
send_push_notification() {
    local PUSH_URL="https://wxpusher.zjiecode.com/api/send/message"
    local APP_TOKEN="AT_jf0zuTx0PjA4qBnyCGeKf5J4t0DeUIc6"
    local TOPICIDS="33181"
    # APP_TOKEN 是应用的Token
    # TOPICIDS 是主题ID
    # summary 是标题
    # content 是推送内容

    # 使用命令行参数构建消息内容，而不是直接在JSON字符串中嵌入变量
    local MESSAGE=$(jq -n \
        --arg summary "$1" \
        --arg content "$2" \
        --arg topicIds "$TOPICIDS" \
        --arg appToken "$APP_TOKEN" \
        '{appToken: $appToken, content: "```\n\($content)\n```", contentType: 3, topicIds: [$topicIds], summary: $summary}')

    # 发送POST请求，并检查是否成功
    local HTTP_STATUS
    HTTP_STATUS=$(curl -sSf -o /dev/null -w "%{http_code}\\n" -X POST -H "Content-Type: application/json" -d "$MESSAGE" "$PUSH_URL")

    if [ $HTTP_STATUS -ne 200 ]; then
        echo "$(date "+%Y-%m-%d %H:%M:%S") 推送失败，HTTP状态码：$HTTP_STATUS"
    fi
    # 示例函数调用
    # send_push_notification "标题" "内容"
}

# 函数：生成并发送彩票推荐
generate_lottery_recommendation() {
    check_log_size #检查日志是否存在和文件大小
    # 生成彩票推荐
    case "$day_of_week" in
        "2" | "4" | "7")  # 星期二、星期四、星期日发送双色球推荐
                if check_time_before "${set_time}"; then
                    numbers=($(shuf -i 1-33 -n 6 | sort -n))
                    special_number=$(printf "%02d" $(shuf -i 1-16 -n 1))
                    formatted_numbers=$(IFS=,; printf "%02d," "${numbers[@]}")
                    formatted_numbers=${formatted_numbers%,}  # 去除最后一个逗号
                    # 获取最新期号和上期开奖号码
                    local info_array=($(get_latest_lottery_info "ssq"))
                    log_message "ssq|$(expr ${info_array[1]} + 1)|$formatted_numbers|$special_number"
                    IFS=@ read -r -a red_balls <<< $(echo "${info_array[2]}" | sed "s/+/@/; s/+/,/g")
                    send_push_notification "${info_array[0]}推荐" "${info_array[0]}推荐${newline}本期期号：$(expr ${info_array[1]} + 1)${newline}红球：${formatted_numbers}${newline}蓝球：${special_number}${newline}${newline}上期开奖号码${newline}红球：${red_balls[0]}${newline}蓝球：${red_balls[1]}"

                else
                    # 查询开奖结果
                    echo "当前时间晚于 19:00，即将获取彩票开奖结果"    
                    # 从日志文件获取最新的一组发财号，并检查彩票开奖结果
                    check_lottery_result=($(check_log_file))
                    # 查询彩票开奖结果
                    check_lottery "${check_lottery_result[1]}" "${check_lottery_result[2]}" "${check_lottery_result[3]}@${check_lottery_result[4]}"
                fi
            ;;
        "1" | "3" | "6")  # 星期一、星期三、星期五发送大乐透推荐
                if check_time_before "${set_time}"; then
                    numbers=($(shuf -i 1-35 -n 5 | sort -n))
                    special_numbers=($(shuf -i 1-12 -n 2 | sort -n))
                    formatted_numbers=$(IFS=,; printf "%02d," "${numbers[@]}")
                    formatted_numbers=${formatted_numbers%,}  # 去除最后一个逗号
                    formatted_special=$(IFS=,; printf "%02d," "${special_numbers[@]}")
                    formatted_special=${formatted_special%,}  # 去除最后一个逗号

                    # 获取最新期号和上期开奖号码
                    local info_array=($(get_latest_lottery_info "cjdlt"))
                    log_message "cjdlt|$(expr ${info_array[1]} + 1)|$formatted_numbers|$formatted_special"
                    IFS=@ read -r -a red_balls <<< $(echo "${info_array[2]}" | sed "s/+/@/; s/+/,/g")
                    send_push_notification "${info_array[0]}推荐" "${info_array[0]}推荐${newline}本期期号：$(expr ${info_array[1]} + 1)${newline}红球：${formatted_numbers}${newline}蓝球：${formatted_special}${newline}${newline}上期开奖号码${newline}红球：${red_balls[0]}${newline}蓝球：${red_balls[1]}"
                else
                    # 查询开奖结果
                    echo "当前时间晚于 19:00，即将获取彩票开奖结果"    
                    # 从日志文件获取最新的一组发财号，并检查彩票开奖结果
                    check_lottery_result=($(check_log_file))
                    # 查询彩票开奖结果
                    check_lottery "${check_lottery_result[1]}" "${check_lottery_result[2]}" "${check_lottery_result[3]}@${check_lottery_result[4]}"
                fi
            ;;
        *)  # 其他日期
            case "$day_of_week" in
                "1") day_name="星期一" ;;
                "2") day_name="星期二" ;;
                "3") day_name="星期三" ;;
                "4") day_name="星期四" ;;
                "5") day_name="星期五" ;;
                "6") day_name="星期六" ;;
                "7") day_name="星期日" ;;
                *) day_name="未知" ;;
            esac
            log_message "今天不是推送日期，今天是$day_name，不发送消息。"
            ;;
    esac
    # 示例函数调用
    # generate_lottery_recommendation
}



# 定义函数：获取最新的彩票信息并返回数组
get_latest_lottery_info() {
    local code="$1"
    local api_url="https://www.mxnzp.com/api/lottery/common/latest"

    # 发送API请求
    response=$(curl -s "${api_url}?code=${code}&app_id=${app_id}&app_secret=${app_secret}")

    # 解析JSON响应
    code=$(echo "$response" | jq -r '.code')
    if [[ $code -ne 1 ]]; then
        msg=$(echo "$response" | jq -r '.msg')
        echo "错误：$msg"
        return 1
    fi

    data=$(echo "$response" | jq -r '.data')

    # 从数据中提取信息
    name=$(echo "$data" | jq -r '.name')
    expect=$(echo "$data" | jq -r '.expect')
    openCode=$(echo "$data" | jq -r '.openCode')
    time=$(echo "$data" | jq -r '.time')

    # 将结果保存到数组
    local result=()
    result+=("${name}")
    result+=("${expect}")
    result+=("${openCode}")
    result+=("${time}")

    # 返回数组
    echo "${result[@]}"
    # 调用函数并接收返回的数组
    #info_array=($(get_latest_lottery_info "ssq"))

    # 输出数组的各个元素
    #echo "彩票名称: ${info_array[0]}"
    #echo "彩票期号: ${info_array[1]}"
    #echo "开奖号码: ${info_array[2]}"
    #echo "开奖时间: ${info_array[3]}"
}

function check_lottery {
    # 查询彩票结果
    # 参数: code, expect, lotteryNo, app_id, app_secret
    local code=$1
    local expect=$2
    local lotteryNo=$3

    # 构造URL
    local url="https://www.mxnzp.com/api/lottery/common/check"
    url="${url}?code=${code}&expect=${expect}&lotteryNo=${lotteryNo}&app_id=${app_id}&app_secret=${app_secret}"

    # 发送GET请求
    local response=$(curl -s "$url")

    # 解析JSON响应
    local code_status=$(echo "$response" | jq -r '.code')
    if [ -z "$code_status" ]; then
        local error_msg=$(echo "$response" | jq -r '.msg')
        echo "API请求失败: $error_msg"
        return
    fi

    if [ "$code_status" -eq 1 ]; then
        local codeValue=$(echo "$response" | jq -r '.data.codeValue')
        local expect=$(echo "$response" | jq -r '.data.expect')
        local checkedCode=$(echo "$response" | jq -r '.data.checkedCode')
        local openCode=$(echo "$response" | jq -r '.data.openCode')
        local resultDesc=$(echo "$response" | jq -r '.data.resultDesc')
        local resultDetails=$(echo "$response" | jq -r '.data.resultDetails')
        # 格式化输出
        send_push_notification "${resultDetails}" "彩票开奖结果${newline}彩票名称：${codeValue}${newline}彩票期号: ${expect}${newline}我的号码：${checkedCode}${newline}开奖号码: $(echo "$openCode" | sed 's/+/@/; s/+/,/g')${newline}中奖结果：${resultDesc}${newline}中奖金额：${resultDetails}"
    else
        echo "错误：API返回失败，错误码：$code_status"
        send_push_notification "开奖查询异常" "API返回失败，错误码：$code_status"
    fi
    # 示例用法
    #check_lottery "cjdlt" "2024088" "23,01,02,32,28@02,05"
}

function check_time_before() {
    # 获取当前小时
    local current_hour=$(date +%H)
    # 传递给函数的时间数值
    local threshold_hour=$1
    if [ "$current_hour" -lt "$threshold_hour" ]; then
        return 0
    else
        return 1
    fi
    # 示例用法
    # if check_time_before "17"; then
    # if ! check_time_before "17"; then
}

generate_lottery_recommendation

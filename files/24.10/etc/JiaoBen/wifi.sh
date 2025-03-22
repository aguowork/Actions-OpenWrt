#!/bin/bash
# 获取脚本名称作为锁文件名目录
LOCKFILE="/tmp/$(basename "${BASH_SOURCE%.*}").lock"
(
    flock -n 200 || { echo "自动切换已经在运行，请勿重复运行！"; exit 0; }
        sleep 20
        # 配置文件放在当前目录下，文件名为wifi.conf
        CONFIG_FILE="$(dirname "$0")/wifi.conf"

        # 设置错误处理的 trap，捕获 ERR 和 EXIT
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
                # 删除锁文件
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


        # 获取当前SSID和密码信息的函数
        get_current_wifi_info() {
            local wifi_info ssid key
            wifi_info=$(uci show "${WIFI_CONFIG_PATH}" 2>/dev/null)

            # 检索SSID和密码
            ssid=$(echo "$wifi_info" | awk -F'=' '/\.ssid=/ {print $2}' | tr -d "'")
            key=$(echo "$wifi_info" | awk -F'=' '/\.key=/ {print $2}' | tr -d "'")

            if [ -z "$ssid" ] || [ -z "$key" ]; then
                log_message "获取当前SSID或密码失败，无法继续。"
                exit 1
            fi

            CURRENT_SSID=$ssid
            CURRENT_PASSWORD=$key
        }


        # 检查互联网连通性
        check_internet() {
            get_current_wifi_info
            if curl -s --head "${PING_HOST}" >/dev/null; then
                return 0
            else
                log_message "无法访问Internet, 当前SSID:${CURRENT_SSID}"
                return 1
            fi
        }

        #桥接状态
        wifi_Connection_status() {
            if [ "$MC" != "$(iwconfig $(ifstatus ${JK_NAME} | jq -r '.device') | awk -F '"' '/ESSID/{print $2}')" ]; then
                log_message "桥接失败哦，请检查 ${MC} 密码：${MM} 是否正确！"
            else
                log_message "桥接 ${MC} 成功"
            fi
        }

        # 切换无线网络
        switch_wifi() {
            # 获取当前SSID和密码信息
            get_current_wifi_info
            CXQD="0"
            for WIFI in "${SHUCHUWIFI[@]}"; do
                if [[ ${WIFIKU[$WIFI]} != *"|"* ]]; then
                    log_message "请检查配置文件格式是否正常。"
                    exit 1
                fi
                DQSJ=$(date "+%Y-%m-%d %H:%M:%S")
                second_field=$(echo "${WIFIKU[$WIFI]}" | cut -d "|" -f 3)
                if ! date -d "$second_field" >/dev/null 2>&1; then
                    log_message "不是时间格式,即将自动写入时间！"
                    WIFIKU[$WIFI]=$(echo "${WIFIKU[$WIFI]}" | awk -F "|" -v OFS="|" '{$3 = "'"${DQSJ}"'"};1')
                fi
                
                Value="${WIFIKU[$WIFI]}"
                MC=${WIFI}
                MM=$(echo "${Value}" | cut -d "|" -f 1)
                PD=$(echo "${Value}" | cut -d "|" -f 2)
                RQSJ=$(echo "${Value}" | cut -d "|" -f 3)
                SJC=$(( $(date -d "$DQSJ" +%s) - $(date -d "$RQSJ" +%s) ))
                WIFIJK=($(uci show wireless | grep wifi-device | awk -F '[.=]' '{print $2}')) #获取无线接口名称

                if [ "$PD" = "2G" ]; then 
                    WIFIJK=${WIFIJK[0]}
                elif [ "$PD" = "5G" ]; then 
                    WIFIJK=${WIFIJK[1]}
                else
                    log_message "频段没有输入,请填入2G/5G"
                    exit 1
                fi


                if [[ ! -v WIFIKU[$MC] ]]; then
                    log_message "没有在备用WiFi库找到 $MC"
                    continue
                elif [[ "$CURRENT_SSID" == "$MC" ]]; then
                    log_message "当前ssid（$CURRENT_SSID）已经连接"
                    wifi_Connection_status #输出连接状态
                    continue
                elif [[ $SJC -lt ${RETRYWIFI_TIMES-0} ]]; then
                    local retry_after=$(( RETRYWIFI_TIMES - SJC ))
                    log_message "请在${retry_after}秒后再重新尝试SSID：$MC，切换太频繁了。"
                    continue
                else
                    log_message "正在切换到：${MC} 密码：${MM} 频段：${PD}"
                    uci set "${WIFI_CONFIG_PATH}.device=${WIFIJK}"
                    uci set "${WIFI_CONFIG_PATH}.ssid=${MC}"
                    uci set "${WIFI_CONFIG_PATH}.key=${MM}"

                    if ! uci commit wireless || ! wifi reload; then
                        log_message "WiFi切换失败，请检查配置！尝试切换到的SSID: ${MC} 密码：${MM} 频段：${PD}"
                        continue
                    fi
                    log_message "已切换到 ${MC} 密码：${MM} 频段：${PD} 将在${RETRY_INTERVAL}秒后检查网络是否正常。"
                    sed -i "s/${Value}/${MM}|${PD}|${DQSJ}/g" "$CONFIG_FILE"
                    sleep "${RETRY_INTERVAL}"
                    
                    wifi_Connection_status #输出连接状态

                    if check_internet; then
                        push_message "${DEVICE_NAME}切换到 ${MC} 网络正常！"
                        log_message "${DEVICE_NAME}切换到 ${MC} 网络正常！"
                        exit 0
                    else
                        log_message "切换到 ${MC}，无法访问Internet，即将切换下一个WiFi"
                        CXQD="1"
                    fi
                fi
            done
            log_message "已检测完成全部备用WiFi，无法访问Internet，结束本次脚本运行！"

            # 判断CXQD变量是否大于0，如果是则执行重启
            if [ "$CXQD" -gt 0 ] && [ "$CQ_TIMES" -lt 10 ]; then
            sed -i "s/CQ_TIMES=\"\([0-9]\+\)\"/CQ_TIMES=\"$((CQ_TIMES + 1))\"/g" "$CONFIG_FILE"
            log_message "执行重启操作"
            sleep 3
            reboot
            fi 

        }


        # 判断配置文件是否存在，并且检查是否可以访问互联网，然后执行切换桥接WiFi
        Start_Task() {
            if [ ! -f "$CONFIG_FILE" ]; then
                log_message "配置文件不存在，请检查路径是否正确。"
                exit 1
            else
                source "$CONFIG_FILE" #载入配置文件的变量
                check_log_size #检查日志文件大小
                # 检查SHUCHUWIFI数组索引是否为空
                if [ -z "${SHUCHUWIFI}" ]; then
                    log_message "SHUCHUWIFI为空，请检查配置文件！"
                    exit 1 # 终止脚本运行
                fi
            fi
            
            for ((i=0; i<${RETRY_TIMES}; i++)); do
                if check_internet; then
                    #log_message "可以访问Internet, 当前SSID:${CURRENT_SSID}"
                    if [ "$CQ_TIMES" -ne 0 ]; then sed -i "s/CQ_TIMES=\"\([0-9]\+\)\"/CQ_TIMES=\"0\"/g" "$CONFIG_FILE"; fi
                    exit 0
                else
                    log_message "无法访问Internet，等待${RETRY_INTERVAL}秒后进行第$((i+1))次重试..."
                    sleep "${RETRY_INTERVAL}"
                fi
            done

            log_message "经过${RETRY_TIMES}次检测无法访问Internet，即将尝试切换备用WiFi..."
            switch_wifi
        }

        # 主逻辑从这开始执行
        # uci get wireless.wifinet2.network
        JK_NAME="wwan"     #桥接出来的网络接口名称(小写)
        if ifstatus ${JK_NAME} &> /dev/null; then
            echo "${JK_NAME} 桥接接口存在，即将执行联网判断！"
            Start_Task #开始脚本任务
        else
            echo "${JK_NAME} 桥接接口不存在，不执行操作！"
        fi
) 200>"$LOCKFILE" 

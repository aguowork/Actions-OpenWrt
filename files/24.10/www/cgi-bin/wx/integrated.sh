#!/bin/bash

# 密码错误限制相关配置
FAIL_COUNT_FILE="$(dirname "$(readlink -f "$0")")/$(basename $0 .sh)_fail_count"  # 错误计数文件路径
MAX_FAIL_COUNT=5                          # 最大错误次数
LOCK_TIME=3600                           # 锁定时间(秒)
# 定义配置文件路径
CONFIG_FILE="/www/wx/wifi-config.json"
# 检测网络失败后重试的间隔时间（单位：秒）不能太快否则wifi会卡住，要重启才行，建议都是120-180为好
RETRY_INTERVAL="30"
# 最多尝试次数
MAX_RETRIES="25"
# 断网最大重试次数
RETRY_TIMES="1"
# 重新连接同一个WIFI的间隔时间（单位：秒）
RETRYWIFI_TIMES="688"
#桥接后还是无法联网，则重启次数
RESTART="10"
# 检测互联网连通性的服务器地址
PING_HOST="223.5.5.5"
# 获取当前脚本所在目录 日志文件的存储路径
LOG_FILE="$(dirname "$(readlink -f "$0")")/$(basename $0 .sh).log"
# 设备名称
DEVICE_NAME=$(uci get system.@system[0].hostname)
# Gitee 项目的地址
GITEE_REPO="https://gitee.com/okuni/wireless.git"
# openwrt网页目录
LOCAL_DIR="/www"
# 临时目录
TEMP_DIR="/tmp/gitee_repo"
# 当前版本标签
CURRENT_VERSION=$(cat "$(dirname "$(readlink -f "$0")")/.ver" 2>/dev/null || echo "未知版本")

# 错误处理函数
handle_error() {
    # 获取最后一次命令的退出状态
    local last_exit_status=$?
    # 获取错误发生的函数名
    local func_name=${FUNCNAME[1]}  # 获取调用 handle_error 的函数名，通常是发生错误的函数
    # 获取错误发生的行号
    local line_number=${BASH_LINENO[0]}

    if [ "$last_exit_status" != "0" ]; then
        echo "发生错误：错误发生在函数 $func_name 的第 $line_number 行。已停止脚本执行，请检查脚本代码！"
        exit 1
    fi
}

# 设置 trap，捕获 ERR 和 EXIT
trap 'handle_error' ERR

# 日志记录函数
log_message() {
    # 当前日期时间 - $1 为日志信息
    local log_entry="$(date "+%Y-%m-%d %H:%M:%S") - $1"
    # 将日志信息写入日志文件
    echo "$log_entry" | tee -a "${LOG_FILE}"
    # 强制刷新输出
    echo "" > /dev/null
}

# 检查日志文件大小
check_log_size() {
    MAX_LOG_SIZE="100"   # 日志文件最大大小，单位为KB
    if [ -e "${LOG_FILE}" ]; then
        local size=$(du -s "${LOG_FILE}" | cut -f1)
        if [ "$size" -gt "$MAX_LOG_SIZE" ]; then
            # 清空日志文件
            > "${LOG_FILE}"
            log_message "日志文件大小超过了最大值，清空日志文件"
        fi
    fi
}

# 推送消息函数
push_message() {
    # 推送消息的API地址
    PUSH_API_URL="https://wxpusher.zjiecode.com/api/send/message/"
    # 替换为您自己的 APP_TOKEN 和 MY_UID 和 TOPIC_ID
    APP_TOKEN="AT_jf0zuTx0PjA4qBnyCGeKf5J4t0DeUIc6"
    MY_UID="UID_L22PV9Qdjy4q6P3d0dthW1TJiA3k"
    TOPIC_ID="25254"
    
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

# 获取wifi接口状态
get_wireless_status() {
    # 获取原始无线数据
    local wx_wifi_json_data=$(ubus call network.wireless status)
    
    # 步骤1：获取所有STA接口的网络名称并检查数量
    local wx_sta_networks=$(echo "$wx_wifi_json_data" | jq -r '
        [.. | select(.config?.mode? == "sta")? | .config.network[0]? | select(. != null)] | 
        if length > 1 then 
            "error:multiple_sta" 
        elif length == 0 then 
            "error:no_sta" 
        else 
            .[0] 
        end')
    
    # 检查STA接口数量
    case "$wx_sta_networks" in
        "error:multiple_sta")
            echo '{"error": "检测到多个STA接口，只支持一个STA接口的配置"}' >&2
            return 1
            ;;
        "error:no_sta")
            echo '{"error": "未获取到无线中继模式的设备信息"}' >&2
            return 1
            ;;
    esac

    # 步骤2：获取STA接口状态
    local wx_sta_status=$(ubus call "network.interface.${wx_sta_networks}" status 2>/dev/null | jsonfilter -e '@.up' || echo "false")

    # 步骤3：处理数据并生成优化后的JSON结构
    local wx_final_output=$(echo "$wx_wifi_json_data" | jq --arg sta_network "$wx_sta_networks" --argjson sta_status "$wx_sta_status" '
    def find_device_for_sta($sta_section):
        to_entries[] | select(.value.interfaces[]?.section == $sta_section) | .key;
    
    def find_band_for_device($device_name):
        .[$device_name].config.band;
    
    {
        "devices": (
            # 首先收集所有设备信息
            [to_entries[] | {
                device: .key,
                band: .value.config.band,
                channel: (.value.config.channel // ""),
                htmode: .value.config.htmode,
                # 获取AP接口信息
                ap: (.value.interfaces[] | select(.config.mode == "ap") | {
                    ssid: .config.ssid,
                    hidden: (.config.hidden // false),
                    encryption: .config.encryption,
                    key: .config.key,
                    disabled: (.config.disabled // false)
                })
            }] 
            # 然后按频段分组
            | reduce .[] as $item ({}; 
                .[$item.band] = {
                    device: $item.device,
                    band: $item.band,
                    channel: $item.channel,
                    htmode: $item.htmode,
                    ssid: $item.ap.ssid,
                    hidden: $item.ap.hidden,
                    encryption: $item.ap.encryption,
                    key: $item.ap.key,
                    disabled: $item.ap.disabled
                }
            )
        ),
        "sta": (first(.. | select(.config?.mode? == "sta")) as $sta | {
            "device": find_device_for_sta($sta.section),
            "band": find_band_for_device(find_device_for_sta($sta.section)),
            "section": $sta.section,
            "ifname": $sta.ifname,
            "ssid": $sta.config.ssid,
            "encryption": $sta.config.encryption,
            "key": $sta.config.key,
            "network": ($sta.config.network | first // null),
            "sta_status": $sta_status
        })
    }')

    # 输出json数据
    #echo "$wx_final_output" | jq -r '.'
    
    # 动态获取所有频段
    local bands=$(echo "$wx_final_output" | jq -r '.devices | keys[]')
    
    # 解析JSON并设置变量
    for band in $bands; do
        # 设备基本信息
        local wx_device_info=$(echo "$wx_final_output" | jq -r --arg band "$band" '.devices[$band]')
        # 检查是否有设备信息
        if [ -n "$wx_device_info" ] && [ "$wx_device_info" != "null" ]; then
            # 设置AP信息变量
            eval "device_${band}=\"$(echo "$wx_device_info" | jq -r '.device')\""
            eval "band_${band}=\"$(echo "$wx_device_info" | jq -r '.band')\""
            eval "channel_${band}=\"$(echo "$wx_device_info" | jq -r '.channel')\""
            eval "htmode_${band}=\"$(echo "$wx_device_info" | jq -r '.htmode')\""
            eval "ssid_${band}=\"$(echo "$wx_device_info" | jq -r '.ssid')\""
            eval "hidden_${band}=\"$(echo "$wx_device_info" | jq -r '.hidden')\""
            eval "encryption_${band}=\"$(echo "$wx_device_info" | jq -r '.encryption')\""
            eval "key_${band}=\"$(echo "$wx_device_info" | jq -r '.key')\""
            eval "disabled_${band}=\"$(echo "$wx_device_info" | jq -r '.disabled')\""
        else
            # 如果设备不存在，设置空值
            eval "device_${band}="
            eval "band_${band}="
            eval "channel_${band}="
            eval "htmode_${band}="
            eval "ssid_${band}="
            eval "hidden_${band}="
            eval "encryption_${band}="
            eval "key_${band}="
            eval "disabled_${band}="
        fi
    done
    
    # 设置STA信息变量
    local wx_sta_info=$(echo "$wx_final_output" | jq -r '.sta')
    if [ "$wx_sta_info" != "null" ]; then
        sta_device="$(echo "$wx_sta_info" | jq -r '.device')"
        sta_band="$(echo "$wx_sta_info" | jq -r '.band')"
        sta_section="$(echo "$wx_sta_info" | jq -r '.section')"
        sta_ifname="$(echo "$wx_sta_info" | jq -r '.ifname')"
        sta_ssid="$(echo "$wx_sta_info" | jq -r '.ssid')"
        sta_encryption="$(echo "$wx_sta_info" | jq -r '.encryption')"
        sta_key="$(echo "$wx_sta_info" | jq -r '.key')"
        sta_network="$(echo "$wx_sta_info" | jq -r '.network')"
        sta_status="$(echo "$wx_sta_info" | jq -r '.sta_status')"
    else
        sta_device=""
        sta_band=""
        sta_section=""
        sta_ifname=""
        sta_ssid=""
        sta_encryption=""
        sta_key=""
        sta_network=""
        sta_status=""
    fi

    # 返回0表示成功，并且结束函数
    return 0
    # debug 动态获取所有频段并打印信息
    for band in $bands; do
        echo "${band}设备: $(eval echo \$device_${band})"
        echo "${band}频段: $(eval echo \$band_${band})"
        echo "${band}信道: $(eval echo \$channel_${band})"
        echo "${band}HT模式: $(eval echo \$htmode_${band})"
        echo "${band} SSID: $(eval echo \$ssid_${band})"
        echo "${band}是否隐藏: $(eval echo \$hidden_${band})"
        echo "${band}加密方式: $(eval echo \$encryption_${band})"
        echo "${band}密钥: $(eval echo \$key_${band})"
        echo "${band}是否禁用: $(eval echo \$disabled_${band})"
        echo
    done
    # 打印STA接口信息
    echo "STA设备: $sta_device"
    echo "STA频段: $sta_band"
    echo "STA区域: $sta_section"
    echo "STA接口名称: $sta_ifname"
    echo "STA SSID: $sta_ssid"
    echo "STA加密方式: $sta_encryption"
    echo "STA密钥: $sta_key"
    echo "STA网络接口名称: $sta_network"
    echo "STA状态: $sta_status" 

}



# 检查互联网连通性
check_internet() {
    if curl -s --head "${PING_HOST}" >/dev/null; then
        return 0
    else
        # log_message "无法访问Internet, 当前SSID:${sta_ssid}"
        return 1
    fi
}


# 切换无线网络
switch_wifi() {

    local LOOP_NAME LOOP_PASSWORD LOOP_BAND LOOP_LAST_UPDATED DIFF WiFi_STATE CXQD

    # 使用 jq 一次性提取wifi-config.json文件所有 Wi-Fi 信息，并直接构建数组
    readarray -t CONFIG_WIFI < <(jq -r '.wifi[] | [.name, .encryption, .password, .band, .last_updated] | @tsv' "$CONFIG_FILE")

    # CXQD 用于防呆，防止死循环，导致设备假死
    CXQD=$(jq -r '.autowifiranking[0].CQ_TIMES' "$CONFIG_FILE")

    # 循环获取 Wi-Fi 数组的每个元素
    for W in "${!CONFIG_WIFI[@]}"; do #循环一
        # 使用 IFS 分割字符串 以获取每个字段 (包括空格) LOOP_NAME是名称 LOOP_PASSWORD是密码 LOOP_BAND是频段 LOOP_LAST_UPDATED是更新时间
        IFS=$'\t' read -r LOOP_NAME LOOP_ENCRYPTION LOOP_PASSWORD LOOP_BAND LOOP_LAST_UPDATED <<< "${CONFIG_WIFI[$W]}"
        # 检查字段是否为空或 BAND 是否不在允许范围内
        if [ -z "$LOOP_NAME" ] || [ -z "$LOOP_ENCRYPTION" ] || [ -z "$LOOP_LAST_UPDATED" ] || { [ "$LOOP_BAND" != "2G" ] && [ "$LOOP_BAND" != "5G" ]; }; then
            log_message "配置文件数据格式不正确，请检查name、encryption是否为空，band 是否为2G或5G。"
            exit 0
        fi

        if ! date -d "$LOOP_LAST_UPDATED" >/dev/null 2>&1; then
            log_message "不是时间格式,即将自动写入时间！"
            jq --arg new_time "$(date "+%Y-%m-%d %H:%M:%S")" --argjson index "$W" '.wifi[$index].last_updated = $new_time' "$CONFIG_FILE" > tmp.$$.json && mv tmp.$$.json "$CONFIG_FILE"
            LOOP_LAST_UPDATED=$(date "+%Y-%m-%d %H:%M:%S")
        fi
        
        # 此判断当前WIFI、密码、频段是否与即将连接的LOOP_NAME、LOOP_PASSWORD、LOOP_BAND一致，一致则跳过，不一致则继续向下执行
        if [ "${sta_ssid}" == "$LOOP_NAME" ] && [ "${sta_key}" == "$LOOP_PASSWORD" ] && [ "$(echo "${sta_band}" | tr 'A-Z' 'a-z')" == "$LOOP_BAND" ]; then
            # 所有条件都相等，执行相关操作
            log_message "当前连接着的 ${sta_ssid} ，与即将尝试切换到 $LOOP_NAME 名称密码频段都一致，跳过本次连接！"
            # 跳出本次循环，执行下一次循环
            continue #跳出循环一
        fi


        # 此处计算时间差，获取秒数
        DIFF=$(( $(date +%s) - $(date -d "$LOOP_LAST_UPDATED" +%s) ))
        # 如果时间差小于300秒，则跳过本次循环，执行下一个循环
        if [ $DIFF -lt $RETRYWIFI_TIMES ]; then
            log_message "请在$(($RETRYWIFI_TIMES - ${DIFF}))秒后再重新尝试SSID：$LOOP_NAME，切换太频繁了。"
            # 跳出本次循环，执行下一次循环
            continue #跳出循环一
        fi
        
        # 此处更新wifi-config.json文件wifi字段的last_updated字段为当前时间
        jq --arg new_time "$(date "+%Y-%m-%d %H:%M:%S")" --argjson index "$W" '.wifi[$index].last_updated = $new_time' "$CONFIG_FILE" > tmp.$$.json && mv tmp.$$.json "$CONFIG_FILE"
        # 刷新LOOP_LAST_UPDATED变量
        LOOP_LAST_UPDATED=$(date "+%Y-%m-%d %H:%M:%S")

        # 通过uci根据LOOP_BAND频段设置网卡名称
        if [[ "$(echo "${LOOP_BAND}" | tr 'A-Z' 'a-z')" == "${band_2g}" ]]; then
            uci set wireless."${sta_section}".device="${device_2g}"
        elif [[ "$(echo "${LOOP_BAND}" | tr 'A-Z' 'a-z')" == "${band_5g}" ]]; then
            uci set wireless."${sta_section}".device="${device_5g}"
        else
            echo "未知频段请检查，仅支持2.4G/5G LOOP_BAND: $LOOP_BAND"
            exit 0
        fi

        # 使用 uci 命令设置新的 WiFi 名称和密码
        uci set wireless."${sta_section}".ssid="$LOOP_NAME"
        uci set wireless."${sta_section}".encryption="$LOOP_ENCRYPTION"
        uci set wireless."${sta_section}".key="$LOOP_PASSWORD"
        # 提交 uci 配置更改
        uci commit wireless
        # 保存应用 WiFi 设置（此时wifi会重启）
        wifi reload
        
        # 等待网络就绪
        log_message "已尝试连接 ${LOOP_NAME} 密码：${LOOP_PASSWORD} 频段：${LOOP_BAND} 安全性：${LOOP_ENCRYPTION} 即将获取连接状态，持续${MAX_RETRIES}次！"
        # 循环等待设备名称获取
        for na in $(seq 1 ${MAX_RETRIES}); do #设备名称获取
            sleep 3 # 延迟3秒获取一次
            sta_ifname=$(ubus call network.interface."$sta_network" status | sed -n 's/.*"device": "\([^"]*\)".*/\1/p')
            if [ -n "$sta_ifname" ]; then
                echo "已获取到设备名称：$sta_ifname"
                break
            elif [ "$na" -eq "${MAX_RETRIES}" ]; then
                CXQD=$((CXQD + 1))
                # 更新配置文件CQ_TIMES字段
                jq --arg value "$CXQD" '.autowifiranking[0].CQ_TIMES = ($value | tonumber)' "$CONFIG_FILE" > "tmp.$$.json" && mv "tmp.$$.json" "$CONFIG_FILE"
                log_message "获取中继设备名称失败，已停止运行！"
                exit 0
            else
                echo "第${na}次获取设备名称失败，即将重新尝试..."    
            fi    
        done #设备名称获取

        # 持续获取 wifi 状态，获取到则停止循环
        for ys in $(seq 1 ${MAX_RETRIES}); do  #循环二
            sleep 3 # 延迟3秒
            WiFi_STATE=$(iwinfo "${sta_ifname}" info | awk -F'"' '/ESSID/{print $2}')
            if [ "$LOOP_NAME" = "$WiFi_STATE" ]; then # 判断LOOP_NAME是否等于WiFi_STATE，如果相等
                log_message "连接成功 ${LOOP_NAME} 密码：${LOOP_PASSWORD} 频段：${LOOP_BAND} 安全性：${LOOP_ENCRYPTION}"
                log_message "开始获取 ${LOOP_NAME} 联网状态 持续${MAX_RETRIES}次！"
                # 获取联网状态
                for yslw in $(seq 1 ${MAX_RETRIES}); do #循环三
                    sleep 2 # 延迟2秒
                    # 检查网络是否连通
                    if curl -s --head "${PING_HOST}" >/dev/null; then
                        log_message "${LOOP_NAME}网络已连通！"
                        push_message "${DEVICE_NAME}切换到 ${LOOP_NAME} 网络正常！"
                        exit 0
                    elif [ "$yslw" -eq "${MAX_RETRIES}" ]; then
                        CXQD=$((CXQD + 1))
                        jq --arg value "$CXQD" '.autowifiranking[0].CQ_TIMES = ($value | tonumber)' "$CONFIG_FILE" > "tmp.$$.json" && mv "tmp.$$.json" "$CONFIG_FILE"
                        log_message "联网失败 ${LOOP_NAME} 即将切换下一个WiFi"
                        break # 结束循环三
                    else
                        echo "第 ${yslw} 次获取 ${LOOP_NAME} 联网状态失败 即将重新尝试..."
                    fi
                done # 循环三
                break # 结束循环二
            elif [ "$ys" -eq "${MAX_RETRIES}" ]; then
                CXQD=$((CXQD + 1))
                # 更新配置文件的CQ_TIMES字段
                jq --arg value "$CXQD" '.autowifiranking[0].CQ_TIMES = ($value | tonumber)' "$CONFIG_FILE" > "tmp.$$.json" && mv "tmp.$$.json" "$CONFIG_FILE"
                log_message "连接失败 请检查 ${LOOP_NAME} 密码：${LOOP_PASSWORD} 频段：${LOOP_BAND} 是否正确！"
                break # 结束循环二
            else
                echo "第 ${ys} 次获取 ${LOOP_NAME} 连接失败 即将重新尝试..."
            fi
        done #循环二
        
    done #循环一

    log_message "已检测配置文件全部WiFi，都无法访问Internet，结束本次脚本运行！"

    # 判断CXQD变量是否大于0，如果是则执行重新启动设备
    if [ "$CXQD" -gt "$RESTART" ]; then
        # 此处CXQD的值写入 wifi-config.json 文件的autowifiranking字段的CQ_TIMES字段
        jq '.autowifiranking[0].CQ_TIMES = 0' "$CONFIG_FILE" > tmp.$$.json && mv tmp.$$.json "$CONFIG_FILE"
        # jq --arg value "$CXQD" '.autowifiranking[0].CQ_TIMES = ($value | tonumber)' "$CONFIG_FILE" > "tmp.$$.json" && mv "tmp.$$.json" "$CONFIG_FILE"
        log_message "执行重启操作"
        sleep 3
        reboot
    fi 
}


# 自动切换中继WiFi  开启断网自动连预设热点
auto_connect_wifi() {
    # 获取脚本名称作为锁文件名目录
    LOCKFILE="/tmp/$(basename "${BASH_SOURCE%.*}").lock"
    # 使用 flock 命令确保脚本不会同时执行
    exec 200>"$LOCKFILE"
    flock -n 200 || { echo "自动切换已经在运行，请勿重复运行！"; exit 0; }

    check_log_size # 检查日志文件大小并且是否存在
    # 判断桥接接口是否存在wwan接口
    if ifstatus ${sta_network} &> /dev/null; then
        echo "${sta_network} 桥接接口存在，即将执行联网判断！"
        # 循环检测互联网状态
        for ((i=0; i<${RETRY_TIMES}; i++)); do
            if check_internet; then
                echo "可以访问Internet, 当前中继热点:${sta_ssid}"
                # 访问互联网正常，退出脚本
                exit 0
            else
                log_message "当前中继热点:${sta_ssid} 无法访问Internet，等待${RETRY_INTERVAL}秒后进行第$((i+1))次重试..."
                for ys in $(seq 1 ${RETRY_INTERVAL}); do
                    # 执行部分操作
                    echo "已等待 $ys 秒..."
                    sleep 1
                done
            fi
        done

        log_message "当前中继热点:${sta_ssid} 经过检测${RETRY_TIMES}次无法访问Internet，即将尝试切换WiFi..."

        # 检查配置文件是否存在
        if [ ! -f "$CONFIG_FILE" ]; then
            log_message "配置文件不存在，请检查 ${CONFIG_FILE} 是否存在。"
            exit 0
        else
            # 检查 wifi/name字段是否为空
            WIFI_NAMES=($(jq -r '.wifi[] | select(.name != null and .name != "") | .name' "$CONFIG_FILE" 2>/dev/null))
            WIFI_COUNT=${#WIFI_NAMES[@]}  # 获取有效名称的数量
            # 频段WIFI_COUNT是否小于等于0
            if [ "$WIFI_COUNT" -le 0 ]; then
                log_message "已知热点为空，请检查！"
                exit 0 # 终止脚本运行
            elif [ "$WIFI_COUNT" -lt 2 ]; then # 频段WIFI_COUNT是否小于2
                log_message "已知热点少于两个，请检查！"
                exit 0 # 终止脚本运行
            fi
        fi
        
        # 尝试切换WiFi
        switch_wifi

    else
        log_message "${sta_network} 桥接接口不存在，请检查桥接接口名称是否为 ${sta_network}"
        exit 0
    fi
}


# 删除 WiFi 配置函数
delete_wifi_config() {
    # 从 POST 请求中获取要删除的 WiFi 名称列表
    read INPUT
    wifi_names_to_delete=$(echo $INPUT | jq -r '.names[]')
    for wifi_name in $wifi_names_to_delete; do
        jq --arg name "$wifi_name" 'del(.wifi[] | select(.name == $name))' "$CONFIG_FILE" > tmp.json
        if [ $? -eq 0 ]; then
            mv tmp.json "$CONFIG_FILE"
        else
            echo "Content-Type: application/json"
            echo ""
            echo '{"status": "error", "message": "更新 JSON 文件失败。"}'
            exit 1
        fi
    done
    # 返回状态
    echo "Content-Type: application/json"
    echo ""
    echo '{"status": "更新 JSON 文件成功"}'
}

# 保存 WiFi 配置函数
save_wifi_config() {
    # 读取 POST 请求的 JSON 数据
    read -r POST_DATA
    # 提取 WiFi 名称、密码和频段
    config_SSID=$(echo "$POST_DATA" | jq -r '.name')
    cinfig_encryption=$(echo "$POST_DATA" | jq -r '.encryption')
    config_PASSWORD=$(echo "$POST_DATA" | jq -r '.password')
    config_BAND=$(echo "$POST_DATA" | jq -r '.band')
    config_CURRENT_TIME=$(date +"%Y-%m-%d %H:%M:%S")  # 获取当前时间

    # 检查配置文件是否存在，如果不存在则创建一个空的 JSON 结构
    [ ! -f "$CONFIG_FILE" ] && echo '{"wifi":[],"autowifiranking":[{"autowifiname":["Name1","Name2"],"CQ_TIMES":0}]}'>"$CONFIG_FILE"

    #这下面的判断我感觉根本就不需要在后端判断，在后端去判断就好了，此处待优化
    # 基本字段验证
    if [ -z "$config_SSID" ] || [ -z "$cinfig_encryption" ] || [ -z "$config_BAND" ]; then
        echo "Content-Type: application/json"
        echo ""
        echo '{"status": "error", "message": "请输入正确的WiFi名称、安全性、频段。"}'
        exit 1
    fi

    # 密码验证逻辑
    if [ "$cinfig_encryption" != "none" ] && [ "$cinfig_encryption" != "owe" ]; then
        # 检查密码是否为空
        if [ -z "$config_PASSWORD" ]; then
            echo "Content-Type: application/json"
            echo ""
            echo '{"status": "error", "message": "请输入WiFi密码"}'
            exit 1
        fi
        
        # 检查密码长度（最少8位，最多63位）
        password_length=${#config_PASSWORD}
        if [ "$password_length" -lt 8 ]; then
            echo "Content-Type: application/json"
            echo ""
            echo '{"status": "error", "message": "WiFi密码长度不能少于8位"}'
            exit 1
        fi
        if [ "$password_length" -gt 63 ]; then
            echo "Content-Type: application/json"
            echo ""
            echo '{"status": "error", "message": "WiFi密码长度不能超过63位"}'
            exit 1
        fi
    fi
    
    # 使用 jq 处理 JSON 文件
    jq --arg ssid "$config_SSID" --arg encryption "$cinfig_encryption" --arg password "$config_PASSWORD" --arg band "$config_BAND" --arg time "$config_CURRENT_TIME" \
       'if (.wifi | any(.name == $ssid)) then
            .wifi |= map(if .name == $ssid then .encryption = $encryption | .password = $password | .band = $band | .last_updated = $time else . end)
         else
            .wifi += [{"name": $ssid, "encryption": $encryption, "password": $password, "band": $band, "last_updated": $time}]
         end' \
       "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

    # 返回保存成功的响应
    echo "Content-Type: text/html; charset=utf-8"
    echo ""
    echo "保存成功，配置文件已更新"
}



# 设置 WiFi 配置函数
config_function() {
    # 如果请求方法是 POST
    if [ "$REQUEST_METHOD" = "POST" ]; then
        # 读取 POST 请求的数据，不再进行转码处理
        read POST_DATA
        # 使用 sed 命令从 POST 数据中提取 WiFi 名（ssid）
        function_SSID=$(echo "$POST_DATA" | sed -n 's/^.*ssid=\([^&]*\).*$/\1/p')
        function_encryption=$(echo "$POST_DATA" | sed -n 's/^.*encryption=\([^&]*\).*$/\1/p')
        # 使用 sed 命令从 POST 数据中提取 WiFi 密码（key）
        function_KEY=$(echo "$POST_DATA" | sed -n 's/^.*key=\([^&]*\).*$/\1/p')
        # 从 POST_DATA 中提取 band 参数并转换为小写
        function_BAND=$(echo "$POST_DATA" | sed -n 's/^.*band=\([^&]*\).*$/\1/p' | tr 'A-Z' 'a-z')
        # 根据频段设置设备
        if [ "$function_BAND" = "${band_2g}" ]; then
            uci set wireless."$sta_section".device="$(uci show wireless | grep -Eo "wireless\..*\.band='$function_BAND'" | cut -d '.' -f 2)"
        elif [ "$function_BAND" = "${band_5g}" ]; then
            uci set wireless."$sta_section".device="$(uci show wireless | grep -Eo "wireless\..*\.band='$function_BAND'" | cut -d '.' -f 2)"
        else
            echo "Content-Type: text/plain"
            echo ""
            echo "错误：无效的频段"
            exit 1
        fi
        # 使用 uci 命令置新的 WiFi 名称和密码
        uci set wireless."$sta_section".ssid="$function_SSID"
        uci set wireless."$sta_section".encryption="$function_encryption"
        uci set wireless."$sta_section".key="$function_KEY"
        # 提交 uci 配置更改
        uci commit wireless
        # 保存应用 WiFi 设置
        wifi reload
        # 返回成功状态
        echo "Content-Type: text/plain"
        echo ""
        echo "中继热点设置成功"
        exit 0
    else
        echo "Content-Type: text/plain"
        echo ""
        echo "中继错误：无效的请求方法"
        exit 1
    fi
}



# 获取 WiFi 配置函数
get_config() {

    # 获取当前的 WiFi 名称
    get_wifi_name=${sta_ssid}
    # 获取当前的 WiFi 密码
    get_wifi_password=${sta_key}
    # 获取无线网络接口的带宽信息并转换为小写
    get_wifi_band=$(echo "${sta_band}" | tr 'A-Z' 'a-z')
    # 获取当前网络接口状态
    get_wifi_Interface=$(if [[ -n "${sta_network}" ]]; then echo "${sta_network}"; else echo "不存在 ${sta_network} 接"; fi)
    # 判断前中继 WiFi 是否连接 $(ifstatus "wwan" &> /dev/null)
    get_wifi_essid=$(iwinfo "${sta_ifname}" info | awk -F'"' '/ESSID/{print $2}')
    get_wifi_bridge_status=$(if [[ -n "${get_wifi_essid}" ]]; then echo "连接成功 ${get_wifi_essid}"; else echo "连接失败 ${get_wifi_essid}"; fi)
    #网络连接状态
    get_wifi_network_status=$(if check_internet; then echo "连接成功"; else echo "连接失败"; fi)
    # 返回包含当前 WiFi 名称、密码和频段的 JSON 格式数据
    echo "Content-Type: application/json; charset=utf-8"
    echo ""
    echo "{\"ssid\":\"$get_wifi_name\",\"key\":\"$get_wifi_password\",\"band\":\"$get_wifi_band\",\"interface\":\"$get_wifi_Interface\",\"bridge_status\":\"$get_wifi_bridge_status\",\"network_status\":\"$get_wifi_network_status\"}"
}

# 获取当前 WiFi 配置
device_get_wifi() {
    get_wireless_status
    if [ $? != 0 ]; then
        echo "Content-Type: text/html; charset=utf-8"
        echo ""
        echo "错误：无法获取当前路由的2.4G/5G网卡名称、WiFi名称、密码"
        exit 1
    fi
}

# 定义一个函数来更新 crontab
auto_crontab() {
    # 获取前端传递的 interval 参数
    interval=$(echo "$QUERY_STRING" | sed -n 's/.*interval=\([^&]*\).*/\1/p')

    # 正则表达式，用于匹配目标任务
    regex="^\*\/([0-5]?\d) \* \* \* \* if \[ ! -x \/www\/cgi-bin\/wx\/integrated.sh \]; then chmod \+x \/www\/cgi-bin\/wx\/integrated.sh; fi && export QUERY_STRING=\"action=autowifi\"; \/www\/cgi-bin\/wx\/integrated.sh"

    # 获取当前 crontab 内容
    current_crontab=$(crontab -l 2>/dev/null)

    # 如果 interval 是 0，删除任务并退出
    if [ "$interval" == "0" ]; then
        # 检查是否存在目标任务
        if echo "$current_crontab" | grep -qE "$regex"; then
            # 删除目标任务
            new_crontab=$(echo "$current_crontab" | grep -vE "$regex")
            echo "$new_crontab" | crontab -
            /etc/init.d/cron reload
            echo "断网自动切换热点任务已删除。"
        else
            echo "断网自动切换热点任务未启用。"
        fi
        exit 0
    fi

    # 检查 interval 是否有效
    if [ -z "$interval" ] || [ "$interval" -le 0 ] || [ "$interval" -gt 60 ]; then
        echo "无效的时间间隔（1-60分钟）。"
        exit 1
    fi

    # 要设置的命令
    cron_command="*/$interval * * * * if [ ! -x /www/cgi-bin/wx/integrated.sh ]; then chmod +x /www/cgi-bin/wx/integrated.sh; fi && export QUERY_STRING=\"action=autowifi\"; /www/cgi-bin/wx/integrated.sh"

    # 检查 crontab 中是否已存在目标任务
    existing_task=$(echo "$current_crontab" | grep -E "$regex")

    if [ -n "$existing_task" ]; then
        # 如果现有任务与新的任务一致
        if [ "$existing_task" == "$cron_command" ]; then
            echo "相同的定时任务已存在，无需更新。"
        else
            # 任务内容不同，更新任务
            new_crontab=$(echo "$current_crontab" | grep -vE "$regex")
            echo "$new_crontab" | (cat - ; echo "$cron_command") | crontab -
            /etc/init.d/cron reload
            echo "定时任务已更新为每 $interval 分钟执行一次。"
        fi
    else
        # 如果没有相似任务，直接添加
        echo "$current_crontab" | (cat - ; echo "$cron_command") | crontab -
        /etc/init.d/cron reload
        echo "定时任务已设置为每 $interval 分钟执行一次。"
    fi

    exit 0
}

# 获取无线设置
get_wireless_settings() {

    # 返回JSON格式的无线设置
    echo "Content-Type: application/json"
    echo ""
    echo "{
        \"disabled_2g\": \"$disabled_2g\",
        \"ssid_2g\": \"$ssid_2g\",
        \"key_2g\": \"$key_2g\",
        \"channel_2g\": \"$channel_2g\",
        \"htmode_2g\": \"$htmode_2g\",
        \"hidden_2g\": \"$hidden_2g\",
        \"disabled_5g\": \"$disabled_5g\",
        \"ssid_5g\": \"$ssid_5g\",
        \"key_5g\": \"$key_5g\",
        \"channel_5g\": \"$channel_5g\",
        \"htmode_5g\": \"$htmode_5g\",
        \"hidden_5g\": \"$hidden_5g\"
    }"
}

# 保存无线设置
wireless_save_wifi() {
    # 读取POST数据
    read -r POST_DATA
    #log_message "收到的POST数据: $POST_DATA"
    # 一次性解析所有JSON数据
    # 使用jq解析JSON,将每个键值对转换为shell变量
    # to_entries将JSON对象转换为键值对数组
    # .[] 遍历数组中的每个元素
    # if .value != null 检查值是否为null
    # "local " + .key 创建本地变量
    # (.value|tostring) 将值转换为字符串
    eval $(echo "$POST_DATA" | jq -r '
        to_entries | 
        .[] | 
        if .value != null then 
            "local " + .key + "=\"" + (.value|tostring) + "\""
        else 
            empty 
        end
    ')
    
    # 2.4G设置
    # 检查并设置2.4G无线参数
    # ${disabled_2g+x}检查变量是否存在
    if [ -n "${disabled_2g+x}" ]; then
        uci set wireless.default_${device_2g}.disabled="$disabled_2g"  # 设置2.4G启用/禁用状态
    fi
    if [ -n "${ssid_2g+x}" ]; then
        uci set wireless.default_${device_2g}.ssid="$ssid_2g"         # 设置2.4G SSID
    fi
    if [ -n "${key_2g+x}" ]; then
        uci set wireless.default_${device_2g}.key="$key_2g"           # 设置2.4G密码
    fi
    if [ -n "${channel_2g+x}" ]; then
        uci set wireless.${device_2g}.channel="$channel_2g"           # 设置2.4G信道
    fi
    if [ -n "${htmode_2g+x}" ]; then
        uci set wireless.${device_2g}.htmode="$htmode_2g"             # 设置2.4G带宽模式
    fi
    if [ -n "${hidden_2g+x}" ]; then
        # 这里判断hidden的值，如果是true，则设置为1，否则删除该参数
        if [ "$hidden_2g" == "true" ]; then
            uci set wireless.default_${device_2g}.hidden="1"
        else
            # 删除hidden参数
            uci del wireless.default_${device_2g}.hidden
        fi
    fi
    
    # 5G设置
    # 检查并设置5G无线参数
    # ${disabled_5g+x}检查变量是否存在
    if [ -n "${disabled_5g+x}" ]; then
        uci set wireless.default_${device_5g}.disabled="$disabled_5g"  # 设置5G启用/禁用状态
    fi
    if [ -n "${ssid_5g+x}" ]; then
        uci set wireless.default_${device_5g}.ssid="$ssid_5g"         # 设置5G SSID
    fi
    if [ -n "${key_5g+x}" ]; then
        uci set wireless.default_${device_5g}.key="$key_5g"           # 设置5G密码
    fi
    if [ -n "${channel_5g+x}" ]; then
        uci set wireless.${device_5g}.channel="$channel_5g"           # 设置5G信道
    fi
    if [ -n "${htmode_5g+x}" ]; then
        uci set wireless.${device_5g}.htmode="$htmode_5g"             # 设置5G带宽模式
    fi
    if [ -n "${hidden_5g+x}" ]; then
        # 这里判断hidden的值，如果是true，则设置为1，否则删除该参数
        if [ "$hidden_5g" == "true" ]; then
            uci set wireless.default_${device_5g}.hidden="1"
        else
            # 删除hidden参数
            uci del wireless.default_${device_5g}.hidden
        fi
    fi
    
    # 提交更改到UCI配置
    uci commit wireless
    
    # 重启无线使配置生效
    wifi reload
    
    # 返回成功消息
    echo "Content-Type: application/json"
    echo ""
    echo '{"status": "success", "message": "无线设置已保存"}'
}

# 检查密码是否已设置
check_password_set() {
    # 检查shadow文件中是否存在wxpage用户
    if grep -q "^wxpage:" /etc/shadow; then
        echo "Content-Type: application/json"
        echo ""
        echo '{"passwordSet": true}'
    else
        echo "Content-Type: application/json"
        echo ""
        echo '{"passwordSet": false}'
    fi
}

# 创建新密码
create_password() {
    # 读取POST数据
    read -r POST_DATA
    password=$(echo "$POST_DATA" | jq -r '.password')
    # 检查密码是否为空
    if [ -z "$password" ]; then
        echo "Content-Type: application/json"
        echo ""
        echo '{"status": "error", "message": "密码不能为空"}'
        exit 1
    fi

    # 使用openssl生成加密密码
    encrypted_pass=$(echo "$password" | openssl passwd -1 -stdin)
    
    # 添加用户到shadow文件
    echo "wxpage:$encrypted_pass:19000:0:99999:7:::" >> /etc/shadow
    log_message "密码创建成功，密码为：$password"
    # 返回成功消息
    echo "Content-Type: application/json"
    echo ""
    echo '{"status": "success", "message": "密码创建成功"}'
}

# 修改验证密码函数,整合锁定检查逻辑
verify_password() {
    # 检查是否被锁定
    if [ -f "$FAIL_COUNT_FILE" ]; then
        local last_time count
        read last_time count < "$FAIL_COUNT_FILE"
        local current_time=$(date +%s)
        local time_diff=$((current_time - last_time))
        # 如果错误次数达到最大值且时间差小于锁定时间，则返回锁定状态
        if [ "$count" -ge "$MAX_FAIL_COUNT" ] && [ "$time_diff" -lt "$LOCK_TIME" ]; then
            local remaining_time=$((LOCK_TIME - time_diff))
            echo "Content-Type: application/json"
            echo ""
            echo "{\"status\": \"locked\", \"message\": \"密码错误次数过多，请在${remaining_time}秒后重试\", \"remainingTime\": $remaining_time}"
            exit 0
        fi
        
        if [ "$time_diff" -ge "$LOCK_TIME" ]; then
            rm -f "$FAIL_COUNT_FILE"
        fi
    fi

    # 读取POST数据
    read -r POST_DATA
    password=$(echo "$POST_DATA" | jq -r '.password')
    
    # 从shadow文件获取加密的密码
    encrypted_pass=$(grep "^wxpage:" /etc/shadow | cut -d: -f2)
    
    # 验证密码
    test_pass=$(echo "$password" | openssl passwd -1 -stdin -salt "${encrypted_pass#\$1\$}")
    # 如果密码验证成功，则删除错误计数文件
    if [ "$test_pass" = "$encrypted_pass" ]; then
        rm -f "$FAIL_COUNT_FILE"
        log_message "登录密码验证成功：$password"
        echo "Content-Type: application/json"
        echo ""
        echo '{"status": "success"}'
    else
        local current_time=$(date +%s)
        local count=1
        
        if [ -f "$FAIL_COUNT_FILE" ]; then
            local last_time old_count
            read last_time old_count < "$FAIL_COUNT_FILE"
            count=$((old_count + 1))
        fi
        
        echo "$current_time $count" > "$FAIL_COUNT_FILE"
        
        log_message "登录密码验证失败：$password"
        echo "Content-Type: application/json"
        echo ""
        if [ "$count" -ge "$MAX_FAIL_COUNT" ]; then
            echo "{\"status\": \"locked\", \"message\": \"密码错误次数过多，请1小时后重试\", \"remainingTime\": $LOCK_TIME}"
        else
            local remaining=$((MAX_FAIL_COUNT - count))
            echo "{\"status\": \"error\", \"message\": \"密码错误，还剩${remaining}次机会\", \"remainingAttempts\": $remaining}"
        fi
    fi
}

# 修改密码
change_password() {
    # 读取POST数据
    read -r POST_DATA
    old_password=$(echo "$POST_DATA" | jq -r '.oldPassword')
    new_password=$(echo "$POST_DATA" | jq -r '.newPassword')
    
    # 验证旧密码
    encrypted_pass=$(grep "^wxpage:" /etc/shadow | cut -d: -f2)
    test_pass=$(echo "$old_password" | openssl passwd -1 -stdin -salt "${encrypted_pass#\$1\$}")
    
    if [ "$test_pass" != "$encrypted_pass" ]; then
        log_message "修改密码失败：当前密码验证错误 $old_password"
        echo "Content-Type: application/json"
        echo ""
        echo '{"status": "error", "message": "当前密码错误"}'
        exit 1
    fi
    
    # 生成新密码的加密形式
    new_encrypted_pass=$(echo "$new_password" | openssl passwd -1 -stdin)
    
    # 更新shadow文件
    sed -i "s|^wxpage:.*|wxpage:$new_encrypted_pass:19000:0:99999:7:::|" /etc/shadow
    
    log_message "密码修改成功，新密码为：$new_password"
    echo "Content-Type: application/json"
    echo ""
    echo '{"status": "success", "message": "密码修改成功"}'
}

# 重启系统
reboot_system() {
    log_message "执行重启操作"
    echo "Content-Type: application/json"
    echo ""
    echo '{"status": "success", "message": "系统即将重启"}'
    # 延迟3秒执行重启,让响应有时间返回给前端
    ( sleep 3 && reboot ) &
}

# 添加保存排序的处理函数
save_order() {
    # 读取POST数据
    read -r POST_DATA
    
    # 使用 jq 格式化 JSON 数据并写入临时文件
    echo "$POST_DATA" | jq '.' > "$CONFIG_FILE.tmp"
    
    # 检查写入是否成功
    if [ $? -eq 0 ]; then
        mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        echo "Content-Type: application/json"
        echo ""
        echo '{"status":"success","message":"排序保存成功"}'
    else
        echo "Content-Type: application/json"
        echo ""
        echo '{"status":"error","message":"保存排序失败"}'
        rm -f "$CONFIG_FILE.tmp"
    fi
}

# 修改 Update_System 函数
Update_System() {
    # 设置响应头
    echo "Content-Type: text/plain; charset=utf-8"
    echo ""

    # 检查本地目标目录是否存在
    if [ ! -d "$LOCAL_DIR" ]; then 
        echo "错误：目录 $LOCAL_DIR 不存在，无法执行更新！"
        exit 1
    fi

    # 检查git和git-http是否安装
    if ! command -v git &> /dev/null || ! opkg list-installed | grep -q "git-http"; then
        echo "未检测到git或git-http，正在安装"
        opkg update > /dev/null 2>&1
        opkg install git git-http > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo "错误：无法安装git或git-http，请检查网络连接或软件源配置！"
            exit 1
        fi
    fi

    # 获取远程仓库的标签
    REMOTE_TAGS=$(git ls-remote --tags "$GITEE_REPO" | sed 's/.*\///' | sort -V)
    # 获取最新的标签
    LATEST_VERSION=$(echo "$REMOTE_TAGS" | tail -n 1 | sed 's/\^{}//')

    # 如果没有获取到标签，退出
    if [ -z "$LATEST_VERSION" ]; then 
        echo "错误：无法获取版本号，无法执行更新！"
        exit 1
    fi

    # 如果当前版本或最新版本为空，退出
    if [ -z "$CURRENT_VERSION" ] || [ -z "$LATEST_VERSION" ]; then 
        echo "错误：当前版本为空，无法进行比较！"
        exit 1
    fi

    # 如果当前版本不等于最新版本，进行更新
    if [ "$CURRENT_VERSION" != "$LATEST_VERSION" ]; then
        # 删除临时目录（如果存在）
        rm -rf "$TEMP_DIR"

        # 克隆 Gitee 仓库到临时目录
        if ! git clone "$GITEE_REPO" "$TEMP_DIR"; then
            echo "错误：检查网络是否正常！"
            exit 1
        fi

        # 检查是否克隆成功，确保临时目录包含 .git 目录
        if [ ! -d "$TEMP_DIR/.git" ]; then
            echo "错误：下载不完整，更新失败，请重试！"
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        # 复制文件到目标目录
        if cp -r "$TEMP_DIR"/* "$LOCAL_DIR/"; then
            # 清理临时目录
            rm -rf "$TEMP_DIR"
            # 设置目录sh脚本权限
            find "$LOCAL_DIR" -type f -name "*.sh" -exec chmod +x {} \;
            # 更新本地版本标记
            CURRENT_VERSION="$LATEST_VERSION"
            echo "更新完成！版本：$CURRENT_VERSION"
        else
            # 复制失败
            echo "错误：复制文件失败，请检查本地目录权限！"
            rm -rf "$TEMP_DIR"
            exit 1
        fi
    else
        echo "无需更新，已是最新版本！"
    fi
}

# 解析 QUERY_STRING 获取 action 参数
action=$(echo "$QUERY_STRING" | sed -n 's/.*action=\([^&]*\).*/\1/p')

if [ "$action" = "delete" ]; then
    # 删除WiFi配置
    device_get_wifi
    delete_wifi_config
elif [ "$action" = "save" ]; then
    device_get_wifi
    save_wifi_config
elif [ "$action" = "config" ]; then
    # 设置WiFi配置
    device_get_wifi
    config_function
elif [ "$action" = "getconfig" ]; then
    # 获取当前WiFi配置
    device_get_wifi
    get_config
elif [ "$action" = "autowifi" ]; then
    # 自动切换WiFi
    echo "Content-Type: text/plain; charset=utf-8"
    echo ""
    # 禁用所有缓冲
    export PYTHONUNBUFFERED=1
    # 强制刷新输出
    exec 1>/proc/self/fd/1
    device_get_wifi
    auto_connect_wifi
elif [ "$action" = "wificrontab" ]; then
    # 设置自动切换定时
    echo "Content-Type: text/html; charset=utf-8"
    echo ""
    auto_crontab
elif [ "$action" = "getwireless" ]; then
    # 获取当前无线设置
    device_get_wifi
    get_wireless_settings
elif [ "$action" = "savewireless" ]; then
    # 保存无线设置
    device_get_wifi
    wireless_save_wifi
elif [ "$action" = "checkPassword" ]; then
    # 检查密码是否已设置
    check_password_set
elif [ "$action" = "createPassword" ]; then
    # 创建新密码
    create_password
elif [ "$action" = "verifyPassword" ]; then
    # 验证密码
    verify_password
elif [ "$action" = "changePassword" ]; then
    # 修改密码
    change_password
elif [ "$action" = "rebootSystem" ]; then
    # 重启系统
    reboot_system
elif [ "$action" = "saveOrder" ]; then
    # 保存排序
    save_order
elif [ "$action" = "updateScript" ]; then
    # 更新脚本
    Update_System
else
    # 无效的参数
    echo "Content-Type: text/html; charset=utf-8"
    echo ""
    echo "错误：无效的参数"
    echo "参数：$QUERY_STRING"
    echo "参数：$action"
    exit 1
fi


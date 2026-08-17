#!/bin/bash

umask 077

SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(dirname "${SCRIPT_PATH}")
SCRIPT_NAME=$(basename "${SCRIPT_PATH}")
SCRIPT_ID="${SCRIPT_NAME%.sh}"

LOG_FILE="${WBZT_LOG_FILE:-/tmp/${SCRIPT_ID}.log}"
STATE_FILE="${WBZT_STATE_FILE:-${SCRIPT_DIR}/${SCRIPT_ID}.state.json}"
# 日志位于 /tmp 内存盘，同时按行数和字节数保留最近记录。
MAX_LOG_SIZE_KB="${WBZT_MAX_LOG_SIZE_KB:-64}"
MAX_LOG_LINES="${WBZT_MAX_LOG_LINES:-500}"
STATE_VERSION=2

WXPUSHER_SETTINGS_FILE="${WXPUSHER_SETTINGS_FILE:-/etc/wx/wx_settings.conf}"
PUSH_API_URL_DEFAULT="https://wxpusher.zjiecode.com/api/send/message"
WEIBO_API_URL_DEFAULT="https://weibo.com/ajax/profile/info"
WEIBO_VISITOR_GEN_URL="https://passport.weibo.com/visitor/genvisitor"
WEIBO_VISITOR_URL="https://passport.weibo.com/visitor/visitor"

LOCK_DIR="${WBZT_LOCK_DIR:-/tmp/${SCRIPT_NAME}.lock}"
ERROR_STATE_FILE="${WBZT_ERROR_STATE_FILE:-/tmp/${SCRIPT_NAME}.error}"
ERROR_NOTIFY_INTERVAL="${WBZT_ERROR_NOTIFY_INTERVAL:-21600}"
VISITOR_COOKIE_FILE="${WBZT_VISITOR_COOKIE_FILE:-/tmp/${SCRIPT_NAME}.visitor.cookie}"

acquire_lock() {
    local previous_pid

    if mkdir "${LOCK_DIR}" 2>/dev/null; then
        if ! printf '%s\n' "$$" > "${LOCK_DIR}/pid"; then
            rmdir "${LOCK_DIR}" 2>/dev/null || true
            return 1
        fi
        return 0
    fi

    if [ ! -r "${LOCK_DIR}/pid" ]; then
        return 1
    fi

    previous_pid=$(cat "${LOCK_DIR}/pid" 2>/dev/null)
    if [ -n "${previous_pid}" ] && kill -0 "${previous_pid}" 2>/dev/null; then
        return 1
    fi

    rm -f "${LOCK_DIR}/pid" 2>/dev/null
    rmdir "${LOCK_DIR}" 2>/dev/null || return 1
    if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
        return 1
    fi
    if ! printf '%s\n' "$$" > "${LOCK_DIR}/pid"; then
        rmdir "${LOCK_DIR}" 2>/dev/null || true
        return 1
    fi
    return 0
}

cleanup_lock() {
    local lock_pid

    lock_pid=$(cat "${LOCK_DIR}/pid" 2>/dev/null)
    if [ "${lock_pid}" = "$$" ]; then
        rm -f "${LOCK_DIR}/pid" 2>/dev/null || true
        rmdir "${LOCK_DIR}" 2>/dev/null || true
    fi
}

if ! acquire_lock; then
    exit 0
fi
trap cleanup_lock EXIT
trap 'exit 130' HUP INT TERM

log_message() {
    local msg="$1"
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${msg}" | tee -a "${LOG_FILE}"
}

check_log_file() {
    local file_size
    local line_count
    local max_bytes
    local temp_file
    local tail_status

    [ "${MAX_LOG_SIZE_KB}" -gt 0 ] 2>/dev/null || MAX_LOG_SIZE_KB=64
    [ "${MAX_LOG_LINES}" -gt 0 ] 2>/dev/null || MAX_LOG_LINES=500

    if [ ! -e "${LOG_FILE}" ]; then
        : > "${LOG_FILE}" || return 1
        return 0
    fi

    if ! file_size=$(wc -c < "${LOG_FILE}" 2>/dev/null) || \
       ! line_count=$(wc -l < "${LOG_FILE}" 2>/dev/null); then
        return 1
    fi
    max_bytes=$((10#${MAX_LOG_SIZE_KB} * 1024))
    if [ "${file_size}" -le "${max_bytes}" ] && \
       [ "${line_count}" -le "${MAX_LOG_LINES}" ]; then
        return 0
    fi

    temp_file=$(mktemp "${LOG_FILE}.rotate.XXXXXX") || return 1
    tail -n "${MAX_LOG_LINES}" "${LOG_FILE}" | \
        tail -c "${max_bytes}" > "${temp_file}"
    tail_status="${PIPESTATUS[*]}"
    if [ "${tail_status}" != "0 0" ]; then
        rm -f "${temp_file}"
        return 1
    fi
    if ! file_size=$(wc -c < "${temp_file}" 2>/dev/null); then
        rm -f "${temp_file}"
        return 1
    fi
    if [ "${file_size}" -eq "${max_bytes}" ] && ! sed -i '1d' "${temp_file}"; then
        rm -f "${temp_file}"
        return 1
    fi

    if ! mv "${temp_file}" "${LOG_FILE}"; then
        rm -f "${temp_file}"
        return 1
    fi
    return 0
}

load_settings() {
    if [ -r "${WXPUSHER_SETTINGS_FILE}" ]; then
        # 配置文件由 root 管理，并由管理页面进行安全转义。
        # shellcheck disable=SC1090
        . "${WXPUSHER_SETTINGS_FILE}"
    fi

    WXPUSHER_ENABLED="${WXPUSHER_ENABLED:-0}"
    APP_TOKEN="${WX_APP_TOKEN:-}"
    MY_UID="${WX_MY_UID:-}"
    PUSH_API_URL="${WXPUSHER_API_URL:-${PUSH_API_URL_DEFAULT}}"

    if [ -z "${WBZT_ENABLED+x}" ]; then
        WBZT_ENABLED=$(uci -q get wbzt.main.enabled 2>/dev/null || printf '0')
    fi
    if [ -z "${WEIBO_UID+x}" ] && [ -z "${WEIBO_UID_B64+x}" ]; then
        WEIBO_UID_B64=$(uci -q get wbzt.main.uid_b64 2>/dev/null || true)
    fi
    WBZT_ENABLED="${WBZT_ENABLED:-0}"
    WEIBO_UID_B64="${WEIBO_UID_B64:-}"
    WEIBO_API_URL="${WEIBO_API_URL:-${WEIBO_API_URL_DEFAULT}}"
}

jsonp_to_json() {
    printf '%s' "$1" | sed -n 's/^[^(]*(\(.*\));[[:space:]]*$/\1/p'
}

generate_visitor_cookie() {
    local fingerprint
    local response
    local response_json
    local tid
    local sub
    local subp
    local temp_file
    local curl_status

    fingerprint='{"os":"1","browser":"Chrome130,0,0,0","fonts":"undefined","screenInfo":"1920*1080*24","plugins":""}'
    response=$(curl -fsS \
        --connect-timeout 10 --max-time 20 \
        --retry 2 --retry-delay 2 --retry-connrefused --retry-max-time 45 \
        -H 'user-agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36' \
        --data-urlencode 'cb=gen_callback' \
        --data-urlencode "fp=${fingerprint}" \
        "${WEIBO_VISITOR_GEN_URL}" 2>/dev/null)
    curl_status=$?
    if [ "${curl_status}" -ne 0 ] || [ -z "${response}" ]; then
        return 1
    fi

    response_json=$(jsonp_to_json "${response}")
    tid=$(printf '%s' "${response_json}" | jq -r \
        'if .retcode == 20000000 then (.data.tid // "") else "" end' 2>/dev/null)
    if [ -z "${tid}" ]; then
        return 1
    fi

    response=$(curl -fsS -G \
        --connect-timeout 10 --max-time 20 \
        --retry 2 --retry-delay 2 --retry-connrefused --retry-max-time 45 \
        -H 'referer: https://weibo.com/' \
        -H 'user-agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36' \
        --data-urlencode 'a=incarnate' \
        --data-urlencode "t=${tid}" \
        --data-urlencode 'w=2' \
        --data-urlencode 'c=095' \
        --data-urlencode 'gc=' \
        --data-urlencode 'cb=cross_domain' \
        --data-urlencode 'from=weibo' \
        --data-urlencode "_rand=$(date +%s)" \
        "${WEIBO_VISITOR_URL}" 2>/dev/null)
    curl_status=$?
    if [ "${curl_status}" -ne 0 ] || [ -z "${response}" ]; then
        return 1
    fi

    response_json=$(jsonp_to_json "${response}")
    sub=$(printf '%s' "${response_json}" | jq -r \
        'if .retcode == 20000000 then (.data.sub // "") else "" end' 2>/dev/null)
    subp=$(printf '%s' "${response_json}" | jq -r \
        'if .retcode == 20000000 then (.data.subp // "") else "" end' 2>/dev/null)
    if [ -z "${sub}" ]; then
        return 1
    fi

    temp_file=$(mktemp "${VISITOR_COOKIE_FILE}.tmp.XXXXXX") || return 1
    if [ -n "${subp}" ]; then
        printf 'SUB=%s; SUBP=%s\n' "${sub}" "${subp}" > "${temp_file}"
    else
        printf 'SUB=%s\n' "${sub}" > "${temp_file}"
    fi
    if ! mv "${temp_file}" "${VISITOR_COOKIE_FILE}"; then
        rm -f "${temp_file}"
        return 1
    fi

    IFS= read -r WEIBO_COOKIE < "${VISITOR_COOKIE_FILE}" || return 1
    log_message "微博匿名访客 Cookie 已自动刷新"
    return 0
}

load_visitor_cookie() {
    if [ -s "${VISITOR_COOKIE_FILE}" ]; then
        IFS= read -r WEIBO_COOKIE < "${VISITOR_COOKIE_FILE}" || true
        if [ -n "${WEIBO_COOKIE}" ]; then
            return 0
        fi
    fi
    generate_visitor_cookie
}

refresh_visitor_cookie() {
    rm -f "${VISITOR_COOKIE_FILE}" 2>/dev/null || true
    generate_visitor_cookie
}

fetch_weibo_data() {
    json_data=$(curl -sS \
        --connect-timeout 10 --max-time 30 \
        --retry 2 --retry-delay 2 --retry-connrefused --retry-max-time 60 \
        "${WEIBO_API_URL}?uid=${WEIBO_UID}" \
        -H "cookie: ${WEIBO_COOKIE}" \
        -H "referer: https://weibo.com/u/${WEIBO_UID}" \
        -H 'accept: application/json, text/plain, */*' \
        -H 'user-agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36' \
        2>/dev/null)
    curl_status=$?
    [ "${curl_status}" -eq 0 ] && [ -n "${json_data}" ]
}

validate_weibo_response() {
    printf '%s' "${json_data}" | jq -e '
        .ok == 1 and
        .data.user != null and
        .data.user.statuses_count != null and
        .data.user.friends_count != null and
        .data.user.followers_count != null and
        .data.user.status_total_counter.repost_cnt != null and
        .data.user.status_total_counter.comment_cnt != null and
        .data.user.status_total_counter.like_cnt != null
    ' >/dev/null 2>&1
}

push_message() {
    local content="$1"
    local summary="$2"
    local encoded_content
    local html_content
    local json_data
    local response_file
    local http_code
    local curl_status
    local business_code
    local business_message

    if [ "${WXPUSHER_ENABLED}" != "1" ] || [ -z "${APP_TOKEN}" ] || [ -z "${MY_UID}" ]; then
        log_message "推送失败：WxPusher 尚未启用或配置不完整"
        return 1
    fi

    encoded_content=$(printf '%s' "${content}" | base64 2>/dev/null | tr -d '\r\n')
    if [ -z "${encoded_content}" ]; then
        log_message "推送失败：Base64 编码失败，已拒绝发送明文"
        return 1
    fi
    html_content="<copy data-clipboard-text=\"${encoded_content}\">${encoded_content}</copy>"

    if ! json_data=$(jq -n \
            --arg appToken "${APP_TOKEN}" \
            --arg content "${html_content}" \
            --arg summary "${summary}" \
            --arg uid "${MY_UID}" \
            '{
                appToken: $appToken,
                content: $content,
                summary: $summary,
                contentType: 2,
                uids: [$uid]
            }' 2>/dev/null); then
        log_message "推送失败：消息 JSON 构建失败"
        return 1
    fi

    response_file=$(mktemp "/tmp/${SCRIPT_ID}.push.XXXXXX") || {
        log_message "推送失败：无法创建临时响应文件"
        return 1
    }

    http_code=$(curl -sS -o "${response_file}" -w '%{http_code}' \
        --connect-timeout 10 --max-time 20 \
        -X POST -H 'Content-Type: application/json' \
        -d "${json_data}" "${PUSH_API_URL}" 2>/dev/null)
    curl_status=$?

    if [ "${curl_status}" -ne 0 ]; then
        rm -f "${response_file}"
        log_message "推送失败：无法连接 WxPusher（curl ${curl_status}）"
        return 1
    fi

    if [ "${http_code}" != "200" ]; then
        rm -f "${response_file}"
        log_message "推送失败：HTTP 状态码 ${http_code}"
        return 1
    fi

    if ! jq -e '.code == 1000 and .success == true' "${response_file}" >/dev/null 2>&1; then
        business_code=$(jq -r '.code // "未知"' "${response_file}" 2>/dev/null)
        business_message=$(jq -r '.msg // "响应格式无效"' "${response_file}" 2>/dev/null)
        rm -f "${response_file}"
        log_message "推送失败：WxPusher 业务码 ${business_code}，${business_message}"
        return 1
    fi

    rm -f "${response_file}"
    log_message "推送消息成功"
    return 0
}

notify_error() {
    local error_key="$1"
    local error_message="$2"
    local now
    local previous_key=""
    local previous_time="0"
    local error_content

    log_message "${error_message}"
    now=$(date +%s)

    if [ -r "${ERROR_STATE_FILE}" ]; then
        read -r previous_key previous_time < "${ERROR_STATE_FILE}" || true
    fi
    case "${previous_time}" in
        ''|*[!0-9]*) previous_time=0 ;;
    esac

    if [ "${previous_key}" = "${error_key}" ] && \
       [ $((now - previous_time)) -lt "${ERROR_NOTIFY_INTERVAL}" ]; then
        return 0
    fi

    printf '%s %s\n' "${error_key}" "${now}" > "${ERROR_STATE_FILE}" 2>/dev/null || true
    error_content=$(printf '脚本异常通知\n\n错误信息：%s\n\n相同异常将在 6 小时内静默。' "${error_message}")
    if push_message "${error_content}" "WZTTS"; then
        log_message "异常通知推送成功"
    else
        log_message "异常通知推送失败"
    fi
}

clear_error_state() {
    rm -f "${ERROR_STATE_FILE}" 2>/dev/null || true
}

validate_state_file() {
    [ -s "${STATE_FILE}" ] || return 1
    jq -e --argjson version "${STATE_VERSION}" '
        type == "object" and
        .version == $version and
        (.updated_at | type == "string") and
        (.statuses_count | type == "string") and
        (.friends_count | type == "string") and
        (.followers_count | type == "string") and
        (.description | type == "string") and
        (.repost_count | type == "string") and
        (.comment_count | type == "string") and
        (.like_count | type == "string")
    ' "${STATE_FILE}" >/dev/null 2>&1
}

load_state() {
    if [ ! -e "${STATE_FILE}" ]; then
        return 1
    fi
    if ! validate_state_file; then
        log_message "警告：状态文件格式无效，将使用当前数据重新初始化"
        return 1
    fi

    old_statuses_count=$(jq -r '.statuses_count' "${STATE_FILE}" 2>/dev/null) || return 1
    old_friends_count=$(jq -r '.friends_count' "${STATE_FILE}" 2>/dev/null) || return 1
    old_followers_count=$(jq -r '.followers_count' "${STATE_FILE}" 2>/dev/null) || return 1
    old_description=$(jq -r '.description' "${STATE_FILE}" 2>/dev/null) || return 1
    old_repost_count=$(jq -r '.repost_count' "${STATE_FILE}" 2>/dev/null) || return 1
    old_comment_count=$(jq -r '.comment_count' "${STATE_FILE}" 2>/dev/null) || return 1
    old_like_count=$(jq -r '.like_count' "${STATE_FILE}" 2>/dev/null) || return 1
    return 0
}

save_state() {
    local temp_file
    local updated_at

    updated_at=$(date '+%Y-%m-%dT%H:%M:%S%z')
    temp_file=$(mktemp "${STATE_FILE}.tmp.XXXXXX") || return 1
    if ! jq -n \
            --argjson version "${STATE_VERSION}" \
            --arg updated_at "${updated_at}" \
            --arg statuses_count "$1" \
            --arg friends_count "$2" \
            --arg followers_count "$3" \
            --arg description "$4" \
            --arg repost_count "$5" \
            --arg comment_count "$6" \
            --arg like_count "$7" \
            '{
                version: $version,
                updated_at: $updated_at,
                statuses_count: $statuses_count,
                friends_count: $friends_count,
                followers_count: $followers_count,
                description: $description,
                repost_count: $repost_count,
                comment_count: $comment_count,
                like_count: $like_count
            }' > "${temp_file}" 2>/dev/null; then
        rm -f "${temp_file}"
        return 1
    fi
    if ! mv "${temp_file}" "${STATE_FILE}"; then
        rm -f "${temp_file}"
        return 1
    fi
    return 0
}

is_unsigned_integer() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

add_change() {
    local label="$1"
    local old_value="$2"
    local new_value="$3"

    if [ "${old_value}" != "${new_value}" ]; then
        changed_labels+=("${label}")
        changed_old_values+=("${old_value}")
        changed_new_values+=("${new_value}")
    fi
}

single_line_value() {
    printf '%s' "$1" | tr '\r\n' ' '
}

load_settings

if [ "${WBZT_ENABLED}" != "1" ]; then
    exit 0
fi

if ! check_log_file; then
    printf '%s\n' '错误：无法初始化日志文件' >&2
    exit 1
fi

for required_command in base64 curl jq mktemp; do
    if ! command -v "${required_command}" >/dev/null 2>&1; then
        log_message "系统缺少 ${required_command}，无法继续执行"
        exit 1
    fi
done

if [ -z "${WEIBO_UID:-}" ]; then
    if [ -z "${WEIBO_UID_B64}" ] || \
       ! WEIBO_UID=$(printf '%s' "${WEIBO_UID_B64}" | base64 -d 2>/dev/null); then
        log_message "配置错误：微博 UID Base64 无效"
        exit 1
    fi
fi

if [ "${WXPUSHER_ENABLED}" != "1" ] || [ -z "${APP_TOKEN}" ] || [ -z "${MY_UID}" ]; then
    log_message "配置错误：请先在系统设置中启用并配置 WxPusher"
    exit 1
fi
if ! is_unsigned_integer "${WEIBO_UID}"; then
    log_message "配置错误：微博 UID 必须为纯数字"
    exit 1
fi

if ! load_visitor_cookie; then
    notify_error "weibo_visitor" "微博匿名访客 Cookie 自动获取失败"
    exit 1
fi

if ! fetch_weibo_data; then
    notify_error "weibo_request" "微博 API 请求失败（curl ${curl_status}），可能是网络异常或接口不可用"
    exit 1
fi

if ! validate_weibo_response; then
    log_message "微博访客身份可能已失效，正在自动刷新后重试"
    if ! refresh_visitor_cookie; then
        notify_error "weibo_visitor" "微博匿名访客 Cookie 自动刷新失败"
        exit 1
    fi
    if ! fetch_weibo_data; then
        notify_error "weibo_request" "刷新访客身份后微博 API 请求仍失败（curl ${curl_status}）"
        exit 1
    fi
    if ! validate_weibo_response; then
        notify_error "weibo_schema" "刷新访客身份后数据格式仍无效，可能是微博 API 发生变化"
        exit 1
    fi
fi

statuses_count=$(printf '%s' "${json_data}" | jq -r '.data.user.statuses_count' 2>/dev/null)
friends_count=$(printf '%s' "${json_data}" | jq -r '.data.user.friends_count' 2>/dev/null)
followers_count=$(printf '%s' "${json_data}" | jq -r '.data.user.followers_count' 2>/dev/null)
description=$(printf '%s' "${json_data}" | jq -r '.data.user.description // ""' 2>/dev/null)
repost_count=$(printf '%s' "${json_data}" | jq -r '.data.user.status_total_counter.repost_cnt' 2>/dev/null | tr -d ',')
comment_count=$(printf '%s' "${json_data}" | jq -r '.data.user.status_total_counter.comment_cnt' 2>/dev/null | tr -d ',')
like_count=$(printf '%s' "${json_data}" | jq -r '.data.user.status_total_counter.like_cnt' 2>/dev/null | tr -d ',')

for count_value in \
    "${statuses_count}" "${friends_count}" "${followers_count}" \
    "${repost_count}" "${comment_count}" "${like_count}"; do
    if ! is_unsigned_integer "${count_value}"; then
        notify_error "weibo_values" "微博数量字段不是有效整数，已拒绝更新状态"
        exit 1
    fi
done

clear_error_state

if ! load_state; then
    if save_state \
        "${statuses_count}" "${friends_count}" "${followers_count}" "${description}" \
        "${repost_count}" "${comment_count}" "${like_count}"; then
        log_message "JSON 状态文件已使用当前微博数据初始化"
        exit 0
    fi
    log_message "错误：无法初始化 JSON 状态文件"
    exit 1
fi

changed_labels=()
changed_old_values=()
changed_new_values=()

add_change "微博" "${old_statuses_count}" "${statuses_count}"
add_change "关注" "${old_friends_count}" "${friends_count}"
add_change "粉丝" "${old_followers_count}" "${followers_count}"
add_change "个人简介" "${old_description}" "${description}"
add_change "累计转发量" "${old_repost_count}" "${repost_count}"
add_change "累计评论量" "${old_comment_count}" "${comment_count}"
add_change "累计获赞" "${old_like_count}" "${like_count}"

if [ "${#changed_labels[@]}" -eq 0 ]; then
    exit 0
fi

push_content="最新数据
微博：${statuses_count}
关注：${friends_count}
粉丝：${followers_count}
个人简介：${description}
累计转发量：${repost_count}
累计评论量：${comment_count}
累计获赞：${like_count}

本次变化"

change_log=""
for ((index = 0; index < ${#changed_labels[@]}; index++)); do
    key=${changed_labels[$index]}
    old_value=${changed_old_values[$index]}
    value=${changed_new_values[$index]}
    old_display=$(single_line_value "${old_value}")
    value_display=$(single_line_value "${value}")

    push_content="${push_content}
${key}：${old_display} → ${value_display}"

    if [ -n "${change_log}" ]; then
        change_log="${change_log}, ${key} ${value_display}（之前 ${old_display}）"
    else
        change_log="${key} ${value_display}（之前 ${old_display}）"
    fi
done

log_message "检测到微博数据变化：${change_log}"

if push_message "${push_content}" "WZTTS"; then
    if ! save_state \
        "${statuses_count}" "${friends_count}" "${followers_count}" "${description}" \
        "${repost_count}" "${comment_count}" "${like_count}"; then
        log_message "错误：推送成功但 JSON 状态保存失败，下次可能重复推送"
        exit 1
    fi
    exit 0
fi

log_message "数据更新推送失败，旧状态已保留，下次任务将继续重试"
exit 1

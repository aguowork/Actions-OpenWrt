#!/bin/bash

umask 077

SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(dirname "${SCRIPT_PATH}")
SCRIPT_NAME=$(basename "${SCRIPT_PATH}")
SCRIPT_ID="${SCRIPT_NAME%.sh}"

LOG_FILE="${XHSZT_LOG_FILE:-/tmp/${SCRIPT_ID}.log}"
STATE_FILE="${XHSZT_STATE_FILE:-${SCRIPT_DIR}/${SCRIPT_ID}.state.json}"
# 日志位于 /tmp 内存盘，同时按行数和字节数保留最近记录。
MAX_LOG_SIZE_KB="${XHSZT_MAX_LOG_SIZE_KB:-64}"
MAX_LOG_LINES="${XHSZT_MAX_LOG_LINES:-500}"
STATE_VERSION=3

WXPUSHER_CONFIG_FILE="${WXPUSHER_CONFIG_FILE:-/etc/JiaoBen/wxpusher.conf}"
PUSH_API_URL_DEFAULT="https://wxpusher.zjiecode.com/api/send/message"
XHS_SHORT_BASE_URL="${XHS_SHORT_BASE_URL:-https://xhslink.cn/m}"
XHS_PROFILE_BASE_URL="${XHS_PROFILE_BASE_URL:-https://www.xiaohongshu.com/user/profile}"

ANDROID_USER_AGENT="${XHS_ANDROID_USER_AGENT:-Mozilla/5.0 (Linux; Android 14; Pixel 8 Pro Build/AP1A.240505.004) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36}"
DESKTOP_USER_AGENT="${XHS_DESKTOP_USER_AGENT:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36}"

LOCK_DIR="${XHSZT_LOCK_DIR:-/tmp/${SCRIPT_NAME}.lock}"
ERROR_STATE_FILE="${XHSZT_ERROR_STATE_FILE:-/tmp/${SCRIPT_NAME}.error}"
ERROR_NOTIFY_INTERVAL="${XHSZT_ERROR_NOTIFY_INTERVAL:-21600}"

RUNTIME_DIR=""
MOBILE_HTML_FILE=""
MOBILE_STATE_FILE=""
DESKTOP_HTML_FILE=""
DESKTOP_STATE_FILE=""
DESKTOP_CANDIDATE_FILE=""
PREVIOUS_STATE_FILE=""
CURRENT_STATE_FILE=""
CHANGES_FILE=""
STATE_FILE_PRESENT=false
HAS_VALID_STATE=false
PREVIOUS_PROFILE_ID=""

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
    mkdir "${LOCK_DIR}" 2>/dev/null || return 1
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

create_runtime_dir() {
    RUNTIME_DIR=$(mktemp -d "/tmp/${SCRIPT_ID}.runtime.XXXXXX") || return 1
    MOBILE_HTML_FILE="${RUNTIME_DIR}/mobile.html"
    MOBILE_STATE_FILE="${RUNTIME_DIR}/mobile.json"
    DESKTOP_HTML_FILE="${RUNTIME_DIR}/desktop.html"
    DESKTOP_STATE_FILE="${RUNTIME_DIR}/desktop.json"
    DESKTOP_CANDIDATE_FILE="${RUNTIME_DIR}/desktop-candidate.json"
    PREVIOUS_STATE_FILE="${RUNTIME_DIR}/previous.json"
    CURRENT_STATE_FILE="${RUNTIME_DIR}/current.json"
    CHANGES_FILE="${RUNTIME_DIR}/changes.json"

    printf '{}\n' > "${DESKTOP_STATE_FILE}" || return 1
}

cleanup_runtime_dir() {
    if [ -n "${RUNTIME_DIR}" ] && [ -d "${RUNTIME_DIR}" ]; then
        case "${RUNTIME_DIR}" in
            "/tmp/${SCRIPT_ID}.runtime."*) rm -rf "${RUNTIME_DIR}" ;;
        esac
    fi
}

cleanup_all() {
    cleanup_runtime_dir
    cleanup_lock
}

if ! acquire_lock; then
    exit 0
fi
trap cleanup_all EXIT
trap 'exit 130' HUP INT TERM

log_message() {
    local message="$1"
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${message}" | tee -a "${LOG_FILE}"
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
    if [ -r "${WXPUSHER_CONFIG_FILE}" ]; then
        # 监控脚本共用的独立配置文件，由 root 管理。
        # shellcheck disable=SC1090
        . "${WXPUSHER_CONFIG_FILE}"
    fi

    WXPUSHER_ENABLED="${WXPUSHER_ENABLED:-0}"
    APP_TOKEN="${WX_APP_TOKEN:-}"
    MY_UID="${WX_MY_UID:-}"
    PUSH_API_URL="${WXPUSHER_API_URL:-${PUSH_API_URL_DEFAULT}}"

    if [ -z "${XHSZT_ENABLED+x}" ]; then
        XHSZT_ENABLED=$(uci -q get xhszt.main.enabled 2>/dev/null || printf '0')
    fi
    if [ -z "${XHS_SHARE_CODE+x}" ] && [ -z "${XHS_SHARE_CODE_B64+x}" ]; then
        XHS_SHARE_CODE_B64=$(uci -q get xhszt.main.share_code_b64 2>/dev/null || true)
    fi

    XHSZT_ENABLED="${XHSZT_ENABLED:-0}"
    XHS_SHARE_CODE_B64="${XHS_SHARE_CODE_B64:-}"
}

decode_monitor_config() {
    if [ -z "${XHS_SHARE_CODE:-}" ]; then
        if [ -z "${XHS_SHARE_CODE_B64}" ] || \
           ! XHS_SHARE_CODE=$(printf '%s' "${XHS_SHARE_CODE_B64}" | base64 -d 2>/dev/null | tr -d '\r\n'); then
            return 1
        fi
    fi

    if [[ ! "${XHS_SHARE_CODE}" =~ ^[A-Za-z0-9_-]{6,64}$ ]]; then
        return 1
    fi

    XHS_SHORT_URL="${XHS_SHORT_BASE_URL}/${XHS_SHARE_CODE}"
    return 0
}

extract_initial_state() {
    local html_file="$1"
    local output_file="$2"

    sed -n '/window\.__INITIAL_STATE__[[:space:]]*=/ {
        s#^.*window\.__INITIAL_STATE__[[:space:]]*=[[:space:]]*##
        s#</script>.*$##
        s/:undefined/:null/g
        p
        q
    }' "${html_file}" > "${output_file}"

    [ -s "${output_file}" ] && jq -e . "${output_file}" >/dev/null 2>&1
}

fetch_mobile_data() {
    local final_url
    local curl_status
    local profile_path

    final_url=$(curl -fsSL \
        --connect-timeout 10 --max-time 30 \
        --retry 2 --retry-delay 2 --retry-connrefused --retry-max-time 60 \
        -A "${ANDROID_USER_AGENT}" \
        -o "${MOBILE_HTML_FILE}" -w '%{url_effective}' \
        "${XHS_SHORT_URL}" 2>/dev/null)
    curl_status=$?
    if [ "${curl_status}" -ne 0 ] || [ ! -s "${MOBILE_HTML_FILE}" ]; then
        return 1
    fi

    case "${final_url}" in
        *"/captcha"*) return 2 ;;
    esac
    case "${final_url}" in
        "${XHS_PROFILE_BASE_URL}/"*) ;;
        *) return 2 ;;
    esac

    profile_path=${final_url#"${XHS_PROFILE_BASE_URL}/"}
    XHS_PROFILE_ID=${profile_path%%[/?#]*}
    if [[ ! "${XHS_PROFILE_ID}" =~ ^[0-9A-Fa-f]{24}$ ]]; then
        return 2
    fi
    XHS_PROFILE_URL="${XHS_PROFILE_BASE_URL}/${XHS_PROFILE_ID}"

    extract_initial_state "${MOBILE_HTML_FILE}" "${MOBILE_STATE_FILE}" || return 2
    jq -e '
        (.profile | type == "object") and
        (.profile.userInfo | type == "object") and
        (.profile.noteData | type == "array") and
        (.profile.userInfo.follows != null) and
        (.profile.userInfo.fans != null) and
        (.profile.userInfo.likeAndCollect != null) and
        (.profile.userInfo.nickname != null) and
        (.profile.userInfo.desc != null) and
        (.profile.userInfo.ipLocation != null)
    ' "${MOBILE_STATE_FILE}" >/dev/null 2>&1
}

fetch_desktop_data() {
    local final_url
    local curl_status

    final_url=$(curl -fsSL \
        --connect-timeout 10 --max-time 30 \
        --retry 2 --retry-delay 2 --retry-connrefused --retry-max-time 60 \
        -A "${DESKTOP_USER_AGENT}" \
        -o "${DESKTOP_HTML_FILE}" -w '%{url_effective}' \
        "${XHS_PROFILE_URL}" 2>/dev/null)
    curl_status=$?
    if [ "${curl_status}" -ne 0 ] || [ ! -s "${DESKTOP_HTML_FILE}" ]; then
        return 1
    fi

    case "${final_url}" in
        *"/captcha"*) return 1 ;;
    esac
    case "${final_url}" in
        *"/user/profile/${XHS_PROFILE_ID}"*) ;;
        *) return 1 ;;
    esac

    # 空壳页通常是空作品、hasMore=true 且 basicInfo 为空；合法零作品页则有完整基本资料。
    extract_initial_state "${DESKTOP_HTML_FILE}" "${DESKTOP_CANDIDATE_FILE}" || return 1
    if ! jq -e --slurpfile mobile "${MOBILE_STATE_FILE}" '
        (.user | type == "object") and
        (.user.notes | type == "array") and
        (.user.notes[0] | type == "array") and
        (.user.noteQueries | type == "array") and
        (.user.noteQueries[0] | type == "object") and
        (.user.noteQueries[0].hasMore | type == "boolean") and
        (.user.userPageData.basicInfo | type == "object") and
        (.user.userPageData.basicInfo | length > 0) and
        (((.user.userPageData.basicInfo.nickname // "") | tostring | length) > 0) and
        (
            ((.user.notes[0] | length) > 0) or
            (.user.noteQueries[0].hasMore == false)
        ) and
        (
            ((.user.notes[0] | length) >=
             ($mobile[0].profile.noteData | length))
        )
    ' "${DESKTOP_CANDIDATE_FILE}" >/dev/null 2>&1; then
        return 1
    fi
    mv "${DESKTOP_CANDIDATE_FILE}" "${DESKTOP_STATE_FILE}"
}

build_current_state() {
    jq -n \
        --argjson version "${STATE_VERSION}" \
        --argjson desktop_available "${DESKTOP_DATA_AVAILABLE}" \
        --argjson has_previous "${HAS_VALID_STATE}" \
        --arg profile_id "${XHS_PROFILE_ID}" \
        --slurpfile mobile "${MOBILE_STATE_FILE}" \
        --slurpfile desktop "${DESKTOP_STATE_FILE}" \
        --slurpfile previous "${PREVIOUS_STATE_FILE}" '
        def text:
            if . == null then "" else tostring end;
        def clean_text:
            text | split("\r") | join(" ") | split("\n") | join(" ");
        def count_text:
            (if . == null or . == "" or . == "-" then "0" else tostring end) |
            split(",") | join("");
        def stable_cover_key:
            text |
            split("?")[0] |
            split("#")[0] |
            split("/") as $parts |
            if (($parts | length) > 3 and $parts[1] == "") then
                ($parts[3:] | join("/"))
            else
                ($parts | join("/"))
            end;

        $mobile[0].profile.userInfo as $user |
        $mobile[0].profile.noteData as $recent |
        ($desktop[0].user.notes[0] // []) as $desktop_entries |
        ($desktop[0].user.noteQueries[0] // {}) as $desktop_query |
        ($previous[0] // {}) as $previous_state |

        ([
            $recent | to_entries[]? |
            .key as $position |
            .value as $note |
            ($note.cover.url | stable_cover_key) as $cover_key |
            {
                key: (
                    if $cover_key != "" then $cover_key
                    else (
                        "fallback:" + ($note.title | clean_text) + ":" +
                        ($note.type | text) + ":" + ($position | tostring)
                    )
                    end
                ),
                title: (($note.title // "") | clean_text),
                type: (($note.type // "") | text),
                likes: (($note.likes // "0") | count_text),
                collects: (($note.collects // "0") | count_text),
                comments: (($note.comments // "0") | count_text)
            }
        ]) as $recent_works |

        ([
            $desktop_entries[]? |
            .noteCard as $card |
            {
                key: (($card.time // "") | text),
                title: (($card.displayTitle // "") | clean_text),
                type: (($card.type // "") | text),
                likes: (($card.interactInfo.likedCount // "0") | count_text)
            } |
            select(.key != "" and .key != "0")
        ]) as $desktop_works |

        ($recent_works | map({
            key: .key,
            title: .title,
            type: .type,
            likes: .likes
        })) as $mobile_works |

        ($recent_works | length) as $mobile_count |
        ($mobile_count < 6) as $mobile_count_exact |
        ($desktop_query.hasMore == false) as $desktop_count_exact |
        (
            ($desktop_available | not) and
            ($mobile_count_exact | not) and
            $has_previous
        ) as $preserve_previous |

        (
            if $desktop_available then $desktop_works
            elif $mobile_count_exact then $mobile_works
            elif $preserve_previous then $previous_state.works
            else $mobile_works
            end
        ) as $selected_works |

        (
            if $desktop_available then "desktop"
            elif $mobile_count_exact then "mobile"
            elif $preserve_previous then ($previous_state.works_source // "mobile")
            else "mobile"
            end
        ) as $works_source |

        {
            version: $version,
            profile_id: $profile_id,
            profile: {
                follows: ($user.follows | count_text),
                fans: ($user.fans | count_text),
                like_and_collect: ($user.likeAndCollect | count_text),
                nickname: ($user.nickname | clean_text),
                description: ($user.desc | clean_text),
                ip_location: ($user.ipLocation | clean_text)
            },
            public_work_count: (
                if $desktop_available then
                    ($desktop_works | length | tostring)
                elif $mobile_count_exact then
                    ($mobile_count | tostring)
                elif $preserve_previous then
                    $previous_state.public_work_count
                else
                    ($mobile_count | tostring)
                end
            ),
            public_work_count_exact: (
                if $desktop_available then $desktop_count_exact
                elif $mobile_count_exact then true
                elif $preserve_previous then $previous_state.public_work_count_exact
                else false
                end
            ),
            works_source: $works_source,
            works_snapshot_current: ($preserve_previous | not),
            works: $selected_works,
            recent_works: $recent_works
        }
    ' > "${CURRENT_STATE_FILE}"
}

validate_state_json() {
    local state_file="$1"

    [ -s "${state_file}" ] || return 1
    jq -e --argjson version "${STATE_VERSION}" '
        def unsigned_integer:
            type == "string" and
            length > 0 and
            all(explode[]; . >= 48 and . <= 57);
        def profile_identifier:
            type == "string" and
            length == 24 and
            all(explode[];
                (. >= 48 and . <= 57) or
                (. >= 65 and . <= 70) or
                (. >= 97 and . <= 102)
            );
        type == "object" and
        .version == $version and
        (.profile_id | profile_identifier) and
        (.profile | type == "object") and
        (.profile.follows | unsigned_integer) and
        (.profile.fans | unsigned_integer) and
        (.profile.like_and_collect | unsigned_integer) and
        (.profile.nickname | type == "string") and
        (.profile.description | type == "string") and
        (.profile.ip_location | type == "string") and
        (.public_work_count | unsigned_integer) and
        (.public_work_count_exact | type == "boolean") and
        (.works_source == "desktop" or .works_source == "mobile") and
        (.works_snapshot_current | type == "boolean") and
        (.works | type == "array") and
        all(.works[];
            (.key | type == "string" and length > 0) and
            (.title | type == "string") and
            (.type | type == "string") and
            (.likes | unsigned_integer)
        ) and
        (.recent_works | type == "array") and
        all(.recent_works[];
            (.key | type == "string" and length > 0) and
            (.title | type == "string") and
            (.type | type == "string") and
            (.likes | unsigned_integer) and
            (.collects | unsigned_integer) and
            (.comments | unsigned_integer)
        )
    ' "${state_file}" >/dev/null 2>&1
}

prepare_previous_state() {
    STATE_FILE_PRESENT=false
    HAS_VALID_STATE=false
    PREVIOUS_PROFILE_ID=""
    PREVIOUS_STATE_FILE="${RUNTIME_DIR}/previous.json"
    printf '{}\n' > "${PREVIOUS_STATE_FILE}" || return 1

    if [ ! -e "${STATE_FILE}" ]; then
        return 0
    fi
    STATE_FILE_PRESENT=true
    if ! validate_state_json "${STATE_FILE}"; then
        return 0
    fi

    PREVIOUS_PROFILE_ID=$(jq -r '.profile_id' "${STATE_FILE}" 2>/dev/null) || return 1
    HAS_VALID_STATE=true
    PREVIOUS_STATE_FILE="${STATE_FILE}"
}

save_current_state() {
    local temp_file

    temp_file=$(mktemp "${STATE_FILE}.tmp.XXXXXX") || return 1
    if ! cp "${CURRENT_STATE_FILE}" "${temp_file}"; then
        rm -f "${temp_file}"
        return 1
    fi
    if ! mv "${temp_file}" "${STATE_FILE}"; then
        rm -f "${temp_file}"
        return 1
    fi
    return 0
}

build_changes() {
    jq -n \
        --slurpfile old "${STATE_FILE}" \
        --slurpfile new "${CURRENT_STATE_FILE}" '
        $old[0] as $previous |
        $new[0] as $current |
        (
            $previous.works_source == $current.works_source and
            $current.works_snapshot_current
        ) as $works_comparable |

        def field_change($label; $before; $after):
            if $before != $after then
                {
                    kind: "field",
                    label: $label,
                    old: ($before | tostring),
                    new: ($after | tostring)
                }
            else
                empty
            end;

        def count_mode($exact):
            if $exact then "精确" else "至少" end;
        def index_by_key:
            reduce .[] as $item ({}; .[$item.key] = $item);
        def display_title($work):
            if $work.title == "" then "无标题" else $work.title end;
        def new_work($work):
            {kind: "new_work", title: $work.title, type: $work.type};
        def deleted_work($work):
            {kind: "deleted_work", title: $work.title, type: $work.type};
        def metadata_changes($work; $old_work):
            (if $old_work.title != $work.title then
                {
                    kind: "work_title",
                    old: $old_work.title,
                    new: $work.title,
                    type: $work.type
                }
             else empty end),
            (if $old_work.type != $work.type then
                {
                    kind: "work_type",
                    title: $work.title,
                    old: $old_work.type,
                    new: $work.type
                }
             else empty end);
        def metric_change($work; $old_work; $field; $label):
            field_change(
                ("作品「" + display_title($work) + "」" + $label);
                $old_work[$field];
                $work[$field]
            );

        ($previous.works | index_by_key) as $old_works |
        ($current.works | index_by_key) as $new_works |
        ($previous.recent_works | index_by_key) as $old_recent |

        [
            field_change("关注"; $previous.profile.follows; $current.profile.follows),
            field_change("粉丝"; $previous.profile.fans; $current.profile.fans),
            field_change("获赞与收藏"; $previous.profile.like_and_collect; $current.profile.like_and_collect),
            field_change("昵称"; $previous.profile.nickname; $current.profile.nickname),
            field_change("简介"; $previous.profile.description; $current.profile.description),
            field_change("IP 属地"; $previous.profile.ip_location; $current.profile.ip_location),
            field_change("公开作品数量"; $previous.public_work_count; $current.public_work_count),
            field_change(
                "作品数量状态";
                count_mode($previous.public_work_count_exact);
                count_mode($current.public_work_count_exact)
            ),

            (if $works_comparable then
                ($current.works[] as $work |
                    ($old_works[$work.key] // null) as $old_work |
                    if $old_work == null then
                        new_work($work)
                    else
                        metadata_changes($work; $old_work),
                        metric_change($work; $old_work; "likes"; "点赞")
                    end
                ),
                (if $previous.public_work_count_exact and $current.public_work_count_exact then
                    ($previous.works[] as $work |
                        select($new_works[$work.key] == null) |
                        deleted_work($work)
                    )
                 else empty end)
             else
                ($current.recent_works[] as $work |
                    ($old_recent[$work.key] // null) as $old_work |
                    if $old_work == null then
                        new_work($work)
                    else
                        metadata_changes($work; $old_work),
                        metric_change($work; $old_work; "likes"; "点赞")
                    end
                )
             end),
            ($current.recent_works[] as $work |
                ($old_recent[$work.key] // null) as $old_work |
                select($old_work != null) |
                metric_change($work; $old_work; "collects"; "收藏"),
                metric_change($work; $old_work; "comments"; "评论")
            )
        ]
    ' > "${CHANGES_FILE}"
}

build_push_content() {
    jq -n -r \
        --slurpfile current "${CURRENT_STATE_FILE}" \
        --slurpfile changes "${CHANGES_FILE}" '
        $current[0] as $state |
        $changes[0] as $items |

        def work_title:
            if . == "" then "（无标题）" else . end;
        def work_type:
            if . == "video" then "视频"
            elif . == "normal" then "图文"
            elif . == "" then "未知"
            else . end;
        def change_line:
            if .kind == "field" then
                (.label + "：" + .old + " → " + .new)
            elif .kind == "new_work" then
                ("发布新作品：" + (.title | work_title) + "【" + (.type | work_type) + "】")
            elif .kind == "deleted_work" then
                ("删除作品：" + (.title | work_title) + "【" + (.type | work_type) + "】")
            elif .kind == "work_title" then
                ("作品标题：" + (.old | work_title) + " → " + (.new | work_title))
            elif .kind == "work_type" then
                ("作品「" + (.title | work_title) + "」类型：" + (.old | work_type) + " → " + (.new | work_type))
            else
                "未知变化"
            end;

        (
            "最新数据\n" +
            "关注：" + $state.profile.follows + "\n" +
            "粉丝：" + $state.profile.fans + "\n" +
            "获赞与收藏：" + $state.profile.like_and_collect + "\n" +
            "昵称：" + $state.profile.nickname + "\n" +
            "简介：" + $state.profile.description + "\n" +
            "IP 属地：" + $state.profile.ip_location + "\n" +
            "公开作品：" +
                (if $state.public_work_count_exact then
                    $state.public_work_count
                 else
                    ("至少 " + $state.public_work_count)
                 end) +
            "\n作品数据：" +
                (if ($state.works_snapshot_current | not) then "沿用上次完整列表"
                 elif $state.works_source == "desktop" then "固定主页增强"
                 else "短链公开数据"
                 end) +
            "\n\n最近作品\n" +
            (
                if ($state.recent_works | length) == 0 then
                    "暂无公开作品"
                else
                    ($state.recent_works | to_entries | map(
                        ((.key + 1) | tostring) + ". " +
                        (.value.title | work_title) + "【" + (.value.type | work_type) + "】" +
                        " 赞 " + .value.likes +
                        " / 收藏 " + .value.collects +
                        " / 评论 " + .value.comments
                    ) | join("\n"))
                end
            ) +
            "\n\n本次变化\n" +
            ($items | map(change_line) | join("\n"))
        )
    ' 2>/dev/null
}

push_message() {
    local content="$1"
    local summary="$2"
    local encoded_content
    local html_content
    local request_json
    local http_code
    local curl_status
    local business_code
    local business_message
    local response_file="${RUNTIME_DIR}/push-response.json"

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

    if ! request_json=$(jq -n \
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

    http_code=$(curl -sS -o "${response_file}" -w '%{http_code}' \
        --connect-timeout 10 --max-time 20 \
        -X POST -H 'Content-Type: application/json' \
        -d "${request_json}" "${PUSH_API_URL}" 2>/dev/null)
    curl_status=$?

    if [ "${curl_status}" -ne 0 ]; then
        log_message "推送失败：无法连接 WxPusher（curl ${curl_status}）"
        return 1
    fi
    if [ "${http_code}" != "200" ]; then
        log_message "推送失败：HTTP 状态码 ${http_code}"
        return 1
    fi
    if ! jq -e '.code == 1000 and .success == true' "${response_file}" >/dev/null 2>&1; then
        business_code=$(jq -r '.code // "未知"' "${response_file}" 2>/dev/null)
        business_message=$(jq -r '.msg // "响应格式无效"' "${response_file}" 2>/dev/null)
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
    error_content=$(printf '脚本异常通知\n\n错误信息：%s\n\n相同异常将在限流周期内静默。' "${error_message}")
    if push_message "${error_content}" "XZTTS"; then
        log_message "异常通知推送成功"
    else
        log_message "异常通知推送失败"
    fi
}

clear_error_state() {
    rm -f "${ERROR_STATE_FILE}" 2>/dev/null || true
}

load_settings

if [ "${XHSZT_ENABLED}" != "1" ]; then
    exit 0
fi

if ! check_log_file; then
    printf '%s\n' '错误：无法初始化日志文件' >&2
    exit 1
fi

for required_command in base64 cp curl jq mktemp sed tr; do
    if ! command -v "${required_command}" >/dev/null 2>&1; then
        log_message "系统缺少 ${required_command}，无法继续执行"
        exit 1
    fi
done

if ! decode_monitor_config; then
    log_message "配置错误：小红书分享短码 Base64 无效"
    exit 1
fi

if [ "${WXPUSHER_ENABLED}" != "1" ] || [ -z "${APP_TOKEN}" ] || [ -z "${MY_UID}" ]; then
    log_message "配置错误：请检查 ${WXPUSHER_CONFIG_FILE} 中的 WxPusher 配置"
    exit 1
fi

if ! create_runtime_dir; then
    log_message "错误：无法创建运行时临时目录"
    exit 1
fi
if ! prepare_previous_state; then
    notify_error "xhs_state" "无法读取小红书历史状态"
    exit 1
fi

fetch_mobile_data
fetch_status=$?
if [ "${fetch_status}" -ne 0 ]; then
    if [ "${fetch_status}" -eq 2 ]; then
        notify_error "xhs_mobile_schema" "小红书分享短链出现验证码、跳转目标无效或 Android 页面数据结构无效"
    else
        notify_error "xhs_mobile_request" "小红书分享短链请求失败，短链可能暂时不可用或已经失效"
    fi
    exit 1
fi

if fetch_desktop_data; then
    DESKTOP_DATA_AVAILABLE=true
else
    DESKTOP_DATA_AVAILABLE=false
fi

if ! build_current_state || ! validate_state_json "${CURRENT_STATE_FILE}"; then
    notify_error "xhs_values" "小红书数据字段无效，已拒绝更新状态"
    exit 1
fi

if [ "${HAS_VALID_STATE}" = "true" ]; then
    if [ -z "${PREVIOUS_PROFILE_ID}" ] || [ "${PREVIOUS_PROFILE_ID}" != "${XHS_PROFILE_ID}" ]; then
        notify_error "xhs_profile_identity" "小红书分享短链跳转的账号发生变化，已拒绝更新状态"
        exit 1
    fi
fi

clear_error_state

if [ "${HAS_VALID_STATE}" != "true" ]; then
    if [ "${STATE_FILE_PRESENT}" = "true" ]; then
        log_message "警告：状态文件格式无效，将使用当前数据重新初始化"
    fi
    if save_current_state; then
        log_message "JSON 状态文件已使用当前小红书数据初始化"
        exit 0
    fi
    log_message "错误：无法初始化 JSON 状态文件"
    exit 1
fi

if ! build_changes; then
    notify_error "xhs_compare" "无法比较小红书新旧状态"
    exit 1
fi

changes_count=$(jq -r 'length' "${CHANGES_FILE}" 2>/dev/null)
case "${changes_count}" in
    ''|*[!0-9]*)
        notify_error "xhs_compare" "小红书变化结果格式无效"
        exit 1
        ;;
esac

if [ "${changes_count}" -eq 0 ]; then
    jq -e --slurpfile current "${CURRENT_STATE_FILE}" '
        $current[0] as $new |
        ($new.works_snapshot_current == true) and
        ((.works_source != $new.works_source) or
         (.works_snapshot_current != $new.works_snapshot_current))
    ' "${STATE_FILE}" >/dev/null 2>&1
    metadata_status=$?
    case "${metadata_status}" in
        0)
            if ! save_current_state; then
                log_message "错误：无法更新作品数据源元信息"
                exit 1
            fi
            ;;
        1) ;;
        *)
            notify_error "xhs_compare" "无法比较小红书作品数据源元信息"
            exit 1
            ;;
    esac
    exit 0
fi

if ! push_content=$(build_push_content) || [ -z "${push_content}" ]; then
    notify_error "xhs_content" "无法生成小红书变化推送内容"
    exit 1
fi

log_message "检测到 ${changes_count} 项小红书数据变化"
if push_message "${push_content}" "XZTTS"; then
    if ! save_current_state; then
        log_message "错误：推送成功但 JSON 状态保存失败，下次可能重复推送"
        exit 1
    fi
    exit 0
fi

log_message "数据更新推送失败，旧状态已保留，下次任务将继续重试"
exit 1

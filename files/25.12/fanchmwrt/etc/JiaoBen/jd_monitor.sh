#!/bin/sh
# 京东商品"重新上架"监控 -> WxPusher 微信推送
# 环境: ImmortalWrt/OpenWRT (BusyBox ash) + curl + jq
# 由 cron 定时调用；仅在"下架 -> 上架"跳变时推送一次，避免重复打扰。
#
# 判据(抓手机商品页 item.m.jd.com)：
#   含 downShelf/notCanBuy -> 已下架 DELISTED
#   StockState 33/39/40    -> 有货   IN_STOCK
#   StockState 34          -> 上架但无货 NO_STOCK
#
# 稳健性(参考 wbzt.sh/xhszt.sh)：
#   - 运行锁：避免上一次抓取未结束时被 cron 再次拉起
#   - 持久日志 + 体积/行数滚动：排障有据可查，又不撑爆 /tmp
#   - 原子写状态：mktemp + mv，杜绝写一半损坏
#   - curl 加超时/重试；抓取或解析的临时性失败保持"静默跳过"（京东风控频繁，
#     不做异常推送以免刷屏），仅落日志，下个周期自动重试。

umask 077

# ============ 配置区 ============
SKU="${JD_SKU:-100153031343}"     # 要监控的商品 SKU ID（可用环境变量覆盖）
# 推送统一走项目的 WxPusher：凭证来自监控脚本共用的 /etc/JiaoBen/wxpusher.conf
# （与 qdts/wbzt/xhszt 等脚本同源，填一次即全部生效；由构建流程从 GitHub
#  Secrets 的 WXPUSHER_TOKEN / WXPUSHER_UIDS 写入）。
WXPUSHER_CONFIG_FILE="${WXPUSHER_CONFIG_FILE:-/etc/JiaoBen/wxpusher.conf}"
[ -r "$WXPUSHER_CONFIG_FILE" ] && . "$WXPUSHER_CONFIG_FILE"
# 从配置派生本脚本使用的变量；未配置时给出安全默认值。
WXPUSHER_ENABLED="${WXPUSHER_ENABLED:-0}"
APP_TOKEN="${WX_APP_TOKEN:-}"
MY_UID="${WX_MY_UID:-}"
PUSH_API_URL="${WXPUSHER_API_URL:-https://wxpusher.zjiecode.com/api/send/message}"
# ================================

STATE_FILE="${JD_STATE_FILE:-/tmp/jd_${SKU}.state}"
LOG_FILE="${JD_LOG_FILE:-/tmp/jd_${SKU}.log}"
LOCK_DIR="${JD_LOCK_DIR:-/tmp/jd_${SKU}.lock}"
MAX_LOG_SIZE_KB="${JD_MAX_LOG_SIZE_KB:-64}"     # 日志超过该体积按行数滚动
MAX_LOG_LINES="${JD_MAX_LOG_LINES:-500}"        # 滚动时保留的最近行数

ITEM_URL="https://item.jd.com/${SKU}.html"
MOBILE_URL="https://item.m.jd.com/product/${SKU}.html"
UA="Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"

# ---- 日志：同时写文件与标准输出（便于 cron 邮件/手动运行查看）----
log() {
    line="$(date '+%Y-%m-%d %H:%M:%S') $*"
    printf '%s\n' "$line"
    printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
}

# 体积超限则只保留最近 MAX_LOG_LINES 行，原子替换，避免 /tmp 被撑爆。
rotate_log() {
    [ -f "$LOG_FILE" ] || return 0
    size=$(wc -c < "$LOG_FILE" 2>/dev/null) || return 0
    max_bytes=$((MAX_LOG_SIZE_KB * 1024))
    [ "$size" -le "$max_bytes" ] 2>/dev/null && return 0
    tmp=$(mktemp "${LOG_FILE}.XXXXXX" 2>/dev/null) || return 0
    if tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$LOG_FILE" 2>/dev/null || rm -f "$tmp"
    else
        rm -f "$tmp"
    fi
}

# ---- 运行锁：mkdir 具原子性；持有者进程已死则抢占 ----
acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$LOCK_DIR/pid" 2>/dev/null
        return 0
    fi
    prev=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$prev" ] && kill -0 "$prev" 2>/dev/null; then
        return 1
    fi
    # 陈旧锁：清理后重试一次
    rm -f "$LOCK_DIR/pid" 2>/dev/null
    rmdir "$LOCK_DIR" 2>/dev/null
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$LOCK_DIR/pid" 2>/dev/null
        return 0
    fi
    return 1
}

cleanup() {
    if [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
        rm -f "$LOCK_DIR/pid" 2>/dev/null
        rmdir "$LOCK_DIR" 2>/dev/null
    fi
}

is_listed() { [ "$1" = "IN_STOCK" ] || [ "$1" = "NO_STOCK" ]; }

# 原子写状态：临时文件 + mv，避免写一半损坏
write_state() {
    tmp=$(mktemp "${STATE_FILE}.XXXXXX" 2>/dev/null)
    if [ -z "$tmp" ]; then
        # 极端情况下退化为直接写，至少不丢功能
        printf '%s\n' "$1" > "$STATE_FILE" 2>/dev/null
        return
    fi
    if printf '%s\n' "$1" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE_FILE" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp" 2>/dev/null
    log "错误：状态写入失败(目标 $STATE_FILE)"
    return 1
}

push() {
    # $1=title(summary)  $2=desp(markdown 正文)  返回 0=成功 非0=失败
    # 走项目统一的 WxPusher：POST JSON，成功判据 HTTP 200 且业务码 code==1000。
    # 正文用 markdown(contentType=3)，保留原有的 **加粗** 与 [链接](url)。
    if [ "$WXPUSHER_ENABLED" != "1" ] || [ -z "$APP_TOKEN" ] || [ -z "$MY_UID" ]; then
        log "WxPusher 未启用或配置不完整，请检查 $WXPUSHER_CONFIG_FILE"
        return 1
    fi
    # summary 显示在消息列表，WxPusher 限制 ≤100 字，超出会报错，这里截断。
    summary=$(printf '%s' "$1" | cut -c1-100)
    # 正文里的 \n 是字面转义，先还原成真正换行，jq 会再正确编码进 JSON，
    # WxPusher markdown 才会换行显示。
    content=$(printf '%b' "$2")
    json=$(jq -n \
        --arg appToken "$APP_TOKEN" \
        --arg content "$content" \
        --arg summary "$summary" \
        --arg uid "$MY_UID" \
        '{
            appToken: $appToken,
            content: $content,
            summary: $summary,
            contentType: 3,
            uids: [$uid]
        }') || { log "推送失败：JSON 构建失败"; return 1; }

    body=$(curl -s -m 25 --connect-timeout 10 \
        --retry 2 --retry-delay 2 --retry-connrefused --retry-max-time 45 \
        -w '\n%{http_code}' \
        -X POST -H 'Content-Type: application/json' \
        -d "$json" "$PUSH_API_URL")
    rc=$?
    code=$(echo "$body" | tail -n1)
    resp=$(echo "$body" | sed '$d')
    if [ "$rc" -ne 0 ]; then
        log "推送失败：无法连接 WxPusher(curl rc=$rc)"
        return 1
    fi
    if [ "$code" != "200" ]; then
        log "推送失败：HTTP 状态码 $code，响应：$resp"
        return 1
    fi
    if ! echo "$resp" | jq -e '.code == 1000' >/dev/null 2>&1; then
        bcode=$(echo "$resp" | jq -r '.code // "未知"' 2>/dev/null)
        bmsg=$(echo "$resp" | jq -r '.msg // "响应格式无效"' 2>/dev/null)
        log "推送失败：WxPusher 业务码 $bcode，$bmsg"
        return 1
    fi
    log "推送成功"
    return 0
}

# ---- 依赖检查 ----
for cmd in curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "错误：缺少 $cmd，无法运行，请先安装 $cmd"
        exit 1
    fi
done

rotate_log

# 测试推送：sh jd_monitor.sh test  —— 用它确认微信能收到
if [ "$1" = "test" ]; then
    if [ "$WXPUSHER_ENABLED" != "1" ] || [ -z "$APP_TOKEN" ] || [ -z "$MY_UID" ]; then
        log "WxPusher 未启用或配置不完整，请先在 $WXPUSHER_CONFIG_FILE 中填写"; exit 1
    fi
    log "发送测试推送..."
    push "京东监控测试" "收到这条即表示 WxPusher 推送配置成功。\n\n监控中的 SKU：\`${SKU}\`"
    exit $?
fi

# ---- 取锁：抓取可能耗时，防止 cron 高频拉起时并发 ----
if ! acquire_lock; then
    log "已有实例在运行，跳过本次"
    exit 0
fi
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

# 抓页面（加超时/重试；失败视为临时性，静默跳过等下次）
PAGE=$(curl -fsSL -m 20 --connect-timeout 10 \
    --retry 2 --retry-delay 2 --retry-connrefused --retry-max-time 50 \
    -A "$UA" "$MOBILE_URL" 2>/dev/null)
if [ -z "$PAGE" ]; then
    log "抓取失败(网络/风控)，跳过本次"
    exit 0
fi

# 判定状态
if echo "$PAGE" | grep -qE 'downShelf|notCanBuy'; then
    STATE="DELISTED"
else
    CODE=$(echo "$PAGE" | grep -oE '"StockState"[[:space:]]*:[[:space:]]*"?[0-9]+' | head -n1 | grep -oE '[0-9]+$')
    case "$CODE" in
        33|39|40) STATE="IN_STOCK" ;;
        34)       STATE="NO_STOCK" ;;
        *)        STATE="UNKNOWN" ;;
    esac
fi

# 状态未知(可能被风控/页面结构变化)：不写状态、不推送，等下次
if [ "$STATE" = "UNKNOWN" ]; then
    log "状态未知(StockState=${CODE:-空})，跳过本次"
    exit 0
fi

LAST=$(cat "$STATE_FILE" 2>/dev/null)
log "当前状态: $STATE (上次: ${LAST:-无})"

# 仅在"由非上架 -> 上架"跳变时推送。
# 关键：推送成功才更新状态；推送失败则保留旧状态，下个周期自动重试，绝不漏报。
if is_listed "$STATE" && ! is_listed "$LAST"; then
    log "检测到重新上架"
    if [ "$WXPUSHER_ENABLED" != "1" ] || [ -z "$APP_TOKEN" ] || [ -z "$MY_UID" ]; then
        log "WxPusher 未启用或配置不完整，暂不更新状态(填好凭证后会自动补推)"
        exit 0
    fi
    if [ "$STATE" = "IN_STOCK" ]; then
        push "京东商品已上架且有货" "SKU \`${SKU}\` 已上架且**有货**！\n\n[点击购买](${ITEM_URL})"
    else
        push "京东商品已重新上架" "SKU \`${SKU}\` 已重新上架(当前可能无货，请尽快查看)。\n\n[查看商品](${ITEM_URL})"
    fi
    if [ $? -eq 0 ]; then
        write_state "$STATE"
        log "推送成功，状态已更新为 $STATE"
    else
        log "推送失败，保留旧状态(${LAST:-无})，下个周期重试"
    fi
else
    # 非跳变：正常记录当前状态
    write_state "$STATE"
fi

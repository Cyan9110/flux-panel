
#!/usr/bin/env bash

set -o nounset
set -o pipefail

# =========================================================
# 参数默认值
# =========================================================

BASE_URL=""
API_UID=""
API_KEY=""
DOMAIN_ID=""
TARGET_HOST=""

WANIPSITE="https://api6.ipify.org"

# =========================================================
# CLI 参数
# =========================================================

while getopts "b:u:k:d:h:i:" opt; do
    case "$opt" in
        b) BASE_URL="$OPTARG" ;;
        u) API_UID="$OPTARG" ;;
        k) API_KEY="$OPTARG" ;;
        d) DOMAIN_ID="$OPTARG" ;;
        h) TARGET_HOST="$OPTARG" ;;
        i) WANIPSITE="$OPTARG" ;;
        *)
            echo "用法:"
            echo "$0 -b BASE_URL -u API_UID -k API_KEY -d DOMAIN_ID -h TARGET_HOST [-i IP_SOURCE]"
            exit 1
            ;;
    esac
done

# =========================================================
# 参数校验
# =========================================================

if [ -z "$BASE_URL" ] ||
   [ -z "$API_UID" ] ||
   [ -z "$API_KEY" ] ||
   [ -z "$DOMAIN_ID" ] ||
   [ -z "$TARGET_HOST" ]; then
    echo "错误：缺少必要参数"
    echo "用法:"
    echo "$0 -b BASE_URL -u API_UID -k API_KEY -d DOMAIN_ID -h TARGET_HOST [-i IP_SOURCE]"
    exit 1
fi

BASE_URL="${BASE_URL%/}"

# =========================================================
# 依赖检查
# =========================================================

for CMD in curl jq md5sum python3; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "缺少依赖: $CMD"
        exit 1
    fi
done

# =========================================================
# 日志
# =========================================================

log() {
    local TAG="$1"
    local MESSAGE="$2"

    echo "[$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')] [$TAG] $MESSAGE"
}

# =========================================================
# API 签名
# =========================================================

make_sign() {
    local TIMESTAMP="$1"

    printf '%s' "${API_UID}${TIMESTAMP}${API_KEY}" |
        md5sum |
        awk '{print $1}'
}

# =========================================================
# IPv6 校验
# =========================================================

check_ipv6() {
    local IP="$1"

    python3 -c '
import ipaddress
import sys

try:
    addr = ipaddress.ip_address(sys.argv[1].strip())
    sys.exit(0 if addr.version == 6 and not addr.is_unspecified
             and not addr.is_multicast else 1)
except ValueError:
    sys.exit(1)
' "$IP"
}

# =========================================================
# 获取公网 IPv6
#
# AWS IMDSv2 优先
# AWS IMDSv1 次之
# 公网 IPv6 接口兜底
# =========================================================

get_wan_ip() {
    local IP=""
    local TOKEN=""
    local CURL_STATUS=0

    # -------------------------
    # AWS IMDSv2
    # -------------------------

    TOKEN=$(curl \
        -sS \
        --connect-timeout 2 \
        --max-time 3 \
        -X PUT \
        "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
        2>/dev/null
    ) || true

    CURL_STATUS=$?

    # 命令替换后的状态不用于判断；直接通过 TOKEN 是否为空判断
    if [ -n "$TOKEN" ]; then
        IP=$(curl \
            -sS \
            --connect-timeout 2 \
            --max-time 3 \
            -H "X-aws-ec2-metadata-token: ${TOKEN}" \
            "http://169.254.169.254/latest/meta-data/ipv6" \
            2>/dev/null
        ) || IP=""

        IP=$(printf '%s' "$IP" | tr -d '\r\n ')

        if check_ipv6 "$IP"; then
            printf '%s' "$IP"
            return 0
        fi
    fi

    # -------------------------
    # AWS IMDSv1
    # -------------------------

    IP=$(curl \
        -sS \
        --connect-timeout 2 \
        --max-time 3 \
        "http://169.254.169.254/latest/meta-data/ipv6" \
        2>/dev/null
    ) || IP=""

    IP=$(printf '%s' "$IP" | tr -d '\r\n ')

    if check_ipv6 "$IP"; then
        printf '%s' "$IP"
        return 0
    fi

    # -------------------------
    # 公网 IPv6 接口兜底
    # -------------------------

    local IP_SOURCES=(
        "$WANIPSITE"
        "https://ipv6.icanhazip.com"
        "https://v6.ident.me"
    )

    local URL

    for URL in "${IP_SOURCES[@]}"; do
        [ -z "$URL" ] && continue

        IP=$(curl \
            -6 \
            -sS \
            --connect-timeout 5 \
            --max-time 8 \
            "$URL" \
            2>/dev/null
        ) || IP=""

        IP=$(printf '%s' "$IP" | tr -d '\r\n ')

        if check_ipv6 "$IP"; then
            printf '%s' "$IP"
            return 0
        fi
    done

    return 1
}

# =========================================================
# 获取 DNS 全部记录
# =========================================================

get_records() {
    local TS
    local SIGN

    TS=$(date +%s)
    SIGN=$(make_sign "$TS")

    curl \
        -sS \
        --connect-timeout 5 \
        --max-time 15 \
        -X POST \
        "${BASE_URL}/api/record/data/${DOMAIN_ID}" \
        --data-urlencode "uid=${API_UID}" \
        --data-urlencode "timestamp=${TS}" \
        --data-urlencode "sign=${SIGN}" \
        --data-urlencode "offset=0" \
        --data-urlencode "limit=200"
}

# =========================================================
# 获取目标 AAAA 记录
# =========================================================

get_target_record() {
    local RESPONSE

    RESPONSE=$(get_records) || return 1

    if [ -z "$RESPONSE" ]; then
        return 1
    fi

    if ! printf '%s' "$RESPONSE" | jq empty >/dev/null 2>&1; then
        log "ERROR" "DNS API 返回无法解析" >&2
        return 1
    fi

    printf '%s' "$RESPONSE" |
        jq -c \
            --arg host "$TARGET_HOST" \
            '.rows[]? | select(.Name == $host and .Type == "AAAA")' |
        head -n 1
}

# =========================================================
# 更新 DNS
# =========================================================

update_record() {
    local RECORD_ID="$1"
    local RECORD_NAME="$2"
    local VALUE="$3"
    local RECORD_LINE="$4"
    local RECORD_TTL="$5"

    local TS
    local SIGN

    TS=$(date +%s)
    SIGN=$(make_sign "$TS")

    curl \
        -sS \
        --connect-timeout 5 \
        --max-time 15 \
        -X POST \
        "${BASE_URL}/api/record/update/${DOMAIN_ID}" \
        --data-urlencode "uid=${API_UID}" \
        --data-urlencode "timestamp=${TS}" \
        --data-urlencode "sign=${SIGN}" \
        --data-urlencode "recordid=${RECORD_ID}" \
        --data-urlencode "name=${RECORD_NAME}" \
        --data-urlencode "type=AAAA" \
        --data-urlencode "value=${VALUE}" \
        --data-urlencode "line=${RECORD_LINE}" \
        --data-urlencode "ttl=${RECORD_TTL}"
}

# =========================================================
# 1. 获取当前 DNS 记录
# =========================================================

if ! RECORD=$(get_target_record); then
    log "ERROR" "获取 DNS 记录失败"
    exit 1
fi

if [ -z "$RECORD" ]; then
    log "ERROR" "未找到 ${TARGET_HOST} 的 AAAA 记录"
    exit 1
fi

RECORD_ID=$(printf '%s' "$RECORD" | jq -r '.RecordId // empty')
RECORD_NAME=$(printf '%s' "$RECORD" | jq -r '.Name // empty')
RECORD_TYPE=$(printf '%s' "$RECORD" | jq -r '.Type // empty')
DNS_IP=$(printf '%s' "$RECORD" | jq -r '.Value // empty')
RECORD_LINE=$(printf '%s' "$RECORD" | jq -r '.Line // empty')
RECORD_TTL=$(printf '%s' "$RECORD" | jq -r '.TTL // empty')

if [ "$RECORD_TYPE" != "AAAA" ]; then
    log "ERROR" "${TARGET_HOST} 不是 AAAA 记录"
    exit 1
fi

if ! check_ipv6 "$DNS_IP"; then
    log "ERROR" "DNS 当前 IPv6 无效: ${DNS_IP}"
    exit 1
fi

if [ -z "$RECORD_ID" ] || [ -z "$RECORD_NAME" ]; then
    log "ERROR" "DNS 记录缺少必要字段"
    exit 1
fi

if [ -z "$RECORD_LINE" ] || [ "$RECORD_LINE" = "null" ]; then
    RECORD_LINE="default"
fi

if [ -z "$RECORD_TTL" ] || [ "$RECORD_TTL" = "null" ]; then
    RECORD_TTL="600"
fi

# =========================================================
# 2. 获取本机当前公网 IPv6
# =========================================================

if ! WAN_IP=$(get_wan_ip); then
    log "ERROR" "获取本机公网 IPv6 失败"
    exit 1
fi

if ! check_ipv6 "$WAN_IP"; then
    log "ERROR" "获取到的公网 IPv6 无效: ${WAN_IP}"
    exit 1
fi

# =========================================================
# 3. 比较
# =========================================================

# IPv6 存在多种等价文本表示，先转换为标准形式再比较
DNS_IP_NORMALIZED=$(python3 -c \
    'import ipaddress,sys; print(ipaddress.IPv6Address(sys.argv[1]))' \
    "$DNS_IP") || {
    log "ERROR" "无法规范化 DNS IPv6"
    exit 1
}

WAN_IP_NORMALIZED=$(python3 -c \
    'import ipaddress,sys; print(ipaddress.IPv6Address(sys.argv[1]))' \
    "$WAN_IP") || {
    log "ERROR" "无法规范化公网 IPv6"
    exit 1
}

if [ "$WAN_IP_NORMALIZED" = "$DNS_IP_NORMALIZED" ]; then
    # 正常情况下保持静默
    exit 0
fi

log "CHANGE" "IPv6变化: ${DNS_IP} -> ${WAN_IP}"

# =========================================================
# 4. 更新 DNS
# =========================================================

log "DNS" "准备更新记录 ${RECORD_NAME} -> ${WAN_IP}"

if ! UPDATE_RESPONSE=$(update_record \
    "$RECORD_ID" \
    "$RECORD_NAME" \
    "$WAN_IP" \
    "$RECORD_LINE" \
    "$RECORD_TTL"
); then
    log "ERROR" "DNS 更新请求失败"
    exit 1
fi

if [ -z "$UPDATE_RESPONSE" ]; then
    log "ERROR" "DNS 更新接口未返回数据"
    exit 1
fi

log "API" "更新接口返回: ${UPDATE_RESPONSE}"

# =========================================================
# 5. 更新后验证
# =========================================================

sleep 1

if ! VERIFY_RECORD=$(get_target_record); then
    log "ERROR" "DNS 更新后验证失败"
    exit 1
fi

if [ -z "$VERIFY_RECORD" ]; then
    log "ERROR" "DNS 更新后未找到目标记录"
    exit 1
fi

VERIFY_IP=$(printf '%s' "$VERIFY_RECORD" | jq -r '.Value // empty')

if ! check_ipv6 "$VERIFY_IP"; then
    log "ERROR" "DNS 更新后返回无效 IPv6: ${VERIFY_IP:-未知}"
    exit 1
fi

VERIFY_IP_NORMALIZED=$(python3 -c \
    'import ipaddress,sys; print(ipaddress.IPv6Address(sys.argv[1]))' \
    "$VERIFY_IP") || {
    log "ERROR" "DNS 更新后 IPv6 规范化失败"
    exit 1
}

if [ "$VERIFY_IP_NORMALIZED" = "$WAN_IP_NORMALIZED" ]; then
    log "DONE" "DNS 更新成功: ${TARGET_HOST} ${DNS_IP} -> ${WAN_IP}"
    exit 0
else
    log "ERROR" "DNS 更新验证失败"
    log "ERROR" "期望: ${WAN_IP}"
    log "ERROR" "实际: ${VERIFY_IP:-未知}"
    exit 1
fi

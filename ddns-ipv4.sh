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

INTERVAL=20
WANIPSITE="https://api.ipify.org"

# =========================================================
# CLI 参数
# =========================================================

while getopts "b:u:k:d:h:i:" opt; do
    case "$opt" in
        b)
            BASE_URL="$OPTARG"
            ;;
        u)
            API_UID="$OPTARG"
            ;;
        k)
            API_KEY="$OPTARG"
            ;;
        d)
            DOMAIN_ID="$OPTARG"
            ;;
        h)
            TARGET_HOST="$OPTARG"
            ;;
        i)
            WANIPSITE="$OPTARG"
            ;;
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

if [ -z "$BASE_URL" ] || \
   [ -z "$API_UID" ] || \
   [ -z "$API_KEY" ] || \
   [ -z "$DOMAIN_ID" ] || \
   [ -z "$TARGET_HOST" ]; then

    echo "错误：缺少必要参数"
    echo
    echo "用法:"
    echo "$0 -b BASE_URL -u API_UID -k API_KEY -d DOMAIN_ID -h TARGET_HOST"
    echo
    echo "示例:"
    echo "$0 \\"
    echo "  -b https://dns.example.com \\"
    echo "  -u 1001 \\"
    echo "  -k your_api_key \\"
    echo "  -d 1 \\"
    echo "  -h cy-aws1"

    exit 1
fi
# =========================
# 依赖检查
# =========================

for CMD in curl jq md5sum; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "缺少依赖: $CMD"
        echo "请执行: apt update && apt install -y curl jq coreutils"
        exit 1
    fi
done


# =========================
# 日志
# =========================

log() {
    local TAG="$1"
    local MESSAGE="$2"

    echo "[$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')] [$TAG] $MESSAGE"
}


# =========================
# API 签名
#
# JS:
#
# md5(uid + timestamp + key)
#
# =========================

make_sign() {
    local TIMESTAMP="$1"

    printf '%s' "${API_UID}${TIMESTAMP}${API_KEY}" \
        | md5sum \
        | awk '{print $1}'
}


# =========================
# IPv4 格式检查
# =========================

check_ipv4() {
    local IP="$1"

    if [[ ! "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi

    IFS='.' read -r A B C D <<< "$IP"

    for N in "$A" "$B" "$C" "$D"; do
        if [ "$N" -lt 0 ] || [ "$N" -gt 255 ]; then
            return 1
        fi
    done

    return 0
}


# =========================
# 获取本机公网 IPv4
# =========================

get_wan_ip() {
    local IP=""
    local TOKEN=""
    local ERR=""

    # =====================================================
    # 1. 优先通过 AWS EC2 IMDSv2 获取公网 IPv4
    # =====================================================

    TOKEN=$(curl -sS \
        --connect-timeout 2 \
        --max-time 3 \
        -X PUT \
        "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
        2>/tmp/ddns-imds-token.err
    )

    if [ $? -eq 0 ] && [ -n "$TOKEN" ]; then

        IP=$(curl -sS \
            --connect-timeout 2 \
            --max-time 3 \
            -H "X-aws-ec2-metadata-token: ${TOKEN}" \
            "http://169.254.169.254/latest/meta-data/public-ipv4" \
            2>/tmp/ddns-imds-ip.err
        )

        IP=$(printf '%s' "$IP" | tr -d '\r\n ')

        if check_ipv4 "$IP"; then
            printf '%s' "$IP"
            return 0
        fi
    fi


    # =====================================================
    # 2. AWS Metadata 获取失败
    #    使用公网接口兜底
    # =====================================================

    local IP_SOURCES=(
        "https://api.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://4.ident.me"
    )

    for URL in "${IP_SOURCES[@]}"; do

        ERR=$(mktemp)

        IP=$(curl \
            -4 \
            -sS \
            --connect-timeout 5 \
            --max-time 8 \
            "$URL" \
            2>"$ERR"
        )

        CURL_STATUS=$?

        IP=$(printf '%s' "$IP" | tr -d '\r\n ')

        if [ "$CURL_STATUS" -eq 0 ] && check_ipv4 "$IP"; then
            rm -f "$ERR"
            printf '%s' "$IP"
            return 0
        fi

        if [ -s "$ERR" ]; then
            log "WAN-WARN" "${URL} 获取失败: $(cat "$ERR")"
        fi

        rm -f "$ERR"
    done


    # =====================================================
    # 全部失败
    # =====================================================

    log "WAN-ERROR" "AWS Metadata 和所有公网 IPv4 接口均获取失败"

    return 1
}


# =========================
# 获取 DNS 全部记录
#
# JS:
#
# axios.post(
#   `${baseURL}/api/record/data/${domainId}`,
#   new URLSearchParams({
#     uid,
#     timestamp: ts,
#     sign,
#     offset: 0,
#     limit: 200
#   })
# )
#
# =========================

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


# =========================
# 获取指定 DNS 记录
# =========================

get_target_record() {
    local RESPONSE

    RESPONSE=$(get_records) || return 1

    if [ -z "$RESPONSE" ]; then
        return 1
    fi

    if ! printf '%s' "$RESPONSE" | jq empty >/dev/null 2>&1; then
        log "ERROR" "DNS API 返回无法解析"
        log "DEBUG" "$RESPONSE"
        return 1
    fi

    printf '%s' "$RESPONSE" \
        | jq -c \
            --arg host "$TARGET_HOST" \
            '.rows[]? | select(.Name == $host and .Type == "A")' \
        | head -n 1
}


# =========================
# 更新 DNS
#
# 完全对应 JS updateRecord()
# =========================

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
        --data-urlencode "type=A" \
        --data-urlencode "value=${VALUE}" \
        --data-urlencode "line=${RECORD_LINE}" \
        --data-urlencode "ttl=${RECORD_TTL}"
}


# =========================================================
# 初始化
#
# 关键：
# 启动时先从 DNS API 获取当前 cy-aws1 的 IP
# =========================================================

CURRENT_DNS_IP=""

while [ -z "$CURRENT_DNS_IP" ]; do

    log "SYSTEM" "正在初始化获取当前 ${TARGET_HOST} 上的 IP..."

    RECORD=$(get_target_record)

    if [ $? -ne 0 ] || [ -z "$RECORD" ]; then
        log "ERROR" "初始化获取 DNS 记录失败，${INTERVAL} 秒后重试"
        sleep "$INTERVAL"
        continue
    fi

    RECORD_ID=$(printf '%s' "$RECORD" | jq -r '.RecordId // empty')
    RECORD_NAME=$(printf '%s' "$RECORD" | jq -r '.Name // empty')
    RECORD_TYPE=$(printf '%s' "$RECORD" | jq -r '.Type // empty')
    CURRENT_DNS_IP=$(printf '%s' "$RECORD" | jq -r '.Value // empty')
    RECORD_LINE=$(printf '%s' "$RECORD" | jq -r '.Line // empty')
    RECORD_TTL=$(printf '%s' "$RECORD" | jq -r '.TTL // empty')


    if [ "$RECORD_TYPE" != "A" ]; then
        log "ERROR" "${TARGET_HOST} 不是 A 记录"
        CURRENT_DNS_IP=""
        sleep "$INTERVAL"
        continue
    fi


    if ! check_ipv4 "$CURRENT_DNS_IP"; then
        log "ERROR" "${TARGET_HOST} 当前 Value 不是有效 IPv4: ${CURRENT_DNS_IP}"
        CURRENT_DNS_IP=""
        sleep "$INTERVAL"
        continue
    fi


    if [ -z "$RECORD_LINE" ]; then
        RECORD_LINE="default"
    fi

    if [ -z "$RECORD_TTL" ]; then
        RECORD_TTL="600"
    fi


    log "SYSTEM" "初始化成功，当前 ${TARGET_HOST} 的 IP 为: ${CURRENT_DNS_IP}"
done


# =========================================================
# 主循环
# =========================================================

while true; do

    # =========================
    # 获取本机当前公网 IPv4
    # =========================

    WAN_IP=$(get_wan_ip)

    if [ $? -ne 0 ] || [ -z "${WAN_IP:-}" ]; then

        log "ERROR" "获取本机公网 IPv4 失败"

        sleep "$INTERVAL"
        continue
    fi


    # =========================
    # IP 没变化
    #
    # 当前公网 IP == DNS 当前 IP
    #
    # 什么都不做
    # =========================

    if [ "$WAN_IP" = "$CURRENT_DNS_IP" ]; then

        sleep "$INTERVAL"
        continue

    fi


    # =========================
    # IP 已发生变化
    # =========================

    log "CHANGE" "IPv4变化: ${CURRENT_DNS_IP} -> ${WAN_IP}"


    # =========================
    # 更新前重新查询 DNS
    #
    # 防止 DNS 被其他程序修改
    # =========================

    RECORD=$(get_target_record)

    if [ $? -ne 0 ] || [ -z "$RECORD" ]; then

        log "ERROR" "重新获取 DNS 记录失败"

        sleep "$INTERVAL"
        continue
    fi


    RECORD_ID=$(printf '%s' "$RECORD" | jq -r '.RecordId // empty')
    RECORD_NAME=$(printf '%s' "$RECORD" | jq -r '.Name // empty')
    DNS_IP=$(printf '%s' "$RECORD" | jq -r '.Value // empty')
    RECORD_LINE=$(printf '%s' "$RECORD" | jq -r '.Line // empty')
    RECORD_TTL=$(printf '%s' "$RECORD" | jq -r '.TTL // empty')


    if [ -z "$RECORD_LINE" ]; then
        RECORD_LINE="default"
    fi

    if [ -z "$RECORD_TTL" ]; then
        RECORD_TTL="600"
    fi


    # =========================
    # DNS 可能已经被其他程序更新
    # =========================

    if [ "$DNS_IP" = "$WAN_IP" ]; then

        CURRENT_DNS_IP="$WAN_IP"

        log "DNS" "DNS 已经是当前公网 IPv4: ${WAN_IP}"

        sleep "$INTERVAL"
        continue
    fi


    # =========================
    # DNS 更新
    # =========================

    log "DNS" "准备更新记录 ${RECORD_NAME} -> ${WAN_IP} (强制修改为 A 记录)"


    UPDATE_RESPONSE=$(update_record \
        "$RECORD_ID" \
        "$RECORD_NAME" \
        "$WAN_IP" \
        "$RECORD_LINE" \
        "$RECORD_TTL"
    )


    if [ $? -ne 0 ] || [ -z "$UPDATE_RESPONSE" ]; then

        log "ERROR" "DNS 更新请求失败"

        sleep "$INTERVAL"
        continue
    fi


    log "API" "更新接口返回: ${UPDATE_RESPONSE}"


    # =========================
    # 更新后验证
    # =========================

    sleep 1

    VERIFY_RECORD=$(get_target_record)

    if [ $? -ne 0 ] || [ -z "$VERIFY_RECORD" ]; then

        log "ERROR" "DNS 更新后验证失败"

        sleep "$INTERVAL"
        continue
    fi


    VERIFY_IP=$(printf '%s' "$VERIFY_RECORD" | jq -r '.Value // empty')


    # =========================
    # 更新成功
    # =========================

    if [ "$VERIFY_IP" = "$WAN_IP" ]; then

        log "DONE" "DNS 更新成功: ${TARGET_HOST} ${CURRENT_DNS_IP} -> ${WAN_IP}"

        CURRENT_DNS_IP="$WAN_IP"

    else

        log "ERROR" "DNS 更新验证失败"
        log "ERROR" "期望: ${WAN_IP}"
        log "ERROR" "实际: ${VERIFY_IP:-未知}"

    fi


    sleep "$INTERVAL"

done

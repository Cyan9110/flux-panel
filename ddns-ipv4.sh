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

    echo "用法:"
    echo "$0 -b BASE_URL -u API_UID -k API_KEY -d DOMAIN_ID -h TARGET_HOST [-i IP_SOURCE]"

    exit 1
fi


BASE_URL="${BASE_URL%/}"


# =========================================================
# 依赖检查
# =========================================================

for CMD in curl jq md5sum; do
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

    printf '%s' "${API_UID}${TIMESTAMP}${API_KEY}" \
        | md5sum \
        | awk '{print $1}'
}


# =========================================================
# IPv4 校验
# =========================================================

check_ipv4() {
    local IP="$1"

    if [[ ! "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi

    local A B C D
    IFS='.' read -r A B C D <<< "$IP"

    for N in "$A" "$B" "$C" "$D"; do
        if [ "$N" -lt 0 ] || [ "$N" -gt 255 ]; then
            return 1
        fi
    done

    return 0
}


# =========================================================
# 获取公网 IPv4
#
# AWS IMDSv2 优先
# IMDSv1 次之
# 公网接口兜底
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
    )

    CURL_STATUS=$?

    if [ "$CURL_STATUS" -eq 0 ] && [ -n "$TOKEN" ]; then

        IP=$(curl \
            -sS \
            --connect-timeout 2 \
            --max-time 3 \
            -H "X-aws-ec2-metadata-token: ${TOKEN}" \
            "http://169.254.169.254/latest/meta-data/public-ipv4" \
            2>/dev/null
        )

        CURL_STATUS=$?

        if [ "$CURL_STATUS" -eq 0 ]; then

            IP=$(printf '%s' "$IP" | tr -d '\r\n ')

            if check_ipv4 "$IP"; then
                printf '%s' "$IP"
                return 0
            fi
        fi
    fi


    # -------------------------
    # AWS IMDSv1
    # -------------------------

    IP=$(curl \
        -sS \
        --connect-timeout 2 \
        --max-time 3 \
        "http://169.254.169.254/latest/meta-data/public-ipv4" \
        2>/dev/null
    )

    CURL_STATUS=$?

    if [ "$CURL_STATUS" -eq 0 ]; then

        IP=$(printf '%s' "$IP" | tr -d '\r\n ')

        if check_ipv4 "$IP"; then
            printf '%s' "$IP"
            return 0
        fi
    fi


    # -------------------------
    # 公网接口兜底
    # -------------------------

    local IP_SOURCES=(
        "$WANIPSITE"
        "https://ipv4.icanhazip.com"
        "https://4.ident.me"
    )

    local URL

    for URL in "${IP_SOURCES[@]}"; do

        [ -z "$URL" ] && continue

        IP=$(curl \
            -4 \
            -sS \
            --connect-timeout 5 \
            --max-time 8 \
            "$URL" \
            2>/dev/null
        )

        CURL_STATUS=$?

        if [ "$CURL_STATUS" -eq 0 ]; then

            IP=$(printf '%s' "$IP" | tr -d '\r\n ')

            if check_ipv4 "$IP"; then
                printf '%s' "$IP"
                return 0
            fi
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
# 获取目标 A 记录
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

    printf '%s' "$RESPONSE" \
        | jq -c \
            --arg host "$TARGET_HOST" \
            '.rows[]? | select(.Name == $host and .Type == "A")' \
        | head -n 1
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
        --data-urlencode "type=A" \
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
    log "ERROR" "未找到 ${TARGET_HOST} 的 A 记录"
    exit 1
fi


RECORD_ID=$(printf '%s' "$RECORD" | jq -r '.RecordId // empty')
RECORD_NAME=$(printf '%s' "$RECORD" | jq -r '.Name // empty')
RECORD_TYPE=$(printf '%s' "$RECORD" | jq -r '.Type // empty')
DNS_IP=$(printf '%s' "$RECORD" | jq -r '.Value // empty')
RECORD_LINE=$(printf '%s' "$RECORD" | jq -r '.Line // empty')
RECORD_TTL=$(printf '%s' "$RECORD" | jq -r '.TTL // empty')


if [ "$RECORD_TYPE" != "A" ]; then
    log "ERROR" "${TARGET_HOST} 不是 A 记录"
    exit 1
fi


if ! check_ipv4 "$DNS_IP"; then
    log "ERROR" "DNS 当前 IP 无效: ${DNS_IP}"
    exit 1
fi


if [ -z "$RECORD_LINE" ] || [ "$RECORD_LINE" = "null" ]; then
    RECORD_LINE="default"
fi


if [ -z "$RECORD_TTL" ] || [ "$RECORD_TTL" = "null" ]; then
    RECORD_TTL="600"
fi


# =========================================================
# 2. 获取本机当前公网 IPv4
# =========================================================

if ! WAN_IP=$(get_wan_ip); then
    log "ERROR" "获取本机公网 IPv4 失败"
    exit 1
fi


if ! check_ipv4 "$WAN_IP"; then
    log "ERROR" "获取到的公网 IPv4 无效: ${WAN_IP}"
    exit 1
fi


# =========================================================
# 3. 比较
# =========================================================

if [ "$WAN_IP" = "$DNS_IP" ]; then

    # 正常情况下保持静默
    exit 0

fi


log "CHANGE" "IPv4变化: ${DNS_IP} -> ${WAN_IP}"


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


if [ "$VERIFY_IP" = "$WAN_IP" ]; then

    log "DONE" "DNS 更新成功: ${TARGET_HOST} ${DNS_IP} -> ${WAN_IP}"

    exit 0

else

    log "ERROR" "DNS 更新验证失败"
    log "ERROR" "期望: ${WAN_IP}"
    log "ERROR" "实际: ${VERIFY_IP:-未知}"

    exit 1

fi

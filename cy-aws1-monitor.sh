#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# 一次性更换 EC2 实例 IP
# 依赖：curl、jq
# 用法：修改下方配置后执行 bash change-ip-once.sh
# ============================================================

# 命令行参数
API_BASE_URL="${1:?用法: bash change-ip-once.sh <网站地址> <TOKEN> [区域] [实例ID]}"
SHARE_GROUP_TOKEN="${2:?请提供 Share Group Token}"
REGION_NAME="${3:-ap-southeast-1}"
INSTANCE_ID="${4:-}"

# 更换 IP 请求参数
STATIC_IP=true
GFW_BLOCKED_CHECK=true
GFW_BLOCKED_CHECK_PORT=22
GFW_BLOCKED_CHECK_CRON="*/59 * * * *"

# ============================================================

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    log "错误：$*"
    exit 1
}

command -v curl >/dev/null 2>&1 || die "未找到 curl，请先安装 curl。"
command -v jq >/dev/null 2>&1 || die "未找到 jq，请先安装 jq。"

[[ -n "$API_BASE_URL" ]] || die "API_BASE_URL 不能为空。"
[[ "$API_BASE_URL" != */ ]] || die "API_BASE_URL 末尾不要带 /。"
[[ -n "$SHARE_GROUP_TOKEN" && "$SHARE_GROUP_TOKEN" != "请填写你的Share-Group-Token" ]] \
    || die "请先在脚本中填写 SHARE_GROUP_TOKEN。"

PROFILES_URL="${API_BASE_URL}/api/ec2-instance-profiles"

log "请求实例配置列表：${PROFILES_URL}"

PROFILES_RESPONSE="$(
    curl --silent --show-error --fail-with-body \
        --request GET \
        --header 'accept: application/json, text/plain, */*' \
        --header 'accept-language: zh-CN,zh;q=0.9,en;q=0.8' \
        --header 'cache-control: no-cache' \
        --header 'pragma: no-cache' \
        --header "x-share-group-token: ${SHARE_GROUP_TOKEN}" \
        "$PROFILES_URL"
)" || die "获取实例列表失败，请检查网站地址、Token、网络或 API 响应。"

printf '%s' "$PROFILES_RESPONSE" | jq -e 'type == "array"' >/dev/null \
    || die "实例列表响应不是 JSON 数组，服务器返回内容如下：$PROFILES_RESPONSE"

if [[ -z "$INSTANCE_ID" ]]; then
    MATCHED_IDS="$(
        printf '%s' "$PROFILES_RESPONSE" |
            jq -r --arg region "$REGION_NAME" '
                .[]
                | select(.regionName == $region)
                | select(.expired != true)
                | select((.instanceId | type) == "string")
                | select(.instanceId != "")
                | .instanceId
            ' |
            sort -u
    )" || die "解析实例列表失败。"

    MATCH_COUNT=0
    if [[ -n "$MATCHED_IDS" ]]; then
        MATCH_COUNT="$(printf '%s\n' "$MATCHED_IDS" | awk 'END { print NR }')"
    fi

    if [[ "$MATCH_COUNT" -eq 0 ]]; then
        die "区域 ${REGION_NAME} 下没有找到未过期的实例。"
    elif [[ "$MATCH_COUNT" -gt 1 ]]; then
        printf '%s\n' "$MATCHED_IDS"
        die "区域 ${REGION_NAME} 下匹配到多个未过期实例。请在 INSTANCE_ID 中明确指定目标实例后重试。"
    fi

    INSTANCE_ID="$MATCHED_IDS"
fi

[[ "$INSTANCE_ID" =~ ^i-[A-Za-z0-9]+$ ]] \
    || die "INSTANCE_ID 格式不正确：${INSTANCE_ID}"

IP_API_URL="${API_BASE_URL}/api/ec2-instances/${INSTANCE_ID}/ip-address"

log "目标区域：${REGION_NAME}"
log "目标实例：${INSTANCE_ID}"
log "提交一次 IP 更换请求：${IP_API_URL}"

REQUEST_BODY="$(
    jq -n \
        --argjson static "$STATIC_IP" \
        --argjson gfw_blocked_check "$GFW_BLOCKED_CHECK" \
        --argjson port "$GFW_BLOCKED_CHECK_PORT" \
        --arg cron "$GFW_BLOCKED_CHECK_CRON" \
        '{
            static: $static,
            gfw_blocked_check: $gfw_blocked_check,
            gfw_blocked_check_port: $port,
            gfw_blocked_check_cron: $cron
        }'
)"

HTTP_RESULT="$(
    curl --silent --show-error \
        --request PATCH \
        --header 'accept: application/json, text/plain, */*' \
        --header 'accept-language: zh-CN,zh;q=0.9,en;q=0.8' \
        --header 'cache-control: no-cache' \
        --header 'content-type: application/json' \
        --header 'pragma: no-cache' \
        --header 'priority: u=1, i' \
        --header 'sec-ch-ua: "Chromium";v="152", "Not?A_Brand";v="24", "Google Chrome";v="152"' \
        --header 'sec-ch-ua-mobile: ?0' \
        --header 'sec-ch-ua-platform: "macOS"' \
        --header 'sec-fetch-dest: empty' \
        --header 'sec-fetch-mode: cors' \
        --header 'sec-fetch-site: same-origin' \
        --header "x-region-name: ${REGION_NAME}" \
        --header "x-share-group-token: ${SHARE_GROUP_TOKEN}" \
        --data "$REQUEST_BODY" \
        --write-out $'\n%{http_code}' \
        "$IP_API_URL"
)" || die "PATCH 请求失败：curl 无法完成请求。"

HTTP_STATUS="${HTTP_RESULT##*$'\n'}"
RESPONSE_BODY="${HTTP_RESULT%$'\n'*}"

printf '\n'
log "HTTP 状态码：${HTTP_STATUS}"
log "服务器响应："
printf '%s\n' "$RESPONSE_BODY"

if [[ ! "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
    die "IP 更换请求未成功，HTTP ${HTTP_STATUS}。"
fi

log "请求已被服务器接受。此脚本只提交一次 PATCH，不会自动重试，也不会等待 DNS IP 变化。"

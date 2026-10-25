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
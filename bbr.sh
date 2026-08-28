#!/usr/bin/env bash

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# =================================================
# BBR 自动检测 / 自动启用脚本
#
# 功能：
# 1. 检查 root 权限
# 2. 检查必要依赖
# 3. 检查网络
# 4. 检查虚拟化类型
# 5. 检查当前 BBR 状态
# 6. 当前内核支持 BBR 时自动启用
# 7. 当前内核不支持 BBR 时直接退出
#
# 不执行任何内核升级操作
# =================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

sh_ver="2.0.0"


# =================================================
# 检查 root 权限
# =================================================

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误：请使用 root 用户运行此脚本${PLAIN}"
    exit 1
fi


# =================================================
# 检测系统
# =================================================

if [[ -f /etc/os-release ]]; then

    . /etc/os-release

    OS="${ID:-unknown}"
    VER="${VERSION_ID:-unknown}"

elif [[ -f /etc/redhat-release ]]; then

    OS="centos"
    VER=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)

else

    OS="unknown"
    VER="unknown"

fi


# =================================================
# 检测架构
# =================================================

ARCH=$(uname -m)

echo ""
echo -e "${BLUE}╔════════════════════════════════════════════╗${PLAIN}"
echo -e "${BLUE}║          BBR 自动加速脚本 v${sh_ver}          ║${PLAIN}"
echo -e "${BLUE}╚════════════════════════════════════════════╝${PLAIN}"
echo ""

echo -e "${GREEN}系统:${PLAIN} ${OS} ${VER}"
echo -e "${GREEN}架构:${PLAIN} ${ARCH}"
echo -e "${GREEN}内核:${PLAIN} $(uname -r)"
echo ""


# =================================================
# 检查 curl
# =================================================

if ! command -v curl &>/dev/null; then

    echo -e "${YELLOW}检测到 curl 未安装，正在自动安装...${PLAIN}"

    if command -v apt-get &>/dev/null; then

        apt-get update -qq
        apt-get install -y curl

    elif command -v dnf &>/dev/null; then

        dnf install -y curl

    elif command -v yum &>/dev/null; then

        yum install -y curl

    fi


    if ! command -v curl &>/dev/null; then

        echo -e "${RED}curl 安装失败${PLAIN}"
        exit 1

    fi

    echo -e "${GREEN}curl 安装完成${PLAIN}"

fi


# =================================================
# 检查依赖
# =================================================

check_dependencies() {

    echo -e "${BLUE}检查系统依赖...${PLAIN}"

    local need_install=()

    for dep in curl wget; do

        if ! command -v "$dep" &>/dev/null; then
            need_install+=("$dep")
        fi

    done


    if [[ ${#need_install[@]} -eq 0 ]]; then

        echo -e "${GREEN}所有依赖已安装${PLAIN}"
        return 0

    fi


    echo -e "${YELLOW}缺少依赖: ${need_install[*]}${PLAIN}"


    if command -v apt-get &>/dev/null; then

        apt-get update -qq
        apt-get install -y "${need_install[@]}"

    elif command -v dnf &>/dev/null; then

        dnf install -y "${need_install[@]}"

    elif command -v yum &>/dev/null; then

        yum install -y "${need_install[@]}"

    else

        echo -e "${RED}无法识别系统包管理器${PLAIN}"
        return 1

    fi


    for dep in "${need_install[@]}"; do

        if ! command -v "$dep" &>/dev/null; then

            echo -e "${RED}依赖安装失败: ${dep}${PLAIN}"
            return 1

        fi

    done


    echo -e "${GREEN}依赖安装完成${PLAIN}"

    return 0
}


# =================================================
# 检查网络
# =================================================

check_network() {

    echo -e "${BLUE}检查网络连接...${PLAIN}"

    local mirrors=(
        "https://www.cloudflare.com"
        "https://www.baidu.com"
        "https://mirrors.aliyun.com"
    )


    for mirror in "${mirrors[@]}"; do

        if curl \
            -s \
            --connect-timeout 5 \
            --max-time 8 \
            "$mirror" \
            >/dev/null 2>&1
        then

            echo -e "${GREEN}网络连接正常${PLAIN}"
            return 0

        fi

    done


    # curl 检测失败后再尝试 ping
    if command -v ping &>/dev/null; then

        if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then

            echo -e "${YELLOW}网络可用，但 HTTPS 访问可能受到限制${PLAIN}"
            return 0

        fi

    fi


    echo -e "${YELLOW}无法确认外部网络连接状态${PLAIN}"

    # BBR 本身不依赖互联网
    # 因此这里不直接退出

    return 0
}


# =================================================
# 检查虚拟化类型
# =================================================

check_virt() {

    echo -e "${BLUE}检查虚拟化类型...${PLAIN}"

    local virt_type="unknown"


    if command -v systemd-detect-virt &>/dev/null; then

        virt_type=$(systemd-detect-virt 2>/dev/null)

        [[ -z "$virt_type" ]] && virt_type="none"

    elif command -v virt-what &>/dev/null; then

        virt_type=$(virt-what 2>/dev/null | head -1)

        [[ -z "$virt_type" ]] && virt_type="unknown"

    else

        if [[ -f /proc/vz/version ]] ||
           grep -qi "openvz" /proc/1/status 2>/dev/null
        then

            virt_type="openvz"

        fi

    fi


    echo -e "${GREEN}虚拟化类型:${PLAIN} ${virt_type}"


    # OpenVZ 老式容器通常无法自行控制 BBR
    if [[ "$virt_type" == "openvz" ]]; then

        echo ""
        echo -e "${RED}╔════════════════════════════════════════════╗${PLAIN}"
        echo -e "${RED}║          检测到 OpenVZ 容器               ║${PLAIN}"
        echo -e "${RED}║                                            ║${PLAIN}"
        echo -e "${RED}║  当前容器通常无法自行启用 BBR             ║${PLAIN}"
        echo -e "${RED}╚════════════════════════════════════════════╝${PLAIN}"
        echo ""

        exit 1

    fi

}


# =================================================
# 检测当前 BBR 状态
# =================================================

check_bbr_status() {

    local congestion

    congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)

    if [[ "$congestion" == "bbr" ]]; then
        return 0
    fi

    return 1
}


# =================================================
# 检查 BBR 算法是否可用
# =================================================

check_bbr_available() {

    local available

    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)

    if echo "$available" | grep -qw "bbr"; then
        return 0
    fi


    # 尝试加载 BBR 模块
    if command -v modprobe &>/dev/null; then

        modprobe tcp_bbr >/dev/null 2>&1

        available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)

        if echo "$available" | grep -qw "bbr"; then
            return 0
        fi

    fi


    return 1
}


# =================================================
# 检测内核版本
# =================================================

check_kernel_native_bbr() {

    local kernel_version
    local major
    local minor

    kernel_version=$(uname -r | cut -d- -f1)

    major=$(echo "$kernel_version" | cut -d. -f1)
    minor=$(echo "$kernel_version" | cut -d. -f2)


    # 确保版本号有效
    if ! [[ "$major" =~ ^[0-9]+$ ]] ||
       ! [[ "$minor" =~ ^[0-9]+$ ]]
    then

        echo -e "${YELLOW}无法正确识别内核版本: ${kernel_version}${PLAIN}"

        # 最终以系统是否实际提供 BBR 为准
        check_bbr_available
        return $?

    fi


    # Linux 4.9 开始包含 BBR
    if (( major > 4 )) ||
       (( major == 4 && minor >= 9 ))
    then

        echo -e "${GREEN}当前内核 ${kernel_version} 支持 BBR${PLAIN}"

        return 0

    fi


    echo -e "${RED}当前内核 ${kernel_version} 版本过低，不支持原生 BBR${PLAIN}"

    return 1
}


# =================================================
# 写入 sysctl 参数
# =================================================

write_bbr_config() {

    echo -e "${BLUE}正在写入 BBR 配置...${PLAIN}"


    cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
# =================================================
# BBR 网络优化
# =================================================

# 使用 Fair Queue
net.core.default_qdisc = fq

# TCP BBR
net.ipv4.tcp_congestion_control = bbr

# TCP Fast Open
net.ipv4.tcp_fastopen = 3

# 空闲连接恢复时避免重新慢启动
net.ipv4.tcp_slow_start_after_idle = 0

# Socket 最大接收缓冲区
net.core.rmem_max = 16777216

# Socket 最大发送缓冲区
net.core.wmem_max = 16777216

# TCP 接收缓冲区
net.ipv4.tcp_rmem = 4096 87380 16777216

# TCP 发送缓冲区
net.ipv4.tcp_wmem = 4096 65536 16777216

# 网卡接收队列
net.core.netdev_max_backlog = 5000

# SYN 队列
net.ipv4.tcp_max_syn_backlog = 8192
EOF


    if [[ ! -f /etc/sysctl.d/99-bbr.conf ]]; then

        echo -e "${RED}BBR 配置文件写入失败${PLAIN}"
        return 1

    fi


    return 0
}


# =================================================
# 启用 BBR
# =================================================

enable_bbr() {

    if check_bbr_status; then

        echo -e "${GREEN}BBR 已经启用，无需重复配置${PLAIN}"
        return 0

    fi


    echo -e "${BLUE}正在检测 BBR 是否可用...${PLAIN}"


    # 尝试加载模块
    if command -v modprobe &>/dev/null; then

        modprobe tcp_bbr >/dev/null 2>&1

    fi


    if ! check_bbr_available; then

        echo ""
        echo -e "${RED}BBR 不可用${PLAIN}"
        echo -e "${RED}当前系统虽然可能满足内核版本要求，但没有提供 tcp_bbr${PLAIN}"
        echo ""

        return 1

    fi


    echo -e "${GREEN}检测到 BBR 可用${PLAIN}"


    # 写入配置
    if ! write_bbr_config; then
        return 1
    fi


    echo -e "${BLUE}正在应用 BBR 配置...${PLAIN}"


    if ! sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1; then

        echo -e "${RED}sysctl 配置加载失败${PLAIN}"
        return 1

    fi


    # 再次验证
    if check_bbr_status; then

        echo ""
        echo -e "${GREEN}╔════════════════════════════════════════════╗${PLAIN}"
        echo -e "${GREEN}║                                            ║${PLAIN}"
        echo -e "${GREEN}║            BBR 启用成功                   ║${PLAIN}"
        echo -e "${GREEN}║                                            ║${PLAIN}"
        echo -e "${GREEN}╚════════════════════════════════════════════╝${PLAIN}"
        echo ""

        return 0

    fi


    echo ""
    echo -e "${RED}BBR 配置已经写入，但启用验证失败${PLAIN}"
    echo ""

    return 1
}


# =================================================
# 显示状态
# =================================================

show_status() {

    local congestion
    local available
    local qdisc
    local module_status


    congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)


    if lsmod 2>/dev/null | grep -qw tcp_bbr; then

        module_status="✅ 已加载"

    elif check_bbr_available; then

        module_status="✅ 可用"

    else

        module_status="❌ 不可用"

    fi


    echo ""
    echo -e "${BLUE}================ 系统状态 ================${PLAIN}"

    echo -e "${GREEN}系统:${PLAIN}       ${OS} ${VER}"
    echo -e "${GREEN}架构:${PLAIN}       ${ARCH}"
    echo -e "${GREEN}内核:${PLAIN}       $(uname -r)"


    if check_bbr_status; then

        echo -e "${GREEN}BBR 状态:${PLAIN}   ✅ 已启用"

    else

        echo -e "${GREEN}BBR 状态:${PLAIN}   ❌ 未启用"

    fi


    echo -e "${GREEN}BBR 模块:${PLAIN}   ${module_status}"
    echo -e "${GREEN}队列算法:${PLAIN}   ${qdisc:-未知}"
    echo -e "${GREEN}拥塞算法:${PLAIN}   ${congestion:-未知}"
    echo -e "${GREEN}可用算法:${PLAIN}   ${available:-未知}"

    echo -e "${BLUE}===========================================${PLAIN}"
    echo ""

}


# =================================================
# 开始执行
# =================================================

echo -e "${BLUE}开始执行预检查...${PLAIN}"
echo ""


# 检查依赖
if ! check_dependencies; then

    echo -e "${RED}系统依赖检查失败${PLAIN}"
    exit 1

fi


echo ""


# 检查网络
check_network


echo ""


# 检查虚拟化
check_virt


echo ""
echo -e "${GREEN}预检查完成${PLAIN}"
echo ""


# =================================================
# 检测 BBR 当前状态
# =================================================

echo -e "${BLUE}正在检测 BBR 状态...${PLAIN}"
echo ""


if check_bbr_status; then

    echo -e "${GREEN}BBR 已经启用，无需重复配置${PLAIN}"

    show_status

    exit 0

fi


echo -e "${YELLOW}当前 BBR 尚未启用${PLAIN}"
echo ""


# =================================================
# 检测内核
# =================================================

if ! check_kernel_native_bbr; then

    echo ""
    echo -e "${RED}╔════════════════════════════════════════════╗${PLAIN}"
    echo -e "${RED}║                                            ║${PLAIN}"
    echo -e "${RED}║          当前内核不支持 BBR               ║${PLAIN}"
    echo -e "${RED}║                                            ║${PLAIN}"
    echo -e "${RED}║       脚本不会执行任何内核升级             ║${PLAIN}"
    echo -e "${RED}║                                            ║${PLAIN}"
    echo -e "${RED}╚════════════════════════════════════════════╝${PLAIN}"
    echo ""

    exit 1

fi


# =================================================
# 自动启用 BBR
# =================================================

echo ""
echo -e "${GREEN}当前内核支持 BBR${PLAIN}"
echo -e "${BLUE}正在自动启用 BBR...${PLAIN}"
echo ""


if enable_bbr; then

    show_status

    exit 0

else

    echo ""
    echo -e "${RED}╔════════════════════════════════════════════╗${PLAIN}"
    echo -e "${RED}║                                            ║${PLAIN}"
    echo -e "${RED}║          BBR 自动启用失败                 ║${PLAIN}"
    echo -e "${RED}║                                            ║${PLAIN}"
    echo -e "${RED}╚════════════════════════════════════════════╝${PLAIN}"
    echo ""

    show_status

    exit 1

fi

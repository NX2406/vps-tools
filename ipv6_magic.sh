#!/bin/bash

# =========================================================
# IPv6 /64 AnyIP 配置脚本 (V7.9 永不掉线版)
# 更新：采用“热接管”模式，不再删除临时 IP，彻底防止因 IP 变动导致的默认路由丢失问题
#
# 修正 & 增强（不改变原功能）：
# 1) Debian/Ubuntu：修复 apt/dpkg lock 导致依赖安装失败的问题（支持等待锁 + APT Lock Timeout + 重试）
# 2) Debian/Ubuntu：修复 ndppd 安装失败后 systemd Unit 不存在导致 restart 报错的问题（确保 service 存在）
# 3) 增加 CentOS/RHEL 全系支持（yum/dnf 自适应 + EPEL + ndppd unit 兜底）
# =========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

# 强制非交互模式
export DEBIAN_FRONTEND=noninteractive

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：请使用 root 权限运行此脚本！${PLAIN}"
   exit 1
fi

# ================= OS / 包管理器检测 =================
detect_release() {
    if [[ -f /etc/redhat-release ]]; then
        echo "centos"
    else
        echo "debian"
    fi
}

detect_pkg_mgr() {
    if command -v apt-get >/dev/null 2>&1; then echo "apt"; return; fi
    if command -v dnf >/dev/null 2>&1; then echo "dnf"; return; fi
    if command -v yum >/dev/null 2>&1; then echo "yum"; return; fi
    echo ""
}

RELEASE="$(detect_release)"
PKG_MGR="$(detect_pkg_mgr)"

# ================= 环境检测函数 =================
wait_for_lock() {
    # 兼容 Debian/Ubuntu：dpkg/apt 常见锁（含 lock-frontend）
    # 不删除锁文件，只等待释放，避免损坏系统。
    local i=0
    local max_wait=300   # 最多等 300 秒（5 分钟）
    while true; do
        local locked=0

        # 常见锁文件：dpkg/apt
        fuser /var/lib/dpkg/lock >/dev/null 2>&1 && locked=1
        fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && locked=1
        fuser /var/lib/apt/lists/lock >/dev/null 2>&1 && locked=1
        fuser /var/cache/apt/archives/lock >/dev/null 2>&1 && locked=1

        # 进程层面：apt/dpkg 后台任务（apt-daily / unattended-upgrades）
        pgrep -x apt-get >/dev/null 2>&1 && locked=1
        pgrep -x dpkg >/dev/null 2>&1 && locked=1
        pgrep -x unattended-upgr >/dev/null 2>&1 && locked=1

        [[ "$locked" -eq 0 ]] && break

        echo -e "${YELLOW}   [等待] 系统后台正在更新/安装，等待锁释放... (${i}s)${PLAIN}"
        sleep 2
        ((i+=2))

        if [ $i -gt $max_wait ]; then
            echo -e "${RED}   [错误] 等待超时（${max_wait}s）。建议稍后重试或重启 VPS 释放后台 apt 任务。${PLAIN}"
            echo -e "${YELLOW}   提示：可查看占用进程：ps -ef | egrep 'apt|dpkg|unattended'${PLAIN}"
            exit 1
        fi
    done
}

install_pkg_with_retry() {
    local PKG_CMD="$1"
    local MAX_RETRIES=3
    local COUNT=0

    while [ $COUNT -lt $MAX_RETRIES ]; do
        # Debian：每次执行前都等锁，且给 apt/dpkg 一个锁等待超时
        if [[ "${RELEASE}" == "debian" ]]; then
            wait_for_lock
        fi

        eval "$PKG_CMD"
        if [ $? -eq 0 ]; then return 0; fi

        ((COUNT++))
        echo -e "${YELLOW}   [警告] 安装失败，3秒后重试... (${COUNT}/${MAX_RETRIES})${PLAIN}"
        sleep 3
    done
    return 1
}

# -------- ndppd：确保安装 + 确保 systemd unit 存在（Debian/CentOS 都兜底） --------
ensure_ndppd() {
    if command -v ndppd >/dev/null 2>&1; then
        # 有命令也不代表有 unit，继续做 unit 校验
        :
    else
        if [[ "${RELEASE}" == "debian" ]]; then
            # 使用 Lock Timeout，减少 dpkg 锁冲突
            install_pkg_with_retry "apt-get -o DPkg::Lock::Timeout=120 install -y ndppd"
        else
            # CentOS/RHEL：先装 epel，再装 ndppd
            if command -v dnf >/dev/null 2>&1; then
                dnf -y install epel-release >/dev/null 2>&1 || true
                install_pkg_with_retry "dnf -y install ndppd"
            else
                yum -y install epel-release >/dev/null 2>&1 || true
                install_pkg_with_retry "yum -y install ndppd"
            fi
        fi
    fi

    # 到这里仍然没有 ndppd 命令则直接报错
    if ! command -v ndppd >/dev/null 2>&1; then
        echo -e "${RED}   [失败] ndppd 安装失败，无法继续。${PLAIN}"
        exit 1
    fi

    # 确保 systemd unit 存在（有的环境只装了二进制没带 unit，或 unit 名不一致）
    if systemctl list-unit-files 2>/dev/null | grep -qE '^ndppd\.service'; then
        return 0
    fi

    # 创建一个兜底 unit：不改变你的功能，只保证 restart/enable 可用
    cat > /etc/systemd/system/ndppd.service <<'UNIT'
[Unit]
Description=NDP Proxy Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/ndppd -d -c /etc/ndppd.conf
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload >/dev/null 2>&1 || true
}

check_update() {
    echo -e "${YELLOW}>>> [0/4] 正在执行系统预检...${PLAIN}"

    if [[ "${RELEASE}" == "debian" ]]; then
        wait_for_lock
        echo -e "${BLUE}   [1/3] 更新软件源...${PLAIN}"
        install_pkg_with_retry "apt-get -o DPkg::Lock::Timeout=120 update -y"

        echo -e "${BLUE}   [2/3] 安装依赖组件...${PLAIN}"
        wait_for_lock
        install_pkg_with_retry "apt-get -o DPkg::Lock::Timeout=120 install -y iproute2 net-tools curl wget grep gawk sed iputils-ping"

    else
        echo -e "${BLUE}   [1/3] 更新软件源...${PLAIN}"
        # 保持你的“更新系统”语义：原来 yum update -y；增加 dnf 兼容
        if command -v dnf >/dev/null 2>&1; then
            install_pkg_with_retry "dnf -y update"
        else
            install_pkg_with_retry "yum update -y"
        fi

        echo -e "${BLUE}   [2/3] 安装依赖组件...${PLAIN}"
        if command -v dnf >/dev/null 2>&1; then
            dnf -y install epel-release >/dev/null 2>&1 || true
            install_pkg_with_retry "dnf -y install iproute net-tools curl wget grep gawk sed iputils"
        else
            yum install -y epel-release >/dev/null 2>&1 || true
            install_pkg_with_retry "yum install -y iproute net-tools curl wget grep gawk sed iputils"
        fi
    fi

    echo -e "${GREEN}   [完成] 环境依赖就绪${PLAIN}"
    echo "----------------------------------------------------"
}

# ================= 菜单界面 =================
clear
echo -e "${YELLOW}==============================================${PLAIN}"
echo -e "${YELLOW}           欢迎使用 ipv6Anyips 脚本           ${PLAIN}"
echo -e "${YELLOW}==============================================${PLAIN}"
echo ""
echo -e "请选择操作："
echo -e "${GREEN}  1. 开始安装 (自动配置 / 救砖绑定)${PLAIN}"
echo -e "${RED}  2. 一键卸载 (移除所有服务与配置)${PLAIN}"
echo ""
read -p "请输入选项 [1-2]: " choice
echo ""

install_anyip() {
    check_update

    echo -e "${YELLOW}>>> [1/4] 正在检测网络环境...${PLAIN}"
    echo "-> 正在探测主网卡接口..."
    MAIN_IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')

    if [ -z "$MAIN_IFACE" ]; then
        echo -e "${RED}   [失败] 无法获取主网卡接口${PLAIN}"
        exit 1
    else
        echo -e "${GREEN}   [成功] 主网卡: ${MAIN_IFACE}${PLAIN}"
    fi

    echo "-> 正在验证 IPv6 /64 配置..."
    RAW_IP=$(ip -6 addr show dev "$MAIN_IFACE" | grep "/64" | grep "scope global" | head -n 1 | awk '{print $2}' | cut -d'/' -f1)

    MANUAL_BIND="no"

    if [ -z "$RAW_IP" ]; then
        echo -e "${YELLOW}   [警告] 未检测到 IPv6，进入救砖模式${PLAIN}"
        read -p "   请输入商家分配的 IPv6 地址/前缀: " USER_PREFIX_INPUT
        USER_INPUT_CLEAN=$(echo "$USER_PREFIX_INPUT" | cut -d'/' -f1 | tr -d ' ')

        if [ -z "$USER_INPUT_CLEAN" ]; then echo -e "${RED}错误：输入为空${PLAIN}"; exit 1; fi

        if [[ "$USER_INPUT_CLEAN" == *":" ]]; then TEST_BIND_IP="${USER_INPUT_CLEAN}1"; else TEST_BIND_IP="$USER_INPUT_CLEAN"; fi

        echo "-> 正在尝试绑定 IP 并测试连通性..."
        ip -6 addr del "${TEST_BIND_IP}/64" dev "$MAIN_IFACE" >/dev/null 2>&1
        ip -6 addr add "${TEST_BIND_IP}/64" dev "$MAIN_IFACE" 2>/dev/null

        if [ $? -ne 0 ]; then
             if [[ "$USER_INPUT_CLEAN" != *":" ]]; then
                 TEST_BIND_IP="${USER_INPUT_CLEAN}::1"
                 ip -6 addr add "${TEST_BIND_IP}/64" dev "$MAIN_IFACE" >/dev/null 2>&1
             fi
        fi

        echo -e "${YELLOW}   [等待] 等待地址生效 (3秒)...${PLAIN}"
        sleep 3

        if ping6 -c 1 -w 3 2001:4860:4860::8888 >/dev/null 2>&1; then
             echo -e "${GREEN}   [成功] 网络连通！${PLAIN}"
             RAW_IP="$TEST_BIND_IP"
             MANUAL_BIND="yes"
        else
             echo -e "${RED}   [失败] 绑定后无法 Ping 通 Google DNS。${PLAIN}"
             echo -e "${YELLOW}   尝试自动修复网关路由...${PLAIN}"
             ip -6 route add default dev "$MAIN_IFACE" >/dev/null 2>&1
             if ping6 -c 1 -w 3 2001:4860:4860::8888 >/dev/null 2>&1; then
                 echo -e "${GREEN}   [成功] 网关修复成功！${PLAIN}"
                 RAW_IP="$TEST_BIND_IP"
                 MANUAL_BIND="yes"
             else
                 echo -e "${RED}   [严重失败] 无法连通 IPv6 网络，请检查控制台网络设置。${PLAIN}"
                 exit 1
             fi
        fi
    fi

    IPV6_PREFIX=$(echo "$RAW_IP" | awk -F: '{print $1":"$2":"$3":"$4}' | sed 's/:*$//')
    IPV6_SUBNET="${IPV6_PREFIX}::/64"
    echo -e "${GREEN}   [成功] 目标网段: ${IPV6_SUBNET}${PLAIN}"
    echo "----------------------------------------------------"

    echo -e "${YELLOW}>>> [2/4] 配置 NDP 代理...${PLAIN}"

    # 修复点：先确保 ndppd 命令与 systemd unit 都存在，再写配置，再 restart
    ensure_ndppd

    cat > /etc/ndppd.conf <<CONF
proxy $MAIN_IFACE {
   rule $IPV6_SUBNET {
      static
   }
}
CONF

    systemctl restart ndppd >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        # 再兜底一次：有些环境 unit 刚生成需要 daemon-reload 后再 restart
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl restart ndppd
    fi

    systemctl enable ndppd >/dev/null 2>&1

    echo -e "\n${YELLOW}>>> [3/4] 配置路由服务...${PLAIN}"
    SERVICE_FILE="/etc/systemd/system/ipv6-anyip.service"

    BIND_CMD=""
    if [ "$MANUAL_BIND" == "yes" ]; then
        BIND_CMD="ExecStart=/bin/bash -c '/sbin/ip addr add ${RAW_IP}/64 dev ${MAIN_IFACE} 2>/dev/null || true'"
        echo -e "${BLUE}   [提示] 已配置热接管模式，保持网络不中断${PLAIN}"
    fi

cat > "$SERVICE_FILE" <<SERVICE
[Unit]
Description=IPv6 AnyIP Routing Setup
After=network.target ndppd.service

[Service]
Type=oneshot
ExecStart=/sbin/sysctl -w net.ipv6.ip_nonlocal_bind=1
${BIND_CMD}
ExecStart=/sbin/ip route replace local $IPV6_SUBNET dev lo
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable ipv6-anyip.service >/dev/null 2>&1

    echo "-> 启动服务..."
    systemctl start ipv6-anyip.service

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}   [成功] 服务启动正常${PLAIN}"
    else
        echo -e "${RED}   [失败] 服务启动异常，请检查日志${PLAIN}"
        exit 1
    fi

    echo -e "\n${YELLOW}>>> [4/4] 最终验证...${PLAIN}"
    RAND_SUFFIX=$(printf '%x' $((RANDOM + 1)))
    TEST_IP="${IPV6_PREFIX}::${RAND_SUFFIX}"
    echo "Ping测试目标: $TEST_IP"

    if ping6 -c 1 -w 2 2001:4860:4860::8888 > /dev/null 2>&1; then
        echo -e "${GREEN}本地网络正常，开始 Ping...${PLAIN}"
        ping6 -c 5 $TEST_IP
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}=========================================${PLAIN}"
            echo -e "${GREEN}      恭喜！脚本执行成功 (Exit 0)        ${PLAIN}"
            echo -e "${GREEN}=========================================${PLAIN}"
            echo -e "${BLUE}everything by 執筆·抒情${PLAIN}"
            exit 0
        else
            echo -e "${RED}警告：IP 已添加但 Ping 不通，请检查防火墙或 NDP 设置。${PLAIN}"
            exit 1
        fi
    else
        echo -e "${YELLOW}错误：本地 IPv6 再次断开。${PLAIN}"
        echo -e "${YELLOW}请尝试手动运行: ip -6 route add default dev ${MAIN_IFACE}${PLAIN}"
        exit 1
    fi
}

uninstall_anyip() {
    echo -e "${YELLOW}>>> 正在执行卸载...${PLAIN}"
    systemctl stop ipv6-anyip.service 2>/dev/null
    systemctl disable ipv6-anyip.service 2>/dev/null
    rm -f /etc/systemd/system/ipv6-anyip.service

    systemctl stop ndppd 2>/dev/null
    systemctl disable ndppd 2>/dev/null
    rm -f /etc/ndppd.conf

    # 若我们创建过兜底 unit，也一并清理（不影响原有系统自带 unit）
    if [[ -f /etc/systemd/system/ndppd.service ]]; then
        rm -f /etc/systemd/system/ndppd.service
    fi

    systemctl daemon-reload
    echo -e "${GREEN}卸载完成。${PLAIN}"
}

case "$choice" in
    1) install_anyip ;;
    2) uninstall_anyip ;;
    *) echo "无效选项"; exit 1 ;;
esac

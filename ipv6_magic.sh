#!/bin/bash

# =========================================================
# IPv6 /64 AnyIP & NDP Proxy 自动配置脚本
# 版本：V3.0 (旗舰版)
# 功能：IPv6检测 / 自动更新 / AnyIP配置 / NDP代理 / 持久化
# =========================================================

# --- [ 配置区域：请修改这里 ] ---
CURRENT_VERSION="3.0"
# 请将下面的链接替换为你 GitHub 仓库里该脚本的【Raw】直链
# 例如: https://raw.githubusercontent.com/你的名字/仓库/main/ipv6_magic.sh
UPDATE_URL="https://raw.githubusercontent.com/NX2406/vps-tools/main/ipv6_magic.sh"
# -----------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# Check Root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：请使用 root 权限运行此脚本！${PLAIN}"
   exit 1
fi

# ================= 模块 1: 环境预检 =================
echo -e "${YELLOW}>>> [1/5] 正在检测环境与更新...${PLAIN}"

# [功能A] 本地 IPv6 能力检测
echo -n "检测 IPv6 支持: "
if ! [ -f /proc/net/if_inet6 ]; then
    echo -e "${RED}失败 (未启用 IPv6 模块)${PLAIN}"
    echo "请联系服务商开启 IPv6。"
    exit 1
fi

# 简单的连通性测试 (Ping Google DNS)
if ping6 -c 1 -w 2 2001:4860:4860::8888 &> /dev/null; then
    echo -e "${GREEN}通畅 (具备访问互联网能力)${PLAIN}"
else
    echo -e "${YELLOW}警告 (无法 Ping 通外网 IPv6，可能是防火墙拦截，脚本继续运行...)${PLAIN}"
fi

# [功能B] 脚本更新检测
echo -n "检测脚本更新: "
# 尝试获取远程脚本的版本号
REMOTE_VERSION=$(curl -s --connect-timeout 3 "$UPDATE_URL" | grep -oP 'CURRENT_VERSION="\K[^"]+')

if [[ -n "$REMOTE_VERSION" ]]; then
    if [[ "$REMOTE_VERSION" != "$CURRENT_VERSION" ]]; then
        echo -e "${YELLOW}发现新版本: V$REMOTE_VERSION (当前: V$CURRENT_VERSION)${PLAIN}"
        echo -e "正在自动更新..."
        wget -q -O "$0" "$UPDATE_URL"
        chmod +x "$0"
        echo -e "${GREEN}更新完成，正在重新启动脚本...${PLAIN}"
        echo -e "------------------------------------"
        exec "$0" "$@"
    else
        echo -e "${GREEN}当前已是最新版本 (V$CURRENT_VERSION)${PLAIN}"
    fi
else
    echo -e "${YELLOW}跳过 (无法连接到 GitHub 仓库或未配置 UPDATE_URL)${PLAIN}"
fi

# ================= 模块 2: 网段识别 (V2 核心算法) =================
echo -e "\n${YELLOW}>>> [2/5] 正在识别网络参数...${PLAIN}"

# 自动检测主网卡
MAIN_IFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
if [ -z "$MAIN_IFACE" ]; then
    echo -e "${RED}无法自动检测到主网卡。${PLAIN}"
    exit 1
fi

# 自动检测 IPv6 /64 网段 (V2 修复版逻辑：只取前缀)
RAW_IP=$(ip -6 addr show dev "$MAIN_IFACE" | grep "/64" | grep "scope global" | head -n 1 | awk '{print $2}' | cut -d'/' -f1)

if [ -z "$RAW_IP" ]; then
    echo -e "${RED}错误：未在网卡 $MAIN_IFACE 上检测到 /64 IPv6 地址。${PLAIN}"
    echo "请确认机器已分配 IPv6 且掩码为 /64。"
    exit 1
fi

# 提取前缀 (Prefix)
IPV6_PREFIX=$(echo "$RAW_IP" | awk -F: '{print $1":"$2":"$3":"$4}')
IPV6_SUBNET="${IPV6_PREFIX}::/64"

echo -e "检测到主网卡: ${GREEN}${MAIN_IFACE}${PLAIN}"
echo -e "检测到 IPv6 网段: ${GREEN}${IPV6_SUBNET}${PLAIN}"
echo -e "${YELLOW}请确认信息准确 (3秒后继续)...${PLAIN}"
sleep 3

# ================= 模块 3: 安装 NDPPD =================
echo -e "\n${YELLOW}>>> [3/5] 配置 NDP 响应代理...${PLAIN}"
if ! command -v ndppd &> /dev/null; then
    echo "安装 ndppd..."
    apt-get update -y > /dev/null 2>&1
    apt-get install ndppd -y > /dev/null 2>&1
fi

# 写入配置
cat > /etc/ndppd.conf <<CONF
proxy $MAIN_IFACE {
   rule $IPV6_SUBNET {
      static
   }
}
CONF

systemctl restart ndppd
systemctl enable ndppd > /dev/null 2>&1

# ================= 模块 4: 配置路由与持久化 =================
echo -e "\n${YELLOW}>>> [4/5] 配置路由持久化服务...${PLAIN}"

cat > /etc/systemd/system/ipv6-anyip.service <<SERVICE
[Unit]
Description=IPv6 AnyIP Routing Setup
After=network.target ndppd.service

[Service]
Type=oneshot
ExecStart=/sbin/sysctl -w net.ipv6.ip_nonlocal_bind=1
ExecStart=/sbin/ip route replace local $IPV6_SUBNET dev lo
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable ipv6-anyip.service > /dev/null 2>&1
systemctl start ipv6-anyip.service

# ================= 模块 5: 最终验证 =================
echo -e "\n${YELLOW}>>> [5/5] 进行连接测试...${PLAIN}"
TEST_IP="${IPV6_PREFIX}::1234"

if ping6 -c 2 -w 2 $TEST_IP &> /dev/null; then
    echo -e "${GREEN}=========================================${PLAIN}"
    echo -e "${GREEN}       IPv6 AnyIP 部署成功！       ${PLAIN}"
    echo -e "${GREEN}=========================================${PLAIN}"
    echo -e "网段: ${IPV6_SUBNET}"
    echo -e "现在你可以绑定该网段内的任意 IP (如: ${TEST_IP})"
else
    echo -e "${RED}测试失败。请检查 ip -6 route 或防火墙设置。${PLAIN}"
    ip -6 route | grep "$IPV6_PREFIX"
fi

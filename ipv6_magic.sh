#!/bin/bash

# =========================================================
# IPv6 /64 AnyIP & NDP Proxy 自动配置脚本
# 版本：V3.1 (修复更新逻辑版)
# =========================================================

# --- [ 配置区域 ] ---
CURRENT_VERSION="3.1"
UPDATE_URL="https://raw.githubusercontent.com/NX2406/vps-tools/main/ipv6_magic.sh"
# -------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：请使用 root 权限运行此脚本！${PLAIN}"
   exit 1
fi

echo -e "${YELLOW}>>> [1/5] 正在检测环境...${PLAIN}"

# 检测 IPv6 支持
if ! [ -f /proc/net/if_inet6 ]; then
    echo -e "${RED}失败 (未启用 IPv6 模块)${PLAIN}"
    exit 1
fi

# 简单的连通性测试
ping6 -c 1 -w 2 2001:4860:4860::8888 &> /dev/null

# ================= 智能更新检测 =================
# 只有当脚本是本地文件时才更新，一键脚本(管道模式)跳过
if [ -f "$0" ]; then
    echo -n "检测脚本更新: "
    REMOTE_VERSION=$(curl -s --connect-timeout 3 "$UPDATE_URL" | grep -oP 'CURRENT_VERSION="\K[^"]+' | tr -d '\r')

    if [[ -n "$REMOTE_VERSION" ]]; then
        if [[ "$REMOTE_VERSION" != "$CURRENT_VERSION" ]]; then
            echo -e "${YELLOW}发现新版本: V$REMOTE_VERSION${PLAIN}"
            wget -q -O "$0" "$UPDATE_URL"
            chmod +x "$0"
            echo -e "更新完成，正在重启脚本..."
            exec "$0" "$@"
        else
            echo -e "${GREEN}当前已是最新 (V$CURRENT_VERSION)${PLAIN}"
        fi
    else
        echo -e "${YELLOW}跳过 (无法连接更新服务器)${PLAIN}"
    fi
else
    echo -e "${GREEN}当前为一键运行模式，跳过自动更新检测。${PLAIN}"
fi

# ================= 模块 2: 网段识别 =================
echo -e "\n${YELLOW}>>> [2/5] 正在识别网络参数...${PLAIN}"

MAIN_IFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
RAW_IP=$(ip -6 addr show dev "$MAIN_IFACE" | grep "/64" | grep "scope global" | head -n 1 | awk '{print $2}' | cut -d'/' -f1)

if [ -z "$RAW_IP" ]; then
    echo -e "${RED}错误：未检测到 /64 IPv6 地址。${PLAIN}"
    exit 1
fi

IPV6_PREFIX=$(echo "$RAW_IP" | awk -F: '{print $1":"$2":"$3":"$4}')
IPV6_SUBNET="${IPV6_PREFIX}::/64"

echo -e "检测到网卡: ${GREEN}${MAIN_IFACE}${PLAIN}"
echo -e "检测到网段: ${GREEN}${IPV6_SUBNET}${PLAIN}"
sleep 2

# ================= 模块 3: 安装 NDPPD =================
echo -e "\n${YELLOW}>>> [3/5] 配置 NDP 代理...${PLAIN}"
if ! command -v ndppd &> /dev/null; then
    apt-get update -y > /dev/null 2>&1
    apt-get install ndppd -y > /dev/null 2>&1
fi

cat > /etc/ndppd.conf <<CONF
proxy $MAIN_IFACE {
   rule $IPV6_SUBNET {
      static
   }
}
CONF

systemctl restart ndppd
systemctl enable ndppd > /dev/null 2>&1

# ================= 模块 4: 配置路由 =================
echo -e "\n${YELLOW}>>> [4/5] 配置路由持久化...${PLAIN}"

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

# ================= 模块 5: 验证 =================
echo -e "\n${YELLOW}>>> [5/5] 连接测试...${PLAIN}"
TEST_IP="${IPV6_PREFIX}::1234"

if ping6 -c 2 -w 2 $TEST_IP &> /dev/null; then
    echo -e "${GREEN}SUCCESS! IPv6 AnyIP 部署成功！${PLAIN}"
    echo -e "网段: ${IPV6_SUBNET}"
else
    echo -e "${RED}测试失败。请检查路由。${PLAIN}"
fi

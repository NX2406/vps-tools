#!/bin/bash

# =========================================================
# IPv6 /64 AnyIP & NDP Proxy 配置脚本
# 版本：V4.0 (纯净稳定版) - 移除所有自动更新逻辑
# =========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 1. 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：请使用 root 权限运行此脚本！${PLAIN}"
   exit 1
fi

echo -e "${YELLOW}>>> 正在检测网络环境...${PLAIN}"

# 2. 核心功能：识别网卡和网段
MAIN_IFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
# 使用最通用的 cut 命令提取 IP，避免 grep 兼容性问题
RAW_IP=$(ip -6 addr show dev "$MAIN_IFACE" | grep "/64" | grep "scope global" | head -n 1 | awk '{print $2}' | cut -d'/' -f1)

if [ -z "$RAW_IP" ]; then
    echo -e "${RED}错误：未检测到 /64 IPv6 地址。${PLAIN}"
    exit 1
fi

IPV6_PREFIX=$(echo "$RAW_IP" | awk -F: '{print $1":"$2":"$3":"$4}')
IPV6_SUBNET="${IPV6_PREFIX}::/64"

echo -e "检测到网卡: ${GREEN}${MAIN_IFACE}${PLAIN}"
echo -e "检测到网段: ${GREEN}${IPV6_SUBNET}${PLAIN}"

# 3. 配置 NDPPD (解决断流)
echo -e "${YELLOW}>>> 配置 NDP 代理...${PLAIN}"
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

# 4. 配置 Systemd (持久化路由)
echo -e "${YELLOW}>>> 配置路由服务...${PLAIN}"

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

# 5. 验证
echo -e "${YELLOW}>>> 正在验证...${PLAIN}"
TEST_IP="${IPV6_PREFIX}::1234"

if ping6 -c 2 -w 2 $TEST_IP &> /dev/null; then
    echo -e "${GREEN}=========================================${PLAIN}"
    echo -e "${GREEN}       配置成功！系统已恢复正常。       ${PLAIN}"
    echo -e "${GREEN}=========================================${PLAIN}"
else
    echo -e "${RED}测试未通过，但服务已安装。${PLAIN}"
fi

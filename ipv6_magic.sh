#!/bin/bash

# =========================================================
# IPv6 /64 AnyIP 配置脚本 (V4.4 逻辑增强版)
# =========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 0. 版本自检 (用于确认是否拉取到了最新版)
echo -e "${YELLOW}>>> 正在运行 V4.4 逻辑增强版...${PLAIN}"

# 1. 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：请使用 root 权限运行此脚本！${PLAIN}"
   exit 1
fi

echo -e "${YELLOW}>>> [1/4] 正在检测网络环境...${PLAIN}"

# 2. 核心功能：识别网卡和网段
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
echo "----------------------------------------------------"

# 3. 配置 NDPPD
echo -e "${YELLOW}>>> [2/4] 配置 NDP 代理...${PLAIN}"

if ! command -v ndppd &> /dev/null; then
    echo "正在安装 ndppd..."
    apt-get update -y
    apt-get install ndppd -y
fi

cat > /etc/ndppd.conf <<CONF
proxy $MAIN_IFACE {
   rule $IPV6_SUBNET {
      static
   }
}
CONF

systemctl restart ndppd
systemctl enable ndppd

# 4. 配置 Systemd
echo -e "\n${YELLOW}>>> [3/4] 配置路由服务...${PLAIN}"

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
systemctl enable ipv6-anyip.service
systemctl start ipv6-anyip.service

# 5. 验证 (包含你要求的逻辑判断)
echo -e "\n${YELLOW}>>> [4/4] 正在验证...${PLAIN}"
TEST_IP="${IPV6_PREFIX}::1234"
echo "Ping测试目标: $TEST_IP"

# 运行 ping，并屏蔽错误输出，只看结果
ping6 -c 4 $TEST_IP

# === 核心逻辑判断 ===
if [ $? -eq 0 ]; then
    echo ""
    echo -e "${GREEN}=========================================${PLAIN}"
    echo -e "${GREEN}      恭喜！脚本执行成功 (Exit 0)        ${PLAIN}"
    echo -e "${GREEN}      逻辑检测通过：网络已连通           ${PLAIN}"
    echo -e "${GREEN}=========================================${PLAIN}"
else
    echo ""
    echo -e "${RED}=========================================${PLAIN}"
    echo -e "${RED}      警告：脚本执行完成但测试失败       ${PLAIN}"
    echo -e "${RED}      逻辑检测未通过：Ping 不通          ${PLAIN}"
    echo -e "${RED}=========================================${PLAIN}"
    exit 1
fi

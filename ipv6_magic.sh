#!/bin/bash

# =========================================================
# IPv6 /64 AnyIP 配置脚本 (V4.1 透明版)
# 特性：显示详细的安装、配置和验证过程日志
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

# 3. 配置 NDPPD (不再静默安装)
echo -e "${YELLOW}>>> [2/4] 配置 NDP 代理 (ndppd)...${PLAIN}"

if ! command -v ndppd &> /dev/null; then
    echo "正在安装 ndppd 软件包..."
    # 移除 > /dev/null，显示安装过程
    apt-get update -y
    apt-get install ndppd -y
else
    echo "ndppd 已安装，跳过安装步骤。"
fi

echo "正在生成 ndppd 配置文件..."
cat > /etc/ndppd.conf <<CONF
proxy $MAIN_IFACE {
   rule $IPV6_SUBNET {
      static
   }
}
CONF

echo "正在启动 ndppd 服务..."
systemctl restart ndppd
# 移除 > /dev/null，显示服务启用状态
systemctl enable ndppd 

# 4. 配置 Systemd (持久化路由)
echo -e "\n${YELLOW}>>> [3/4] 配置路由持久化服务...${PLAIN}"

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

echo "正在刷新 Systemd 守护进程..."
systemctl daemon-reload
echo "正在启用 ipv6-anyip 服务..."
systemctl enable ipv6-anyip.service
echo "正在启动服务..."
systemctl start ipv6-anyip.service

# 5. 验证 (显示 Ping 详细过程)
echo -e "\n${YELLOW}>>> [4/4] 正在验证 (Ping 测试)...${PLAIN}"
TEST_IP="${IPV6_PREFIX}::1234"
echo -e "目标测试 IP: ${GREEN}${TEST_IP}${PLAIN}"
echo "----------------------------------------------------"

# 直接运行 ping，不隐藏输出
ping6 -c 4 $TEST_IP

# 检查上一条命令(ping)的退出状态码
if [ $? -eq 0 ]; then
    echo "

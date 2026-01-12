#!/bin/bash

# =========================================================
# IPv6 /64 AnyIP 配置脚本 (V4.7)
# 更新内容：Ping次数改为5次 | 新增本地IPv6环境预检功能
# =========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'


echo -e "${YELLOW}>>> 正在运行 V4.7 智能检测版...${PLAIN}"


if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：请使用 root 权限运行此脚本！${PLAIN}"
   exit 1
fi

echo -e "${YELLOW}>>> [1/4] 正在检测网络环境...${PLAIN}"


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


echo -e "\n${YELLOW}>>> [4/4] 正在验证...${PLAIN}"
TEST_IP="${IPV6_PREFIX}::1234"
echo "Ping测试目标: $TEST_IP"
echo "----------------------------------------------------"


if ping6 -c 1 -w 2 2001:4860:4860::8888 > /dev/null 2>&1; then

    echo -e "${GREEN}本地v6网络正常，开始ping...${PLAIN}"
    echo "----------------------------------------------------"
    

    ping6 -c 5 $TEST_IP


    if [ $? -eq 0 ]; then
        echo "----------------------------------------------------"
        echo -e "${GREEN}=========================================${PLAIN}"
        echo -e "${GREEN}      恭喜！脚本执行成功 (Exit 0)        ${PLAIN}"
        echo -e "${GREEN}      逻辑检测通过：网络已连通           ${PLAIN}"
        echo -e "${GREEN}=========================================${PLAIN}"
        

        echo ""
        echo -e "${BLUE}everything by 執筆·抒情${PLAIN}"
        echo ""
        exit 0
    else
        echo "----------------------------------------------------"
        echo -e "${RED}=========================================${PLAIN}"
        echo -e "${RED}      警告：脚本执行完成但测试失败       ${PLAIN}"
        echo -e "${RED}      逻辑检测未通过：Ping 不通          ${PLAIN}"
        echo -e "${RED}=========================================${PLAIN}"
        exit 1
    fi

else

    echo -e "${YELLOW}本地无v6环境，请开启v6访问或连接手机热点后自行验证${PLAIN}"
    echo "----------------------------------------------------"
    exit 0
fi

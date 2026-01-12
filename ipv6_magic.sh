#!/bin/bash

# =========================================================
# IPv6 /64 AnyIP 配置脚本 (V4.9 全链路透明版)
# 更新：步骤 2 (NDP代理) 增加详细过程显示与报错检测
# =========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

# 0. 版本提示
echo -e "${YELLOW}>>> 正在运行 V4.9 全链路透明版...${PLAIN}"

# 1. 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：请使用 root 权限运行此脚本！${PLAIN}"
   exit 1
fi

echo -e "${YELLOW}>>> [1/4] 正在检测网络环境 (详细模式)...${PLAIN}"

# --- 步骤 1: 详细识别与报错 ---
echo -n "正在探测主网卡接口... "
MAIN_IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')

if [ -z "$MAIN_IFACE" ]; then
    echo -e "${RED}失败${PLAIN}"
    echo -e "${RED}错误：无法自动获取主网卡接口，请检查网络设置。${PLAIN}"
    exit 1
else
    echo -e "${GREEN}成功 (${MAIN_IFACE})${PLAIN}"
fi

echo -n "正在该网卡上搜索 /64 IPv6 地址... "
RAW_IP=$(ip -6 addr show dev "$MAIN_IFACE" | grep "/64" | grep "scope global" | head -n 1 | awk '{print $2}' | cut -d'/' -f1)

if [ -z "$RAW_IP" ]; then
    echo -e "${RED}失败${PLAIN}"
    echo -e "${RED}严重错误：在设备 ${MAIN_IFACE} 上未找到 /64 网段的 IPv6 地址。${PLAIN}"
    exit 1
else
    IPV6_PREFIX=$(echo "$RAW_IP" | awk -F: '{print $1":"$2":"$3":"$4}')
    IPV6_SUBNET="${IPV6_PREFIX}::/64"
    echo -e "${GREEN}成功${PLAIN}"
    echo -e "识别到前缀: ${GREEN}${IPV6_PREFIX}${PLAIN}"
    echo -e "目标子网段: ${GREEN}${IPV6_SUBNET}${PLAIN}"
fi
echo "----------------------------------------------------"

# --- [修改部分：步骤 2] 详细 NDP 配置 ---
echo -e "${YELLOW}>>> [2/4] 配置 NDP 代理 (详细模式)...${PLAIN}"

echo -n "检查 ndppd 软件状态... "
if command -v ndppd &> /dev/null; then
    echo -e "${GREEN}已安装 (跳过安装)${PLAIN}"
else
    echo -e "${YELLOW}未安装${PLAIN}"
    
    echo -n "正在更新软件源 (apt-get update)... "
    apt-get update -y >/dev/null 2>&1
    if [ $? -eq 0 ]; then echo -e "${GREEN}成功${PLAIN}"; else echo -e "${RED}失败${PLAIN}"; exit 1; fi
    
    echo -n "正在安装 ndppd (apt-get install)... "
    apt-get install ndppd -y >/dev/null 2>&1
    if [ $? -eq 0 ]; then echo -e "${GREEN}成功${PLAIN}"; else echo -e "${RED}失败 (请检查网络或源)${PLAIN}"; exit 1; fi
fi

CONFIG_FILE="/etc/ndppd.conf"
echo -n "正在生成配置文件 ($CONFIG_FILE)... "
cat > "$CONFIG_FILE" <<CONF
proxy $MAIN_IFACE {
   rule $IPV6_SUBNET {
      static
   }
}
CONF
if [ $? -eq 0 ]; then echo -e "${GREEN}成功${PLAIN}"; else echo -e "${RED}失败 (权限不足?)${PLAIN}"; exit 1; fi

echo -n "正在重启 ndppd 服务... "
systemctl restart ndppd
if [ $? -eq 0 ]; then echo -e "${GREEN}成功${PLAIN}"; else echo -e "${RED}失败 (服务启动错误)${PLAIN}"; exit 1; fi

echo -n "正在设置开机自启... "
systemctl enable ndppd >/dev/null 2>&1
if [ $? -eq 0 ]; then echo -e "${GREEN}成功${PLAIN}"; else echo -e "${RED}失败${PLAIN}"; exit 1; fi

# --- 步骤 3: 详细 Systemd 配置 ---
echo -e "\n${YELLOW}>>> [3/4] 配置路由服务 (详细模式)...${PLAIN}"

SERVICE_FILE="/etc/systemd/system/ipv6-anyip.service"
echo -n "正在写入服务文件 ($SERVICE_FILE)... "

cat > "$SERVICE_FILE" <<SERVICE
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

if [ $? -eq 0 ]; then echo -e "${GREEN}成功${PLAIN}"; else echo -e "${RED}失败${PLAIN}"; exit 1; fi

echo -n "正在重载 Systemd 守护进程... "
systemctl daemon-reload
if [ $? -eq 0 ]; then echo -e "${GREEN}成功${PLAIN}"; else echo -e "${RED}失败${PLAIN}"; exit 1; fi

echo -n "正在启用服务 (Enable)... "
systemctl enable ipv6-anyip.service >/dev/null 2>&1
if [ $? -eq 0 ]; then echo -e "${GREEN}成功${PLAIN}"; else echo -e "${RED}失败${PLAIN}"; exit 1; fi

echo -n "正在启动服务 (Start)... "
systemctl start ipv6-anyip.service
if [ $? -eq 0 ]; then
    echo -e "${GREEN}成功${PLAIN}"
else
    echo -e "${RED}失败${PLAIN}"
    echo -e "${RED}错误：服务启动失败，以下是错误日志：${PLAIN}"
    systemctl status ipv6-anyip.service --no-pager
    exit 1
fi

# --- 步骤 4: 验证 (Ping 5次 + 预检) ---
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

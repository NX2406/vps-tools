#!/bin/bash

# =========================================================
# IPv6 /64 AnyIP 配置脚本 (V5.2 柔性容错版)
# 更新：修复API误判导致的脚本停止 / 优化IP与地区解析逻辑
# =========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

# 0. 版本提示
echo -e "${YELLOW}>>> 正在运行 V5.2 柔性容错版...${PLAIN}"

# 1. 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：请使用 root 权限运行此脚本！${PLAIN}"
   exit 1
fi

echo -e "${YELLOW}>>> [1/4] 正在检测网络环境...${PLAIN}"

# --- 柔性探测：公网 IP 与 地理位置 ---
echo "-> 正在分析公网网络信息 (仅供参考)..."

# 定义探测函数 (增加超时容错)
get_ip_info() {
    # 请求 query(IP), country(国家), regionName(地区)
    # 使用 curl -m 2 设置2秒超时，防止卡住
    curl -s -m 2 "$1" "http://ip-api.com/line/?fields=query,country,regionName"
}

# 1. 检测 IPv4
RAW_V4=$(get_ip_info -4)
if [[ -n "$RAW_V4" ]]; then
    # 按行读取，确保解析准确
    IP4=$(echo "$RAW_V4" | sed -n '1p')
    LOC4_COUNTRY=$(echo "$RAW_V4" | sed -n '2p')
    LOC4_REGION=$(echo "$RAW_V4" | sed -n '3p')
    echo -e "${GREEN}   [IPv4] IP: ${IP4} (${LOC4_REGION}, ${LOC4_COUNTRY})${PLAIN}"
else
    echo -e "${YELLOW}   [IPv4] 外部探测超时 (不影响后续运行)${PLAIN}"
fi

# 2. 检测 IPv6 (核心修复：失败不退出)
RAW_V6=$(get_ip_info -6)
if [[ -n "$RAW_V6" ]]; then
    IP6=$(echo "$RAW_V6" | sed -n '1p')
    LOC6_COUNTRY=$(echo "$RAW_V6" | sed -n '2p')
    LOC6_REGION=$(echo "$RAW_V6" | sed -n '3p')
    echo -e "${GREEN}   [IPv6] IP: ${IP6} (${LOC6_REGION}, ${LOC6_COUNTRY})${PLAIN}"
else
    # 重点：这里只警告，不退出了！
    echo -e "${YELLOW}   [IPv6] 外部探测超时，切换至本地网卡检测模式...${PLAIN}"
fi
echo "----------------------------------------------------"

# --- 步骤 1 (继续): 本地网卡硬核识别 ---
echo "-> 正在探测主网卡接口..."
MAIN_IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')

if [ -z "$MAIN_IFACE" ]; then
    echo -e "${RED}   [失败] 无法获取主网卡接口${PLAIN}"
    exit 1
else
    echo -e "${GREEN}   [成功] 主网卡: ${MAIN_IFACE}${PLAIN}"
fi

echo "-> 正在验证 IPv6 /64 配置 (权威检测)..."
# 依然保留本地接口检测，作为双重保险
RAW_IP=$(ip -6 addr show dev "$MAIN_IFACE" | grep "/64" | grep "scope global" | head -n 1 | awk '{print $2}' | cut -d'/' -f1)

if [ -z "$RAW_IP" ]; then
    echo -e "${RED}   [失败] 未找到符合条件的 /64 IPv6 地址${PLAIN}"
    echo -e "${YELLOW}   提示：请确认 VPS商家 已分配 IPv6 且网卡已启用。${PLAIN}"
    exit 1
else
    IPV6_PREFIX=$(echo "$RAW_IP" | awk -F: '{print $1":"$2":"$3":"$4}')
    IPV6_SUBNET="${IPV6_PREFIX}::/64"
    echo -e "${GREEN}   [成功] 目标网段: ${IPV6_SUBNET}${PLAIN}"
fi
echo "----------------------------------------------------"

# --- 步骤 2: NDP 代理 ---
echo -e "${YELLOW}>>> [2/4] 配置 NDP 代理 (详细追踪)...${PLAIN}"

echo "-> 正在检查 ndppd 软件..."
if command -v ndppd &> /dev/null; then
    echo -e "${GREEN}   [已安装] 跳过安装步骤${PLAIN}"
else
    echo -e "${YELLOW}   [未安装] 准备安装 ndppd...${PLAIN}"
    echo "   -> 更新软件源 (apt-get update)..."
    apt-get update -y >/dev/null 2>&1
    echo "   -> 安装软件包 (apt-get install)..."
    apt-get install ndppd -y >/dev/null 2>&1
    
    if command -v ndppd &> /dev/null; then
        echo -e "${GREEN}   [成功] ndppd 安装完毕${PLAIN}"
    else
        echo -e "${RED}   [失败] 安装失败，请检查 apt 源${PLAIN}"
        exit 1
    fi
fi

echo "-> 正在生成配置文件 (/etc/ndppd.conf)..."
cat > /etc/ndppd.conf <<CONF
proxy $MAIN_IFACE {
   rule $IPV6_SUBNET {
      static
   }
}
CONF
echo -e "${GREEN}   [成功] 配置文件已写入${PLAIN}"

echo "-> 正在重启 ndppd 服务..."
systemctl restart ndppd
if [ $? -eq 0 ]; then
    echo -e "${GREEN}   [成功] 服务已重启${PLAIN}"
else
    echo -e "${RED}   [失败] 服务启动异常${PLAIN}"
    exit 1
fi

echo "-> 设置开机自启..."
systemctl enable ndppd >/dev/null 2>&1
echo -e "${GREEN}   [成功] 已设为开机自启${PLAIN}"

# --- 步骤 3: 路由服务 ---
echo -e "\n${YELLOW}>>> [3/4] 配置路由服务 (详细追踪)...${PLAIN}"

SERVICE_FILE="/etc/systemd/system/ipv6-anyip.service"
echo "-> 生成 Systemd 服务文件..."
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
echo -e "${GREEN}   [成功] 服务文件已创建${PLAIN}"

echo "-> 重载 Systemd 配置..."
systemctl daemon-reload
echo -e "${GREEN}   [成功] 完成${PLAIN}"

echo "-> 启用 ipv6-anyip 服务..."
systemctl enable ipv6-anyip.service >/dev/null 2>&1
echo -e "${GREEN}   [成功] 已启用${PLAIN}"

echo "-> 启动服务 (Start)..."
systemctl start ipv6-anyip.service
if [ $? -eq 0 ]; then
    echo -e "${GREEN}   [成功] 服务启动正常${PLAIN}"
else
    echo -e "${RED}   [失败] 服务启动错误，日志如下：${PLAIN}"
    systemctl status ipv6-anyip.service --no-pager
    exit 1
fi

# --- 步骤 4: 验证 ---
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

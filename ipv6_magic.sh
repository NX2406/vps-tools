#!/bin/bash

# =========================================================
# IPv6 /64 AnyIP 配置脚本 (V7.1 智能输入容错版)
# 更新：修复手动绑定时输入完整 IP 导致的格式拼接错误
# =========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：请使用 root 权限运行此脚本！${PLAIN}"
   exit 1
fi

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
    # 尝试自动获取
    RAW_IP=$(ip -6 addr show dev "$MAIN_IFACE" | grep "/64" | grep "scope global" | head -n 1 | awk '{print $2}' | cut -d'/' -f1)
    
    MANUAL_BIND="no"

    if [ -z "$RAW_IP" ]; then
        echo -e "${YELLOW}   [警告] 网卡上未检测到 /64 IPv6 地址！${PLAIN}"
        echo -e "${YELLOW}   这种情况通常是因为商家分配了 IP 但未自动配置到系统。${PLAIN}"
        echo ""
        echo -e "   请输入商家分配给您的 IPv6 地址或前缀"
        echo -e "   (例如: 2605:xx:4:: 或 2605:xx:4::1 均可)"
        read -p "   输入: " USER_PREFIX_INPUT
        
        # === 核心修复 V7.1: 智能输入处理 ===
        # 1. 去除 /64 后缀和空格
        USER_INPUT_CLEAN=$(echo "$USER_PREFIX_INPUT" | cut -d'/' -f1 | tr -d ' ')
        
        if [ -z "$USER_INPUT_CLEAN" ]; then
            echo -e "${RED}   [错误] 输入为空，脚本退出。${PLAIN}"
            exit 1
        fi

        echo "-> 正在尝试临时绑定并测试连通性..."
        
        # 逻辑分支：智能判断绑定方式
        # 尝试直接绑定用户输入的地址（假设是完整 IP 或以 :: 结尾的）
        TEST_BIND_IP="$USER_INPUT_CLEAN"
        ip -6 addr add "${TEST_BIND_IP}/64" dev "$MAIN_IFACE" 2>/dev/null
        
        # 如果上一步失败（状态码非0），说明格式不对（可能是纯前缀 2602:xx:4 没加冒号）
        if [ $? -ne 0 ]; then
             echo -e "${YELLOW}   [提示] 尝试自动补全 IP 格式...${PLAIN}"
             # 尝试补全 ::1
             TEST_BIND_IP="${USER_INPUT_CLEAN}::1"
             ip -6 addr add "${TEST_BIND_IP}/64" dev "$MAIN_IFACE" 2>/dev/null
             
             if [ $? -ne 0 ]; then
                 echo -e "${RED}   [失败] IP 格式错误，无法绑定。请检查输入。${PLAIN}"
                 exit 1
             fi
        fi
        
        # 验证是否通畅
        if ping6 -c 2 -w 2 2001:4860:4860::8888 >/dev/null 2>&1; then
             echo -e "${GREEN}   [成功] 绑定成功且网络已连通！${PLAIN}"
             # 将绑定成功的这个 IP 赋值给 RAW_IP，以便后续提取前缀
             RAW_IP="$TEST_BIND_IP"
             MANUAL_BIND="yes"
        else
             echo -e "${RED}   [失败] 绑定后无法连接 IPv6 网络。${PLAIN}"
             echo -e "${RED}   原因可能是：商家未下发网关路由、或防火墙拦截。${PLAIN}"
             # 回滚操作
             ip -6 addr del "${TEST_BIND_IP}/64" dev "$MAIN_IFACE" 2>/dev/null
             exit 1
        fi
    fi

    # 标准化前缀提取逻辑 (兼容所有格式)
    # 使用 sed 's/:*$//' 确保去除末尾冒号
    IPV6_PREFIX=$(echo "$RAW_IP" | awk -F: '{print $1":"$2":"$3":"$4}' | sed 's/:*$//')
    IPV6_SUBNET="${IPV6_PREFIX}::/64"
    echo -e "${GREEN}   [成功] 目标网段: ${IPV6_SUBNET}${PLAIN}"
    echo "----------------------------------------------------"

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

    echo -e "\n${YELLOW}>>> [3/4] 配置路由服务 (详细追踪)...${PLAIN}"

    SERVICE_FILE="/etc/systemd/system/ipv6-anyip.service"
    echo "-> 生成 Systemd 服务文件..."
    
    # === 构建服务文件 ===
    BIND_CMD=""
    if [ "$MANUAL_BIND" == "yes" ]; then
        # 这里的 ${RAW_IP} 是刚才验证成功的那个完整 IP
        BIND_CMD="ExecStart=/sbin/ip addr add ${RAW_IP}/64 dev ${MAIN_IFACE}"
        echo -e "${BLUE}   [提示] 已将救砖 IP (${RAW_IP}) 加入开机自启${PLAIN}"
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
    echo -e "${GREEN}   [成功] 服务文件已创建${

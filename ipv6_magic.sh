#!/bin/bash

# =========================================================
# powered by 執筆·抒情(TG:zbsh0510)
# IPv6 /64 AnyIP 配置脚本 (V6.1)
# 更新：验证阶段使用随机生成的 IPv6 后缀，避免冲突
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
echo -e "${GREEN}  1. 开始安装 (配置 AnyIP & NDP)${PLAIN}"
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
    RAW_IP=$(ip -6 addr show dev "$MAIN_IFACE" | grep "/64" | grep "scope global" | head -n 1 | awk '{print $2}' | cut -d'/' -f1)

    if [ -z "$RAW_IP" ]; then
        echo -e "${RED}   [失败] 未找到符合条件的 /64 IPv6 地址${PLAIN}"
        echo -e "${YELLOW}   提示：请确认 VPS 确实分配了 IPv6 且网卡已启用。${PLAIN}"
        exit 1
    else
        IPV6_PREFIX=$(echo "$RAW_IP" | awk -F: '{print $1":"$2":"$3":"$4}')
        IPV6_SUBNET="${IPV6_PREFIX}::/64"
        echo -e "${GREEN}   [成功] 目标网段: ${IPV6_SUBNET}${PLAIN}"
    fi
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


    echo -e "\n${YELLOW}>>> [4/4] 正在验证...${PLAIN}"
    

    RAND_SUFFIX=$(printf '%x' $((RANDOM + 1)))
    TEST_IP="${IPV6_PREFIX}::${RAND_SUFFIX}"
    
    echo "Ping测试目标 (随机生成): $TEST_IP"
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
            echo -e "${BLUE}everything by 執筆·抒情(TG:zbsh0510)${PLAIN}"
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
}


uninstall_anyip() {
    echo -e "${YELLOW}>>> 正在执行卸载操作...${PLAIN}"

    echo "-> 停止路由服务 (ipv6-anyip)..."
    systemctl stop ipv6-anyip.service 2>/dev/null
    systemctl disable ipv6-anyip.service 2>/dev/null
    rm -f /etc/systemd/system/ipv6-anyip.service
    echo -e "${GREEN}   [成功] 服务文件已移除${PLAIN}"

    echo "-> 停止 NDP 代理 (ndppd)..."
    systemctl stop ndppd 2>/dev/null
    systemctl disable ndppd 2>/dev/null
    rm -f /etc/ndppd.conf
    echo -e "${GREEN}   [成功] 配置文件已移除${PLAIN}"

    echo "-> 刷新 Systemd 状态..."
    systemctl daemon-reload
    
    echo "----------------------------------------------------"
    echo -e "${GREEN}卸载完成！所有相关配置和服务已清理干净。${PLAIN}"
    echo -e "${YELLOW}提示：已安装的 'ndppd' 软件包依然保留，如需彻底删除请手动运行: apt-get remove ndppd -y${PLAIN}"
    echo ""
}


case "$choice" in
    1)
        install_anyip
        ;;
    2)
        uninstall_anyip
        ;;
    *)
        echo -e "${RED}错误：无效的选项，脚本退出。${PLAIN}"
        exit 1
        ;;
esac

#!/bin/bash

# =========================================================
# IPv6 /64 AnyIP 配置脚本 (V7.5 最终大结局版)
# 更新：在服务启动后增加 5秒 等待，彻底解决验证阶段的假死报错
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
        
        # 1. 清洗输入
        USER_INPUT_CLEAN=$(echo "$USER_PREFIX_INPUT" | cut -d'/' -f1 | tr -d ' ')
        
        if [ -z "$USER_INPUT_CLEAN" ]; then
            echo -e "${RED}   [错误] 输入为空，脚本退出。${PLAIN}"
            exit 1
        fi

        echo "-> 正在尝试临时绑定并测试连通性..."
        
        # 2. 智能构建测试 IP
        if [[ "$USER_INPUT_CLEAN" == *":" ]]; then
            TEST_BIND_IP="${USER_INPUT_CLEAN}1"
        else
            TEST_BIND_IP="$USER_INPUT_CLEAN"
        fi

        # 3. 防冲突处理
        ip -6 addr del "${TEST_BIND_IP}/64" dev "$MAIN_IFACE" >/dev/null 2>&1
        
        # 4. 执行绑定
        ip -6 addr add "${TEST_BIND_IP}/64" dev "$MAIN_IFACE" 2>/dev/null
        
        if [ $? -ne 0 ]; then
             # 补救尝试
             if [[ "$USER_INPUT_CLEAN" != *":" ]]; then
                 echo -e "${YELLOW}   [提示] 尝试自动补全后缀...${PLAIN}"
                 TEST_BIND_IP="${USER_INPUT_CLEAN}::1"
                 ip -6 addr del "${TEST_BIND_IP}/64" dev "$MAIN_IFACE" >/dev/null 2>&1
                 ip -6 addr add "${TEST_BIND_IP}/64" dev "$MAIN_IFACE" 2>/dev/null
             fi
             
             if [ $? -ne 0 ]; then
                 echo -e "${RED}   [失败] IP 格式错误或被占用，无法绑定。${PLAIN}"
                 exit 1
             fi
        fi
        
        echo -e "${YELLOW}   [等待] 正在等待 IPv6 地址生效 (3秒)...${PLAIN}"
        sleep 3
        
        # 5. 验证连通性
        if ping6 -c 2 -w 4 2001:4860:4860::8888 >/dev/null 2>&1; then
             echo -e "${GREEN}   [成功] 绑定成功且网络已连通！${PLAIN}"
             RAW_IP="$TEST_BIND_IP"
             MANUAL_BIND="yes"
        else
             echo -e "${RED}   [失败] 绑定后无法连接 IPv6 网络。${PLAIN}"
             # 回滚
             ip -6 addr del "${TEST_BIND_IP}/64" dev "$MAIN_IFACE" 2>/dev/null
             exit 1
        fi
    fi

    # 标准化前缀提取逻辑
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
    
    BIND_CMD=""
    if [ "$MANUAL_BIND" == "yes" ]; then
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
    echo -e "${GREEN}   [成功] 服务文件已创建${PLAIN}"

    echo "-> 重载 Systemd 配置..."
    systemctl daemon-reload
    echo -e "${GREEN}   [成功] 完成${PLAIN}"

    echo "-> 启用 ipv6-anyip 服务..."
    systemctl enable ipv6-anyip.service >/dev/null 2>&1
    echo -e "${GREEN}   [成功] 已启用${PLAIN}"

    echo "-> 启动服务 (Start)..."
    
    # === 核心修复 V7.4: 临时 IP 撤销逻辑 ===
    if [ "$MANUAL_BIND" == "yes" ]; then
        echo -e "${YELLOW}   [处理] 正在移交 IP 管理权给 Systemd...${PLAIN}"
        ip -6 addr del "${RAW_IP}/64" dev "$MAIN_IFACE" >/dev/null 2>&1
    fi

    systemctl start ipv6-anyip.service
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}   [成功] 服务启动正常${PLAIN}"
    else
        echo -e "${RED}   [失败] 服务启动错误，日志如下：${PLAIN}"
        systemctl status ipv6-anyip.service --no-pager
        exit 1
    fi

    # === 核心修复 V7.5: 服务启动后的缓冲等待 ===
    echo -e "${YELLOW}   [等待] 正在等待服务网络生效 (5秒)...${PLAIN}"
    sleep 5

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
        echo -e "${YELLOW}本地无v6环境，请开启v6访问或稍后自行验证${PLAIN}"
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
    echo -e "${YELLOW}提示：已安装的 'ndppd' 软件包依然保留，如需彻底删除请手动运行: apt-get remove ndppd${PLAIN}"
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

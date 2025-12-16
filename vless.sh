#!/bin/bash

#===============================================================================================
# VLESS + Argo Tunnel Management Script for LXC (Multi-OS Support)
#
# Description: A comprehensive script for one-click deployment and management of 
#              VLESS with Cloudflare Argo Tunnel. Supports Debian and Alpine Linux.
# Author:      AI Assistant
# Version:     1.3.2 (Always Show Full Menu)
#===============================================================================================

# --- 颜色代码 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 文件和及服务路径 ---
XRAY_INSTALL_DIR="/usr/local/etc/xray"
XRAY_CONFIG_FILE="${XRAY_INSTALL_DIR}/config.json"
XRAY_BINARY="/usr/local/bin/xray"

CLOUDFLARED_BINARY="/usr/local/bin/cloudflared"

NODE_INFO_FILE="/root/vless_node_info.txt"

# --- 全局状态变量 ---
INSTALLED_STATUS="not_installed"
CURRENT_UUID=""
CURRENT_DOMAIN=""
TUNNEL_MODE="" # temp or permanent
OS_TYPE="" # debian or alpine
SERVICE_MANAGER="" # systemd or openrc

# 服务文件路径(根据系统类型动态设置)
XRAY_SERVICE_FILE=""
CLOUDFLARED_SERVICE_FILE=""

#===============================================================================================
#                              系统检测函数
#===============================================================================================

# 检测操作系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" == "alpine" ]]; then
            OS_TYPE="alpine"
            SERVICE_MANAGER="openrc"
            XRAY_SERVICE_FILE="/etc/init.d/xray"
            CLOUDFLARED_SERVICE_FILE="/etc/init.d/cloudflared"
        elif [[ "$ID" == "debian" ]] || [[ "$ID" == "ubuntu" ]]; then
            OS_TYPE="debian"
            SERVICE_MANAGER="systemd"
            XRAY_SERVICE_FILE="/etc/systemd/system/xray.service"
            CLOUDFLARED_SERVICE_FILE="/etc/systemd/system/cloudflared.service"
        else
            echo -e "${RED}不支持的操作系统: $ID${NC}"
            exit 1
        fi
    else
        echo -e "${RED}无法检测操作系统类型${NC}"
        exit 1
    fi
}

#===============================================================================================
#                              核心辅助函数
#===============================================================================================

# 检查是否为 root 用户
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误:此脚本必须以 root 身份运行。请使用 'sudo' 或 'su'。${NC}"
        exit 1
    fi
}

# 通过检查文件来更新安装状态
update_status() {
    if [ -f "$XRAY_BINARY" ] && [ -f "$CLOUDFLARED_BINARY" ] && [ -f "$NODE_INFO_FILE" ]; then
        INSTALLED_STATUS="installed"
        CURRENT_UUID=$(grep "UUID:" "$NODE_INFO_FILE" | awk '{print $2}')
        CURRENT_DOMAIN=$(grep "域名:" "$NODE_INFO_FILE" | awk '{print $2}')
        if grep -q "trycloudflare.com" <<< "$CURRENT_DOMAIN"; then
            TUNNEL_MODE="temp"
        else
            TUNNEL_MODE="permanent"
        fi
    else
        INSTALLED_STATUS="not_installed"
    fi
}

# 暂停并等待用户按下回车键
press_any_key() {
    echo -e "\n${YELLOW}按回车键继续...${NC}"
    read -r
}

# 生成UUID (通用函数)
generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

#===============================================================================================
#                              安装功能函数
#===============================================================================================

# 安装必要的依赖
install_dependencies() {
    echo -e "${BLUE}正在更新软件包列表并安装依赖项...${NC}"
    
    if [ "$OS_TYPE" = "alpine" ]; then
        apk update > /dev/null 2>&1
        apk add curl wget unzip bash > /dev/null 2>&1
    else
        apt-get update > /dev/null 2>&1
        apt-get install -y curl wget unzip > /dev/null 2>&1
    fi
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}依赖项安装失败。${NC}"
        exit 1
    fi
    echo -e "${GREEN}依赖项安装成功。${NC}"
}

# 安装 Xray-core (通用方法,适配Alpine)
install_xray() {
    echo -e "${BLUE}正在安装 Xray-core...${NC}"
    
    if [ "$OS_TYPE" = "debian" ]; then
        # Debian/Ubuntu 使用官方安装脚本
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" -s install 2>&1 | grep -v "^error:"
        if [ ! -f "$XRAY_BINARY" ]; then
            echo -e "${RED}Xray 安装失败。${NC}"
            exit 1
        fi
    else
        # Alpine 手动下载安装
        ARCH=$(uname -m)
        echo -e "${BLUE}检测到架构: ${ARCH}${NC}"
        
        if [ "$ARCH" = "x86_64" ]; then
            XRAY_DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
        elif [ "$ARCH" = "aarch64" ]; then
            XRAY_DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip"
        else
            echo -e "${RED}不支持的架构: $ARCH${NC}"
            exit 1
        fi
        
        echo -e "${BLUE}正在下载 Xray...${NC}"
        wget -q "$XRAY_DOWNLOAD_URL" -O /tmp/xray.zip
        if [ $? -ne 0 ]; then
            echo -e "${RED}下载 Xray 失败${NC}"
            exit 1
        fi
        
        echo -e "${BLUE}正在解压和安装...${NC}"
        unzip -q /tmp/xray.zip -d /tmp/xray
        mv /tmp/xray/xray $XRAY_BINARY
        chmod +x $XRAY_BINARY
        rm -rf /tmp/xray /tmp/xray.zip
        
        if [ ! -f "$XRAY_BINARY" ]; then
            echo -e "${RED}Xray 安装失败${NC}"
            exit 1
        fi
    fi
    
    # 生成UUID (通用方法)
    CURRENT_UUID=$(generate_uuid)
    
    # 创建 Xray 配置文件
    mkdir -p $XRAY_INSTALL_DIR
    cat > $XRAY_CONFIG_FILE <<-EOF
{
  "inbounds": [
    {
      "port": 10000,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${CURRENT_UUID}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/vless"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

    # 创建服务文件
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        cat > $XRAY_SERVICE_FILE <<-EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${XRAY_BINARY} run -config ${XRAY_CONFIG_FILE}
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF
    else
        # OpenRC 服务文件
        cat > $XRAY_SERVICE_FILE <<-EOF
#!/sbin/openrc-run

name="xray"
description="Xray Service"
command="${XRAY_BINARY}"
command_args="run -config ${XRAY_CONFIG_FILE}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/xray.log"
error_log="/var/log/xray.err"

depend() {
    need net
    after firewall
}
EOF
        chmod +x $XRAY_SERVICE_FILE
    fi
    
    echo -e "${GREEN}Xray-core 安装和配置成功。${NC}"
}

# 安装 Cloudflared
install_cloudflared() {
    echo -e "${BLUE}正在安装 Cloudflared...${NC}"
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        DOWNLOAD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
    elif [ "$ARCH" = "aarch64" ]; then
        DOWNLOAD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
    else
        echo -e "${RED}不支持的架构: $ARCH. 仅支持 x86_64 和 aarch64。${NC}"
        exit 1
    fi
    
    wget -q $DOWNLOAD_URL -O $CLOUDFLARED_BINARY
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载 Cloudflared 失败。${NC}"
        exit 1
    fi
    
    chmod +x $CLOUDFLARED_BINARY
    echo -e "${GREEN}Cloudflared 安装成功。${NC}"
}

# 配置隧道
configure_tunnel() {
    clear
    echo -e "${BLUE}--- 隧道模式选择 ---${NC}"
    echo "1. 临时隧道模式 (易于测试,重启后域名会变化)"
    echo "2. 固定隧道模式 (需要 Cloudflare Token 和自定义域名)"
    echo -e "--------------------------------"
    read -p "请选择一个模式 [1-2]: " mode_choice

    local exec_start_cmd

    if [ "$mode_choice" = "1" ]; then
        TUNNEL_MODE="temp"
        exec_start_cmd="${CLOUDFLARED_BINARY} tunnel --no-autoupdate --url http://127.0.0.1:10000"
        CURRENT_DOMAIN="pending..."
        echo -e "${GREEN}已选择临时隧道模式。${NC}"
    elif [ "$mode_choice" = "2" ]; then
        TUNNEL_MODE="permanent"
        read -p "请输入您的 Cloudflare Argo Tunnel Token: " argo_token
        if [ -z "$argo_token" ]; then
            echo -e "${RED}Token 不能为空。正在中止。${NC}"
            exit 1
        fi
        read -p "请输入您的自定义域名 (例如 sub.yourdomain.com): " custom_domain
        if [ -z "$custom_domain" ]; then
            echo -e "${RED}域名不能为空。正在中止。${NC}"
            exit 1
        fi
        CURRENT_DOMAIN=$custom_domain
        exec_start_cmd="${CLOUDFLARED_BINARY} tunnel --no-autoupdate run --token ${argo_token}"
        echo -e "${GREEN}已为域名 ${CURRENT_DOMAIN} 选择固定隧道模式${NC}"
        echo -e "${YELLOW}重要提示:请确保您已在 Cloudflare DNS 中为 '${CURRENT_DOMAIN}' 设置了 CNAME 记录。${NC}"
    else
        echo -e "${RED}无效的选择。正在中止。${NC}"
        exit 1
    fi

    # 创建服务文件
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        cat > $CLOUDFLARED_SERVICE_FILE <<-EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
User=root
Type=simple
Restart=on-failure
RestartSec=5s
ExecStart=${exec_start_cmd}

[Install]
WantedBy=multi-user.target
EOF
    else
        # OpenRC 服务文件
        local cmd_args="${exec_start_cmd#${CLOUDFLARED_BINARY} }"
        cat > $CLOUDFLARED_SERVICE_FILE <<-EOF
#!/sbin/openrc-run

name="cloudflared"
description="Cloudflare Tunnel"
command="${CLOUDFLARED_BINARY}"
command_args="${cmd_args}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/cloudflared.log"
error_log="/var/log/cloudflared.err"

depend() {
    need net
    after firewall
}
EOF
        chmod +x $CLOUDFLARED_SERVICE_FILE
    fi
}

# 生成并保存节点信息
generate_and_save_node_info() {
    if [ -z "$CURRENT_UUID" ] || [ -z "$CURRENT_DOMAIN" ] || [ "$CURRENT_DOMAIN" = "pending..." ]; then
        echo -e "${RED}无法生成节点信息:缺少 UUID 或域名。${NC}"
        return 1
    fi

    local standard_link="vless://${CURRENT_UUID}@${CURRENT_DOMAIN}:443?encryption=none&security=tls&type=ws&host=${CURRENT_DOMAIN}&path=%2Fvless#VLESS"
    local preferred_link="vless://${CURRENT_UUID}@cf.877774.xyz:443?encryption=none&security=tls&sni=${CURRENT_DOMAIN}&fp=chrome&alpn=h3,h2,http/1.1&type=ws&host=${CURRENT_DOMAIN}&path=%2Fvless#VLESS-优选"
    
    cat > $NODE_INFO_FILE <<-EOF
# ===============================================================
#          VLESS + Argo 隧道节点信息
# ===============================================================

模式:             ${TUNNEL_MODE} 隧道
域名:             ${CURRENT_DOMAIN}
UUID:             ${CURRENT_UUID}
端口:             443
路径:             /vless
安全性:           tls
网络:             ws

# --- 标准版连接链接 ---
${standard_link}

# --- 优选IP版连接链接 (推荐) ---
${preferred_link}

# ===============================================================
#          客户端配置参数
# ===============================================================
地址:             ${CURRENT_DOMAIN} (优选IP版请使用 cf.877774.xyz)
端口:             443
UUID:             ${CURRENT_UUID}
额外ID(AlterId):  0
加密方式:         none
网络:             ws
WebSocket 主机:   ${CURRENT_DOMAIN}
WebSocket 路径:   /vless
TLS:              开启
SNI(服务器名称):  ${CURRENT_DOMAIN}
指纹(Fingerprint): chrome
ALPN:             h3,h2,http/1.1
EOF

    echo -e "${GREEN}节点信息已保存到 ${NODE_INFO_FILE}${NC}"
}

# 服务管理通用函数
service_control() {
    local action=$1
    local service=$2
    
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl ${action} ${service}
    else
        rc-service ${service} ${action}
    fi
}

# 完整安装流程
do_install() {
    install_dependencies
    install_xray
    install_cloudflared
    configure_tunnel
    
    echo -e "${BLUE}正在启用并启动服务...${NC}"
    
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl daemon-reload
        systemctl enable xray > /dev/null 2>&1
        systemctl enable cloudflared > /dev/null 2>&1
        systemctl start xray
        systemctl start cloudflared
    else
        rc-update add xray default > /dev/null 2>&1
        rc-update add cloudflared default > /dev/null 2>&1
        rc-service xray start
        rc-service cloudflared start
    fi
    
    if [ "$TUNNEL_MODE" = "temp" ]; then
        echo -e "${YELLOW}正在等待临时隧道建立... (约10秒)${NC}"
        sleep 10
        fetch_temp_domain
        if [ "$CURRENT_DOMAIN" = "not_found" ]; then
            echo -e "${RED}获取临时域名失败。请检查 Cloudflared 日志。${NC}"
            press_any_key
            return
        fi
    fi
    
    generate_and_save_node_info
    echo -e "\n${GREEN}安装完成!${NC}"
    view_node_info
}

#===============================================================================================
#                              管理功能函数
#===============================================================================================

# 启动、停止、重启服务
manage_services() {
    local action=$1
    local action_zh
    case $action in
        start) action_zh="启动" ;;
        stop) action_zh="停止" ;;
        restart) action_zh="重启" ;;
    esac

    echo -e "${BLUE}正在 ${action_zh} 服务 (Xray 和 Cloudflared)...${NC}"
    service_control ${action} xray
    service_control ${action} cloudflared
    echo -e "${GREEN}服务已${action_zh}。${NC}"
    
    if [ "$action" = "restart" ] || [ "$action" = "start" ]; then
        if [ "$TUNNEL_MODE" = "temp" ]; then
            echo -e "${YELLOW}检测到临时隧道模式。域名可能已更改。${NC}"
            echo -e "${YELLOW}正在于 10 秒后检查新域名...${NC}"
            sleep 10
            fetch_temp_domain
            generate_and_save_node_info
            echo -e "${BLUE}新域名是: ${CURRENT_DOMAIN}${NC}"
        fi
    fi
    press_any_key
}

# 检查服务状态
check_status() {
    echo -e "${BLUE}--- Xray 服务状态 ---${NC}"
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl status xray --no-pager
    else
        rc-service xray status
    fi
    
    echo -e "\n${BLUE}--- Cloudflared 服务状态 ---${NC}"
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl status cloudflared --no-pager
    else
        rc-service cloudflared status
    fi
    press_any_key
}

# 查看节点信息
view_node_info() {
    if [ -f "$NODE_INFO_FILE" ]; then
        clear
        echo -e "${GREEN}"
        cat "$NODE_INFO_FILE"
        echo -e "${NC}"
    else
        echo -e "${RED}未找到节点信息文件。${NC}"
    fi
    press_any_key
}

# 从日志中获取临时 Argo 域名
fetch_temp_domain() {
    echo -e "${BLUE}正在从日志中获取临时域名...${NC}"
    for i in {1..5}; do
        if [ "$SERVICE_MANAGER" = "systemd" ]; then
            domain=$(journalctl -u cloudflared.service --since "5 minutes ago" 2>/dev/null | grep -o 'https://[a-z0-9-]*\.trycloudflare.com' | tail -n 1 | sed 's/https:\/\///')
        else
            domain=$(cat /var/log/cloudflared.log 2>/dev/null | grep -o 'https://[a-z0-9-]*\.trycloudflare.com' | tail -n 1 | sed 's/https:\/\///')
        fi
        if [ -n "$domain" ]; then
            CURRENT_DOMAIN=$domain
            echo -e "${GREEN}找到域名: ${CURRENT_DOMAIN}${NC}"
            return 0
        fi
        sleep 2
    done
    CURRENT_DOMAIN="not_found"
    return 1
}

# 查看临时域名
view_temp_domain() {
    if [ "$TUNNEL_MODE" != "temp" ]; then
        echo -e "${YELLOW}此功能仅适用于临时隧道模式。${NC}"
        press_any_key
        return
    fi
    fetch_temp_domain
    if [ "$CURRENT_DOMAIN" != "not_found" ]; then
        echo -e "${GREEN}当前临时域名: ${CURRENT_DOMAIN}${NC}"
        local old_domain=$(grep "域名:" "$NODE_INFO_FILE" | awk '{print $2}')
        if [ "$old_domain" != "$CURRENT_DOMAIN" ]; then
            echo -e "${YELLOW}域名已从 ${old_domain} 更改。${NC}"
            read -p "是否要更新节点信息文件?[y/N]: " confirm
            if [[ "$confirm" =~ ^[yY]$ ]]; then
                generate_and_save_node_info
            fi
        fi
    else
        echo -e "${RED}在最近的日志中找不到临时域名。${NC}"
    fi
    press_any_key
}

# 查看日志
view_logs() {
    local service_name=$1
    echo -e "${BLUE}正在显示 ${service_name} 的日志。按 Ctrl+C 退出。${NC}"
    sleep 1
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        journalctl -u "${service_name}" -f --no-pager
    else
        tail -f /var/log/${service_name}.log 2>/dev/null
    fi
    press_any_key
}

#===============================================================================================
#                              修改功能函数
#===============================================================================================

# 修改 UUID
modify_uuid() {
    echo -e "${BLUE}正在生成新的 UUID...${NC}"
    CURRENT_UUID=$(generate_uuid)
    
    sed -i "s/\"id\": \".*\"/\"id\": \"${CURRENT_UUID}\"/" $XRAY_CONFIG_FILE
    
    echo -e "${GREEN}新 UUID: ${CURRENT_UUID}${NC}"
    echo -e "${BLUE}正在重启 Xray 服务以应用更改...${NC}"
    service_control restart xray
    
    echo -e "${BLUE}正在更新节点信息文件...${NC}"
    generate_and_save_node_info
    
    echo -e "${GREEN}UUID 更改并成功更新节点信息!${NC}"
    press_any_key
}

# 切换到或重新配置固定隧道
modify_permanent_tunnel() {
    echo -e "${BLUE}--- 重新配置固定隧道 ---${NC}"
    read -p "请输入您的新 Cloudflare Argo Tunnel Token: " argo_token
    if [ -z "$argo_token" ]; then
        echo -e "${RED}Token 不能为空。正在中止。${NC}"
        press_any_key
        return
    fi
    read -p "请输入您的新自定义域名: " custom_domain
    if [ -z "$custom_domain" ]; then
        echo -e "${RED}域名不能为空。正在中止。${NC}"
        press_any_key
        return
    fi
    
    CURRENT_DOMAIN=$custom_domain
    TUNNEL_MODE="permanent"
    
    local exec_start_cmd="${CLOUDFLARED_BINARY} tunnel --no-autoupdate run --token ${argo_token}"
    
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        sed -i "/^ExecStart=/c\ExecStart=${exec_start_cmd}" $CLOUDFLARED_SERVICE_FILE
        systemctl daemon-reload
    else
        local cmd_args="${exec_start_cmd#${CLOUDFLARED_BINARY} }"
        sed -i "/^command_args=/c\command_args=\"${cmd_args}\"" $CLOUDFLARED_SERVICE_FILE
    fi
    
    service_control restart cloudflared
    
    echo -e "${BLUE}正在更新节点信息...${NC}"
    generate_and_save_node_info
    
    echo -e "${GREEN}成功切换到固定隧道模式!${NC}"
    press_any_key
}

# 切换到临时隧道
switch_to_temp_tunnel() {
    echo -e "${BLUE}--- 切换到临时隧道 ---${NC}"
    
    local exec_start_cmd="${CLOUDFLARED_BINARY} tunnel --no-autoupdate --url http://127.0.0.1:10000"
    
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        sed -i "/^ExecStart=/c\ExecStart=${exec_start_cmd}" $CLOUDFLARED_SERVICE_FILE
        systemctl daemon-reload
    else
        local cmd_args="${exec_start_cmd#${CLOUDFLARED_BINARY} }"
        sed -i "/^command_args=/c\command_args=\"${cmd_args}\"" $CLOUDFLARED_SERVICE_FILE
    fi
    
    service_control restart cloudflared
    
    TUNNEL_MODE="temp"
    
    echo -e "${YELLOW}正在等待临时隧道建立... (约10秒)${NC}"
    sleep 10
    fetch_temp_domain
    if [ "$CURRENT_DOMAIN" = "not_found" ]; then
        echo -e "${RED}获取临时域名失败。请检查 Cloudflared 日志。${NC}"
        press_any_key
        return
    fi
    
    generate_and_save_node_info
    echo -e "${GREEN}成功切换到临时隧道模式!${NC}"
    press_any_key
}

#===============================================================================================
#                              卸载功能函数
#===============================================================================================

do_uninstall() {
    clear
    echo -e "${RED}!!! 警告 !!!${NC}"
    echo -e "${YELLOW}此操作将彻底删除 Xray、Cloudflared 及所有相关配置文件。${NC}"
    read -p "您确定要卸载吗?[y/N]: " confirm
    
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        echo -e "${BLUE}正在停止服务...${NC}"
        service_control stop xray 2>/dev/null
        service_control stop cloudflared 2>/dev/null
        
        if [ "$SERVICE_MANAGER" = "systemd" ]; then
            systemctl disable xray > /dev/null 2>&1
            systemctl disable cloudflared > /dev/null 2>&1
            rm -f $XRAY_SERVICE_FILE
            rm -f $CLOUDFLARED_SERVICE_FILE
            systemctl daemon-reload
        else
            rc-update del xray default > /dev/null 2>&1
            rc-update del cloudflared default > /dev/null 2>&1
            rm -f $XRAY_SERVICE_FILE
            rm -f $CLOUDFLARED_SERVICE_FILE
        fi
        
        echo -e "${BLUE}正在删除 Xray...${NC}"
        if [ "$OS_TYPE" = "debian" ]; then
            bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" -s uninstall --remove 2>/dev/null
        fi
        rm -f $XRAY_BINARY
        rm -rf $XRAY_INSTALL_DIR
        
        echo -e "${BLUE}正在删除 Cloudflared...${NC}"
        rm -f $CLOUDFLARED_BINARY
        
        echo -e "${BLUE}正在清理节点信息文件...${NC}"
        rm -f $NODE_INFO_FILE
        
        # 清理日志文件
        if [ "$SERVICE_MANAGER" = "openrc" ]; then
            rm -f /var/log/xray.log /var/log/xray.err
            rm -f /var/log/cloudflared.log /var/log/cloudflared.err
        fi
        
        echo -e "\n${GREEN}卸载完成。${NC}"
    else
        echo -e "${GREEN}卸载已取消。${NC}"
    fi
    press_any_key
}

#===============================================================================================
#                                  菜单界面
#===============================================================================================

show_service_menu() {
    clear
    echo -e "${BLUE}--- 服务管理 ---${NC}"
    echo "1. 查看服务状态"
    echo "2. 启动所有服务"
    echo "3. 停止所有服务"
    echo "4. 重启所有服务"
    echo "0. 返回主菜单"
    echo "--------------------------"
    read -p "请输入您的选择: " choice
    case $choice in
        1) check_status ;;
        2) manage_services "start" ;;
        3) manage_services "stop" ;;
        4) manage_services "restart" ;;
        0) return ;;
        *) echo -e "${RED}无效的选择。${NC}" && press_any_key ;;
    esac
}

show_info_log_menu() {
    clear
    echo -e "${BLUE}--- 信息与日志 ---${NC}"
    echo "1. 查看 Xray 日志"
    echo "2. 查看 Cloudflared 日志"
    echo "3. 查看临时 Argo 域名"
    echo "0. 返回主菜单"
    echo "---------------------"
    read -p "请输入您的选择: " choice
    case $choice in
        1) view_logs "xray" ;;
        2) view_logs "cloudflared" ;;
        3) view_temp_domain ;;
        0) return ;;
        *) echo -e "${RED}无效的选择。${NC}" && press_any_key ;;
    esac
}

show_modify_menu() {
    clear
    echo -e "${BLUE}--- 修改配置 ---${NC}"
    echo "1. 修改 UUID"
    echo "2. 重新配置/切换到固定隧道"
    echo "3. 切换到临时隧道"
    echo "0. 返回主菜单"
    echo "----------------------------"
    read -p "请输入您的选择: " choice
    case $choice in
        1) modify_uuid ;;
        2) modify_permanent_tunnel ;;
        3) switch_to_temp_tunnel ;;
        0) return ;;
        *) echo -e "${RED}无效的选择。${NC}" && press_any_key ;;
    esac
}

show_main_menu() {
    clear
    update_status
    
    local mode_zh
    if [ "$TUNNEL_MODE" = "temp" ]; then
        mode_zh="临时"
    elif [ "$TUNNEL_MODE" = "permanent" ]; then
        mode_zh="固定"
    fi

    echo "======================================================"
    echo "      VLESS + Argo 隧道一键管理脚本 v1.3.2"
    echo "        支持 Debian/Ubuntu 和 Alpine Linux"
    echo "======================================================"
    if [ "$INSTALLED_STATUS" = "installed" ]; then
        echo -e "系统: ${GREEN}${OS_TYPE}${NC} | 状态: ${GREEN}已安装${NC}"
        echo -e "模式: ${YELLOW}${mode_zh}${NC} | 域名: ${YELLOW}${CURRENT_DOMAIN}${NC}"
    else
        echo -e "系统: ${GREEN}${OS_TYPE}${NC} | 状态: ${RED}未安装${NC}"
    fi
    echo "------------------------------------------------------"
    echo " 1. 一键安装 / 查看节点信息"
    echo " 2. 服务管理"
    echo " 3. 信息与日志"
    echo " 4. 修改配置"
    echo " "
    echo " 9. 卸载脚本"
    echo " 0. 退出脚本"
    echo "------------------------------------------------------"
}

#===============================================================================================
#                                 主脚本逻辑
#===============================================================================================

# --- 入口点 ---
main() {
    check_root
    
    # 首次运行时立即检测系统类型
    detect_os
    
    while true; do
        show_main_menu
        read -p "请输入您的选择: " choice
        
        case $choice in
            1)
                if [ "$INSTALLED_STATUS" = "installed" ]; then
                    view_node_info
                else
                    do_install
                fi
                ;;
            2) show_service_menu ;;
            3) show_info_log_menu ;;
            4) show_modify_menu ;;
            9) do_uninstall ;;
            0) break ;;
            *) echo -e "${RED}无效的选择。${NC}" && press_any_key ;;
        esac
    done
    
    echo -e "${GREEN}再见!${NC}"
}

# 运行主函数
main

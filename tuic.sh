#!/bin/bash

#===============================================================================================
# TUIC Protocol Management Script for LXC Debian
#
# Description: A comprehensive script for one-click deployment and management of 
#              a TUIC v5 server in an LXC Debian container.
# Author:      AI Assistant
# Version:     1.2.0 (Stable Download Fix)
#===============================================================================================

# --- 颜色代码 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 文件和及服务路径 ---
TUIC_INSTALL_DIR="/etc/tuic"
TUIC_BINARY="/usr/local/bin/tuic-server"
TUIC_CONFIG_FILE="${TUIC_INSTALL_DIR}/config.json"
TUIC_SERVICE_FILE="/etc/systemd/system/tuic.service"
CERT_DIR="${TUIC_INSTALL_DIR}/certs"
CERT_FILE="${CERT_DIR}/cert.pem"
KEY_FILE="${CERT_DIR}/priv.key"

NODE_INFO_FILE="/root/tuic_node_info.txt"

# --- 全局状态变量 ---
INSTALLED_STATUS="not_installed"
CURRENT_UUID=""
CURRENT_TOKEN=""
CURRENT_PORT=""
SERVER_IP=""

#===============================================================================================
#                              核心辅助函数
#===============================================================================================

# 检查是否为 root 用户
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：此脚本必须以 root 身份运行。请使用 'sudo' 或 'su'。${NC}"
        exit 1
    fi
}

# 通过检查文件来更新安装状态
update_status() {
    if [ -f "$TUIC_BINARY" ] && [ -f "$TUIC_CONFIG_FILE" ] && [ -f "$NODE_INFO_FILE" ]; then
        INSTALLED_STATUS="installed"
        SERVER_IP=$(grep "服务器IP:" "$NODE_INFO_FILE" | awk '{print $2}')
        CURRENT_PORT=$(grep "端口:" "$NODE_INFO_FILE" | awk '{print $2}')
        CURRENT_UUID=$(grep "UUID:" "$NODE_INFO_FILE" | awk '{print $2}')
        CURRENT_TOKEN=$(grep "密码(Token):" "$NODE_INFO_FILE" | awk '{print $2}')
    else
        INSTALLED_STATUS="not_installed"
    fi
}

# 暂停并等待用户按下回车键
press_any_key() {
    echo -e "\n${YELLOW}按回车键继续...${NC}"
    read -r
}

# 获取公网IP地址
get_public_ip() {
    echo -e "${BLUE}正在获取公网IP地址...${NC}"
    SERVER_IP=$(curl -s ip.sb)
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(curl -s https://api.ipify.org)
    fi
    if [ -z "$SERVER_IP" ]; then
        echo -e "${RED}获取公网IP地址失败，请检查网络连接。${NC}"
        exit 1
    fi
    echo -e "${GREEN}获取到公网IP: ${SERVER_IP}${NC}"
}

#===============================================================================================
#                              安装功能函数
#===============================================================================================

# 安装必要的依赖
install_dependencies() {
    echo -e "${BLUE}正在更新软件包列表并安装依赖项 (curl, wget, openssl)...${NC}"
    apt-get update && apt-get install -y curl wget openssl > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}依赖项安装失败。${NC}"
        exit 1
    fi
    echo -e "${GREEN}依赖项安装成功。${NC}"
}

# 安装 TUIC Server
install_tuic_server() {
    echo -e "${BLUE}正在安装 TUIC Server...${NC}"
    ARCH=$(uname -m)
    local STABLE_VERSION="5.0.0" # 使用一个已知的稳定v5版本
    local DOWNLOAD_URL=""

    if [ "$ARCH" = "x86_64" ]; then
        DOWNLOAD_URL="https://github.com/EAimTY/tuic/releases/download/tuic-server-${STABLE_VERSION}/tuic-server-${STABLE_VERSION}-x86_64-linux-gnu"
    elif [ "$ARCH" = "aarch64" ]; then
        DOWNLOAD_URL="https://github.com/EAimTY/tuic/releases/download/tuic-server-${STABLE_VERSION}/tuic-server-${STABLE_VERSION}-aarch64-linux-gnu"
    else
        echo -e "${RED}不支持的架构: $ARCH. 仅支持 x86_64 和 aarch64。${NC}"
        exit 1
    fi

    echo -e "${BLUE}正在从固定链接下载 (版本: ${STABLE_VERSION})...${NC}"
    wget -q "$DOWNLOAD_URL" -O $TUIC_BINARY
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载 TUIC Server 失败。请检查网络或稍后再试。${NC}"
        exit 1
    fi
    
    chmod +x $TUIC_BINARY
    echo -e "${GREEN}TUIC Server 安装成功。${NC}"
}

# 生成自签名证书
generate_self_signed_cert() {
    echo -e "${BLUE}正在生成自签名证书...${NC}"
    mkdir -p $CERT_DIR
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
        -keyout "${KEY_FILE}" -out "${CERT_FILE}" \
        -subj "/CN=cloudflare.com" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}生成自签名证书失败。${NC}"
        exit 1
    fi
    echo -e "${GREEN}证书生成成功。${NC}"
}

# 配置 TUIC
configure_tuic() {
    echo -e "${BLUE}--- 开始配置 TUIC ---${NC}"
    while true; do
        read -p "请输入 TUIC 服务要使用的端口 (例如 443, 8443, 20000): " input_port
        if [[ "$input_port" =~ ^[0-9]+$ && "$input_port" -gt 0 && "$input_port" -le 65535 ]]; then
            CURRENT_PORT=$input_port
            break
        else
            echo -e "${RED}无效的端口号，请输入 1-65535 之间的数字。${NC}"
        fi
    done
    
    CURRENT_UUID=$($TUIC_BINARY --gen-uuid)
    CURRENT_TOKEN=$(openssl rand -base64 16)
    
    get_public_ip
    
    mkdir -p $TUIC_INSTALL_DIR
    cat > $TUIC_CONFIG_FILE <<-EOF
{
    "port": ${CURRENT_PORT},
    "token": ["${CURRENT_TOKEN}"],
    "users": {
        "${CURRENT_UUID}": "${CURRENT_TOKEN}" 
    },
    "certificate": "${CERT_FILE}",
    "private_key": "${KEY_FILE}",
    "congestion_control": "bbr",
    "alpn": ["h3", "spdy/3.1"],
    "log_level": "warn"
}
EOF
    echo -e "${GREEN}TUIC 配置完成。${NC}"
}

# 创建 systemd 服务文件
create_systemd_service() {
    cat > $TUIC_SERVICE_FILE <<-EOF
[Unit]
Description=TUIC Server
After=network.target

[Service]
User=root
WorkingDirectory=${TUIC_INSTALL_DIR}
ExecStart=${TUIC_BINARY} -c ${TUIC_CONFIG_FILE}
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    echo -e "${GREEN}Systemd 服务文件创建成功。${NC}"
}

# 生成并保存节点信息
generate_and_save_node_info() {
    local share_link="tuic://${CURRENT_UUID}:${CURRENT_TOKEN}@${SERVER_IP}:${CURRENT_PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1"

    cat > $NODE_INFO_FILE <<-EOF
# ===============================================================
#          TUIC 节点信息 (版本: v5)
# ===============================================================

服务器IP:         ${SERVER_IP}
端口:             ${CURRENT_PORT}
UUID:             ${CURRENT_UUID}
密码(Token):      ${CURRENT_TOKEN}
拥塞控制:         bbr
ALPN:             h3
允许不安全连接:   是 (因为使用自签名证书)

# --- 客户端分享链接 ---
${share_link}

# ===============================================================
#          客户端配置参数
# ===============================================================
服务器 (Server):    ${SERVER_IP}
端口 (Port):        ${CURRENT_PORT}
UUID:             ${CURRENT_UUID}
密码 (Password):    ${CURRENT_TOKEN}
拥塞控制 (Congestion Control): bbr
UDP 转发模式 (UDP Relay Mode): native
应用层协议协商 (ALPN): h3
跳过证书验证 (Skip Certificate Verification): true
EOF

    echo -e "${GREEN}节点信息已保存到 ${NODE_INFO_FILE}${NC}"
}

# 完整安装流程
do_install() {
    install_dependencies
    install_tuic_server
    generate_self_signed_cert
    configure_tuic
    create_systemd_service
    
    echo -e "${BLUE}正在启用并启动服务...${NC}"
    systemctl daemon-reload
    systemctl enable tuic > /dev/null 2>&1
    systemctl start tuic
    
    generate_and_save_node_info
    
    echo -e "\n${YELLOW}==================== 重要提示 ====================${NC}"
    echo -e "${YELLOW}安装已完成！请务必在您的服务器防火墙或云服务商安全组中，${NC}"
    echo -e "${YELLOW}为公网 IP ${SERVER_IP} 开放 ${RED}UDP端口: ${CURRENT_PORT}${NC}"
    echo -e "${YELLOW}否则客户端将无法连接！${NC}"
    echo -e "${YELLOW}====================================================${NC}"
    
    view_node_info
}

#===============================================================================================
#                              管理功能函数
#===============================================================================================

# 服务管理
manage_services() {
    local action=$1
    local action_zh
    case $action in
        start) action_zh="启动" ;;
        stop) action_zh="停止" ;;
        restart) action_zh="重启" ;;
    esac

    echo -e "${BLUE}正在 ${action_zh} TUIC 服务...${NC}"
    systemctl ${action} tuic
    echo -e "${GREEN}服务已${action_zh}。${NC}"
    press_any_key
}

# 检查服务状态
check_status() {
    echo -e "${BLUE}--- TUIC 服务状态 ---${NC}"
    systemctl status tuic --no-pager
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

# 查看日志
view_logs() {
    echo -e "${BLUE}正在显示 TUIC 的日志。按 Ctrl+C 退出。${NC}"
    sleep 1
    journalctl -u tuic -f --no-pager
    press_any_key
}

#===============================================================================================
#                              修改功能函数
#===============================================================================================

# 修改 UUID
modify_uuid() {
    echo -e "${BLUE}正在生成新的 UUID...${NC}"
    local OLD_UUID=$CURRENT_UUID
    CURRENT_UUID=$($TUIC_BINARY --gen-uuid)
    
    sed -i "s/\"${OLD_UUID}\": \".*\"/\"${CURRENT_UUID}\": \"${CURRENT_TOKEN}\"/" $TUIC_CONFIG_FILE
    
    echo -e "${GREEN}新 UUID: ${CURRENT_UUID}${NC}"
    echo -e "${BLUE}正在重启 TUIC 服务以应用更改...${NC}"
    systemctl restart tuic
    
    echo -e "${BLUE}正在更新节点信息文件...${NC}"
    generate_and_save_node_info
    
    echo -e "${GREEN}UUID 更改并成功更新节点信息！${NC}"
    press_any_key
}

# 修改 Token
modify_token() {
    echo -e "${BLUE}正在生成新的密码(Token)...${NC}"
    local OLD_TOKEN=$CURRENT_TOKEN
    CURRENT_TOKEN=$(openssl rand -base64 16)
    
    sed -i "s/\"${OLD_TOKEN}\"/\"${CURRENT_TOKEN}\"/" $TUIC_CONFIG_FILE
    sed -i "s/\"${CURRENT_UUID}\": \".*\"/\"${CURRENT_UUID}\": \"${CURRENT_TOKEN}\"/" $TUIC_CONFIG_FILE
    
    echo -e "${GREEN}新密码(Token)已生成。${NC}"
    echo -e "${BLUE}正在重启 TUIC 服务以应用更改...${NC}"
    systemctl restart tuic
    
    echo -e "${BLUE}正在更新节点信息文件...${NC}"
    generate_and_save_node_info
    
    echo -e "${GREEN}密码(Token)更改并成功更新节点信息！${NC}"
    press_any_key
}

# 修改端口
modify_port() {
    local OLD_PORT=$CURRENT_PORT
    echo -e "${BLUE}--- 修改服务端口 ---${NC}"
    while true; do
        read -p "请输入新的端口号: " input_port
        if [[ "$input_port" =~ ^[0-9]+$ && "$input_port" -gt 0 && "$input_port" -le 65535 ]]; then
            CURRENT_PORT=$input_port
            break
        else
            echo -e "${RED}无效的端口号。${NC}"
        fi
    done

    sed -i "s/\"port\": ${OLD_PORT}/\"port\": ${CURRENT_PORT}/" $TUIC_CONFIG_FILE
    
    echo -e "${BLUE}正在重启 TUIC 服务以应用更改...${NC}"
    systemctl restart tuic
    
    echo -e "${BLUE}正在更新节点信息文件...${NC}"
    generate_and_save_node_info
    
    echo -e "\n${YELLOW}==================== 重要提示 ====================${NC}"
    echo -e "${YELLOW}端口已从 ${OLD_PORT} 修改为 ${CURRENT_PORT}！${NC}"
    echo -e "${YELLOW}请记得更新您的防火墙规则，开放新的 ${RED}UDP端口: ${CURRENT_PORT}${NC}"
    echo -e "${YELLOW}并关闭旧的端口。${NC}"
    echo -e "${YELLOW}====================================================${NC}"
    press_any_key
}

#===============================================================================================
#                              卸载功能函数
#===============================================================================================

do_uninstall() {
    clear
    echo -e "${RED}!!! 警告 !!!${NC}"
    echo -e "${YELLOW}此操作将彻底删除 TUIC Server 及所有相关配置文件和证书。${NC}"
    read -p "您确定要卸载吗？[y/N]: " confirm
    
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        echo -e "${BLUE}正在停止服务...${NC}"
        systemctl stop tuic
        systemctl disable tuic > /dev/null 2>&1
        
        echo -e "${BLUE}正在删除服务文件...${NC}"
        rm -f $TUIC_SERVICE_FILE
        systemctl daemon-reload
        
        echo -e "${BLUE}正在删除 TUIC 程序文件...${NC}"
        rm -f $TUIC_BINARY
        
        echo -e "${BLUE}正在删除配置文件和证书...${NC}"
        rm -rf $TUIC_INSTALL_DIR
        
        echo -e "${BLUE}正在清理节点信息文件...${NC}"
        rm -f $NODE_INFO_FILE
        
        echo -e "\n${GREEN}卸载完成。${NC}"
        echo -e "${YELLOW}提醒：请手动关闭您之前为 TUIC 开放的防火墙端口。${NC}"
    else
        echo -e "${GREEN}卸载已取消。${NC}"
    fi
    press_any_key
}

#===============================================================================================
#                                  菜单界面
#===============================================================================================

show_modify_menu() {
    clear
    local CURRENT_UUID_OLD=$CURRENT_UUID
    echo -e "${BLUE}--- 修改配置 ---${NC}"
    echo "1. 修改 UUID"
    echo "2. 修改密码 (Token)"
    echo "3. 修改端口"
    echo "0. 返回主菜单"
    echo "----------------------------"
    read -p "请输入您的选择: " choice
    case $choice in
        1) modify_uuid ;;
        2) modify_token ;;
        3) modify_port ;;
        0) return ;;
        *) echo -e "${RED}无效的选择。${NC}" && press_any_key ;;
    esac
}

show_main_menu() {
    clear
    update_status
    echo "======================================================"
    echo "      TUIC v5 协议一键部署管理脚本 v1.2.0 (稳定版)"
    echo "======================================================"
    if [ "$INSTALLED_STATUS" = "installed" ]; then
        echo -e "状态: ${GREEN}已安装${NC} | IP: ${YELLOW}${SERVER_IP}${NC} | 端口: ${YELLOW}${CURRENT_PORT} (UDP)${NC}"
        echo "------------------------------------------------------"
        echo " 1. 查看节点信息"
        echo " 2. 服务管理 (启/停/重启/状态)"
        echo " 3. 查看 TUIC 日志"
        echo " 4. 修改配置 (UUID/密码/端口)"
        echo " "
        echo " 9. 卸载 TUIC"
        echo " 0. 退出脚本"
        echo "------------------------------------------------------"
    else
        echo -e "状态: ${RED}未安装${NC}"
        echo "------------------------------------------------------"
        echo " 1. 一键安装 TUIC"
        echo " 0. 退出脚本"
        echo "------------------------------------------------------"
    fi
}

#===============================================================================================
#                                 主脚本逻辑
#===============================================================================================

main() {
    check_root
    while true; do
        show_main_menu
        read -p "请输入您的选择: " choice
        
        if [ "$INSTALLED_STATUS" = "installed" ]; then
            case $choice in
                1) view_node_info ;;
                2) 
                    clear
                    echo -e "${BLUE}--- 服务管理 ---${NC}"
                    echo "1. 查看服务状态"
                    echo "2. 启动服务"
                    echo "3. 停止服务"
                    echo "4. 重启服务"
                    echo "0. 返回"
                    read -p "请输入您的选择: " sub_choice
                    case $sub_choice in
                        1) check_status ;;
                        2) manage_services "start" ;;
                        3) manage_services "stop" ;;
                        4) manage_services "restart" ;;
                        *) ;;
                    esac
                    ;;
                3) view_logs ;;
                4) show_modify_menu ;;
                9) do_uninstall ;;
                0) break ;;
                *) echo -e "${RED}无效的选择。${NC}" && press_any_key ;;
            esac
        else
            case $choice in
                1) do_install ;;
                0) break ;;
                *) echo -e "${RED}无效的选择。${NC}" && press_any_key ;;
            esac
        fi
    done
    
    echo -e "${GREEN}再见！${NC}"
}

# 运行主函数
main

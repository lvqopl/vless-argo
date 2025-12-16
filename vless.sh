#!/bin/bash

#===============================================================================================
# VLESS + Argo Tunnel Management Script for LXC (Multi-OS Support)
#
# Description: A comprehensive script for one-click deployment and management of 
#              VLESS with Cloudflare Argo Tunnel. Supports Debian and Alpine Linux.
# Author:      AI Assistant
# Version:     1.2.0 (Multi-OS)
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
    echo -e "${GREEN}检测到系统: $OS_TYPE (服务管理: $SERVICE_MANAGER)${NC}"
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
    echo "      VLESS + Argo 隧道一键管理脚本 v1.2.0"
    echo "        支持 Debian/Ubuntu 和 Alpine Linux"
    echo "======================================================"
    if [ "$INSTALLED_STATUS" = "installed" ]; then
        echo -e "系统: ${GREEN}${OS_TYPE}${NC} | 状态: ${GREEN}已安装${NC}"
        echo -e "模式: ${YELLOW}${mode_zh}${NC} | 域名: ${YELLOW}${CURRENT_DOMAIN}${NC}"
        echo "------------------------------------------------------"
        echo " 1. 查看节点信息"
        echo " 2. 服务管理"
        echo " 3. 信息与日志"
        echo " 4. 修改配置"
        echo " "
        echo " 9. 卸载脚本"
        echo " 0. 退出脚本"
        echo "------------------------------------------------------"
    else
        echo -e "状态: ${RED}未安装${NC}"
        echo "------------------------------------------------------"
        echo " 1. 一键安装 VLESS + Argo 隧道"
        echo " 0. 退出脚本"
        echo "------------------------------------------------------"
    fi
}

#===============================================================================================
#                                 主脚本逻辑
#===============================================================================================

# --- 入口点 ---
main() {
    check_root
    
    # 如果已安装,则检测系统类型
    if [ -f "$XRAY_BINARY" ] || [ -f "$CLOUDFLARED_BINARY" ]; then
        detect_os
    fi
    
    while true; do
        show_main_menu
        read -p "请输入您的选择: " choice
        
        if [ "$INSTALLED_STATUS" = "installed" ]; then
            case $choice in
                1) view_node_info ;;
                2) show_service_menu ;;
                3) show_info_log_menu ;;
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
    
    echo -e "${GREEN}再见!${NC}"
}

# 运行主函数
main

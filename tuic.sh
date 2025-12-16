#!/bin/bash

#===============================================================================================
# TUIC Protocol Management Script for LXC Debian
#
# Description: A comprehensive script for one-click deployment and management of 
#              a TUIC v5 server in an LXC Debian container.
# Author:      AI Assistant
# Version:     1.1.0
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
        # 从信息文件中加载配置
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
    echo -e "${BLUE}正在更新软件包列表并安装依赖项 (curl, wget, openssl, jq)...${NC}"
    apt-get update && apt-get install -y curl wget openssl jq > /dev/null 2>&1
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
    
    # 优先使用 API 获取最新版本
    echo -e "${BLUE}正在尝试通过 GitHub API 获取最新版本...${NC}"
    if [ "$ARCH" = "x86_64" ]; then
        DOWNLOAD_URL=$(curl -sL "https://api.github.com/repos/EAimTY/tuic/releases/latest" | jq -r '.assets[] | select(.name | contains("x86_64-linux-gnu")) | .browser_download_url')
    elif [ "$ARCH" = "aarch64" ]; then
        DOWNLOAD_URL=$(curl -sL "https://api.github.com/repos/EAimTY/tuic/releases/latest" | jq -r '.assets[] | select(.name | contains("aarch64-linux-gnu")) | .browser_download_url')
    fi

    # 如果 API 失败，则使用备用方案
    if [ -z "$DOWNLOAD_URL" ]; then
        echo -e "${YELLOW}通过 API 获取链接失败 (可能触发了速率限制)，正在启用备用下载方案...${NC}"
        # 在这里设置一个已知的稳定版本作为备用
        local FALLBACK_VERSION="5.0.0" 
        if [ "$ARCH" = "x86_64" ]; then
            DOWNLOAD_URL="https://github.com/EAimTY/tuic/releases/download/tuic-server-${FALLBACK_VERSION}/tuic-server-${FALLBACK_VERSION}-x86_64-linux-gnu"
        elif [ "$ARCH" = "aarch64" ]; then
            DOWNLOAD_URL="https://github.com/EAimTY/tuic/releases/download/tuic-server-${FALLBACK_VERSION}/tuic-server-${FALLBACK_VERSION}-aarch64-linux-gnu"
        fi
    fi

    # 最终检查
    if [ -z "$DOWNLOAD_URL" ]; then
        echo -e "${RED}获取 TUIC Server 下载链接失败。请检查网络或稍后再试。${NC}"
        exit 1
    fi

    echo -e "${BLUE}正在从以下链接下载: ${DOWNLOAD_URL}${NC}"
    wget -q "$DOWNLOAD_URL" -O $TUIC_BINARY
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载 TUIC Server 失败。${NC}"
        exit 1
    fi
    
    chmod +x $TUIC_BINARY
    echo -e "${GREEN}TUIC Server 安装成功。${NC}"
}

# --- 其他函数 (generate_self_signed_cert, configure_tuic 等) 保持不变 ---
# ... (为节省篇幅，此处省略与原脚本相同的函数，请在下方复制代码块中的完整脚本)

#===============================================================================================
#                              完整脚本
#===============================================================================================

# 为了让您能直接复制使用，下面是包含所有修复和未变动部分的完整脚本。

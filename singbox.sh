#!/bin/bash

# =========================================================
# 脚本名称: Simple Sing-box Installer
# 功能: 交互式安装 VLESS-Reality / Hysteria2 / Shadowsocks
# 系统支持: Ubuntu / Debian / CentOS
# =========================================================

# --- 全局变量 ---
SB_PATH="/usr/local/bin/sing-box"
CONF_DIR="/etc/sing-box"
CONF_FILE="${CONF_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
CERT_DIR="${CONF_DIR}/cert"

# --- 颜色定义 ---
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# --- 检查 Root 权限 ---
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行此脚本！\n" && exit 1

# --- 基础函数 ---

check_sys() {
    if [[ -f /etc/redhat-release ]]; then
        release="centos"
    elif cat /etc/issue | grep -q -E -i "debian"; then
        release="debian"
    elif cat /etc/issue | grep -q -E -i "ubuntu"; then
        release="ubuntu"
    elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
        release="centos"
    elif cat /proc/version | grep -q -E -i "debian"; then
        release="debian"
    elif cat /proc/version | grep -q -E -i "ubuntu"; then
        release="ubuntu"
    elif cat /proc/version | grep -q -E -i "centos|red hat|redhat"; then
        release="centos"
    else
        echo -e "${RED}未检测到支持的操作系统，脚本退出。${PLAIN}"
        exit 1
    fi
    
    # 架构检测
    arch=$(uname -m)
    if [[ $arch == "x86_64" ]]; then
        cpu_arch="amd64"
    elif [[ $arch == "aarch64" ]]; then
        cpu_arch="arm64"
    else
        echo -e "${RED}不支持的架构: $arch${PLAIN}"
        exit 1
    fi
}

install_dependencies() {
    echo -e "${GREEN}正在安装依赖...${PLAIN}"
    if [[ ${release} == "centos" ]]; then
        yum install -y curl wget tar jq openssl policycoreutils-python-utils
    else
        apt-get update
        apt-get install -y curl wget tar jq openssl
    fi
    
    # 开启 BBR
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
    fi
}

install_singbox() {
    echo -e "${GREEN}正在下载 Sing-box 核心...${PLAIN}"
    # 获取最新版本号
    TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name)
    if [[ -z "$TAG" ]] || [[ "$TAG" == "null" ]]; then
        echo -e "${RED}获取最新版本失败，尝试使用默认版本 v1.10.0${PLAIN}"
        TAG="v1.10.0"
    fi
    # 处理版本号前缀 (API返回带v，下载链接里文件名通常也带v，但需确保格式统一)
    VERSION=${TAG#v}
    
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${VERSION}-linux-${cpu_arch}.tar.gz"
    
    wget -O sing-box.tar.gz "$DOWNLOAD_URL"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}下载失败，请检查网络连接。${PLAIN}"
        exit 1
    fi
    
    tar -zxvf sing-box.tar.gz
    cd "sing-box-${VERSION}-linux-${cpu_arch}" || exit
    mv sing-box /usr/local/bin/
    cd ..
    rm -rf sing-box.tar.gz "sing-box-${VERSION}-linux-${cpu_arch}"
    chmod +x $SB_PATH
    
    # 创建配置目录
    mkdir -p $CONF_DIR
    mkdir -p $CERT_DIR

    # 创建 Systemd 服务
    cat > $SERVICE_FILE <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
User=root
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box
    echo -e "${GREEN}Sing-box 核心安装完成。${PLAIN}"
}

# --- 生成随机端口 ---
get_random_port() {
    echo $((RANDOM % 55000 + 10000))
}

# --- 协议安装函数 ---

install_vless_reality() {
    echo -e "${YELLOW}正在配置 VLESS-Reality...${PLAIN}"
    read -p "请输入端口 (默认随机): " port
    [[ -z "$port" ]] && port=$(get_random_port)
    
    # 生成 UUID
    uuid=$(cat /proc/sys/kernel/random/uuid)
    
    # 生成 Reality 密钥对
    keys=$($SB_PATH generate reality-keypair)
    private_key=$(echo "$keys" | grep "PrivateKey" | awk '{print $2}')
    public_key=$(echo "$keys" | grep "PublicKey" | awk '{print $2}')
    short_id=$(openssl rand -hex 8)
    
    # 目标网站 (SNI)
    dest_server="www.yahoo.com"
    server_names='"www.yahoo.com", "yahoo.com"'

    cat > $CONF_FILE <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $port,
      "users": [
        {
          "uuid": "$uuid",
          "flow": "xtls-rprx-vision",
          "name": "vless_user"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$dest_server",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$dest_server",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": ["$short_id"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
    # 写入元数据方便读取（Hack方式，放在 JSON 外部或特定字段，这里选择直接依靠 jq 读取 config.json，不存额外文件）
    restart_service
    show_info
}

install_hysteria2() {
    echo -e "${YELLOW}正在配置 Hysteria2 (自签证书)...${PLAIN}"
    echo -e "${YELLOW}注意：Hysteria2 使用 UDP 协议，请确保防火墙放行 UDP。${PLAIN}"
    read -p "请输入端口 (默认随机): " port
    [[ -z "$port" ]] && port=$(get_random_port)
    
    password=$(cat /proc/sys/kernel/random/uuid)
    
    # 生成自签证书
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 \
    -nodes -keyout $CERT_DIR/self.key -out $CERT_DIR/self.crt \
    -subj "/CN=bing.com" -addext "subjectAltName=DNS:bing.com,DNS:www.bing.com" >/dev/null 2>&1

    cat > $CONF_FILE <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $port,
      "users": [
        {
          "password": "$password"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$CERT_DIR/self.crt",
        "key_path": "$CERT_DIR/self.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
    restart_service
    show_info
}

install_shadowsocks() {
    echo -e "${YELLOW}正在配置 Shadowsocks-2022...${PLAIN}"
    read -p "请输入端口 (默认随机): " port
    [[ -z "$port" ]] && port=$(get_random_port)
    
    method="2022-blake3-aes-128-gcm"
    # 2022-blake3-aes-128-gcm 需要 16字节 key
    password=$($SB_PATH generate rand --hex 16)
    
    cat > $CONF_FILE <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": $port,
      "method": "$method",
      "password": "$password"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
    restart_service
    show_info
}

restart_service() {
    systemctl restart sing-box
    sleep 1
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}服务启动成功！${PLAIN}"
    else
        echo -e "${RED}服务启动失败！请运行 'journalctl -u sing-box -n 20' 查看日志。${PLAIN}"
    fi
}

# --- 信息展示与配置修改 ---

show_info() {
    if [[ ! -f $CONF_FILE ]]; then
        echo -e "${RED}配置文件不存在，请先安装。${PLAIN}"
        return
    fi

    # 获取本机 IP
    local_ip=$(curl -s4m8 ip.sb)
    
    # 解析配置
    protocol=$(jq -r '.inbounds[0].type' $CONF_FILE)
    port=$(jq -r '.inbounds[0].listen_port' $CONF_FILE)

    echo -e "\n${GREEN}================= 节点信息 =================${PLAIN}"
    echo -e "协议类型: ${YELLOW}${protocol}${PLAIN}"
    echo -e "地址 (IP): ${YELLOW}${local_ip}${PLAIN}"
    echo -e "端口: ${YELLOW}${port}${PLAIN}"

    if [[ "$protocol" == "vless" ]]; then
        uuid=$(jq -r '.inbounds[0].users[0].uuid' $CONF_FILE)
        pub_key=$(jq -r '.inbounds[0].tls.reality.private_key' $CONF_FILE | xargs -I {} $SB_PATH generate reality-keypair --private-key {} | grep PublicKey | awk '{print $2}')
        sni=$(jq -r '.inbounds[0].tls.server_name' $CONF_FILE)
        sid=$(jq -r '.inbounds[0].tls.reality.short_id[0]' $CONF_FILE)
        flow=$(jq -r '.inbounds[0].users[0].flow' $CONF_FILE)
        
        echo -e "UUID: ${YELLOW}${uuid}${PLAIN}"
        echo -e "Flow: ${YELLOW}${flow}${PLAIN}"
        echo -e "SNI: ${YELLOW}${sni}${PLAIN}"
        echo -e "Reality Public Key: ${YELLOW}${pub_key}${PLAIN}"
        echo -e "Short ID: ${YELLOW}${sid}${PLAIN}"
        
        # 拼接 VLESS 链接
        link="vless://${uuid}@${local_ip}:${port}?encryption=none&flow=${flow}&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&sid=${sid}&type=tcp&headerType=none#Singbox-Vless"
        echo -e "\n${GREEN}分享链接:${PLAIN} \n${link}"

    elif [[ "$protocol" == "hysteria2" ]]; then
        password=$(jq -r '.inbounds[0].users[0].password' $CONF_FILE)
        echo -e "认证密码: ${YELLOW}${password}${PLAIN}"
        # 自签证书通常建议开启 skip-cert-verify
        echo -e "SNI (可选): ${YELLOW}bing.com${PLAIN}"
        
        link="hysteria2://${password}@${local_ip}:${port}?peer=bing.com&insecure=1&obfs=none#Singbox-Hy2"
        echo -e "\n${GREEN}分享链接:${PLAIN} \n${link}"

    elif [[ "$protocol" == "shadowsocks" ]]; then
        method=$(jq -r '.inbounds[0].method' $CONF_FILE)
        password=$(jq -r '.inbounds[0].password' $CONF_FILE)
        echo -e "加密方式: ${YELLOW}${method}${PLAIN}"
        echo -e "密码: ${YELLOW}${password}${PLAIN}"
        
        base64_str=$(echo -n "${method}:${password}" | base64 -w 0)
        link="ss://${base64_str}@${local_ip}:${port}#Singbox-SS"
        echo -e "\n${GREEN}分享链接:${PLAIN} \n${link}"
    fi
    echo -e "${GREEN}============================================${PLAIN}\n"
}

modify_config() {
    if [[ ! -f $CONF_FILE ]]; then
        echo -e "${RED}请先安装节点。${PLAIN}"
        return
    fi
    
    echo -e "1. 修改端口"
    echo -e "2. 修改 UUID/密码"
    read -p "请选择: " choice
    
    if [[ "$choice" == "1" ]]; then
        read -p "输入新端口: " new_port
        if [[ -n "$new_port" ]]; then
            tmp=$(mktemp)
            jq --argjson p "$new_port" '.inbounds[0].listen_port = $p' $CONF_FILE > "$tmp" && mv "$tmp" $CONF_FILE
            restart_service
            echo -e "${GREEN}端口已修改。${PLAIN}"
        fi
    elif [[ "$choice" == "2" ]]; then
        protocol=$(jq -r '.inbounds[0].type' $CONF_FILE)
        if [[ "$protocol" == "vless" ]]; then
            new_uuid=$(cat /proc/sys/kernel/random/uuid)
            tmp=$(mktemp)
            jq --arg u "$new_uuid" '.inbounds[0].users[0].uuid = $u' $CONF_FILE > "$tmp" && mv "$tmp" $CONF_FILE
            echo -e "${GREEN}UUID 已更新为: $new_uuid${PLAIN}"
        elif [[ "$protocol" == "hysteria2" ]]; then
            read -p "输入新密码: " new_pass
            tmp=$(mktemp)
            jq --arg p "$new_pass" '.inbounds[0].users[0].password = $p' $CONF_FILE > "$tmp" && mv "$tmp" $CONF_FILE
        elif [[ "$protocol" == "shadowsocks" ]]; then
            # SS-2022 需要特定长度密钥，这里简单处理重新生成
            new_pass=$($SB_PATH generate rand --hex 16)
            tmp=$(mktemp)
            jq --arg p "$new_pass" '.inbounds[0].password = $p' $CONF_FILE > "$tmp" && mv "$tmp" $CONF_FILE
             echo -e "${GREEN}密码已更新为: $new_pass${PLAIN}"
        fi
        restart_service
    fi
}

uninstall_singbox() {
    systemctl stop sing-box
    systemctl disable sing-box
    rm -f $SERVICE_FILE
    rm -rf $CONF_DIR
    rm -f $SB_PATH
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成。${PLAIN}"
}

# --- 主菜单 ---

menu() {
    clear
    echo -e "${GREEN}Sing-box 一键管理脚本 (精简版)${PLAIN}"
    echo -e "----------------------------------"
    echo -e "1. 安装/重置 VLESS-Reality (推荐,最稳)"
    echo -e "2. 安装/重置 Hysteria2 (速度快,自签证书)"
    echo -e "3. 安装/重置 Shadowsocks-2022"
    echo -e "----------------------------------"
    echo -e "4. 查看当前节点配置/链接"
    echo -e "5. 修改配置 (端口/密码)"
    echo -e "6. 更新 Sing-box 核心"
    echo -e "7. 卸载"
    echo -e "0. 退出"
    echo -e "----------------------------------"
    read -p "请选择 [0-7]: " num

    case "$num" in
        1)
            check_sys
            install_dependencies
            [[ ! -f $SB_PATH ]] && install_singbox
            install_vless_reality
            ;;
        2)
            check_sys
            install_dependencies
            [[ ! -f $SB_PATH ]] && install_singbox
            install_hysteria2
            ;;
        3)
            check_sys
            install_dependencies
            [[ ! -f $SB_PATH ]] && install_singbox
            install_shadowsocks
            ;;
        4)
            show_info
            ;;
        5)
            modify_config
            ;;
        6)
            rm -f $SB_PATH
            check_sys
            install_singbox
            restart_service
            ;;
        7)
            uninstall_singbox
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}输入错误，请重新输入${PLAIN}"
            sleep 1
            menu
            ;;
    esac
}

menu

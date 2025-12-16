#!/bin/bash

# VLESS + Argo Tunnel 管理脚本
# 版本: 2.0 - 集成安装、管理、卸载功能

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 此脚本必须以 root 权限运行${NC}" 
   exit 1
fi

# 检查是否已安装
check_installed() {
    if systemctl is-active --quiet xray && systemctl is-active --quiet cloudflared; then
        return 0
    else
        return 1
    fi
}

# 显示主菜单
show_main_menu() {
    clear
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}VLESS + Argo Tunnel 管理脚本${NC}"
    echo -e "${GREEN}================================${NC}"
    echo ""
    
    if check_installed; then
        echo -e "${GREEN}✓ 检测到已安装 VLESS + Argo Tunnel${NC}"
        echo ""
        echo "1) 查看服务状态"
        echo "2) 重启所有服务"
        echo "3) 查看监控日志"
        echo "4) 查看 Argo 域名"
        echo "5) 查看配置信息"
        echo "6) 查看节点信息"
        echo "7) 查看 Timer 状态"
        echo "8) 查看日志文件信息"
        echo "9) 手动运行监控检查"
        echo "10) 停止所有服务"
        echo "11) 启动所有服务"
        echo "12) 重新安装"
        echo "13) 完全卸载"
        echo "0) 退出"
    else
        echo -e "${YELLOW}未检测到 VLESS + Argo Tunnel 安装${NC}"
        echo ""
        echo "1) 开始安装"
        echo "0) 退出"
    fi
    echo ""
}

# 安装函数
install_vless() {
    clear
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}VLESS + Argo Tunnel 一键安装${NC}"
    echo -e "${GREEN}================================${NC}"
    echo ""
    
    # 生成随机 UUID
    UUID=$(cat /proc/sys/kernel/random/uuid)
    ARGO_TOKEN=""
    ARGO_DOMAIN=""
    CUSTOM_DOMAIN=""
    PREFERRED_IP="cf.877774.xyz"
    NODE_INFO_FILE="/root/vless_node_info.txt"
    
    # 安装必要的软件包
    echo -e "${YELLOW}[1/7] 更新系统并安装依赖...${NC}"
    apt-get update -y
    apt-get install -y curl wget unzip qrencode
    
    # 下载并安装 Xray
    echo -e "${YELLOW}[2/7] 下载并安装 Xray...${NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    # 创建 Xray 配置文件
    echo -e "${YELLOW}[3/7] 配置 Xray...${NC}"
    cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 8080,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "level": 0
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
    
    # 启动 Xray
    echo -e "${YELLOW}[4/7] 启动 Xray 服务...${NC}"
    systemctl enable xray
    systemctl start xray
    
    # 下载并安装 Cloudflared
    echo -e "${YELLOW}[5/7] 安装 Cloudflared...${NC}"
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
    elif [[ "$ARCH" == "aarch64" ]]; then
        CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
    else
        echo -e "${RED}不支持的架构: $ARCH${NC}"
        return 1
    fi
    
    wget -O /usr/local/bin/cloudflared $CLOUDFLARED_URL
    chmod +x /usr/local/bin/cloudflared
    
    # 配置 Cloudflared 服务
    echo -e "${YELLOW}[6/7] 配置 Cloudflared Argo Tunnel...${NC}"
    echo ""
    echo -e "${GREEN}请选择 Argo Tunnel 配置方式:${NC}"
    echo "1) 使用临时隧道 (自动获取域名，无需 Token)"
    echo "2) 使用固定隧道 (需要 Cloudflare Argo Token 和域名)"
    read -p "请输入选项 [1/2]: " ARGO_CHOICE
    
    if [[ "$ARGO_CHOICE" == "2" ]]; then
        read -p "请输入你的 Argo Tunnel Token: " ARGO_TOKEN
        read -p "请输入你的固定隧道域名 (例如: tunnel.example.com): " CUSTOM_DOMAIN
        CUSTOM_DOMAIN=$(echo "$CUSTOM_DOMAIN" | sed 's|https\?://||')
        
        cat > /etc/systemd/system/cloudflared.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token ${ARGO_TOKEN}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    else
        cat > /etc/systemd/system/cloudflared.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --url http://localhost:8080
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    fi
    
    systemctl daemon-reload
    systemctl enable cloudflared
    systemctl start cloudflared
    
    # 创建监控脚本
    echo -e "${YELLOW}[7/7] 配置服务监控...${NC}"
    cat > /usr/local/bin/vless_monitor.sh << 'MONITOR_EOF'
#!/bin/bash
LOG_FILE="/var/log/vless_monitor.log"
MAX_LOG_SIZE=5242880
MAX_OLD_LOGS=2

rotate_log() {
    if [ -f "$LOG_FILE" ]; then
        local size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null)
        if [ "$size" -gt "$MAX_LOG_SIZE" ]; then
            [ -f "$LOG_FILE.2" ] && rm -f "$LOG_FILE.2"
            [ -f "$LOG_FILE.1" ] && mv "$LOG_FILE.1" "$LOG_FILE.2"
            [ -f "$LOG_FILE.old" ] && mv "$LOG_FILE.old" "$LOG_FILE.1"
            mv "$LOG_FILE" "$LOG_FILE.old"
            touch "$LOG_FILE"
        fi
    else
        touch "$LOG_FILE"
    fi
}

log_message() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
check_and_restart() {
    local service=$1
    if ! systemctl is-active --quiet $service; then
        log_message "警告: $service 未运行，重启中..."
        systemctl restart $service
    fi
}

rotate_log
check_and_restart xray
check_and_restart cloudflared
log_message "监控检查完成"
MONITOR_EOF
    
    chmod +x /usr/local/bin/vless_monitor.sh
    
    # 创建 systemd 服务
    cat > /etc/systemd/system/vless-monitor.service << 'EOF'
[Unit]
Description=VLESS Monitor Service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vless_monitor.sh
EOF
    
    cat > /etc/systemd/system/vless-monitor.timer << 'EOF'
[Unit]
Description=VLESS Monitor Timer

[Timer]
OnBootSec=10sec
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF
    
    systemctl daemon-reload
    systemctl enable vless-monitor.timer
    systemctl start vless-monitor.timer
    
    # 获取域名
    sleep 5
    if [[ "$ARGO_CHOICE" == "1" ]]; then
        for i in {1..3}; do
            ARGO_DOMAIN=$(journalctl -u cloudflared -n 100 --no-pager | grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' | head -1 | sed 's|https://||')
            [[ -n "$ARGO_DOMAIN" ]] && break
            sleep 3
        done
    else
        ARGO_DOMAIN="$CUSTOM_DOMAIN"
    fi
    
    # 生成节点信息
    cat > $NODE_INFO_FILE << EOF
================================
VLESS + Argo Tunnel 节点信息
================================
生成时间: $(date '+%Y-%m-%d %H:%M:%S')

UUID: ${UUID}
域名: ${ARGO_DOMAIN:-未获取到}
端口: 443
路径: /vless
传输: WebSocket
TLS: 开启

【标准版连接】
vless://${UUID}@${ARGO_DOMAIN}:443?encryption=none&security=tls&type=ws&host=${ARGO_DOMAIN}&path=%2Fvless#ArgoVLESS

【优选IP版连接（推荐）】
vless://${UUID}@${PREFERRED_IP}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&fp=chrome&alpn=h3%2Ch2%2Chttp%2F1.1&insecure=0&type=ws&host=${ARGO_DOMAIN}&path=%2Fvless#ArgoVLESS-优选

================================
管理命令: bash <(curl -Ls 你的脚本链接)
节点信息: cat $NODE_INFO_FILE
================================
EOF
    
    echo ""
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}安装完成！${NC}"
    echo -e "${GREEN}================================${NC}"
    echo ""
    cat $NODE_INFO_FILE
    echo ""
    read -p "按回车键返回主菜单..."
}

# 管理功能
check_status() {
    echo -e "${YELLOW}=== 服务状态 ===${NC}"
    systemctl status xray --no-pager -l | head -20
    echo ""
    systemctl status cloudflared --no-pager -l | head -20
    read -p "按回车继续..."
}

restart_services() {
    echo -e "${YELLOW}正在重启服务...${NC}"
    systemctl restart xray cloudflared
    sleep 2
    echo -e "${GREEN}✓ 服务已重启${NC}"
    read -p "按回车继续..."
}

show_logs() {
    tail -50 /var/log/vless_monitor.log 2>/dev/null || echo "日志文件不存在"
    read -p "按回车继续..."
}

show_argo_domain() {
    echo -e "${YELLOW}Argo 域名:${NC}"
    journalctl -u cloudflared -n 100 --no-pager | grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1
    read -p "按回车继续..."
}

show_config() {
    if [ -f /usr/local/etc/xray/config.json ]; then
        echo "UUID: $(grep -oP '(?<="id": ")[^"]+' /usr/local/etc/xray/config.json)"
        echo "端口: 8080"
        echo "路径: /vless"
    fi
    read -p "按回车继续..."
}

show_node_info() {
    cat /root/vless_node_info.txt 2>/dev/null || echo "节点信息文件不存在"
    read -p "按回车继续..."
}

uninstall_all() {
    echo -e "${RED}警告: 将完全卸载所有组件${NC}"
    read -p "输入 'yes' 确认卸载: " confirm
    [[ "$confirm" != "yes" ]] && return
    
    systemctl stop vless-monitor.timer xray cloudflared 2>/dev/null
    systemctl disable vless-monitor.timer xray cloudflared 2>/dev/null
    rm -f /etc/systemd/system/vless-monitor.* /etc/systemd/system/cloudflared.service
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge 2>/dev/null
    rm -rf /usr/local/bin/{xray,cloudflared,vless_monitor.sh} /usr/local/etc/xray /var/log/{xray,vless_monitor.log*} /root/vless_node_info.txt
    systemctl daemon-reload
    
    echo -e "${GREEN}✓ 卸载完成${NC}"
    read -p "按回车继续..."
}

# 主循环
while true; do
    show_main_menu
    
    if check_installed; then
        read -p "请选择操作 [0-13]: " choice
        case $choice in
            1) check_status ;;
            2) restart_services ;;
            3) show_logs ;;
            4) show_argo_domain ;;
            5) show_config ;;
            6) show_node_info ;;
            7) systemctl status vless-monitor.timer --no-pager; read -p "按回车继续..." ;;
            8) ls -lh /var/log/vless_monitor.log* 2>/dev/null; read -p "按回车继续..." ;;
            9) /usr/local/bin/vless_monitor.sh; read -p "按回车继续..." ;;
            10) systemctl stop xray cloudflared vless-monitor.timer; echo "✓ 已停止"; read -p "按回车继续..." ;;
            11) systemctl start xray cloudflared vless-monitor.timer; echo "✓ 已启动"; read -p "按回车继续..." ;;
            12) uninstall_all; install_vless ;;
            13) uninstall_all ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
        esac
    else
        read -p "请选择操作 [0-1]: " choice
        case $choice in
            1) install_vless ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
        esac
    fi
done

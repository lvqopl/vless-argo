#!/bin/bash

# VLESS + Argo Tunnel 完整管理脚本
# 版本: 3.0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

[[ $EUID -ne 0 ]] && { echo -e "${RED}错误: 需要 root 权限${NC}"; exit 1; }

is_installed() {
    [[ -f /usr/local/bin/xray && -f /usr/local/bin/cloudflared ]]
}

show_menu() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   VLESS + Argo Tunnel 管理面板   ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════╝${NC}"
    echo ""
    
    if is_installed; then
        echo -e "${GREEN}● 状态: 已安装${NC}"
        echo ""
        echo "【服务管理】"
        echo "  1) 查看服务状态"
        echo "  2) 启动所有服务"
        echo "  3) 停止所有服务"
        echo "  4) 重启所有服务"
        echo ""
        echo "【信息查看】"
        echo "  5) 查看节点信息"
        echo "  6) 查看 Argo 域名"
        echo "  7) 查看日志"
        echo ""
        echo "【高级功能】"
        echo "  8) 重新安装"
        echo "  9) 完全卸载"
        echo ""
        echo "  0) 退出"
    else
        echo -e "${RED}● 状态: 未安装${NC}"
        echo ""
        echo "  1) 开始安装"
        echo "  0) 退出"
    fi
    echo ""
    echo -n -e "${GREEN}请选择操作: ${NC}"
}

install_system() {
    clear
    echo -e "${GREEN}╔════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        开始安装 VLESS + Argo       ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════╝${NC}"
    echo ""
    
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PREFERRED_IP="cf.877774.xyz"
    NODE_FILE="/root/vless_node_info.txt"
    
    # 安装依赖
    echo -e "${YELLOW}[1/7] 安装依赖包...${NC}"
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl wget unzip qrencode >/dev/null 2>&1
    echo -e "${GREEN}✓ 完成${NC}"
    
    # 安装 Xray
    echo -e "${YELLOW}[2/7] 安装 Xray...${NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
    echo -e "${GREEN}✓ 完成${NC}"
    
    # 配置 Xray
    echo -e "${YELLOW}[3/7] 配置 Xray...${NC}"
    mkdir -p /usr/local/etc/xray
    cat > /usr/local/etc/xray/config.json << XRAYCONFIG
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
XRAYCONFIG
    
    systemctl enable xray >/dev/null 2>&1
    systemctl start xray
    echo -e "${GREEN}✓ 完成${NC}"
    
    # 安装 Cloudflared
    echo -e "${YELLOW}[4/7] 安装 Cloudflared...${NC}"
    ARCH=$(uname -m)
    [[ "$ARCH" == "x86_64" ]] && CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" || CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
    wget -q -O /usr/local/bin/cloudflared "$CF_URL"
    chmod +x /usr/local/bin/cloudflared
    echo -e "${GREEN}✓ 完成${NC}"
    
    # 配置 Argo Tunnel
    echo -e "${YELLOW}[5/7] 配置 Argo Tunnel...${NC}"
    echo ""
    echo "选择隧道类型:"
    echo "1) 临时隧道 (自动获取域名)"
    echo "2) 固定隧道 (需要 Token 和域名)"
    read -p "请选择 [1/2]: " tunnel_type
    
    if [[ "$tunnel_type" == "2" ]]; then
        read -p "输入 Argo Token: " argo_token
        read -p "输入固定域名: " custom_domain
        custom_domain=$(echo "$custom_domain" | sed 's|https\?://||')
        
        cat > /etc/systemd/system/cloudflared.service << FIXEDTUNNEL
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token ${argo_token}
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
FIXEDTUNNEL
    else
        cat > /etc/systemd/system/cloudflared.service << 'TEMPTUNNEL'
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --url http://localhost:8080
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
TEMPTUNNEL
    fi
    
    systemctl daemon-reload
    systemctl enable cloudflared >/dev/null 2>&1
    systemctl start cloudflared
    echo -e "${GREEN}✓ 完成${NC}"
    
    # 配置监控
    echo -e "${YELLOW}[6/7] 配置监控服务...${NC}"
    cat > /usr/local/bin/vless_monitor.sh << 'MONITOR'
#!/bin/bash
for svc in xray cloudflared; do
    systemctl is-active --quiet $svc || systemctl restart $svc
done
MONITOR
    chmod +x /usr/local/bin/vless_monitor.sh
    
    cat > /etc/systemd/system/vless-monitor.service << 'MONSVC'
[Unit]
Description=VLESS Monitor
[Service]
Type=oneshot
ExecStart=/usr/local/bin/vless_monitor.sh
MONSVC
    
    cat > /etc/systemd/system/vless-monitor.timer << 'MONTIMER'
[Unit]
Description=VLESS Monitor Timer
[Timer]
OnBootSec=30sec
OnUnitActiveSec=2min
[Install]
WantedBy=timers.target
MONTIMER
    
    systemctl daemon-reload
    systemctl enable vless-monitor.timer >/dev/null 2>&1
    systemctl start vless-monitor.timer
    echo -e "${GREEN}✓ 完成${NC}"
    
    # 生成节点信息
    echo -e "${YELLOW}[7/7] 生成节点信息...${NC}"
    sleep 5
    
    if [[ "$tunnel_type" == "2" ]]; then
        domain="$custom_domain"
    else
        domain=$(journalctl -u cloudflared -n 100 --no-pager 2>/dev/null | grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' | head -1 | sed 's|https://||')
        [[ -z "$domain" ]] && domain="正在获取域名..."
    fi
    
    # 生成节点信息文件
    {
        echo "════════════════════════════════════"
        echo "    VLESS + Argo 节点信息"
        echo "════════════════════════════════════"
        echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "【基本信息】"
        echo "UUID: ${UUID}"
        echo "域名: ${domain}"
        echo "端口: 443"
        echo "路径: /vless"
        echo "传输: WebSocket"
        echo "TLS: 开启"
        echo ""
        echo "【标准连接】"
        echo "vless://${UUID}@${domain}:443?encryption=none&security=tls&type=ws&host=${domain}&path=%2Fvless#ArgoVLESS"
        echo ""
        echo "【优选IP连接（推荐）】"
        echo "vless://${UUID}@${PREFERRED_IP}:443?encryption=none&security=tls&sni=${domain}&fp=chrome&alpn=h3%2Ch2%2Chttp%2F1.1&type=ws&host=${domain}&path=%2Fvless#ArgoVLESS-优选"
        echo ""
        echo "【客户端配置 - 优选IP版】"
        echo "服务器地址: ${PREFERRED_IP}"
        echo "端口: 443"
        echo "UUID: ${UUID}"
        echo "传输协议: ws"
        echo "路径: /vless"
        echo "SNI: ${domain}"
        echo "TLS: 开启"
        echo "指纹: chrome"
        echo "ALPN: h3,h2,http/1.1"
        echo ""
        echo "════════════════════════════════════"
        echo "查看节点: cat ${NODE_FILE}"
        echo "查看域名: journalctl -u cloudflared -n 50 | grep trycloudflare"
        echo "════════════════════════════════════"
    } > "$NODE_FILE"
    
    echo -e "${GREEN}✓ 完成${NC}"
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║            安装成功！              ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════╝${NC}"
    echo ""
    cat "$NODE_FILE"
    echo ""
    read -p "按回车返回主菜单..."
}

uninstall_system() {
    echo ""
    echo -e "${RED}警告: 将删除所有组件和配置${NC}"
    read -p "输入 'yes' 确认卸载: " confirm
    [[ "$confirm" != "yes" ]] && return
    
    echo -e "${YELLOW}正在卸载...${NC}"
    systemctl stop vless-monitor.timer xray cloudflared 2>/dev/null
    systemctl disable vless-monitor.timer xray cloudflared 2>/dev/null
    
    rm -rf /etc/systemd/system/vless-monitor.{timer,service} /etc/systemd/system/cloudflared.service
    rm -rf /usr/local/bin/{xray,cloudflared,vless_monitor.sh}
    rm -rf /usr/local/etc/xray /root/vless_node_info.txt
    
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge 2>/dev/null
    
    systemctl daemon-reload
    echo -e "${GREEN}✓ 卸载完成${NC}"
    read -p "按回车返回主菜单..."
}

check_status() {
    clear
    echo "════════════════════════════════════"
    echo "   服务状态"
    echo "════════════════════════════════════"
    echo ""
    systemctl status xray cloudflared --no-pager | head -30
    echo ""
    read -p "按回车返回..."
}

show_node() {
    clear
    echo "════════════════════════════════════"
    echo "   节点信息"
    echo "════════════════════════════════════"
    echo ""
    cat /root/vless_node_info.txt 2>/dev/null || echo "节点信息文件不存在"
    echo ""
    read -p "按回车返回..."
}

show_domain() {
    clear
    echo "════════════════════════════════════"
    echo "   Argo 域名"
    echo "════════════════════════════════════"
    echo ""
    domain=$(journalctl -u cloudflared -n 100 --no-pager 2>/dev/null | grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1)
    echo -e "${GREEN}${domain:-未找到域名}${NC}"
    echo ""
    read -p "按回车返回..."
}

# 主循环
while true; do
    show_menu
    read choice
    
    if is_installed; then
        case $choice in
            1) check_status ;;
            2) systemctl start xray cloudflared; echo "✓ 已启动"; sleep 2 ;;
            3) systemctl stop xray cloudflared; echo "✓ 已停止"; sleep 2 ;;
            4) systemctl restart xray cloudflared; echo "✓ 已重启"; sleep 2 ;;
            5) show_node ;;
            6) show_domain ;;
            7) journalctl -u xray -u cloudflared -n 50 --no-pager; read -p "按回车..." ;;
            8) uninstall_system; install_system ;;
            9) uninstall_system ;;
            0) echo "再见!"; exit 0 ;;
            *) sleep 1 ;;
        esac
    else
        case $choice in
            1) install_system ;;
            0) echo "再见!"; exit 0 ;;
            *) sleep 1 ;;
        esac
    fi
done

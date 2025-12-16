#!/bin/bash

# VLESS + Argo Tunnel 完整管理脚本

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 需要 root 权限${NC}" 
   exit 1
fi

is_installed() {
    [[ -f /usr/local/bin/xray ]] && [[ -f /usr/local/bin/cloudflared ]]
}

show_menu() {
    clear
    echo "╔════════════════════════════════════╗"
    echo "║   VLESS + Argo Tunnel 管理面板   ║"
    echo "╚════════════════════════════════════╝"
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
        echo "  7) 查看配置详情"
        echo ""
        echo "【高级功能】"
        echo "  8) 修改节点信息"
        echo "  9) 重新安装"
        echo "  10) 完全卸载"
        echo ""
        echo "  0) 退出"
    else
        echo -e "${RED}● 状态: 未安装${NC}"
        echo ""
        echo "  1) 开始安装"
        echo "  0) 退出"
    fi
    echo ""
    echo -n "请选择: "
}

install_system() {
    clear
    echo "开始安装 VLESS + Argo Tunnel"
    echo ""
    
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PREFERRED_IP="cf.877774.xyz"
    NODE_FILE="/root/vless_node_info.txt"
    
    echo "[1/7] 安装依赖..."
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl wget unzip qrencode >/dev/null 2>&1
    echo "✓ 完成"
    
    echo "[2/7] 安装 Xray..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
    echo "✓ 完成"
    
    echo "[3/7] 配置 Xray..."
    mkdir -p /usr/local/etc/xray
    cat > /usr/local/etc/xray/config.json <<'EOF'
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": 8080,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "UUID_PLACEHOLDER", "level": 0}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": {"path": "/vless"}
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
    sed -i "s/UUID_PLACEHOLDER/${UUID}/" /usr/local/etc/xray/config.json
    systemctl enable xray >/dev/null 2>&1
    systemctl start xray
    echo "✓ 完成"
    
    echo "[4/7] 安装 Cloudflared..."
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
    else
        CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
    fi
    wget -q -O /usr/local/bin/cloudflared $CF_URL
    chmod +x /usr/local/bin/cloudflared
    echo "✓ 完成"
    
    echo "[5/7] 配置 Argo Tunnel..."
    echo ""
    echo "选择隧道类型:"
    echo "1) 临时隧道"
    echo "2) 固定隧道"
    read -p "请选择 [1/2]: " tunnel_type
    
    if [[ "$tunnel_type" == "2" ]]; then
        read -p "输入 Token: " argo_token
        read -p "输入域名: " custom_domain
        custom_domain=$(echo "$custom_domain" | sed 's|https\?://||')
        
        cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token ${argo_token}
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    else
        cat > /etc/systemd/system/cloudflared.service <<'EOF'
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --url http://localhost:8080
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    fi
    
    systemctl daemon-reload
    systemctl enable cloudflared >/dev/null 2>&1
    systemctl start cloudflared
    echo "✓ 完成"
    
    echo "[6/7] 配置监控..."
    cat > /usr/local/bin/vless_monitor.sh <<'EOF'
#!/bin/bash
for svc in xray cloudflared; do
    systemctl is-active --quiet $svc || systemctl restart $svc
done
EOF
    chmod +x /usr/local/bin/vless_monitor.sh
    
    cat > /etc/systemd/system/vless-monitor.service <<'EOF'
[Unit]
Description=VLESS Monitor
[Service]
Type=oneshot
ExecStart=/usr/local/bin/vless_monitor.sh
EOF
    
    cat > /etc/systemd/system/vless-monitor.timer <<'EOF'
[Unit]
Description=VLESS Monitor Timer
[Timer]
OnBootSec=30sec
OnUnitActiveSec=2min
[Install]
WantedBy=timers.target
EOF
    
    systemctl daemon-reload
    systemctl enable vless-monitor.timer >/dev/null 2>&1
    systemctl start vless-monitor.timer
    echo "✓ 完成"
    
    echo "[7/7] 生成节点信息..."
    sleep 5
    
    if [[ "$tunnel_type" == "2" ]]; then
        domain="$custom_domain"
    else
        domain=$(journalctl -u cloudflared -n 100 --no-pager 2>/dev/null | grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' | head -1 | sed 's|https://||')
    fi
    
    echo "════════════════════════════════" > "$NODE_FILE"
    echo "  VLESS + Argo 节点信息" >> "$NODE_FILE"
    echo "════════════════════════════════" >> "$NODE_FILE"
    echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')" >> "$NODE_FILE"
    echo "" >> "$NODE_FILE"
    echo "【基本信息】" >> "$NODE_FILE"
    echo "UUID: ${UUID}" >> "$NODE_FILE"
    echo "域名: ${domain}" >> "$NODE_FILE"
    echo "端口: 443" >> "$NODE_FILE"
    echo "路径: /vless" >> "$NODE_FILE"
    echo "" >> "$NODE_FILE"
    echo "【标准连接】" >> "$NODE_FILE"
    echo "vless://${UUID}@${domain}:443?encryption=none&security=tls&type=ws&host=${domain}&path=%2Fvless#ArgoVLESS" >> "$NODE_FILE"
    echo "" >> "$NODE_FILE"
    echo "【优选IP连接】" >> "$NODE_FILE"
    echo "vless://${UUID}@${PREFERRED_IP}:443?encryption=none&security=tls&sni=${domain}&fp=chrome&alpn=h3%2Ch2%2Chttp%2F1.1&type=ws&host=${domain}&path=%2Fvless#ArgoVLESS-优选" >> "$NODE_FILE"
    echo "" >> "$NODE_FILE"
    echo "════════════════════════════════" >> "$NODE_FILE"
    
    echo "✓ 完成"
    echo ""
    echo "安装成功！"
    echo ""
    cat "$NODE_FILE"
    echo ""
    read -p "按回车返回..."
}

uninstall_system() {
    echo ""
    read -p "确认卸载? 输入 'yes': " confirm
    [[ "$confirm" != "yes" ]] && return
    
    systemctl stop vless-monitor.timer xray cloudflared 2>/dev/null
    systemctl disable vless-monitor.timer xray cloudflared 2>/dev/null
    rm -rf /etc/systemd/system/vless-monitor.* /etc/systemd/system/cloudflared.service
    rm -rf /usr/local/bin/{xray,cloudflared,vless_monitor.sh}
    rm -rf /usr/local/etc/xray /root/vless_node_info.txt
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge 2>/dev/null
    systemctl daemon-reload
    echo "✓ 卸载完成"
    read -p "按回车返回..."
}

check_status() {
    echo ""
    systemctl status xray --no-pager | head -15
    echo ""
    systemctl status cloudflared --no-pager | head -15
    read -p "按回车返回..."
}

show_node() {
    echo ""
    cat /root/vless_node_info.txt 2>/dev/null || echo "节点信息不存在"
    read -p "按回车返回..."
}

show_domain() {
    echo ""
    journalctl -u cloudflared -n 50 --no-pager | grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1
    read -p "按回车返回..."
}

while true; do
    show_menu
    read choice
    
    if is_installed; then
        case $choice in
            1) check_status ;;
            2) systemctl start xray cloudflared; echo "✓ 已启动"; sleep 1 ;;
            3) systemctl stop xray cloudflared; echo "✓ 已停止"; sleep 1 ;;
            4) systemctl restart xray cloudflared; echo "✓ 已重启"; sleep 1 ;;
            5) show_node ;;
            6) show_domain ;;
            7) cat /usr/local/etc/xray/config.json; read -p "按回车..." ;;
            8) nano /root/vless_node_info.txt ;;
            9) uninstall_system; install_system ;;
            10) uninstall_system ;;
            0) exit 0 ;;
            *) sleep 1 ;;
        esac
    else
        case $choice in
            1) install_system ;;
            0) exit 0 ;;
            *) sleep 1 ;;
        esac
    fi
done

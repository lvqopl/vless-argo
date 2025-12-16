#!/bin/bash

# VLESS + Argo Tunnel 管理脚本

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

[[ $EUID -ne 0 ]] && { echo -e "${RED}需要 root 权限${NC}"; exit 1; }

is_installed() {
    [[ -f /usr/local/bin/xray ]] && [[ -f /usr/local/bin/cloudflared ]]
}

show_menu() {
    clear
    echo "════════════════════════════════════"
    echo "   VLESS + Argo Tunnel 管理"
    echo "════════════════════════════════════"
    echo ""
    if is_installed; then
        echo -e "${GREEN}状态: 已安装${NC}"
        echo ""
        echo "1) 查看状态    2) 启动服务"
        echo "3) 停止服务    4) 重启服务"
        echo "5) 查看节点    6) 查看域名"
        echo "7) 重新安装    8) 卸载"
        echo "0) 退出"
    else
        echo -e "${RED}状态: 未安装${NC}"
        echo ""
        echo "1) 安装    0) 退出"
    fi
    echo ""
    echo -n "选择: "
}

install_system() {
    clear
    echo "开始安装..."
    echo ""
    
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PREFERRED_IP="cf.877774.xyz"
    
    # 安装依赖
    apt-get update -y >/dev/null 2>&1
    apt-get install -y curl wget unzip >/dev/null 2>&1
    
    # 安装 Xray
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
    
    # 配置 Xray
    mkdir -p /usr/local/etc/xray
    cat > /usr/local/etc/xray/config.json <<EOF
{
  "inbounds": [{
    "port": 8080,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${UUID}"}],
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
    
    systemctl enable xray && systemctl start xray
    
    # 安装 Cloudflared
    ARCH=$(uname -m)
    [[ "$ARCH" == "x86_64" ]] && URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" || URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
    wget -qO /usr/local/bin/cloudflared "$URL" && chmod +x /usr/local/bin/cloudflared
    
    # 配置隧道
    echo "隧道类型: 1)临时 2)固定"
    read -p "选择: " type
    
    if [[ "$type" == "2" ]]; then
        read -p "Token: " token
        read -p "域名: " domain
        domain=${domain#https://}
        cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token ${token}
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
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --url http://localhost:8080
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    fi
    
    systemctl daemon-reload
    systemctl enable cloudflared && systemctl start cloudflared
    
    # 等待获取域名
    sleep 8
    [[ "$type" != "2" ]] && domain=$(journalctl -u cloudflared -n 100 --no-pager | grep -oP '(?<=https://)[a-z0-9-]+\.trycloudflare\.com' | head -1)
    
    # 生成节点
    cat > /root/vless_node_info.txt <<EOF
════════════════════════════════════
VLESS 节点信息
════════════════════════════════════
UUID: ${UUID}
域名: ${domain}
端口: 443
路径: /vless

标准连接:
vless://${UUID}@${domain}:443?encryption=none&security=tls&type=ws&host=${domain}&path=/vless#VLESS

优选IP连接:
vless://${UUID}@${PREFERRED_IP}:443?encryption=none&security=tls&sni=${domain}&fp=chrome&alpn=h3,h2,http/1.1&type=ws&host=${domain}&path=/vless#VLESS-优选

════════════════════════════════════
EOF
    
    echo ""
    echo "安装完成！"
    cat /root/vless_node_info.txt
    echo ""
    read -p "按回车..."
}

uninstall_system() {
    read -p "确认卸载? (yes/no): " c
    [[ "$c" != "yes" ]] && return
    
    systemctl stop xray cloudflared
    systemctl disable xray cloudflared
    rm -rf /etc/systemd/system/cloudflared.service
    rm -rf /usr/local/bin/{xray,cloudflared}
    rm -rf /usr/local/etc/xray /root/vless_node_info.txt
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge 2>/dev/null
    systemctl daemon-reload
    
    echo "卸载完成"
    read -p "按回车..."
}

while true; do
    show_menu
    read choice
    
    if is_installed; then
        case $choice in
            1) systemctl status xray cloudflared --no-pager | head -20; read -p "按回车..." ;;
            2) systemctl start xray cloudflared; echo "已启动"; sleep 1 ;;
            3) systemctl stop xray cloudflared; echo "已停止"; sleep 1 ;;
            4) systemctl restart xray cloudflared; echo "已重启"; sleep 1 ;;
            5) clear; cat /root/vless_node_info.txt 2>/dev/null || echo "无节点信息"; read -p "按回车..." ;;
            6) clear; journalctl -u cloudflared -n 50 --no-pager | grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1; read -p "按回车..." ;;
            7) uninstall_system; install_system ;;
            8) uninstall_system ;;
            0) exit 0 ;;
        esac
    else
        case $choice in
            1) install_system ;;
            0) exit 0 ;;
        esac
    fi
done

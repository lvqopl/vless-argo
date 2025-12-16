#!/bin/bash

# VLESS + Argo Tunnel 一键安装脚本 (适用于 LXC Debian)
# 版本: 2.0 - 支持固定隧道域名配置和优选域名

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

echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}VLESS + Argo Tunnel 一键安装${NC}"
echo -e "${GREEN}================================${NC}"

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
systemctl status xray --no-pager

# 下载并安装 Cloudflared
echo -e "${YELLOW}[5/7] 安装 Cloudflared...${NC}"
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
elif [[ "$ARCH" == "aarch64" ]]; then
    CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
else
    echo -e "${RED}不支持的架构: $ARCH${NC}"
    exit 1
fi

wget -O /usr/local/bin/cloudflared $CLOUDFLARED_URL
chmod +x /usr/local/bin/cloudflared

# 配置 Cloudflared 服务
echo -e "${YELLOW}[6/7] 配置 Cloudflared Argo Tunnel...${NC}"

# 询问用户是否有 Argo Token
echo -e "${GREEN}请选择 Argo Tunnel 配置方式:${NC}"
echo "1) 使用临时隧道 (自动获取域名，无需 Token)"
echo "2) 使用固定隧道 (需要 Cloudflare Argo Token 和域名)"
read -p "请输入选项 [1/2]: " ARGO_CHOICE

if [[ "$ARGO_CHOICE" == "2" ]]; then
    read -p "请输入你的 Argo Tunnel Token: " ARGO_TOKEN
    read -p "请输入你的固定隧道域名 (例如: tunnel.example.com): " CUSTOM_DOMAIN
    
    # 去除可能的协议前缀
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
    # 使用临时隧道
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

# 启动 Cloudflared
systemctl daemon-reload
systemctl enable cloudflared
systemctl start cloudflared

# 创建服务监控脚本
echo -e "${YELLOW}[7/7] 配置服务监控和自动重启 (systemd timer)...${NC}"
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
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 日志已轮转" >> "$LOG_FILE"
        fi
    else
        touch "$LOG_FILE"
    fi
    
    local log_count=$(ls -1 ${LOG_FILE}.* 2>/dev/null | wc -l)
    if [ "$log_count" -gt "$MAX_OLD_LOGS" ]; then
        ls -1t ${LOG_FILE}.* 2>/dev/null | tail -n +$((MAX_OLD_LOGS + 1)) | xargs rm -f
    fi
}

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

check_and_restart() {
    local service=$1
    if ! systemctl is-active --quiet $service; then
        log_message "警告: $service 服务未运行，正在重启..."
        systemctl restart $service
        sleep 3
        systemctl is-active --quiet $service && log_message "成功: $service 服务已重启" || log_message "错误: $service 服务重启失败"
    fi
}

check_port() {
    local port=$1
    local service=$2
    if ! ss -tuln 2>/dev/null | grep -q ":$port "; then
        log_message "警告: 端口 $port 未监听，$service 可能异常"
        return 1
    fi
    return 0
}

rotate_log
check_and_restart xray
check_port 8080 "Xray" || systemctl restart xray
check_and_restart cloudflared

for proc in xray cloudflared; do
    count=$(pgrep -c $proc)
    if [ "$count" -eq 0 ]; then
        log_message "警告: $proc 进程不存在，强制重启"
        systemctl restart $proc
    elif [ "$count" -gt 3 ]; then
        log_message "警告: $proc 进程数量异常 ($count)，重启服务"
        systemctl restart $proc
    fi
done

TOTAL_MEM=$(free -m | awk 'NR==2{print $2}')
USED_MEM=$(free -m | awk 'NR==2{print $3}')
MEM_USAGE=$(awk "BEGIN {printf \"%.0f\", ($USED_MEM/$TOTAL_MEM)*100}")
if [ "$MEM_USAGE" -gt 90 ]; then
    log_message "警告: 内存使用率过高 ($MEM_USAGE%)"
    ps aux --sort=-%mem | head -10 >> "$LOG_FILE"
fi

log_message "监控检查完成 - Xray: 运行中 | Cloudflared: 运行中"
MONITOR_EOF

chmod +x /usr/local/bin/vless_monitor.sh

# 创建 systemd service 和 timer 文件
cat > /etc/systemd/system/vless-monitor.service << 'SERVICE_EOF'
[Unit]
Description=VLESS Argo Monitor Service
After=network.target xray.service cloudflared.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vless_monitor.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_EOF

cat > /etc/systemd/system/vless-monitor.timer << 'TIMER_EOF'
[Unit]
Description=VLESS Argo Monitor Timer
Requires=vless-monitor.service

[Timer]
OnBootSec=10sec
OnUnitActiveSec=1min
Unit=vless-monitor.service

[Install]
WantedBy=timers.target
TIMER_EOF

systemctl daemon-reload
systemctl enable vless-monitor.timer
systemctl start vless-monitor.timer

# 创建管理脚本
cat > /usr/local/bin/vless_manage.sh << 'MANAGE_EOF'
#!/bin/bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

show_menu() {
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}VLESS + Argo 管理脚本${NC}"
    echo -e "${GREEN}================================${NC}"
    echo "1) 查看服务状态"
    echo "2) 重启所有服务"
    echo "3) 查看监控日志"
    echo "4) 查看 Argo 域名"
    echo "5) 查看配置信息"
    echo "6) 手动运行监控检查"
    echo "7) 查看 Timer 状态"
    echo "8) 查看日志文件信息"
    echo "9) 查看节点信息"
    echo "10) 停止所有服务"
    echo "11) 启动所有服务"
    echo "12) 完全卸载"
    echo "0) 退出"
    echo ""
}

check_status() {
    echo -e "${YELLOW}=== Xray 状态 ===${NC}"
    systemctl status xray --no-pager -l
    echo ""
    echo -e "${YELLOW}=== Cloudflared 状态 ===${NC}"
    systemctl status cloudflared --no-pager -l
    echo ""
    echo -e "${YELLOW}=== 监控 Timer 状态 ===${NC}"
    systemctl status vless-monitor.timer --no-pager -l
    echo ""
    echo -e "${YELLOW}=== 端口监听状态 ===${NC}"
    ss -tuln | grep 8080
}

restart_services() {
    echo -e "${YELLOW}正在重启服务...${NC}"
    systemctl restart xray cloudflared
    sleep 3
    echo -e "${GREEN}服务已重启${NC}"
    check_status
}

show_logs() {
    echo -e "${YELLOW}最近 50 条监控日志:${NC}"
    tail -50 /var/log/vless_monitor.log 2>/dev/null || echo "日志文件不存在"
    echo ""
    echo -e "${YELLOW}最近 20 条 systemd 日志:${NC}"
    journalctl -u vless-monitor.service -n 20 --no-pager
}

show_argo_domain() {
    echo -e "${YELLOW}正在查询 Argo 域名...${NC}"
    journalctl -u cloudflared -n 100 --no-pager | grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1
}

show_config() {
    echo -e "${YELLOW}=== 配置信息 ===${NC}"
    if [ -f /usr/local/etc/xray/config.json ]; then
        echo "UUID: $(grep -oP '(?<="id": ")[^"]+' /usr/local/etc/xray/config.json)"
        echo "端口: 8080"
        echo "路径: /vless"
    else
        echo -e "${RED}配置文件不存在${NC}"
    fi
}

run_monitor() {
    echo -e "${YELLOW}运行监控检查...${NC}"
    /usr/local/bin/vless_monitor.sh
    echo -e "${GREEN}检查完成${NC}"
}

show_timer_status() {
    echo -e "${YELLOW}=== Timer 状态 ===${NC}"
    systemctl status vless-monitor.timer --no-pager -l
    echo ""
    echo -e "${YELLOW}=== 下次运行时间 ===${NC}"
    systemctl list-timers vless-monitor.timer
    echo ""
    echo -e "${YELLOW}=== 最近执行记录 ===${NC}"
    journalctl -u vless-monitor.service -n 10 --no-pager
}

show_log_info() {
    echo -e "${YELLOW}=== 日志文件信息 ===${NC}"
    if [ -f /var/log/vless_monitor.log ]; then
        echo "当前日志大小: $(du -h /var/log/vless_monitor.log | cut -f1)"
        echo "日志行数: $(wc -l < /var/log/vless_monitor.log)"
        echo ""
        echo "所有日志文件:"
        ls -lh /var/log/vless_monitor.log* 2>/dev/null
        echo ""
        echo -e "${YELLOW}日志管理配置:${NC}"
        echo "- 单个日志最大: 5MB"
        echo "- 保留旧日志: 2 个"
        echo "- 自动轮转: 启用"
    else
        echo -e "${RED}日志文件不存在${NC}"
    fi
}

show_node_info() {
    if [ -f /root/vless_node_info.txt ]; then
        cat /root/vless_node_info.txt
    else
        echo -e "${RED}节点信息文件不存在${NC}"
    fi
}

stop_services() {
    echo -e "${YELLOW}正在停止服务...${NC}"
    systemctl stop xray cloudflared vless-monitor.timer
    echo -e "${GREEN}服务已停止${NC}"
}

start_services() {
    echo -e "${YELLOW}正在启动服务...${NC}"
    systemctl start xray cloudflared vless-monitor.timer
    sleep 3
    echo -e "${GREEN}服务已启动${NC}"
    check_status
}

uninstall_all() {
    echo -e "${RED}================================${NC}"
    echo -e "${RED}警告：卸载操作${NC}"
    echo -e "${RED}================================${NC}"
    echo -e "${YELLOW}此操作将完全卸载 VLESS 和 Argo Tunnel${NC}"
    echo -e "${YELLOW}包括所有配置文件、日志和服务${NC}"
    echo ""
    read -p "确定要卸载吗？输入 'yes' 确认: " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        echo -e "${GREEN}已取消卸载${NC}"
        return
    fi
    
    echo ""
    echo -e "${YELLOW}[1/8] 停止服务...${NC}"
    systemctl stop vless-monitor.timer vless-monitor.service xray cloudflared 2>/dev/null
    echo -e "${GREEN}✓ 服务已停止${NC}"
    
    echo -e "${YELLOW}[2/8] 禁用服务自启动...${NC}"
    systemctl disable vless-monitor.timer vless-monitor.service xray cloudflared 2>/dev/null
    echo -e "${GREEN}✓ 已禁用自启动${NC}"
    
    echo -e "${YELLOW}[3/8] 删除 systemd 服务文件...${NC}"
    rm -f /etc/systemd/system/vless-monitor.timer
    rm -f /etc/systemd/system/vless-monitor.service
    rm -f /etc/systemd/system/cloudflared.service
    systemctl daemon-reload
    echo -e "${GREEN}✓ systemd 文件已删除${NC}"
    
    echo -e "${YELLOW}[4/8] 卸载 Xray...${NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge 2>/dev/null
    rm -rf /usr/local/bin/xray /usr/local/etc/xray /var/log/xray /usr/local/share/xray
    echo -e "${GREEN}✓ Xray 已卸载${NC}"
    
    echo -e "${YELLOW}[5/8] 删除 Cloudflared...${NC}"
    rm -f /usr/local/bin/cloudflared
    rm -rf /root/.cloudflared
    echo -e "${GREEN}✓ Cloudflared 已删除${NC}"
    
    echo -e "${YELLOW}[6/8] 删除脚本文件...${NC}"
    rm -f /usr/local/bin/vless_monitor.sh
    echo -e "${GREEN}✓ 脚本文件已删除${NC}"
    
    echo -e "${YELLOW}[7/8] 删除日志和配置文件...${NC}"
    rm -f /var/log/vless_monitor.log*
    rm -f /root/vless_node_info.txt
    echo -e "${GREEN}✓ 日志和配置已删除${NC}"
    
    echo -e "${YELLOW}[8/8] 清理残留文件...${NC}"
    rm -rf /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
    systemctl daemon-reload
    echo -e "${GREEN}✓ 清理完成${NC}"
    
    echo ""
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}卸载完成！${NC}"
    echo -e "${GREEN}================================${NC}"
    echo ""
    echo "本管理脚本将在 3 秒后自动删除..."
    sleep 3
    rm -f /usr/local/bin/vless_manage.sh
    exit 0
}

while true; do
    show_menu
    read -p "请选择操作 [0-12]: " choice
    case $choice in
        1) check_status ;;
        2) restart_services ;;
        3) show_logs ;;
        4) show_argo_domain ;;
        5) show_config ;;
        6) run_monitor ;;
        7) show_timer_status ;;
        8) show_log_info ;;
        9) show_node_info ;;
        10) stop_services ;;
        11) start_services ;;
        12) uninstall_all ;;
        0) echo "退出"; exit 0 ;;
        *) echo -e "${RED}无效选项${NC}" ;;
    esac
    echo ""
    read -p "按回车继续..."
done
MANAGE_EOF

chmod +x /usr/local/bin/vless_manage.sh

# 等待服务启动并获取域名
sleep 5
echo -e "${YELLOW}正在获取 Argo 隧道信息...${NC}"
sleep 5

if [[ "$ARGO_CHOICE" == "1" ]]; then
    for i in {1..3}; do
        ARGO_DOMAIN=$(journalctl -u cloudflared -n 100 --no-pager | grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' | head -1 | sed 's/https:\/\///')
        [[ -n "$ARGO_DOMAIN" ]] && break
        echo "尝试获取域名... ($i/3)"
        sleep 3
    done
else
    ARGO_DOMAIN="$CUSTOM_DOMAIN"
fi

/usr/local/bin/vless_monitor.sh

# 生成节点信息文件
cat > $NODE_INFO_FILE << EOF
================================
VLESS + Argo Tunnel 节点信息
================================
生成时间: $(date '+%Y-%m-%d %H:%M:%S')

【基础配置】
UUID: ${UUID}
本地端口: 8080
路径: /vless
传输协议: WebSocket
加密: none
TLS: 启用 (通过 Cloudflare)

EOF

if [[ -n "$ARGO_DOMAIN" ]]; then
    # 生成标准连接链接
    VLESS_LINK_STANDARD="vless://${UUID}@${ARGO_DOMAIN}:443?encryption=none&security=tls&type=ws&host=${ARGO_DOMAIN}&path=%2Fvless#ArgoVLESS"
    
    # 生成带优选 IP 的完整连接链接
    VLESS_LINK_OPTIMIZED="vless://${UUID}@${PREFERRED_IP}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&fp=chrome&alpn=h3%2Ch2%2Chttp%2F1.1&insecure=0&allowInsecure=0&type=ws&host=${ARGO_DOMAIN}&path=%2Fvless#ArgoVLESS-优选"
    
    cat >> $NODE_INFO_FILE << EOF
【Argo Tunnel 信息】
实际域名: ${ARGO_DOMAIN}
优选地址: ${PREFERRED_IP}
$([ "$ARGO_CHOICE" == "1" ] && echo "类型: 临时隧道" || echo "类型: 固定隧道")

【VLESS 连接链接 - 标准版】
${VLESS_LINK_STANDARD}

【VLESS 连接链接 - 优选 IP 版（推荐）】
${VLESS_LINK_OPTIMIZED}

【客户端配置 - 标准版】
服务器地址: ${ARGO_DOMAIN}
端口: 443
UUID: ${UUID}
传输协议: WebSocket
WebSocket 路径: /vless
TLS: 开启
跳过证书验证: 关闭

【客户端配置 - 优选 IP 版（速度更快）】
服务器地址: ${PREFERRED_IP}
端口: 443
UUID: ${UUID}
传输协议: WebSocket
WebSocket 路径: /vless
SNI/Host: ${ARGO_DOMAIN}
TLS: 开启
指纹: chrome
ALPN: h3,h2,http/1.1
跳过证书验证: 关闭
允许不安全: 关闭

EOF
    
    if command -v qrencode &> /dev/null; then
        echo "【标准版二维码】" >> $NODE_INFO_FILE
        qrencode -t ANSIUTF8 "${VLESS_LINK_STANDARD}" >> $NODE_INFO_FILE 2>/dev/null
        echo "" >> $NODE_INFO_FILE
        echo "【优选 IP 版二维码】" >> $NODE_INFO_FILE
        qrencode -t ANSIUTF8 "${VLESS_LINK_OPTIMIZED}" >> $NODE_INFO_FILE 2>/dev/null
        echo "" >> $NODE_INFO_FILE
    fi
else
    cat >> $NODE_INFO_FILE << EOF
【Argo Tunnel 信息】
类型: 固定隧道
注意: 未能自动获取域名，请手动配置

查看域名命令:
journalctl -u cloudflared -n 50 | grep -E "trycloudflare|registered"

EOF
fi

cat >> $NODE_INFO_FILE << EOF
================================
【管理命令】
================================
查看节点信息: cat $NODE_INFO_FILE
管理界面: vless_manage.sh
查看 Argo 域名: journalctl -u cloudflared -n 50 | grep trycloudflare.com
重启服务: systemctl restart xray cloudflared

【注意事项】
1. 临时隧道域名会在重启后变化，建议使用固定隧道
2. 优选 IP 版本可提供更好的连接速度
3. 默认优选地址: ${PREFERRED_IP}
4. 可在客户端自行测试其他优选 IP

【推荐优选 IP 列表】
- cf.877774.xyz (默认)
- 104.16.0.0/12
- 162.159.0.0/16
- 172.64.0.0/13

================================
脚本版本: v2.0
生成日期: $(date '+%Y-%m-%d')
================================
EOF

echo ""
echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}安装完成！${NC}"
echo -e "${GREEN}================================${NC}"
echo ""
cat $NODE_INFO_FILE
echo ""
echo -e "${YELLOW}监控配置:${NC}"
echo "✓ 开机 10 秒后首次运行，之后每 1 分钟检查"
echo "✓ 日志自动管理: 5MB 自动轮转，保留 2 个旧日志"
echo ""
echo -e "${GREEN✓ 节点信息已保存: ${NODE_INFO_FILE}${NC}"
echo -e "${GREEN}✓ 管理命令: vless_manage.sh${NC}"
echo ""
echo -e "${GREEN}安装完成！推荐使用优选 IP 版本获得更好的连接速度！${NC}"

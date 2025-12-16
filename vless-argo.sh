#!/bin/bash

# VLESS + Argo Tunnel 一键安装脚本 (适用于 LXC Debian)
# 包含 systemd timer 服务监控和自动日志管理

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

# 安装必要的软件包
echo -e "${YELLOW}[1/7] 更新系统并安装依赖...${NC}"
apt-get update -y
apt-get install -y curl wget unzip

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
echo "2) 使用固定隧道 (需要 Cloudflare Argo Token)"
read -p "请输入选项 [1/2]: " ARGO_CHOICE

if [[ "$ARGO_CHOICE" == "2" ]]; then
    read -p "请输入你的 Argo Tunnel Token: " ARGO_TOKEN
    
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

# 创建服务监控脚本 - 包含改进的日志管理
echo -e "${YELLOW}[7/7] 配置服务监控和自动重启 (systemd timer)...${NC}"
cat > /usr/local/bin/vless_monitor.sh << 'MONITOR_EOF'
#!/bin/bash

# 日志文件配置
LOG_FILE="/var/log/vless_monitor.log"
MAX_LOG_SIZE=5242880  # 5MB (5 * 1024 * 1024)
MAX_OLD_LOGS=2        # 保留最多 2 个旧日志文件

# 改进的日志轮转函数
rotate_log() {
    if [ -f "$LOG_FILE" ]; then
        local size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null)
        if [ "$size" -gt "$MAX_LOG_SIZE" ]; then
            # 删除最旧的日志
            if [ -f "$LOG_FILE.2" ]; then
                rm -f "$LOG_FILE.2"
            fi
            
            # 日志文件轮转
            if [ -f "$LOG_FILE.1" ]; then
                mv "$LOG_FILE.1" "$LOG_FILE.2"
            fi
            
            if [ -f "$LOG_FILE.old" ]; then
                mv "$LOG_FILE.old" "$LOG_FILE.1"
            fi
            
            # 当前日志改名
            mv "$LOG_FILE" "$LOG_FILE.old"
            touch "$LOG_FILE"
            
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 日志已轮转，旧日志已备份" >> "$LOG_FILE"
        fi
    else
        touch "$LOG_FILE"
    fi
    
    # 清理超过指定数量的旧日志
    local log_count=$(ls -1 ${LOG_FILE}.* 2>/dev/null | wc -l)
    if [ "$log_count" -gt "$MAX_OLD_LOGS" ]; then
        ls -1t ${LOG_FILE}.* 2>/dev/null | tail -n +$((MAX_OLD_LOGS + 1)) | xargs rm -f
    fi
}

# 写日志函数
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 检查并重启服务函数
check_and_restart() {
    local service=$1
    
    if ! systemctl is-active --quiet $service; then
        log_message "警告: $service 服务未运行，正在重启..."
        systemctl restart $service
        sleep 3
        
        if systemctl is-active --quiet $service; then
            log_message "成功: $service 服务已重启"
        else
            log_message "错误: $service 服务重启失败"
        fi
    fi
}

# 检查端口是否监听
check_port() {
    local port=$1
    local service=$2
    
    if ! ss -tuln 2>/dev/null | grep -q ":$port "; then
        log_message "警告: 端口 $port 未监听，$service 可能异常"
        return 1
    fi
    return 0
}

# 主监控逻辑
rotate_log

# 检查 Xray 服务
check_and_restart xray

# 检查 Xray 端口
if ! check_port 8080 "Xray"; then
    log_message "尝试重启 Xray 服务..."
    systemctl restart xray
fi

# 检查 Cloudflared 服务
check_and_restart cloudflared

# 检查进程数量（防止进程僵死）
XRAY_PROCESS=$(pgrep -c xray)
if [ "$XRAY_PROCESS" -eq 0 ]; then
    log_message "警告: Xray 进程不存在，强制重启"
    systemctl restart xray
elif [ "$XRAY_PROCESS" -gt 3 ]; then
    log_message "警告: Xray 进程数量异常 ($XRAY_PROCESS)，重启服务"
    systemctl restart xray
fi

CLOUDFLARED_PROCESS=$(pgrep -c cloudflared)
if [ "$CLOUDFLARED_PROCESS" -eq 0 ]; then
    log_message "警告: Cloudflared 进程不存在，强制重启"
    systemctl restart cloudflared
elif [ "$CLOUDFLARED_PROCESS" -gt 3 ]; then
    log_message "警告: Cloudflared 进程数量异常 ($CLOUDFLARED_PROCESS)，重启服务"
    systemctl restart cloudflared
fi

# 内存检查（可选，防止内存泄漏）
TOTAL_MEM=$(free -m | awk 'NR==2{print $2}')
USED_MEM=$(free -m | awk 'NR==2{print $3}')
MEM_USAGE=$(awk "BEGIN {printf \"%.0f\", ($USED_MEM/$TOTAL_MEM)*100}")

if [ "$MEM_USAGE" -gt 90 ]; then
    log_message "警告: 内存使用率过高 ($MEM_USAGE%)，记录状态"
    ps aux --sort=-%mem | head -10 >> "$LOG_FILE"
fi

log_message "监控检查完成 - Xray: 运行中 | Cloudflared: 运行中"
MONITOR_EOF

chmod +x /usr/local/bin/vless_monitor.sh

# 创建 systemd service 文件
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

# 创建 systemd timer 文件 - 开机立即启动，每分钟执行
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

# 重载 systemd 并启动 timer
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
    echo "9) 停止所有服务"
    echo "10) 启动所有服务"
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
    systemctl restart xray
    systemctl restart cloudflared
    sleep 3
    echo -e "${GREEN}服务已重启${NC}"
    check_status
}

show_logs() {
    echo -e "${YELLOW}最近 50 条监控日志:${NC}"
    tail -50 /var/log/vless_monitor.log
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

stop_services() {
    echo -e "${YELLOW}正在停止服务...${NC}"
    systemctl stop xray
    systemctl stop cloudflared
    systemctl stop vless-monitor.timer
    echo -e "${GREEN}服务已停止${NC}"
}

start_services() {
    echo -e "${YELLOW}正在启动服务...${NC}"
    systemctl start xray
    systemctl start cloudflared
    systemctl start vless-monitor.timer
    sleep 3
    echo -e "${GREEN}服务已启动${NC}"
    check_status
}

while true; do
    show_menu
    read -p "请选择操作 [0-10]: " choice
    case $choice in
        1) check_status ;;
        2) restart_services ;;
        3) show_logs ;;
        4) show_argo_domain ;;
        5) show_config ;;
        6) run_monitor ;;
        7) show_timer_status ;;
        8) show_log_info ;;
        9) stop_services ;;
        10) start_services ;;
        0) echo "退出"; exit 0 ;;
        *) echo -e "${RED}无效选项${NC}" ;;
    esac
    echo ""
    read -p "按回车继续..."
done
MANAGE_EOF

chmod +x /usr/local/bin/vless_manage.sh

# 等待服务启动
sleep 5

# 获取 Argo 域名
echo -e "${YELLOW}正在获取 Argo 隧道信息...${NC}"
sleep 3

if [[ "$ARGO_CHOICE" == "1" ]]; then
    ARGO_DOMAIN=$(journalctl -u cloudflared -n 50 --no-pager | grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' | head -1 | sed 's/https:\/\///')
fi

# 运行一次监控检查
/usr/local/bin/vless_monitor.sh

# 显示配置信息
echo ""
echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}安装完成！${NC}"
echo -e "${GREEN}================================${NC}"
echo ""
echo -e "${YELLOW}VLESS 配置信息:${NC}"
echo -e "UUID: ${GREEN}${UUID}${NC}"
echo -e "端口: ${GREEN}8080${NC}"
echo -e "路径: ${GREEN}/vless${NC}"
echo -e "传输协议: ${GREEN}WebSocket${NC}"
echo ""

if [[ -n "$ARGO_DOMAIN" ]]; then
    echo -e "${YELLOW}Argo Tunnel 信息:${NC}"
    echo -e "域名: ${GREEN}${ARGO_DOMAIN}${NC}"
    echo ""
    echo -e "${YELLOW}VLESS 连接信息:${NC}"
    echo -e "${GREEN}vless://${UUID}@${ARGO_DOMAIN}:443?encryption=none&security=tls&type=ws&host=${ARGO_DOMAIN}&path=%2Fvless#ArgoVLESS${NC}"
else
    echo -e "${YELLOW}注意: 如使用固定隧道，请在 Cloudflare Dashboard 中配置${NC}"
    echo ""
    echo -e "${YELLOW}临时隧道域名获取命令:${NC}"
    echo -e "${GREEN}journalctl -u cloudflared -n 50 | grep trycloudflare.com${NC}"
fi

echo ""
echo -e "${YELLOW}自动监控已配置 (systemd timer):${NC}"
echo -e "✓ 开机 10 秒后首次运行"
echo -e "✓ 之后每 1 分钟自动检查服务状态"
echo -e "✓ 服务异常时自动重启"
echo -e "✓ 监控日志: /var/log/vless_monitor.log"
echo -e "✓ 日志自动管理: 超过 5MB 自动轮转"
echo -e "✓ 保留旧日志: 最多 2 个"
echo ""
echo -e "${YELLOW}管理命令:${NC}"
echo -e "快捷管理: ${GREEN}vless_manage.sh${NC}"
echo -e "查看 timer 状态: ${GREEN}systemctl status vless-monitor.timer${NC}"
echo -e "查看下次运行时间: ${GREEN}systemctl list-timers vless-monitor.timer${NC}"
echo -e "查看监控日志: ${GREEN}journalctl -u vless-monitor.service -f${NC}"
echo -e "手动运行监控: ${GREEN}/usr/local/bin/vless_monitor.sh${NC}"
echo -e "查看日志大小: ${GREEN}du -h /var/log/vless_monitor.log*${NC}"
echo ""
echo -e "${YELLOW}Timer 控制命令:${NC}"
echo "systemctl start vless-monitor.timer   # 启动定时器"
echo "systemctl stop vless-monitor.timer    # 停止定时器"
echo "systemctl restart vless-monitor.timer # 重启定时器"
echo ""
echo -e "${GREEN}安装脚本执行完毕！${NC}"
echo -e "${GREEN}systemd timer 监控已启动，将自动维护服务运行状态${NC}"

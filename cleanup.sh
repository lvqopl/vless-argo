#!/bin/bash

# VLESS + Argo Tunnel 完全清理脚本
# 用于清理之前安装留下的所有残余文件

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 此脚本必须以 root 权限运行${NC}" 
   exit 1
fi

echo -e "${YELLOW}================================${NC}"
echo -e "${YELLOW}VLESS + Argo Tunnel 清理工具${NC}"
echo -e "${YELLOW}================================${NC}"
echo ""
echo -e "${RED}警告: 此操作将删除所有相关文件和配置${NC}"
echo ""
read -p "确定要继续吗？(yes/no): " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    echo -e "${GREEN}已取消清理${NC}"
    exit 0
fi

echo ""
echo -e "${YELLOW}开始清理...${NC}"
echo ""

# 1. 停止所有服务
echo -e "${YELLOW}[1/9] 停止所有服务...${NC}"
systemctl stop vless-monitor.timer 2>/dev/null
systemctl stop vless-monitor.service 2>/dev/null
systemctl stop xray 2>/dev/null
systemctl stop xray@.service 2>/dev/null
systemctl stop cloudflared 2>/dev/null
echo -e "${GREEN}✓ 服务已停止${NC}"

# 2. 禁用服务自启动
echo -e "${YELLOW}[2/9] 禁用服务自启动...${NC}"
systemctl disable vless-monitor.timer 2>/dev/null
systemctl disable vless-monitor.service 2>/dev/null
systemctl disable xray 2>/dev/null
systemctl disable xray@.service 2>/dev/null
systemctl disable cloudflared 2>/dev/null
echo -e "${GREEN}✓ 已禁用自启动${NC}"

# 3. 删除 systemd 服务文件
echo -e "${YELLOW}[3/9] 删除 systemd 服务文件...${NC}"
rm -f /etc/systemd/system/vless-monitor.timer
rm -f /etc/systemd/system/vless-monitor.service
rm -f /etc/systemd/system/cloudflared.service
rm -f /etc/systemd/system/xray.service
rm -f /etc/systemd/system/xray@.service
rm -f /lib/systemd/system/xray.service
rm -f /lib/systemd/system/xray@.service
systemctl daemon-reload
echo -e "${GREEN}✓ systemd 文件已删除${NC}"

# 4. 卸载 Xray
echo -e "${YELLOW}[4/9] 卸载 Xray...${NC}"
if command -v xray &> /dev/null; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge 2>/dev/null
fi
rm -rf /usr/local/bin/xray
rm -rf /usr/local/etc/xray
rm -rf /var/log/xray
rm -rf /usr/local/share/xray
rm -rf /etc/xray
echo -e "${GREEN}✓ Xray 已卸载${NC}"

# 5. 删除 Cloudflared
echo -e "${YELLOW}[5/9] 删除 Cloudflared...${NC}"
rm -f /usr/local/bin/cloudflared
rm -rf /root/.cloudflared
rm -rf /etc/cloudflared
rm -rf /var/log/cloudflared
echo -e "${GREEN}✓ Cloudflared 已删除${NC}"

# 6. 删除脚本文件
echo -e "${YELLOW}[6/9] 删除脚本文件...${NC}"
rm -f /usr/local/bin/vless_monitor.sh
rm -f /usr/local/bin/vless_manage.sh
echo -e "${GREEN}✓ 脚本文件已删除${NC}"

# 7. 删除日志文件
echo -e "${YELLOW}[7/9] 删除日志文件...${NC}"
rm -f /var/log/vless_monitor.log*
rm -rf /var/log/xray
echo -e "${GREEN}✓ 日志文件已删除${NC}"

# 8. 删除配置和节点信息文件
echo -e "${YELLOW}[8/9] 删除配置文件...${NC}"
rm -f /root/vless_node_info.txt
rm -rf /usr/local/etc/xray
echo -e "${GREEN}✓ 配置文件已删除${NC}"

# 9. 最后检查和清理
echo -e "${YELLOW}[9/9] 最后检查和清理...${NC}"
# 检查进程
pkill -9 xray 2>/dev/null
pkill -9 cloudflared 2>/dev/null

# 再次重载 systemd
systemctl daemon-reload
systemctl reset-failed

echo -e "${GREEN}✓ 清理完成${NC}"

echo ""
echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}清理完成！${NC}"
echo -e "${GREEN}================================${NC}"
echo ""
echo -e "${YELLOW}已清理的内容：${NC}"
echo "✓ 所有 systemd 服务文件"
echo "✓ Xray 程序和配置"
echo "✓ Cloudflared 程序和配置"
echo "✓ 监控脚本和管理脚本"
echo "✓ 所有日志文件"
echo "✓ 节点信息文件"
echo "✓ 所有进程"
echo ""
echo -e "${GREEN}系统已完全清理，可以重新安装${NC}"

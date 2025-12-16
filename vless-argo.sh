#!/bin/bash

#===============================================================================================
# VLESS + Argo Tunnel Management Script for LXC Debian
#
# Description: A comprehensive script for one-click deployment and management of 
#              VLESS with Cloudflare Argo Tunnel in an LXC Debian container.
# Author:      AI Assistant
# Version:     1.0.0
# GitHub:      (Please upload to your own repository)
#===============================================================================================

# --- Color Codes ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- File and Service Paths ---
XRAY_INSTALL_DIR="/usr/local/etc/xray"
XRAY_CONFIG_FILE="${XRAY_INSTALL_DIR}/config.json"
XRAY_BINARY="/usr/local/bin/xray"
XRAY_SERVICE_FILE="/etc/systemd/system/xray.service"

CLOUDFLARED_BINARY="/usr/local/bin/cloudflared"
CLOUDFLARED_SERVICE_FILE="/etc/systemd/system/cloudflared.service"

NODE_INFO_FILE="/root/vless_node_info.txt"

# --- Global State Variables ---
INSTALLED_STATUS="not_installed"
CURRENT_UUID=""
CURRENT_DOMAIN=""
TUNNEL_MODE="" # temp or permanent

#===============================================================================================
#                              CORE HELPER FUNCTIONS
#===============================================================================================

# Check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}Error: This script must be run as root. Please use 'sudo' or 'su'.${NC}"
        exit 1
    fi
}

# Update the installation status by checking files
update_status() {
    if [ -f "$XRAY_BINARY" ] && [ -f "$CLOUDFLARED_BINARY" ] && [ -f "$NODE_INFO_FILE" ]; then
        INSTALLED_STATUS="installed"
        # Load config from info file
        CURRENT_UUID=$(grep "UUID:" "$NODE_INFO_FILE" | awk '{print $2}')
        CURRENT_DOMAIN=$(grep "Domain:" "$NODE_INFO_FILE" | awk '{print $2}')
        if grep -q "trycloudflare.com" <<< "$CURRENT_DOMAIN"; then
            TUNNEL_MODE="temp"
        else
            TUNNEL_MODE="permanent"
        fi
    else
        INSTALLED_STATUS="not_installed"
    fi
}

# Pause and wait for user to press Enter
press_any_key() {
    echo -e "\n${YELLOW}Press Enter to continue...${NC}"
    read -r
}

#===============================================================================================
#                              INSTALLATION FUNCTIONS
#===============================================================================================

# Install necessary dependencies
install_dependencies() {
    echo -e "${BLUE}Updating package lists and installing dependencies (curl, wget, unzip)...${NC}"
    apt-get update && apt-get install -y curl wget unzip > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to install dependencies.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Dependencies installed successfully.${NC}"
}

# Install Xray-core
install_xray() {
    echo -e "${BLUE}Installing Xray-core...${NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" -s install
    if [ ! -f "$XRAY_BINARY" ]; then
        echo -e "${RED}Xray installation failed.${NC}"
        exit 1
    fi
    
    # Generate UUID
    CURRENT_UUID=$($XRAY_BINARY uuid)
    
    # Create Xray config
    mkdir -p $XRAY_INSTALL_DIR
    cat > $XRAY_CONFIG_FILE <<-EOF
{
  "inbounds": [
    {
      "port": 8080,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${CURRENT_UUID}"
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

    # Create systemd service file for Xray
    cat > $XRAY_SERVICE_FILE <<-EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${XRAY_BINARY} run -config ${XRAY_CONFIG_FILE}
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF
    echo -e "${GREEN}Xray-core installed and configured successfully.${NC}"
}

# Install Cloudflared
install_cloudflared() {
    echo -e "${BLUE}Installing Cloudflared...${NC}"
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        DOWNLOAD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
    elif [ "$ARCH" = "aarch64" ]; then
        DOWNLOAD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
    else
        echo -e "${RED}Unsupported architecture: $ARCH. Only x86_64 and aarch64 are supported.${NC}"
        exit 1
    fi
    
    wget -q $DOWNLOAD_URL -O $CLOUDFLARED_BINARY
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to download Cloudflared.${NC}"
        exit 1
    fi
    
    chmod +x $CLOUDFLARED_BINARY
    echo -e "${GREEN}Cloudflared installed successfully.${NC}"
}

# Configure Tunnel (Temporary or Permanent)
configure_tunnel() {
    clear
    echo -e "${BLUE}--- Tunnel Mode Selection ---${NC}"
    echo "1. Temporary Tunnel (Easy test, domain changes on restart)"
    echo "2. Permanent Tunnel (Requires Cloudflare Token and custom domain)"
    echo -e "--------------------------------"
    read -p "Please choose a mode [1-2]: " mode_choice

    local exec_start_cmd

    if [ "$mode_choice" = "1" ]; then
        TUNNEL_MODE="temp"
        exec_start_cmd="${CLOUDFLARED_BINARY} tunnel --no-autoupdate --url http://127.0.0.1:8080"
        CURRENT_DOMAIN="pending..." # Will be fetched later
        echo -e "${GREEN}Temporary tunnel mode selected.${NC}"
    elif [ "$mode_choice" = "2" ]; then
        TUNNEL_MODE="permanent"
        read -p "Please enter your Cloudflare Argo Tunnel Token: " argo_token
        if [ -z "$argo_token" ]; then
            echo -e "${RED}Token cannot be empty. Aborting.${NC}"
            exit 1
        fi
        read -p "Please enter your custom domain (e.g., sub.yourdomain.com): " custom_domain
        if [ -z "$custom_domain" ]; then
            echo -e "${RED}Domain cannot be empty. Aborting.${NC}"
            exit 1
        fi
        CURRENT_DOMAIN=$custom_domain
        exec_start_cmd="${CLOUDFLARED_BINARY} tunnel --no-autoupdate run --token ${argo_token}"
        echo -e "${GREEN}Permanent tunnel mode selected for domain: ${CURRENT_DOMAIN}${NC}"
        echo -e "${YELLOW}Important: Make sure you have set up a CNAME record in your Cloudflare DNS for '${CURRENT_DOMAIN}' pointing to your tunnel's ID (e.g., xxxxx.cfargotunnel.com).${NC}"
    else
        echo -e "${RED}Invalid choice. Aborting.${NC}"
        exit 1
    fi

    # Create systemd service file for Cloudflared
    cat > $CLOUDFLARED_SERVICE_FILE <<-EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
User=root
Type=simple
Restart=on-failure
RestartSec=5s
ExecStart=${exec_start_cmd}

[Install]
WantedBy=multi-user.target
EOF
}

# Generate and save node connection info
generate_and_save_node_info() {
    if [ -z "$CURRENT_UUID" ] || [ -z "$CURRENT_DOMAIN" ] || [ "$CURRENT_DOMAIN" = "pending..." ]; then
        echo -e "${RED}Could not generate node info: UUID or Domain is missing.${NC}"
        return 1
    fi

    local standard_link="vless://${CURRENT_UUID}@${CURRENT_DOMAIN}:443?encryption=none&security=tls&type=ws&host=${CURRENT_DOMAIN}&path=%2Fvless#VLESS"
    local preferred_link="vless://${CURRENT_UUID}@cf.877774.xyz:443?encryption=none&security=tls&sni=${CURRENT_DOMAIN}&fp=chrome&alpn=h3,h2,http/1.1&type=ws&host=${CURRENT_DOMAIN}&path=%2Fvless#VLESS-优选"
    
    cat > $NODE_INFO_FILE <<-EOF
# ===============================================================
#          VLESS + Argo Tunnel Node Information
# ===============================================================

Mode:             ${TUNNEL_MODE} Tunnel
Domain:           ${CURRENT_DOMAIN}
UUID:             ${CURRENT_UUID}
Port:             443
Path:             /vless
Security:         tls
Network:          ws

# --- Standard Connection Link ---
${standard_link}

# --- Preferred IP Connection Link (Recommended) ---
${preferred_link}

# ===============================================================
#          Client Configuration Parameters
# ===============================================================
Address:          ${CURRENT_DOMAIN} (or cf.877774.xyz for preferred)
Port:             443
UUID:             ${CURRENT_UUID}
AlterId:          0
Security:         none
Network:          ws
WS Host:          ${CURRENT_DOMAIN}
WS Path:          /vless
TLS:              On
SNI:              ${CURRENT_DOMAIN}
Fingerprint:      chrome
ALPN:             h3,h2,http/1.1
EOF

    echo -e "${GREEN}Node information has been saved to ${NODE_INFO_FILE}${NC}"
}

# Full installation process
do_install() {
    install_dependencies
    install_xray
    install_cloudflared
    configure_tunnel
    
    echo -e "${BLUE}Enabling and starting services...${NC}"
    systemctl daemon-reload
    systemctl enable xray > /dev/null 2>&1
    systemctl enable cloudflared > /dev/null 2>&1
    systemctl start xray
    systemctl start cloudflared
    
    # If temp mode, fetch the domain
    if [ "$TUNNEL_MODE" = "temp" ]; then
        echo -e "${YELLOW}Waiting for temporary tunnel to establish...${NC}"
        sleep 10
        fetch_temp_domain
        if [ "$CURRENT_DOMAIN" = "not_found" ]; then
            echo -e "${RED}Failed to get temporary domain. Please check Cloudflared logs.${NC}"
            press_any_key
            return
        fi
    fi
    
    generate_and_save_node_info
    echo -e "\n${GREEN}Installation complete!${NC}"
    view_node_info
}

#===============================================================================================
#                              MANAGEMENT FUNCTIONS
#===============================================================================================

# Start, stop, restart services
manage_services() {
    local action=$1
    echo -e "${BLUE}${action^}ing services (Xray and Cloudflared)...${NC}"
    systemctl ${action} xray
    systemctl ${action} cloudflared
    echo -e "${GREEN}Services ${action}ed.${NC}"
    if [ "$action" = "restart" ] || [ "$action" = "start" ]; then
        if [ "$TUNNEL_MODE" = "temp" ]; then
            echo -e "${YELLOW}Temporary tunnel mode detected. The domain may have changed.${NC}"
            echo -e "${YELLOW}Checking for new domain in 10 seconds...${NC}"
            sleep 10
            fetch_temp_domain
            generate_and_save_node_info
            echo -e "${BLUE}New domain is: ${CURRENT_DOMAIN}${NC}"
        fi
    fi
    press_any_key
}

# Check service status
check_status() {
    echo -e "${BLUE}--- Xray Service Status ---${NC}"
    systemctl status xray --no-pager
    echo -e "\n${BLUE}--- Cloudflared Service Status ---${NC}"
    systemctl status cloudflared --no-pager
    press_any_key
}

# View node info
view_node_info() {
    if [ -f "$NODE_INFO_FILE" ]; then
        clear
        echo -e "${GREEN}"
        cat "$NODE_INFO_FILE"
        echo -e "${NC}"
    else
        echo -e "${RED}Node info file not found.${NC}"
    fi
    press_any_key
}

# Fetch temporary Argo domain from logs
fetch_temp_domain() {
    echo -e "${BLUE}Fetching temporary domain from logs...${NC}"
    # Retry loop to get the domain
    for i in {1..5}; do
        domain=$(journalctl -u cloudflared.service --since "5 minutes ago" | grep -o 'https://[a-z0-9-]*\.trycloudflare.com' | tail -n 1 | sed 's/https:\/\///')
        if [ -n "$domain" ]; then
            CURRENT_DOMAIN=$domain
            echo -e "${GREEN}Found domain: ${CURRENT_DOMAIN}${NC}"
            return 0
        fi
        sleep 2
    done
    CURRENT_DOMAIN="not_found"
    return 1
}

# View temporary domain
view_temp_domain() {
    if [ "$TUNNEL_MODE" != "temp" ]; then
        echo -e "${YELLOW}This function is only for temporary tunnel mode.${NC}"
        press_any_key
        return
    fi
    fetch_temp_domain
    if [ "$CURRENT_DOMAIN" != "not_found" ]; then
        echo -e "${GREEN}Current temporary domain: ${CURRENT_DOMAIN}${NC}"
        # Check if domain has changed and offer to update
        local old_domain=$(grep "Domain:" "$NODE_INFO_FILE" | awk '{print $2}')
        if [ "$old_domain" != "$CURRENT_DOMAIN" ]; then
            echo -e "${YELLOW}The domain has changed from ${old_domain}.${NC}"
            read -p "Do you want to update the node info file? [y/N]: " confirm
            if [[ "$confirm" =~ ^[yY]$ ]]; then
                generate_and_save_node_info
            fi
        fi
    else
        echo -e "${RED}Could not find the temporary domain in recent logs.${NC}"
    fi
    press_any_key
}

# View logs
view_logs() {
    local service_name=$1
    echo -e "${BLUE}Showing logs for ${service_name}. Press Ctrl+C to exit.${NC}"
    sleep 1
    journalctl -u "${service_name}" -f --no-pager
    press_any_key
}

#===============================================================================================
#                              MODIFICATION FUNCTIONS
#===============================================================================================

# Modify UUID
modify_uuid() {
    echo -e "${BLUE}Generating new UUID...${NC}"
    CURRENT_UUID=$($XRAY_BINARY uuid)
    
    # Use sed to update the config file
    sed -i "s/\"id\": \".*\"/\"id\": \"${CURRENT_UUID}\"/" $XRAY_CONFIG_FILE
    
    echo -e "${GREEN}New UUID: ${CURRENT_UUID}${NC}"
    echo -e "${BLUE}Restarting Xray service to apply changes...${NC}"
    systemctl restart xray
    
    echo -e "${BLUE}Updating node information file...${NC}"
    generate_and_save_node_info
    
    echo -e "${GREEN}UUID changed and node info updated successfully!${NC}"
    press_any_key
}

# Switch to or reconfigure permanent tunnel
modify_permanent_tunnel() {
    echo -e "${BLUE}--- Reconfiguring Permanent Tunnel ---${NC}"
    read -p "Please enter your new Cloudflare Argo Tunnel Token: " argo_token
    if [ -z "$argo_token" ]; then
        echo -e "${RED}Token cannot be empty. Aborting.${NC}"
        press_any_key
        return
    fi
    read -p "Please enter your new custom domain: " custom_domain
    if [ -z "$custom_domain" ]; then
        echo -e "${RED}Domain cannot be empty. Aborting.${NC}"
        press_any_key
        return
    fi
    
    CURRENT_DOMAIN=$custom_domain
    TUNNEL_MODE="permanent"
    
    # Update cloudflared service
    local exec_start_cmd="${CLOUDFLARED_BINARY} tunnel --no-autoupdate run --token ${argo_token}"
    sed -i "/^ExecStart=/c\ExecStart=${exec_start_cmd}" $CLOUDFLARED_SERVICE_FILE
    
    systemctl daemon-reload
    systemctl restart cloudflared
    
    echo -e "${BLUE}Updating node information...${NC}"
    generate_and_save_node_info
    
    echo -e "${GREEN}Switched to permanent tunnel mode successfully!${NC}"
    press_any_key
}

# Switch to temporary tunnel
switch_to_temp_tunnel() {
    echo -e "${BLUE}--- Switching to Temporary Tunnel ---${NC}"
    
    # Update cloudflared service
    local exec_start_cmd="${CLOUDFLARED_BINARY} tunnel --no-autoupdate --url http://127.0.0.1:8080"
    sed -i "/^ExecStart=/c\ExecStart=${exec_start_cmd}" $CLOUDFLARED_SERVICE_FILE
    
    systemctl daemon-reload
    systemctl restart cloudflared
    
    TUNNEL_MODE="temp"
    
    echo -e "${YELLOW}Waiting for temporary tunnel to establish...${NC}"
    sleep 10
    fetch_temp_domain
    if [ "$CURRENT_DOMAIN" = "not_found" ]; then
        echo -e "${RED}Failed to get temporary domain. Please check Cloudflared logs.${NC}"
        press_any_key
        return
    fi
    
    generate_and_save_node_info
    echo -e "${GREEN}Switched to temporary tunnel mode successfully!${NC}"
    press_any_key
}

#===============================================================================================
#                              UNINSTALL FUNCTION
#===============================================================================================

do_uninstall() {
    clear
    echo -e "${RED}!!! WARNING !!!${NC}"
    echo -e "${YELLOW}This will completely remove Xray, Cloudflared, and all related configuration files.${NC}"
    read -p "Are you sure you want to uninstall? [y/N]: " confirm
    
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        echo -e "${BLUE}Stopping services...${NC}"
        systemctl stop xray
        systemctl stop cloudflared
        systemctl disable xray > /dev/null 2>&1
        systemctl disable cloudflared > /dev/null 2>&1
        
        echo -e "${BLUE}Removing service files...${NC}"
        rm -f $XRAY_SERVICE_FILE
        rm -f $CLOUDFLARED_SERVICE_FILE
        systemctl daemon-reload
        
        echo -e "${BLUE}Removing Xray...${NC}"
        # Use official uninstall script
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" -s uninstall --remove
        rm -rf $XRAY_INSTALL_DIR # Ensure config dir is gone
        
        echo -e "${BLUE}Removing Cloudflared...${NC}"
        rm -f $CLOUDFLARED_BINARY
        
        echo -e "${BLUE}Cleaning up node info file...${NC}"
        rm -f $NODE_INFO_FILE
        
        echo -e "\n${GREEN}Uninstallation complete.${NC}"
    else
        echo -e "${GREEN}Uninstallation cancelled.${NC}"
    fi
    press_any_key
}


#===============================================================================================
#                                  MENU UI
#===============================================================================================

# --- Sub Menus ---
show_service_menu() {
    clear
    echo -e "${BLUE}--- Service Management ---${NC}"
    echo "1. Check Service Status"
    echo "2. Start Services"
    echo "3. Stop Services"
    echo "4. Restart Services"
    echo "0. Back to Main Menu"
    echo "--------------------------"
    read -p "Enter your choice: " choice
    case $choice in
        1) check_status ;;
        2) manage_services "start" ;;
        3) manage_services "stop" ;;
        4) manage_services "restart" ;;
        0) return ;;
        *) echo -e "${RED}Invalid choice.${NC}" && press_any_key ;;
    esac
}

show_log_menu() {
    clear
    echo -e "${BLUE}--- View Logs ---${NC}"
    echo "1. View Xray Log"
    echo "2. View Cloudflared Log"
    echo "0. Back to Main Menu"
    echo "---------------------"
    read -p "Enter your choice: " choice
    case $choice in
        1) view_logs "xray" ;;
        2) view_logs "cloudflared" ;;
        0) return ;;
        *) echo -e "${RED}Invalid choice.${NC}" && press_any_key ;;
    esac
}

show_modify_menu() {
    clear
    echo -e "${BLUE}--- Modify Configuration ---${NC}"
    echo "1. Modify UUID"
    echo "2. Reconfigure/Switch to Permanent Tunnel"
    echo "3. Switch to Temporary Tunnel"
    echo "0. Back to Main Menu"
    echo "----------------------------"
    read -p "Enter your choice: " choice
    case $choice in
        1) modify_uuid ;;
        2) modify_permanent_tunnel ;;
        3) switch_to_temp_tunnel ;;
        0) return ;;
        *) echo -e "${RED}Invalid choice.${NC}" && press_any_key ;;
    esac
}

# --- Main Menu ---
show_main_menu() {
    clear
    update_status
    echo "======================================================"
    echo "    VLESS + Argo Tunnel Management Script v1.0.0    "
    echo "======================================================"
    if [ "$INSTALLED_STATUS" = "installed" ]; then
        echo -e "Status: ${GREEN}Installed${NC} | Mode: ${YELLOW}${TUNNEL_MODE^}${NC} | Domain: ${YELLOW}${CURRENT_DOMAIN}${NC}"
        echo "------------------------------------------------------"
        echo "1. View Node Info"
        echo "2. Service Management"
        echo "3. Information & Logs"
        echo "4. Modify Configuration"
        echo "5. View Temporary Argo Domain (if applicable)"
        echo " "
        echo "9. Uninstall"
        echo "0. Exit"
        echo "------------------------------------------------------"
    else
        echo -e "Status: ${RED}Not Installed${NC}"
        echo "------------------------------------------------------"
        echo "1. Install VLESS + Argo Tunnel"
        echo "0. Exit"
        echo "------------------------------------------------------"
    fi
}

#===============================================================================================
#                                 MAIN SCRIPT LOGIC
#===============================================================================================

# --- Entry Point ---
main() {
    check_root
    while true; do
        show_main_menu
        read -p "Enter your choice: " choice
        
        if [ "$INSTALLED_STATUS" = "installed" ]; then
            case $choice in
                1) view_node_info ;;
                2) show_service_menu ;;
                3) show_log_menu ;;
                4) show_modify_menu ;;
                5) view_temp_domain ;;
                9) do_uninstall ;;
                0) break ;;
                *) echo -e "${RED}Invalid choice.${NC}" && press_any_key ;;
            esac
        else
            case $choice in
                1) do_install ;;
                0) break ;;
                *) echo -e "${RED}Invalid choice.${NC}" && press_any_key ;;
            esac
        fi
    done
    
    echo -e "${GREEN}Goodbye!${NC}"
}

# Run the main function
main

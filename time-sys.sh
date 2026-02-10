#!/bin/bash

#===============================================================================================
#
#          FILE: setup_time.sh
#         USAGE: sudo ./setup_time.sh
#   DESCRIPTION: 多功能时间同步脚本 (针对 DNS 故障与跨境网络优化版)
#        AUTHOR: Gemini AI
#       VERSION: 2.4
#      REVISION: 1. 增加 DNS 解析自动检测与修复建议；
#                2. 增加强制超时控制 (timeout) 防止脚本卡死；
#                3. 加入固定 IP 同步作为 DNS 失效时的保底方案。
#
#===============================================================================================

# --- 全局变量 ---
TIMEZONE="Asia/Hong_Kong"
CHRONY_CONF=""
declare -a NTP_SERVERS

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 函数定义 ---

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}错误：此脚本必须以 root 权限运行。${NC}"
        exit 1
    fi
}

# 新增：DNS 环境自动检测
check_dns_health() {
    echo -e "${YELLOW}正在检测网络环境...${NC}"
    if ! host google.com &>/dev/null && ! nslookup google.com &>/dev/null; then
        echo -e "${RED}[错误] 检测到 DNS 解析失效！这会导致无法连接 NTP 服务器。${NC}"
        read -p "是否尝试自动修复 DNS 配置 (/etc/resolv.conf)? [y/n]: " fix_dns
        if [[ "$fix_dns" == "y" ]]; then
            echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf
            echo -e "${GREEN}DNS 已更新为 8.8.8.8 和 1.1.1.1${NC}"
        else
            echo -e "${YELLOW}请注意：如果 DNS 不通，脚本将尝试使用固定 IP 同步。${NC}"
        fi
    fi
}

find_chrony_conf() {
    [ -n "$CHRONY_CONF" ] && return
    local locations=("/etc/chrony/chrony.conf" "/etc/chrony.conf")
    for loc in "${locations[@]}"; do
        if [ -f "$loc" ]; then CHRONY_CONF="$loc"; return; fi
    done
    CHRONY_CONF="/etc/chrony.conf"
}

install_deps() {
    if ! command -v chronyc &> /dev/null; then
        echo -e "${YELLOW}正在安装依赖 chrony...${NC}"
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y chrony dnsutils
        elif command -v dnf &> /dev/null; then
            dnf install -y chrony bind-utils
        elif command -v yum &> /dev/null; then
            yum install -y chrony bind-utils
        fi
    fi
}

select_ntp_source() {
    while true; do
        clear
        echo "================================================"
        echo "      NTP 时间同步工具 v2.4 (DNS 容错版)"
        echo "================================================"
        echo -e "  ${CYAN}1. 香港天文台 (HK)${NC}"
        echo -e "  ${CYAN}2. 台湾标准时间 (TW)${NC}"
        echo -e "  ${CYAN}3. 日本 NICT (JP)${NC}"
        echo -e "  ${CYAN}4. 美国西部 (US West - Cloudflare/AWS)${NC}"
        echo -e "  ${CYAN}5. 欧洲中部 (EU Central)${NC}"
        echo -e "  ${RED}0. 返回主菜单${NC}"
        echo "================================================"
        read -p "请输入选项 [1-5, 0]: " choice

        case $choice in
            1) NTP_SERVERS=("stdtime.gov.hk" "time.hko.hk" "118.143.17.82"); return 0 ;;
            2) NTP_SERVERS=("tock.stdtime.gov.tw" "time.stdtime.gov.tw" "118.163.81.1"); return 0 ;;
            3) NTP_SERVERS=("ntp.nict.jp" "time.google.com" "133.243.238.243"); return 0 ;;
            4) NTP_SERVERS=("162.159.200.1" "us-west.pool.ntp.org" "time.aws.com"); return 0 ;; # 优先使用 IP
            5) NTP_SERVERS=("de.pool.ntp.org" "162.159.200.1" "212.18.3.19"); return 0 ;;
            0) return 1 ;;
            *) echo -e "${RED}无效输入${NC}"; sleep 1 ;;
        esac
    done
}

sync_now() {
    check_dns_health
    if ! select_ntp_source; then return; fi
    
    echo -e "\n${YELLOW}--- 正在同步时间 (带 15s 超时保护)... ---${NC}"
    systemctl stop chronyd 2>/dev/null
    
    local success=false
    for server in "${NTP_SERVERS[@]}"; do
        echo -ne "连接尝试: ${CYAN}$server${NC} ... "
        
        # 使用 timeout 防止 DNS 查找或网络握手卡死
        if timeout 15 chronyd -q "server $server iburst" &>/dev/null; then
            echo -e "${GREEN}[成功]${NC}"
            success=true
            hwclock -w 2>/dev/null
            break
        else
            echo -e "${RED}[失败/超时]${NC}"
        fi
    done

    if [ "$success" = false ]; then
        echo -e "${RED}所有预设源均不可用。尝试最后的全球公共 IP 兜底...${NC}"
        timeout 15 chronyd -q "server 1.1.1.1 iburst" && success=true
    fi
    
    systemctl start chronyd 2>/dev/null
    echo -e "\n当前系统时间: ${GREEN}$(date)${NC}"
}

setup_background_sync() {
    if ! select_ntp_source; then return; fi
    find_chrony_conf
    
    echo -e "\n${YELLOW}--- 正在配置后台守护进程 ---${NC}"
    cp "$CHRONY_CONF" "$CHRONY_CONF.bak.$(date +%H%M%S)"
    
    sed -i 's/^\(server .*\)/#\1/' "$CHRONY_CONF"
    sed -i 's/^\(pool .*\)/#\1/' "$CHRONY_CONF"
    sed -i '/# BEGIN SETUP_TIME_SH/,/# END SETUP_TIME_SH/d' "$CHRONY_CONF"

    {
        echo "# BEGIN SETUP_TIME_SH"
        echo "# Added on $(date +'%Y-%m-%d %H:%M')"
        for server in "${NTP_SERVERS[@]}"; do
            echo "server $server iburst"
        done
        # 即使 DNS 挂了，后台也会尝试这个 IP
        echo "server 1.1.1.1 iburst" 
        echo "# END SETUP_TIME_SH"
    } >> "$CHRONY_CONF"

    systemctl restart chronyd
    systemctl enable chronyd &>/dev/null
    echo -e "${GREEN}后台同步已开启！${NC}"
}

show_status() {
    echo -e "\n${YELLOW}--- 系统时间状态 ---${NC}"
    timedatectl
    echo "----------------------------------------"
    if systemctl is-active --quiet chronyd; then
        chronyc sources -v
    else
        echo -e "${RED}警告: Chrony 服务未运行。${NC}"
    fi
}

main_menu() {
    while true; do
        clear
        echo "================================================"
        echo "      NTP 时间同步与时区工具 v2.4"
        echo "================================================"
        echo -e "  ${GREEN}1. 设置时区为 香港 (Asia/Hong_Kong)${NC}"
        echo -e "  ${GREEN}2. 立即手动同步 (一次性校准)${NC}"
        echo -e "  ${GREEN}3. 开启后台持久同步 (推荐)${NC}"
        echo -e "  ${GREEN}4. 查看当前同步状态${NC}"
        echo -e "  ${RED}0. 退出${NC}"
        echo "================================================"
        read -p "请选择 [1-4, 0]: " choice

        case $choice in
            1) timedatectl set-timezone "$TIMEZONE"; echo -e "${GREEN}时区已设为香港${NC}"; sleep 1 ;;
            2) sync_now ;;
            3) setup_background_sync ;;
            4) show_status ;;
            0) exit 0 ;;
        esac
        echo -e "\n按任意键继续..."
        read -n 1 -s
    done
}

check_root
install_deps
main_menu

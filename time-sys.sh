#!/bin/bash

#===============================================================================================
#
#          FILE: setup_time.sh
#         USAGE: sudo ./setup_time.sh
#   DESCRIPTION: 多功能时间同步脚本。支持时区设置与多国 NTP 源切换。
#        AUTHOR: Gemini AI
#       VERSION: 2.2
#      REVISION: 1. 增加美西、欧中 NTP 源；2. 优化 chrony 配置清理逻辑；3. 增强同步健壮性。
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

find_chrony_conf() {
    [ -n "$CHRONY_CONF" ] && return
    local locations=("/etc/chrony/chrony.conf" "/etc/chrony.conf")
    for loc in "${locations[@]}"; do
        if [ -f "$loc" ]; then CHRONY_CONF="$loc"; return; fi
    done
    CHRONY_CONF="/etc/chrony.conf" # 兜底路径
}

install_deps() {
    if ! command -v chronyc &> /dev/null; then
        echo -e "${YELLOW}未找到 chrony，正在安装...${NC}"
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y chrony
        elif command -v dnf &> /dev/null; then
            dnf install -y chrony
        elif command -v yum &> /dev/null; then
            yum install -y chrony
        fi
    fi
}

select_ntp_source() {
    while true; do
        clear
        echo "================================================"
        echo "           请选择 NTP 服务器源 (v2.2)"
        echo "================================================"
        echo -e "  ${CYAN}1. 香港天文台 (HK)${NC}"
        echo -e "  ${CYAN}2. 台湾标准时间 (TW)${NC}"
        echo -e "  ${CYAN}3. 日本 NICT (JP)${NC}"
        echo -e "  ${CYAN}4. 美国西部 (US West - Oregon/California)${NC}"
        echo -e "  ${CYAN}5. 欧洲中部 (EU Central - Germany/Frankfurt)${NC}"
        echo -e "  ${RED}0. 返回主菜单${NC}"
        echo "================================================"
        read -p "请输入选项 [1-5, 0]: " choice

        case $choice in
            1) NTP_SERVERS=("stdtime.gov.hk" "time.hko.hk"); return 0 ;;
            2) NTP_SERVERS=("tock.stdtime.gov.tw" "time.stdtime.gov.tw"); return 0 ;;
            3) NTP_SERVERS=("ntp.nict.jp" "time.google.com"); return 0 ;;
            4) NTP_SERVERS=("us-west.pool.ntp.org" "time.aws.com" "time1.google.com"); return 0 ;;
            5) NTP_SERVERS=("de.pool.ntp.org" "eu-central-1.pool.ntp.org" "time.euro.apple.com"); return 0 ;;
            0) return 1 ;;
            *) echo -e "${RED}无效输入${NC}"; sleep 1 ;;
        esac
    done
}

set_timezone() {
    echo -e "\n${YELLOW}--- 正在设置时区为: $TIMEZONE ---${NC}"
    timedatectl set-timezone "$TIMEZONE"
    timedatectl
}

sync_now() {
    if ! select_ntp_source; then return; fi
    echo -e "\n${YELLOW}--- 正在强制同步时间... ---${NC}"
    
    systemctl stop chronyd 2>/dev/null
    
    # 优先使用 chronyd 的单次同步模式 (-q)
    if command -v chronyd &> /dev/null; then
        chronyd -q "server ${NTP_SERVERS[0]} iburst"
    elif command -v ntpdate &> /dev/null; then
        ntpdate -u "${NTP_SERVERS[0]}"
    fi

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}同步成功！${NC}"
        hwclock -w 2>/dev/null
    else
        echo -e "${RED}同步失败，请检查网络连接。${NC}"
    fi
    
    systemctl start chronyd 2>/dev/null
    date
}

setup_background_sync() {
    if ! select_ntp_source; then return; fi
    find_chrony_conf
    
    echo -e "\n${YELLOW}--- 正在配置后台同步 (Chrony) ---${NC}"
    
    # 备份
    cp "$CHRONY_CONF" "$CHRONY_CONF.bak.$(date +%H%M%S)"
    
    # 1. 注释掉原有的 server/pool 配置
    sed -i 's/^\(server .*\)/#\1/' "$CHRONY_CONF"
    sed -i 's/^\(pool .*\)/#\1/' "$CHRONY_CONF"
    
    # 2. 使用标记块清理旧的脚本配置，防止重复堆积
    sed -i '/# BEGIN SETUP_TIME_SH/,/# END SETUP_TIME_SH/d' "$CHRONY_CONF"

    # 3. 写入新配置
    {
        echo "# BEGIN SETUP_TIME_SH"
        echo "# Added by script on $(date +'%Y-%m-%d %H:%M')"
        for server in "${NTP_SERVERS[@]}"; do
            echo "server $server iburst"
        done
        echo "# END SETUP_TIME_SH"
    } >> "$CHRONY_CONF"

    systemctl restart chronyd
    systemctl enable chronyd &>/dev/null
    
    echo -e "${GREEN}配置已更新。正在检查同步状态...${NC}"
    sleep 3
    chronyc sources
}

show_status() {
    echo -e "\n${YELLOW}--- 当前系统状态 ---${NC}"
    timedatectl
    echo "----------------------------------------"
    if systemctl is-active --quiet chronyd; then
        chronyc sources -v
    else
        echo "警告: Chrony 服务未在运行。"
    fi
}

main_menu() {
    while true; do
        clear
        echo "================================================"
        echo "      NTP 时间同步与时区工具 v2.2"
        echo "================================================"
        echo -e "  ${GREEN}1. 设置时区为 香港${NC}"
        echo -e "  ${GREEN}2. 立即手动同步 (One-shot)${NC}"
        echo -e "  ${GREEN}3. 开启后台持久同步 (Daemon)${NC}"
        echo -e "  ${GREEN}4. 查看当前同步状态${NC}"
        echo -e "  ${RED}0. 退出${NC}"
        echo "================================================"
        read -p "请选择 [1-4, 0]: " choice

        case $choice in
            1) set_timezone ;;
            2) sync_now ;;
            3) setup_background_sync ;;
            4) show_status ;;
            0) exit 0 ;;
        esac
        echo -e "\n按任意键继续..."
        read -n 1 -s
    done
}

# --- 执行 ---
check_root
install_deps
main_menu

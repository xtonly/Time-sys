#!/bin/bash

#===============================================================================================
#
#          FILE: setup_time.sh
#
#         USAGE: sudo ./setup_time.sh
#
#   DESCRIPTION: 一个多功能时间同步脚本。可设置时区为香港，并允许用户从多个
#                国家/地区的NTP服务器源中进行选择。
#
#       OPTIONS: ---
#  REQUIREMENTS: ---
#          BUGS: ---
#         NOTES: ---
#        AUTHOR: Gemini AI
#       VERSION: 2.1
#       CREATED: 2025-09-27
#      REVISION: 新增两组日本NTP服务器源 (NICT, NAOJ)。
#
#===============================================================================================

# --- 全局变量 ---
TIMEZONE="Asia/Hong_Kong"
CHRONY_CONF="" # 将在此处动态查找路径
declare -a NTP_SERVERS # 声明为数组，将在选择后填充

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- 函数定义 ---

# 检查脚本是否以root权限运行
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}错误：此脚本必须以 root 权限运行。${NC}"
        echo -e "${YELLOW}请尝试使用 'sudo ./setup_time.sh'${NC}"
        exit 1
    fi
}

# 动态查找 chrony 配置文件
find_chrony_conf() {
    if [ -n "$CHRONY_CONF" ]; then return; fi
    local locations=("/etc/chrony/chrony.conf" "/etc/chrony.conf")
    for loc in "${locations[@]}"; do
        if [ -f "$loc" ]; then CHRONY_CONF="$loc"; return; fi
    done
    echo -e "${YELLOW}在标准位置未找到配置文件，正在搜索 /etc ...${NC}"
    local found_path=$(find /etc -name "chrony.conf" 2>/dev/null | head -n 1)
    if [ -n "$found_path" ]; then
        CHRONY_CONF="$found_path"
        echo -e "${GREEN}成功找到配置文件: $CHRONY_CONF${NC}"; sleep 1
    fi
}

# 检查并安装依赖
install_deps() {
    if ! command -v chronyc &> /dev/null; then
        echo -e "${YELLOW}未找到 chrony，正在尝试安装...${NC}"
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y chrony
        elif command -v dnf &> /dev/null; then
            dnf install -y chrony
        elif command -v yum &> /dev/null; then
            yum install -y chrony
        else
            echo -e "${RED}无法确定包管理器，请手动安装 chrony。${NC}"; exit 1
        fi
        if ! command -v chronyc &> /dev/null; then
             echo -e "${RED}chrony 安装失败！${NC}"; exit 1
        fi
    fi
    echo -e "${GREEN}依赖工具 'chrony' 已准备就绪。${NC}"
}

# 菜单：选择NTP服务器源
select_ntp_source() {
    while true; do
        clear
        echo "================================================"
        echo "          请选择要使用的NTP服务器源"
        echo "================================================"
        echo -e "  ${CYAN}1. 香港天文台${NC}"
        echo -e "  ${CYAN}2. 台湾国家时间与频率标准实验室${NC}"
        echo -e "  ${CYAN}3. 日本信息通信研究所 (NICT)${NC}"
        echo -e "  ${CYAN}4. 日本国立天文台水沢 (NAOJ)${NC}"
        echo -e "  ${RED}0. 返回主菜单${NC}"
        echo "================================================"
        read -p "请输入选项 [1-4, 0]: " choice

        case $choice in
            1)
                NTP_SERVERS=("stdtime.gov.hk" "time.hko.hk")
                return 0
                ;;
            2)
                NTP_SERVERS=("tock.stdtime.gov.tw" "watch.stdtime.gov.tw" "time.stdtime.gov.tw" "clock.stdtime.gov.tw")
                return 0
                ;;
            3)
                NTP_SERVERS=("ntp.nict.jp")
                return 0
                ;;
            4)
                NTP_SERVERS=("s2csntp.miz.nao.ac.jp")
                return 0
                ;;
            0)
                return 1 # 用户取消
                ;;
            *)
                echo -e "${RED}无效输入，请输入有效选项。${NC}"; sleep 2
                ;;
        esac
    done
}

# 1. 设置系统时区为香港
set_timezone() {
    echo -e "\n${YELLOW}--- 1. 正在设置时区为: $TIMEZONE ---${NC}"
    timedatectl set-timezone "$TIMEZONE"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}时区设置成功！${NC}"; timedatectl
    else
        echo -e "${RED}时区设置失败！${NC}"
    fi
}

# 2. 立即手动同步时间
sync_now() {
    if ! select_ntp_source; then echo -e "${YELLOW}操作已取消。${NC}"; return; fi

    echo -e "\n${YELLOW}--- 2. 正在手动同步时间... ---${NC}"
    echo "使用服务器: ${NTP_SERVERS[0]}"

    systemctl stop chronyd 2>/dev/null; systemctl stop ntpd 2>/dev/null

    if command -v ntpdate &> /dev/null; then
        ntpdate -u "${NTP_SERVERS[0]}"
    else
        echo "未找到 ntpdate, 使用 chronyd 进行一次性同步..."
        chronyd -q "server ${NTP_SERVERS[0]} iburst"
    fi

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}时间同步成功！${NC}"
    else
        echo -e "${RED}时间同步失败！请检查网络或服务器地址。${NC}"
    fi

    if systemctl is-active --quiet chronyd; then systemctl start chronyd; fi
    
    if command -v hwclock &> /dev/null; then
        hwclock -w; echo "系统时间已写入硬件时钟。"
    else
        echo -e "${YELLOW}提示: 'hwclock' 命令未找到，跳过此步骤。${NC}"
    fi
    echo "当前时间: $(date)"
}

# 3. 设置并开启后台自动同步
setup_background_sync() {
    if ! select_ntp_source; then echo -e "${YELLOW}操作已取消。${NC}"; return; fi
    
    find_chrony_conf
    if [ -z "$CHRONY_CONF" ]; then
        echo -e "${RED}错误：无法自动定位 chrony 配置文件。${NC}"; return 1
    fi

    echo -e "\n${YELLOW}--- 3. 正在配置后台自动同步服务 (chrony)... ---${NC}"
    echo "使用配置文件: $CHRONY_CONF"
    
    cp "$CHRONY_CONF" "$CHRONY_CONF.bak.$(date +%F-%H%M%S)"
    echo "配置文件已备份到: $CHRONY_CONF.bak.$(date +%F-%H%M%S)"

    sed -i -e 's/^\(server .*\)/#\1/g' -e 's/^\(pool .*\)/#\1/g' "$CHRONY_CONF"
    echo "已注释掉默认的服务器配置。"

    # 清理所有之前由本脚本添加的配置
    sed -i -e '/# Added by setup_time.sh/d' \
           -e '/stdtime.gov.hk/d' \
           -e '/time.hko.hk/d' \
           -e '/stdtime.gov.tw/d' \
           -e '/ntp.nict.jp/d' \
           -e '/s2csntp.miz.nao.ac.jp/d' "$CHRONY_CONF"
    echo "已清理旧的脚本配置。"
    
    # 添加新的服务器配置
    {
        echo ""
        echo "# Added by setup_time.sh"
        for server in "${NTP_SERVERS[@]}"; do
            echo "server $server iburst"
        done
    } >> "$CHRONY_CONF"
    echo -e "${GREEN}已将您选择的NTP服务器添加到配置文件。${NC}"

    echo "正在重启并设置 chrony 服务开机自启..."
    systemctl restart chronyd
    systemctl enable chronyd &>/dev/null

    if systemctl is-active --quiet chronyd; then
        echo -e "${GREEN}chrony 后台同步服务已成功配置并启动！${NC}"
        echo "等待几秒钟让服务稳定..."
        sleep 5; chronyc sources
    else
        echo -e "${RED}chrony 服务启动失败！请使用 'systemctl status chronyd' 查看详情。${NC}"
    fi
}

# 4. 显示当前时间和同步状态
show_status() {
    echo -e "\n${YELLOW}--- 4. 当前系统时间和NTP状态 ---${NC}"
    timedatectl
    echo "----------------------------------------"
    if command -v chronyc &> /dev/null && systemctl is-active --quiet chronyd; then
      echo "Chrony 同步源状态:"
      chronyc sources
    else
      echo "Chrony 服务未运行或未安装。"
    fi
    echo -e "${GREEN}检查完毕。${NC}"
}

# --- 主菜单 ---
main_menu() {
    while true; do
        clear
        echo "================================================"
        echo "      NTP 时间同步与时区设置工具 (v2.1)"
        echo "================================================"
        echo -e "请选择操作:"
        echo -e "  ${GREEN}1. 设置时区为 香港 (Asia/Hong_Kong)${NC}"
        echo -e "  ${GREEN}2. [手动] 同步一次时间 (需选择服务器)${NC}"
        echo -e "  ${GREEN}3. [自动] 设置后台同步服务 (需选择服务器)${NC}"
        echo -e "  ${GREEN}4. 查看当前状态${NC}"
        echo -e "  ${RED}0. 退出脚本${NC}"
        echo "================================================"
        read -p "请输入选项 [1-4, 0]: " choice

        case $choice in
            1) set_timezone ;;
            2) sync_now ;;
            3) setup_background_sync ;;
            4) show_status ;;
            0) echo "退出脚本。"; exit 0 ;;
            *) echo -e "${RED}无效输入，请输入有效选项。${NC}"; sleep 2 ;;
        esac
        echo -e "\n按任意键返回主菜单..."
        read -n 1 -s
    done
}

# --- 脚本主程序 ---
check_root
install_deps
main_menu

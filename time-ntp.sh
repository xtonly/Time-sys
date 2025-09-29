
#!/bin/bash

#===============================================================================================
#
#          FILE: setup_time.sh
#
#         USAGE: sudo ./setup_time.sh
#
#   DESCRIPTION: 一个用于设置时区为香港、配置阿里云NTP服务器并同步时间的自动化脚本。
#                支持手动同步和设置后台服务。优先使用 chrony。
#
#       OPTIONS: ---
#  REQUIREMENTS: ---
#          BUGS: ---
#         NOTES: ---
#        AUTHOR: Gemini AI
#       VERSION: 1.1
#       CREATED: 2025-09-27
#      REVISION:
#
#===============================================================================================

# --- 全局变量和配置 ---
TIMEZONE="Asia/Hong_Kong"
NTP_SERVERS=("ntp.aliyun.com" "ntp1.aliyun.com")
CHRONY_CONF="/etc/chrony/chrony.conf"
# 有些系统的chrony配置文件路径不同
if [ ! -f "$CHRONY_CONF" ]; then
    CHRONY_CONF="/etc/chrony.conf"
fi
NTP_CONF="/etc/ntp.conf"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# 检查并安装依赖
install_deps() {
    # 优先检查并安装chrony
    if ! command -v chronyc &> /dev/null; then
        echo -e "${YELLOW}未找到 chrony，正在尝试安装...${NC}"
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y chrony
        elif command -v dnf &> /dev/null; then
            dnf install -y chrony
        elif command -v yum &> /dev/null; then
            yum install -y chrony
        else
            echo -e "${RED}无法确定包管理器，请手动安装 chrony。${NC}"
            exit 1
        fi
        if ! command -v chronyc &> /dev/null; then
             echo -e "${RED}chrony 安装失败，请检查您的系统和网络。${NC}"
             exit 1
        fi
    fi
    echo -e "${GREEN}依赖工具 'chrony' 已准备就绪。${NC}"
}

# 1. 设置系统时区为香港
set_timezone() {
    echo -e "\n${YELLOW}--- 1. 正在设置时区为: $TIMEZONE ---${NC}"
    timedatectl set-timezone "$TIMEZONE"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}时区设置成功！${NC}"
        echo -e "当前系统时间："
        timedatectl
    else
        echo -e "${RED}时区设置失败！${NC}"
    fi
    sleep 2
}

# 2. 立即手动同步时间
sync_now() {
    echo -e "\n${YELLOW}--- 2. 正在手动同步时间... ---${NC}"
    echo "使用服务器: ${NTP_SERVERS[0]}"

    # 停止正在运行的服务，避免冲突
    systemctl stop chronyd 2>/dev/null
    systemctl stop ntpd 2>/dev/null

    # 使用 ntpdate (如果存在) 或 chronyd -q
    if command -v ntpdate &> /dev/null; then
        ntpdate -u "${NTP_SERVERS[0]}"
    else
        echo "未找到 ntpdate, 使用 chronyd 进行一次性同步..."
        # -q 选项会在后台同步时间并退出
        chronyd -q "server ${NTP_SERVERS[0]} iburst"
    fi

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}时间同步成功！${NC}"
    else
        echo -e "${RED}时间同步失败！请检查网络连接或NTP服务器地址。${NC}"
    fi

    # 重新启动后台服务（如果之前在运行）
    if systemctl is-active --quiet chronyd; then
        systemctl start chronyd
    fi
    hwclock -w # 将系统时间写入硬件时钟
    echo "当前时间: $(date)"
    sleep 2
}

# 3. 设置并开启后台自动同步
setup_background_sync() {
    echo -e "\n${YELLOW}--- 3. 正在配置后台自动同步服务 (chrony)... ---${NC}"

    # 备份原始配置文件
    if [ -f "$CHRONY_CONF" ]; then
        cp "$CHRONY_CONF" "$CHRONY_CONF.bak.$(date +%F)"
        echo "配置文件已备份到: $CHRONY_CONF.bak.$(date +%F)"
    else
        echo -e "${RED}找不到 chrony 配置文件: $CHRONY_CONF ${NC}"
        return 1
    fi

    # 注释掉默认的 server/pool 配置
    sed -i -e 's/^\(server .*\)/#\1/g' -e 's/^\(pool .*\)/#\1/g' "$CHRONY_CONF"
    echo "已注释掉旧的服务器配置。"

    # 添加阿里云 NTP 服务器
    # 先删除可能已存在的旧配置
    sed -i '/# Added by setup_time.sh/d' "$CHRONY_CONF"
    sed -i '/ntp.*.aliyun.com/d' "$CHRONY_CONF"

    echo "" >> "$CHRONY_CONF"
    echo "# Added by setup_time.sh" >> "$CHRONY_CONF"
    for server in "${NTP_SERVERS[@]}"; do
        echo "server $server iburst" >> "$CHRONY_CONF"
    done
    echo "已将阿里云NTP服务器添加到配置文件。"

    # 重启并启用 chrony 服务
    echo "正在重启并设置 chrony 服务开机自启..."
    systemctl restart chronyd
    systemctl enable chronyd

    if systemctl is-active --quiet chronyd; then
        echo -e "${GREEN}chrony 后台同步服务已成功配置并启动！${NC}"
        echo "等待几秒钟让服务稳定..."
        sleep 5
        chronyc sources
    else
        echo -e "${RED}chrony 服务启动失败！请使用 'systemctl status chronyd' 查看详情。${NC}"
    fi
    sleep 2
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
    sleep 2
}


# --- 主菜单 ---
main_menu() {
    while true; do
        clear
        echo "================================================"
        echo "      阿里云 NTP 时间同步与时区设置脚本"
        echo "================================================"
        echo -e "请选择操作:"
        echo -e "  ${GREEN}1. 设置时区为 香港 (Asia/Hong_Kong)${NC}"
        echo -e "  ${GREEN}2. [手动] 立即同步一次时间${NC}"
        echo -e "  ${GREEN}3. [自动] 设置并开启后台同步服务 (推荐)${NC}"
        echo -e "  ${GREEN}4. 查看当前状态${NC}"
        echo -e "  ${RED}5. 退出脚本${NC}"
        echo "================================================"
        read -p "请输入选项 [1-5]: " choice

        case $choice in
            1) set_timezone ;;
            2) sync_now ;;
            3) setup_background_sync ;;
            4) show_status ;;
            5) echo "退出脚本。"; exit 0 ;;
            *) echo -e "${RED}无效输入，请输入 1-5 之间的数字。${NC}"; sleep 2 ;;
        esac
        echo -e "\n按任意键返回主菜单..."
        read -n 1
    done
}

# --- 脚本主程序 ---
check_root
install_deps
main_menu

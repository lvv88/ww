#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

#Add some basic function here
function LOGD() {
    echo -e "${yellow}[DEG] $* ${plain}"
}

function LOGE() {
    echo -e "${red}[ERR] $* ${plain}"
}

function LOGI() {
    echo -e "${green}[INF] $* ${plain}"
}

# Port helpers: detect listener and owning process (best effort)
is_port_in_use() {
    local port="$1"
    if command -v ss > /dev/null 2>&1; then
        ss -ltn 2> /dev/null | awk -v p=":${port}$" '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v netstat > /dev/null 2>&1; then
        netstat -lnt 2> /dev/null | awk -v p=":${port} " '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v lsof > /dev/null 2>&1; then
        lsof -nP -iTCP:${port} -sTCP:LISTEN > /dev/null 2>&1 && return 0
    fi
    return 1
}

# Simple helpers for domain/IP validation
is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0 || return 1
}
is_ipv6() {
    [[ "$1" =~ : ]] && return 0 || return 1
}
is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}
is_domain() {
    [[ "$1" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+(xn--[a-z0-9]{2,}|[A-Za-z]{2,})$ ]] && return 0 || return 1
}

# acme.sh's standalone server binds IPv4 by default; --listen-v6 makes it
# v6-only, which breaks HTTP-01 validation when the domain's A record points
# at this host's IPv4 (#4994). Only force IPv6 when the host has no global
# IPv4 address at all.
acme_listen_flag() {
    if ip -4 addr show scope global 2> /dev/null | grep -q "inet "; then
        echo ""
    else
        echo "--listen-v6"
    fi
}

# check root
[[ $EUID -ne 0 ]] && LOGE "错误：必须使用 root 用户运行本脚本！ \n" && exit 1

# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "检测系统类型失败，请联系作者！" >&2
    exit 1
fi
echo "当前系统类型为: $release"

os_version=""
os_version=$(grep "^VERSION_ID" /etc/os-release | cut -d '=' -f2 | tr -d '"' | tr -d '.')

running_in_docker="false"
if [[ -f /.dockerenv ]] || [[ "${XUI_IN_DOCKER}" == "true" ]]; then
    running_in_docker="true"
fi

# Declare Variables
if [[ "${running_in_docker}" == "true" ]]; then
    xui_folder="${XUI_MAIN_FOLDER:=/app}"
else
    xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
fi
xui_service="${XUI_SERVICE:=/etc/systemd/system}"
log_folder="${XUI_LOG_FOLDER:=/var/log/x-ui}"
mkdir -p "${log_folder}"
iplimit_log_path="${log_folder}/3xipl.log"
iplimit_banned_log_path="${log_folder}/3xipl-banned.log"

confirm() {
    if [[ $# > 1 ]]; then
        echo && read -rp "$1 [默认 $2]: " temp
        if [[ "${temp}" == "" ]]; then
            temp=$2
        fi
    else
        read -rp "$1 [y/n]: " temp
    fi
    if [[ "${temp}" == "y" || "${temp}" == "Y" ]]; then
        return 0
    else
        return 1
    fi
}

confirm_restart() {
    confirm "重启面板，注意：重启面板会同时重启 xray" "y"
    if [[ $? == 0 ]]; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    echo && echo -n -e "${yellow}按回车返回主菜单: ${plain}" && read -r temp
    show_menu
}

install() {
    bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh)
    if [[ $? == 0 ]]; then
        if [[ $# == 0 ]]; then
            start
        else
            start 0
        fi
    fi
}

update() {
    confirm "此操作会将面板所有组件更新到最新版本，数据不会丢失，是否继续？" "y"
    if [[ $? != 0 ]]; then
        LOGE "已取消"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/main/update.sh)
    if [[ $? == 0 ]]; then
        LOGI "更新完成，面板已自动重启 "
        before_show_menu
    fi
}

update_dev() {
    confirm "将把面板更新到最新开发版提交（dev-latest 滚动版本，非稳定版），数据会保留，是否继续？" "y"
    if [[ $? != 0 ]]; then
        LOGE "已取消"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    # XUI_UPDATE_TAG tells update.sh to install the dev-latest pre-release
    # instead of the latest stable tag.
    XUI_UPDATE_TAG="dev-latest" bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/main/update.sh)
    if [[ $? == 0 ]]; then
        LOGI "开发版更新完成，面板已自动重启 "
        before_show_menu
    fi
}

replace_xui_script() {
    local url="$1"
    local use_if_modified_since="$2"
    local temp_file="/usr/bin/ww-temp.$$"

    rm -f "$temp_file"
    if [[ "$use_if_modified_since" == "true" ]]; then
        curl -fLRo "$temp_file" -z /usr/bin/ww "$url"
    else
        curl -fLRo "$temp_file" "$url"
    fi
    if [[ $? != 0 ]]; then
        rm -f "$temp_file"
        return 1
    fi

    if [[ ! -s "$temp_file" ]]; then
        rm -f "$temp_file"
        # -z above means "not modified since /usr/bin/ww" rather than a
        # real failure, so an empty download here is success, not an error.
        [[ "$use_if_modified_since" == "true" ]] && return 0
        return 1
    fi

    mv -f "$temp_file" /usr/bin/ww
    if [[ $? != 0 ]]; then
        rm -f "$temp_file"
        return 1
    fi
    # The move already landed the new script; a transient chmod failure here
    # shouldn't make callers think the whole replace failed.
    chmod +x /usr/bin/ww
    return 0
}

update_menu() {
    echo -e "${yellow}正在更新菜单脚本${plain}"
    confirm "此操作会从官方仓库下载最新菜单脚本（英文版，会覆盖当前中文菜单），是否继续？" "y"
    if [[ $? != 0 ]]; then
        LOGE "已取消"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi

    if replace_xui_script "https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh" "false"; then
        chmod +x ${xui_folder}/x-ui.sh
        echo -e "${green}更新成功，面板已自动重启。${plain}"
        exit 0
    else
        echo -e "${red}菜单更新失败。${plain}"
        return 1
    fi
}

legacy_version() {
    echo -n "请输入面板版本号（例如 2.4.0）："
    read -r tag_version

    if [ -z "$tag_version" ]; then
        echo "面板版本号不能为空，已退出。"
        exit 1
    fi
    # Use the entered panel version in the download link
    install_command="bash <(curl -Ls "https://raw.githubusercontent.com/mhsanaei/3x-ui/v$tag_version/install.sh") v$tag_version"

    echo "正在下载并安装面板版本 $tag_version ..."
    eval $install_command
}

# Function to handle the deletion of the script file
delete_script() {
    rm "$0" # Remove the script file itself
    exit 1
}

xui_env_file_path() {
    case "${release}" in
        ubuntu | debian | armbian)
            echo "/etc/default/x-ui"
            ;;
        arch | manjaro | parch | alpine)
            echo "/etc/conf.d/x-ui"
            ;;
        *)
            echo "/etc/sysconfig/x-ui"
            ;;
    esac
}

uninstall() {
    confirm "确定要卸载面板吗？xray 也会被一并卸载！" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi

    if [[ $release == "alpine" ]]; then
        rc-service x-ui stop
        rc-update del x-ui
        rm /etc/init.d/x-ui -f
    else
        systemctl stop x-ui
        systemctl disable x-ui
        rm ${xui_service}/x-ui.service -f
        systemctl daemon-reload
        systemctl reset-failed
    fi

    local panel_used_postgres="false"
    local db_env_file
    db_env_file="$(xui_env_file_path)"
    if [[ -r "$db_env_file" ]] && grep -q '^XUI_DB_TYPE=postgres' "$db_env_file"; then
        panel_used_postgres="true"
    fi

    rm /etc/x-ui/ -rf
    rm ${xui_folder}/ -rf
    rm -f "$db_env_file"

    if [[ "$panel_used_postgres" == "true" ]] && postgresql_installed; then
        purge_postgresql
    fi

    echo ""
    echo -e "卸载成功。\n"
    echo "如需重新安装面板，可使用以下命令："
    echo -e "${green}bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)${plain}"
    echo ""
    # Trap the SIGTERM signal
    trap delete_script SIGTERM
    delete_script
}

reset_user() {
    confirm "确定要重置面板的用户名和密码吗？" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi

    read -rp "请设置登录用户名 [默认随机生成]: " config_account
    [[ -z $config_account ]] && config_account=$(gen_random_string 10)
    read -rp "请设置登录密码 [默认随机生成]: " config_password
    [[ -z $config_password ]] && config_password=$(gen_random_string 18)

    read -rp "是否关闭当前已配置的两步验证？(y/n): " twoFactorConfirm
    if [[ $twoFactorConfirm != "y" && $twoFactorConfirm != "Y" ]]; then
        ${xui_folder}/x-ui setting -username "${config_account}" -password "${config_password}" > /dev/null 2>&1
    else
        ${xui_folder}/x-ui setting -username "${config_account}" -password "${config_password}" -resetTwoFactor=true > /dev/null 2>&1
        echo -e "两步验证已关闭。"
    fi

    echo -e "面板登录用户名已重置为: ${green} ${config_account} ${plain}"
    echo -e "面板登录密码已重置为: ${green} ${config_password} ${plain}"
    echo -e "${green} 请使用新的用户名和密码登录面板，并牢记它们！ ${plain}"
    confirm_restart
}

gen_random_string() {
    local length="$1"
    openssl rand -base64 $((length * 2)) \
        | tr -dc 'a-zA-Z0-9' \
        | head -c "$length"
}

reset_webbasepath() {
    echo -e "${yellow}正在重置面板访问路径${plain}"

    read -rp "确定要重置面板访问路径吗？(y/n): " confirm
    if [[ $confirm != "y" && $confirm != "Y" ]]; then
        echo -e "${yellow}操作已取消。${plain}"
        return
    fi

    config_webBasePath=$(gen_random_string 18)

    # Apply the new web base path setting
    ${xui_folder}/x-ui setting -webBasePath "${config_webBasePath}" > /dev/null 2>&1

    echo -e "面板访问路径已重置为: ${green}${config_webBasePath}${plain}"
    echo -e "${green}请使用新的访问路径访问面板。${plain}"
    restart
}

reset_config() {
    confirm "确定要重置所有面板设置吗？账号数据不会丢失，用户名和密码不会改变" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    ${xui_folder}/x-ui setting -reset
    echo -e "所有面板设置已恢复为默认值。"
    restart
}

check_config() {
    local info=$(${xui_folder}/x-ui setting -show true)
    if [[ $? != 0 ]]; then
        LOGE "获取当前设置失败，请检查日志"
        show_menu
        return
    fi
    LOGI "${info}"

    local db_env_file
    db_env_file="$(xui_env_file_path)"
    if [[ -r "$db_env_file" ]] && grep -q '^XUI_DB_TYPE=postgres' "$db_env_file"; then
        local dsn
        dsn="$(grep -E '^XUI_DB_DSN=' "$db_env_file" | head -1 | cut -d= -f2-)"
        local dsn_safe
        dsn_safe="$(echo "$dsn" | sed -E 's|(://[^:/@]+:)[^@]+@|\1****@|')"
        echo -e "${green}数据库: PostgreSQL — ${dsn_safe}${plain}"
    else
        echo -e "${green}数据库: SQLite (/etc/x-ui/x-ui.db)${plain}"
    fi

    local existing_webBasePath=$(echo "$info" | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(echo "$info" | grep -Eo 'port: .+' | awk '{print $2}')
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    local URL_lists=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
        "https://check-host.net/ip"
    )
    local server_ip=""
    for ip_address in "${URL_lists[@]}"; do
        local response=$(curl -s -w "\n%{http_code}" --max-time 3 "${ip_address}" 2> /dev/null)
        local http_code=$(echo "$response" | tail -n1)
        local ip_result=$(echo "$response" | head -n-1 | tr -d '[:space:]"')
        if [[ "${http_code}" == "200" && "${ip_result}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            server_ip="${ip_result}"
            break
        fi
    done

    if [[ -z "$server_ip" ]]; then
        echo -e "${yellow}无法自动检测服务器公网 IP。${plain}"
        while [[ -z "$server_ip" ]]; do
            read -rp "请输入服务器的公网 IPv4 地址: " server_ip
            server_ip="${server_ip// /}"
            if [[ ! "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo -e "${red}IPv4 地址无效，请重试。${plain}"
                server_ip=""
            fi
        done
    fi

    if [[ -n "$existing_cert" ]]; then
        local domain=$(basename "$(dirname "$existing_cert")")
        # The cert folder name is only the certificate's first domain. A
        # multidomain (SAN) certificate may be served under any name it covers,
        # so read the real names from the certificate itself (#5070).
        local cert_sans=""
        if [[ -f "$existing_cert" ]] && command -v openssl > /dev/null 2>&1; then
            cert_sans=$(openssl x509 -in "$existing_cert" -noout -ext subjectAltName 2> /dev/null \
                | grep -Eo 'DNS:[^,[:space:]]+' | cut -d: -f2)
            if [[ -n "$cert_sans" ]] && ! echo "$cert_sans" | grep -qx "$domain"; then
                domain=$(echo "$cert_sans" | head -n1)
            fi
        fi

        if [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            echo -e "${green}访问地址: https://${domain}:${existing_port}${existing_webBasePath}${plain}"
        else
            echo -e "${green}访问地址: https://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
        fi
        if [[ -n "$cert_sans" && $(echo "$cert_sans" | wc -l) -gt 1 ]]; then
            echo -e "${yellow}该证书还包含以下域名:${plain} $(echo "$cert_sans" | grep -vx "$domain" | tr '\n' ' ')"
        fi
    else
        echo -e "${red}⚠ 警告：尚未配置 SSL 证书！${plain}"
        echo -e "${yellow}你可以为服务器 IP 申请 Let's Encrypt 证书（有效期约 6 天，自动续期）。${plain}"
        read -rp "现在为该 IP 申请 SSL 证书吗？[y/N]: " gen_ssl
        if [[ "$gen_ssl" == "y" || "$gen_ssl" == "Y" ]]; then
            stop 0 > /dev/null 2>&1
            ssl_cert_issue_for_ip
            if [[ $? -eq 0 ]]; then
                echo -e "${green}访问地址: https://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
                # ssl_cert_issue_for_ip already restarts the panel, but ensure it's running
                start 0 > /dev/null 2>&1
            else
                LOGE "IP 证书配置失败。"
                echo -e "${yellow}你可以在主菜单选项 20（SSL 证书管理）中重试。${plain}"
                start 0 > /dev/null 2>&1
            fi
        else
            echo -e "${yellow}访问地址: http://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
            echo -e "${yellow}为了安全，请使用主菜单选项 20（SSL 证书管理）配置 SSL 证书${plain}"
        fi
    fi
}

set_port() {
    echo -n "请输入端口号[1-65535]: "
    read -r port
    if [[ -z "${port}" ]]; then
        LOGD "已取消"
        before_show_menu
    else
        ${xui_folder}/x-ui setting -port ${port}
        echo -e "端口设置成功，请立即重启面板，并使用新端口 ${green}${port}${plain} 访问面板"
        confirm_restart
    fi
}

start() {
    check_status
    if [[ $? == 0 ]]; then
        echo ""
        LOGI "面板已在运行，无需重复启动；如需重启请选择重启"
    else
        if [[ "${running_in_docker}" == "true" ]]; then
            LOGE "容器内的面板进程未运行。"
            LOGI "在 Docker 中面板是容器主进程，请重启容器以恢复运行："
            LOGI "  docker restart <container_name>"
            if [[ $# == 0 ]]; then
                before_show_menu
            fi
            return 0
        fi
        if [[ $release == "alpine" ]]; then
            rc-service x-ui start
        else
            systemctl start x-ui
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            LOGI "面板启动成功"
        else
            LOGE "面板启动失败，可能是启动耗时超过两秒，请稍后查看日志信息"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

stop() {
    check_status
    if [[ $? == 1 ]]; then
        echo ""
        LOGI "面板已停止，无需重复停止！"
    else
        if [[ "${running_in_docker}" == "true" ]]; then
            LOGI "在 Docker 中面板作为容器主进程运行。"
            LOGI "如需停止，请在宿主机上停止该容器："
            LOGI "  docker stop <container_name>"
            if [[ $# == 0 ]]; then
                before_show_menu
            fi
            return 0
        fi
        if [[ $release == "alpine" ]]; then
            rc-service x-ui stop
        else
            systemctl stop x-ui
        fi
        sleep 2
        check_status
        if [[ $? == 1 ]]; then
            LOGI "面板与 xray 已成功停止"
        else
            LOGE "面板停止失败，可能是停止耗时超过两秒，请稍后查看日志信息"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart() {
    if [[ "${running_in_docker}" == "true" ]]; then
        if signal_xui HUP; then
            sleep 1
            signal_xui USR1
            LOGI "已向面板与 xray-core 发送重启信号。"
        else
            LOGE "未找到正在运行的面板进程。"
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            LOGI "面板与 xray 重启成功"
        else
            LOGE "面板重启失败，请稍后查看日志信息"
        fi
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    if [[ $release == "alpine" ]]; then
        rc-service x-ui restart
    else
        systemctl restart x-ui
    fi
    sleep 2
    check_status
    if [[ $? == 0 ]]; then
        LOGI "面板与 xray 重启成功"
    else
        LOGE "面板重启失败，可能是启动耗时超过两秒，请稍后查看日志信息"
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart_xray() {
    if [[ "${running_in_docker}" == "true" ]]; then
        if signal_xui USR1; then
            LOGI "已成功发送 xray-core 重启信号，请查看日志确认 xray 是否重启成功"
        else
            LOGE "未找到正在运行的面板进程。"
        fi
        sleep 2
        show_xray_status
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    if [[ $release == "alpine" ]]; then
        rc-service x-ui reload
    else
        systemctl reload x-ui
    fi
    LOGI "已成功发送 xray-core 重启信号，请查看日志确认 xray 是否重启成功"
    sleep 2
    show_xray_status
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

status() {
    if [[ "${running_in_docker}" == "true" ]]; then
        show_status
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    if [[ $release == "alpine" ]]; then
        rc-service x-ui status
    else
        systemctl status x-ui -l
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

enable() {
    if [[ "${running_in_docker}" == "true" ]]; then
        LOGI "开机自启由 Docker 的重启策略控制（如 docker-compose.yml 中的 'restart: unless-stopped'）。"
        LOGI "容器内没有需要设置的服务。"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    if [[ $release == "alpine" ]]; then
        rc-update add x-ui default
    else
        systemctl enable x-ui
    fi
    if [[ $? == 0 ]]; then
        LOGI "面板开机自启设置成功"
    else
        LOGE "面板开机自启设置失败"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

disable() {
    if [[ "${running_in_docker}" == "true" ]]; then
        LOGI "开机自启由 Docker 的重启策略控制（如 docker-compose.yml 中的 'restart: unless-stopped'）。"
        LOGI "在宿主机将容器设置为 'restart: no' 即可取消开机自启。"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    if [[ $release == "alpine" ]]; then
        rc-update del x-ui
    else
        systemctl disable x-ui
    fi
    if [[ $? == 0 ]]; then
        LOGI "已成功取消面板开机自启"
    else
        LOGE "取消面板开机自启失败"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_log() {
    if [[ $release == "alpine" ]]; then
        echo -e "${green}\t1.${plain} 调试日志"
        echo -e "${green}\t0.${plain} 返回主菜单"
        read -rp "请选择: " choice

        case "$choice" in
            0)
                show_menu
                ;;
            1)
                grep -F 'x-ui[' /var/log/messages
                if [[ $# == 0 ]]; then
                    before_show_menu
                fi
                ;;
            *)
                echo -e "${red}无效选项，请输入正确的数字。${plain}\n"
                show_log
                ;;
        esac
    else
        echo -e "${green}\t1.${plain} 调试日志"
        echo -e "${green}\t2.${plain} 清空所有日志"
        echo -e "${green}\t0.${plain} 返回主菜单"
        read -rp "请选择: " choice

        case "$choice" in
            0)
                show_menu
                ;;
            1)
                journalctl -u x-ui -e --no-pager -f -p debug
                if [[ $# == 0 ]]; then
                    before_show_menu
                fi
                ;;
            2)
                sudo journalctl --rotate
                sudo journalctl --vacuum-time=1s
                echo "所有日志已清空。"
                restart
                ;;
            *)
                echo -e "${red}无效选项，请输入正确的数字。${plain}\n"
                show_log
                ;;
        esac
    fi
}

bbr_menu() {
    echo -e "${green}\t1.${plain} 开启 BBR"
    echo -e "${green}\t2.${plain} 关闭 BBR"
    echo -e "${green}\t0.${plain} 返回主菜单"
    read -rp "请选择: " choice
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            enable_bbr
            bbr_menu
            ;;
        2)
            disable_bbr
            bbr_menu
            ;;
        *)
            echo -e "${red}无效选项，请输入正确的数字。${plain}\n"
            bbr_menu
            ;;
    esac
}

disable_bbr() {

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != "bbr" ]] || [[ ! $(sysctl -n net.core.default_qdisc) =~ ^(fq|cake)$ ]]; then
        echo -e "${yellow}当前未启用 BBR。${plain}"
        before_show_menu
    fi

    if [ -f "/etc/sysctl.d/99-bbr-x-ui.conf" ]; then
        old_settings=$(head -1 /etc/sysctl.d/99-bbr-x-ui.conf | tr -d '#')
        # sysctl -w already restores the live values, so no `sysctl --system`
        # afterwards — it would re-apply every sysctl file on the host and
        # surface unrelated errors from the distro's own defaults (see issue #5160)
        sysctl -w net.core.default_qdisc="${old_settings%:*}"
        sysctl -w net.ipv4.tcp_congestion_control="${old_settings#*:}"
        rm /etc/sysctl.d/99-bbr-x-ui.conf
    else
        # Replace BBR with CUBIC configurations
        if [ -f "/etc/sysctl.conf" ]; then
            sed -i 's/net.core.default_qdisc=fq/net.core.default_qdisc=pfifo_fast/' /etc/sysctl.conf
            sed -i 's/net.ipv4.tcp_congestion_control=bbr/net.ipv4.tcp_congestion_control=cubic/' /etc/sysctl.conf
            sysctl -p
        fi
    fi

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != "bbr" ]]; then
        echo -e "${green}已成功将 BBR 切换为 CUBIC。${plain}"
    else
        echo -e "${red}切换为 CUBIC 失败，请检查系统配置。${plain}"
    fi
}

enable_bbr() {
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]] && [[ $(sysctl -n net.core.default_qdisc) =~ ^(fq|cake)$ ]]; then
        echo -e "${green}BBR 已经启用！${plain}"
        before_show_menu
    fi

    # Enable BBR
    if [ -d "/etc/sysctl.d/" ]; then
        {
            echo "#$(sysctl -n net.core.default_qdisc):$(sysctl -n net.ipv4.tcp_congestion_control)"
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        } > "/etc/sysctl.d/99-bbr-x-ui.conf"
        if [ -f "/etc/sysctl.conf" ]; then
            # Backup old settings from sysctl.conf, if any
            sed -i 's/^net.core.default_qdisc/# &/' /etc/sysctl.conf
            sed -i 's/^net.ipv4.tcp_congestion_control/# &/' /etc/sysctl.conf
        fi
        # Apply only our config file; `sysctl --system` would re-apply every
        # sysctl file on the host and surface unrelated errors from the distro's
        # own defaults (see issue #5160)
        sysctl -p /etc/sysctl.d/99-bbr-x-ui.conf
    else
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        echo "net.core.default_qdisc=fq" | tee -a /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" | tee -a /etc/sysctl.conf
        sysctl -p
    fi

    # Verify that BBR is enabled
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]]; then
        echo -e "${green}BBR 已成功启用。${plain}"
    else
        echo -e "${red}启用 BBR 失败，请检查系统配置。${plain}"
    fi
}

update_shell() {
    if replace_xui_script "https://github.com/MHSanaei/3x-ui/raw/main/x-ui.sh" "true"; then
        LOGI "脚本升级成功，请重新运行脚本"
        before_show_menu
    else
        echo ""
        LOGE "脚本下载失败，请检查服务器能否连接 Github"
        before_show_menu
    fi
}

xui_pid() {
    ps -ef 2> /dev/null | grep -F "${xui_folder}/x-ui" | grep -v grep | awk 'NR==1 {print $1}'
}

signal_xui() {
    local sig="$1" pid
    pid="$(xui_pid)"
    if [[ -z "${pid}" ]]; then
        return 1
    fi
    kill -"${sig}" "${pid}" 2> /dev/null
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ "${running_in_docker}" == "true" ]]; then
        if [[ ! -x "${xui_folder}/x-ui" ]]; then
            return 2
        fi
        if [[ -n "$(xui_pid)" ]]; then
            return 0
        else
            return 1
        fi
    fi
    if [[ $release == "alpine" ]]; then
        if [[ ! -f /etc/init.d/x-ui ]]; then
            return 2
        fi
        if [[ $(rc-service x-ui status | grep -F 'status: started' -c) == 1 ]]; then
            return 0
        else
            return 1
        fi
    else
        if [[ ! -f ${xui_service}/x-ui.service ]]; then
            return 2
        fi
        temp=$(systemctl status x-ui | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ "${temp}" == "running" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

check_enabled() {
    if [[ $release == "alpine" ]]; then
        if [[ $(rc-update show | grep -F 'x-ui' | grep default -c) == 1 ]]; then
            return 0
        else
            return 1
        fi
    else
        temp=$(systemctl is-enabled x-ui)
        if [[ "${temp}" == "enabled" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

check_uninstall() {
    check_status
    if [[ $? != 2 ]]; then
        echo ""
        LOGE "面板已安装，请勿重复安装"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo ""
        LOGE "请先安装面板"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

show_status() {
    check_status
    case $? in
        0)
            echo -e "面板状态: ${green}运行中${plain}"
            show_enable_status
            ;;
        1)
            echo -e "面板状态: ${yellow}未运行${plain}"
            show_enable_status
            ;;
        2)
            echo -e "面板状态: ${red}未安装${plain}"
            ;;
    esac
    show_xray_status
    show_mtproto_status
}

show_enable_status() {
    if [[ "${running_in_docker}" == "true" ]]; then
        echo -e "开机自启: ${green}由 Docker 管理${plain}"
        return
    fi
    check_enabled
    if [[ $? == 0 ]]; then
        echo -e "开机自启: ${green}是${plain}"
    else
        echo -e "开机自启: ${red}否${plain}"
    fi
}

check_xray_status() {
    count=$(ps -ef | grep "xray-linux" | grep -v "grep" | wc -l)
    if [[ count -ne 0 ]]; then
        return 0
    else
        return 1
    fi
}

show_xray_status() {
    check_xray_status
    if [[ $? == 0 ]]; then
        echo -e "xray 状态: ${green}运行中${plain}"
    else
        echo -e "xray 状态: ${red}未运行${plain}"
    fi
}

# show_mtproto_status reports each mtproto inbound's mtg sidecar (one process per
# inbound, run outside xray). Silent when no mtproto 入站 is configured.
show_mtproto_status() {
    local cfg_dir="${xui_folder}/bin/mtproto"
    local cfgs=()
    if [[ -d "${cfg_dir}" ]]; then
        for f in "${cfg_dir}"/mtg-*.toml; do
            [[ -e "$f" ]] && cfgs+=("$f")
        done
    fi
    [[ ${#cfgs[@]} -eq 0 ]] && return

    local running
    running=$(ps -ef | grep "mtg-linux" | grep -v "grep" | grep -oE 'mtg-[0-9]+\.toml')
    for f in "${cfgs[@]}"; do
        local name id bind
        name=$(basename "$f")
        id=$(echo "${name}" | sed -E 's/mtg-([0-9]+)\.toml/\1/')
        bind=$(grep -E '^[[:space:]]*bind-to' "$f" | head -1 | cut -d'"' -f2)
        if echo "${running}" | grep -qx "${name}"; then
            echo -e "mtproto 入站 ${id} (${bind}): ${green}运行中${plain}"
        else
            echo -e "mtproto 入站 ${id} (${bind}): ${red}未运行${plain}"
        fi
    done
}

firewall_menu() {
    echo -e "${green}\t1.${plain} ${green}安装${plain}防火墙"
    echo -e "${green}\t2.${plain} 端口列表[带编号]"
    echo -e "${green}\t3.${plain} ${green}开放${plain}端口"
    echo -e "${green}\t4.${plain} ${red}删除${plain}列表中的端口"
    echo -e "${green}\t5.${plain} ${green}启用${plain}防火墙"
    echo -e "${green}\t6.${plain} ${red}禁用${plain}防火墙"
    echo -e "${green}\t7.${plain} 防火墙状态"
    echo -e "${green}\t0.${plain} 返回主菜单"
    read -rp "请选择: " choice
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            install_firewall
            firewall_menu
            ;;
        2)
            ufw status numbered
            firewall_menu
            ;;
        3)
            open_ports
            firewall_menu
            ;;
        4)
            delete_ports
            firewall_menu
            ;;
        5)
            ufw enable
            firewall_menu
            ;;
        6)
            ufw disable
            firewall_menu
            ;;
        7)
            ufw status verbose
            firewall_menu
            ;;
        *)
            echo -e "${red}无效选项，请输入正确的数字。${plain}\n"
            firewall_menu
            ;;
    esac
}

install_firewall() {
    if ! command -v ufw &> /dev/null; then
        echo "未安装 ufw 防火墙，正在安装..."
        apt-get update
        apt-get install -y ufw
    else
        echo "ufw 防火墙已安装"
    fi

    # Check if the firewall is inactive
    if ufw status | grep -q "Status: active"; then
        echo "防火墙已处于启用状态"
    else
        echo "正在启用防火墙..."
        # Open the necessary ports
        ufw allow ssh
        ufw allow http
        ufw allow https
        ufw allow 2053/tcp #webPort
        ufw allow 2096/tcp #subport

        # Enable the firewall
        ufw --force enable
    fi
}

open_ports() {
    # Prompt the user to enter the ports they want to open
    read -rp "请输入要开放的端口（例如 80,443,2053 或范围 400-500）: " ports

    # Check if the input is valid
    if ! [[ $ports =~ ^([0-9]+|[0-9]+-[0-9]+)(,([0-9]+|[0-9]+-[0-9]+))*$ ]]; then
        echo "错误：输入无效。请输入以逗号分隔的端口或端口范围（例如 80,443,2053 或 400-500）。" >&2
        exit 1
    fi

    # Open the specified ports using ufw
    IFS=',' read -ra PORT_LIST <<< "$ports"
    for port in "${PORT_LIST[@]}"; do
        if [[ $port == *-* ]]; then
            # Split the range into start and end ports
            start_port=$(echo $port | cut -d'-' -f1)
            end_port=$(echo $port | cut -d'-' -f2)
            # Open the port range
            ufw allow $start_port:$end_port/tcp
            ufw allow $start_port:$end_port/udp
        else
            # Open the single port
            ufw allow "$port"
        fi
    done

    # Confirm that the ports are opened
    echo "已开放指定端口:"
    for port in "${PORT_LIST[@]}"; do
        if [[ $port == *-* ]]; then
            start_port=$(echo $port | cut -d'-' -f1)
            end_port=$(echo $port | cut -d'-' -f2)
            # Check if the port range has been successfully opened
            (ufw status | grep -q "$start_port:$end_port") && echo "$start_port-$end_port"
        else
            # Check if the individual port has been successfully opened
            (ufw status | grep -q "$port") && echo "$port"
        fi
    done
}

delete_ports() {
    # Display current rules with numbers
    echo "当前 UFW 规则:"
    ufw status numbered

    # Ask the user how they want to delete rules
    echo "请选择删除方式:"
    echo "1) 按规则编号"
    echo "2) 按端口"
    read -rp "请输入选择（1 或 2）: " choice

    if [[ $choice -eq 1 ]]; then
        # Deleting by rule numbers
        read -rp "请输入要删除的规则编号（如 1, 2）: " rule_numbers

        # Validate the input
        if ! [[ $rule_numbers =~ ^([0-9]+)(,[0-9]+)*$ ]]; then
            echo "错误：输入无效。请输入以逗号分隔的规则编号。" >&2
            exit 1
        fi

        # Split numbers into an array
        IFS=',' read -ra RULE_NUMBERS <<< "$rule_numbers"
        for rule_number in "${RULE_NUMBERS[@]}"; do
            # Delete the rule by number
            ufw delete "$rule_number" || echo "删除规则编号 $rule_number 失败"
        done

        echo "所选规则已删除。"

    elif [[ $choice -eq 2 ]]; then
        # Deleting by ports
        read -rp "请输入要删除的端口（例如 80,443,2053 或范围 400-500）: " ports

        # Validate the input
        if ! [[ $ports =~ ^([0-9]+|[0-9]+-[0-9]+)(,([0-9]+|[0-9]+-[0-9]+))*$ ]]; then
            echo "错误：输入无效。请输入以逗号分隔的端口或端口范围（例如 80,443,2053 或 400-500）。" >&2
            exit 1
        fi

        # Split ports into an array
        IFS=',' read -ra PORT_LIST <<< "$ports"
        for port in "${PORT_LIST[@]}"; do
            if [[ $port == *-* ]]; then
                # Split the port range
                start_port=$(echo $port | cut -d'-' -f1)
                end_port=$(echo $port | cut -d'-' -f2)
                # Delete the port range
                ufw delete allow $start_port:$end_port/tcp
                ufw delete allow $start_port:$end_port/udp
            else
                # Delete a single port
                ufw delete allow "$port"
            fi
        done

        # Confirmation of deletion
        echo "已删除指定端口:"
        for port in "${PORT_LIST[@]}"; do
            if [[ $port == *-* ]]; then
                start_port=$(echo $port | cut -d'-' -f1)
                end_port=$(echo $port | cut -d'-' -f2)
                # Check if the port range has been deleted
                (ufw status | grep -q "$start_port:$end_port") || echo "$start_port-$end_port"
            else
                # Check if the individual port has been deleted
                (ufw status | grep -q "$port") || echo "$port"
            fi
        done
    else
        echo "${red}错误:${plain} 选择无效，请输入 1 或 2。" >&2
        exit 1
    fi
}

update_all_geofiles() {
    local failed=0
    update_geofiles "main" || failed=1
    update_geofiles "IR" || failed=1
    update_geofiles "RU" || failed=1
    return $failed
}

update_geofiles() {
    case "${1}" in
        "main")
            dat_files=(geoip geosite)
            dat_source="Loyalsoldier/v2ray-rules-dat"
            ;;
        "IR")
            dat_files=(geoip_IR geosite_IR)
            dat_source="chocolate4u/Iran-v2ray-rules"
            ;;
        "RU")
            dat_files=(geoip_RU geosite_RU)
            dat_source="runetfreedom/russia-v2ray-rules-dat"
            ;;
        *)
            echo -e "${red}update_geofiles: 未知数据集 '${1}'${plain}"
            return 1
            ;;
    esac
    local failed=0 http_code
    for dat in "${dat_files[@]}"; do
        # Remove suffix for remote filename (e.g., geoip_IR -> geoip)
        remote_file="${dat%%_*}"
        local dest="${xui_folder}/bin/${dat}.dat"
        local temp_file="${dest}.tmp.$$"
        rm -f "$temp_file"
        # -z (against the live file, not the temp file) skips the download
        # (server answers 304) when the local copy is already current.
        http_code=$(curl -sSfLRo "$temp_file" -z "$dest" -w '%{http_code}' \
            https://github.com/${dat_source}/releases/latest/download/${remote_file}.dat)
        if [[ $? -ne 0 ]]; then
            echo -e "${red}${dat}.dat: 下载失败${plain}"
            rm -f "$temp_file"
            failed=1
        elif [[ "$http_code" == "304" ]]; then
            echo -e "${dat}.dat: 已是最新"
            rm -f "$temp_file"
        elif [[ ! -s "$temp_file" ]]; then
            echo -e "${red}${dat}.dat: 下载的文件为空${plain}"
            rm -f "$temp_file"
            failed=1
        else
            mv -f "$temp_file" "$dest"
            if [[ $? -ne 0 ]]; then
                echo -e "${red}${dat}.dat: 安装失败${plain}"
                rm -f "$temp_file"
                failed=1
            else
                echo -e "${green}${dat}.dat: 已更新${plain}"
                geo_updated=1
            fi
        fi
    done
    return $failed
}

run_geo_update() {
    local name="$1"
    shift
    geo_updated=0
    "$@"
    if [[ $? -ne 0 ]]; then
        echo -e "${red}部分 ${name} 更新失败，请查看上方错误信息。${plain}"
    elif [[ $geo_updated -eq 1 ]]; then
        echo -e "${green}${name} 更新成功！${plain}"
        restart
    else
        echo -e "${green}${name} 已是最新，无需重启。${plain}"
    fi
}

update_geo() {
    echo -e "${green}\t1.${plain} Loyalsoldier (geoip.dat, geosite.dat)"
    echo -e "${green}\t2.${plain} chocolate4u (geoip_IR.dat, geosite_IR.dat)"
    echo -e "${green}\t3.${plain} runetfreedom (geoip_RU.dat, geosite_RU.dat)"
    echo -e "${green}\t4.${plain} 全部"
    echo -e "${green}\t0.${plain} 返回主菜单"
    read -rp "请选择: " choice

    case "$choice" in
        0)
            show_menu
            ;;
        1)
            run_geo_update "Loyalsoldier datasets" update_geofiles "main"
            ;;
        2)
            run_geo_update "chocolate4u datasets" update_geofiles "IR"
            ;;
        3)
            run_geo_update "runetfreedom datasets" update_geofiles "RU"
            ;;
        4)
            run_geo_update "geo files" update_all_geofiles
            ;;
        *)
            echo -e "${red}无效选项，请输入正确的数字。${plain}\n"
            update_geo
            ;;
    esac

    before_show_menu
}

install_acme() {
    # Check if acme.sh is already installed
    if command -v ~/.acme.sh/acme.sh &> /dev/null; then
        LOGI "acme.sh 已安装。"
        return 0
    fi

    LOGI "正在安装 acme.sh..."
    cd ~ || return 1 # Ensure you can change to the home directory

    curl -s https://get.acme.sh | sh
    if [ $? -ne 0 ]; then
        LOGE "acme.sh 安装失败。"
        return 1
    else
        LOGI "acme.sh 安装成功。"
    fi

    return 0
}

ssl_cert_issue_main() {
    echo -e "${green}\t1.${plain} 申请 SSL 证书（域名）"
    echo -e "${green}\t2.${plain} 吊销并删除证书"
    echo -e "${green}\t3.${plain} 强制续期"
    echo -e "${green}\t4.${plain} 查看已有域名证书"
    echo -e "${green}\t5.${plain} 为面板设置证书路径"
    echo -e "${green}\t6.${plain} 为 IP 申请 SSL 证书（约 6 天，自动续期）"
    echo -e "${green}\t0.${plain} 返回主菜单"

    read -rp "请选择: " choice
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            ssl_cert_issue
            ssl_cert_issue_main
            ;;
        2)
            local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2> /dev/null)
            if [ -z "$domains" ]; then
                echo "未找到可吊销的证书。"
            else
                echo "已有域名:"
                echo "$domains"
                read -rp "请输入列表中要吊销并删除证书的域名: " domain
                if echo "$domains" | grep -qw "$domain"; then
                    # The IP-cert flow (option 6) stores files under /root/cert/ip, but acme.sh
                    # tracks the cert under the actual IP address(es). Resolve those so renewal
                    # state is torn down too; otherwise the acme.sh cron re-creates the deleted cert.
                    local acme_ids="${domain}"
                    if [[ "${domain}" == "ip" ]]; then
                        acme_ids=$(~/.acme.sh/acme.sh --list 2> /dev/null | awk 'NR>1 {print $1}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$|:')
                    fi
                    for id in ${acme_ids}; do
                        # Best-effort revoke at the CA, then drop acme.sh renewal tracking.
                        ~/.acme.sh/acme.sh --revoke -d "${id}" 2> /dev/null
                        ~/.acme.sh/acme.sh --remove -d "${id}" 2> /dev/null
                        # --remove leaves the cert files on disk, so delete the state dirs (RSA + ECC).
                        rm -rf ~/.acme.sh/"${id}" ~/.acme.sh/"${id}_ecc"
                    done
                    # Delete the local certificate files for this domain.
                    rm -rf "/root/cert/${domain}"
                    LOGI "已吊销并删除域名证书: ${domain}"

                    # If the panel currently serves this domain's cert, clear the stored paths
                    # so it stops loading the now-deleted files, then restart.
                    local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
                    if [[ "${existing_cert}" == "/root/cert/${domain}/"* ]]; then
                        ${xui_folder}/x-ui cert -reset
                        LOGI "已清除面板中引用 ${domain} 的证书路径，正在重启面板。"
                        restart
                    fi
                else
                    echo "输入的域名无效。"
                fi
            fi
            ssl_cert_issue_main
            ;;
        3)
            local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2> /dev/null)
            if [ -z "$domains" ]; then
                echo "未找到可续期的证书。"
            else
                echo "已有域名:"
                echo "$domains"
                read -rp "请输入列表中要续期证书的域名: " domain
                if echo "$domains" | grep -qw "$domain"; then
                    ~/.acme.sh/acme.sh --renew -d ${domain} --force
                    LOGI "已强制续期域名证书: $domain"
                else
                    echo "输入的域名无效。"
                fi
            fi
            ssl_cert_issue_main
            ;;
        4)
            local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2> /dev/null)
            if [ -z "$domains" ]; then
                echo "/root/cert 下未找到证书。"
            else
                echo "已有域名及其证书路径:"
                for domain in $domains; do
                    local cert_path="/root/cert/${domain}/fullchain.pem"
                    local key_path="/root/cert/${domain}/privkey.pem"
                    if [[ -f "${cert_path}" && -f "${key_path}" ]]; then
                        echo -e "域名: ${domain}"
                        echo -e "\t证书路径: ${cert_path}"
                        echo -e "\t私钥路径: ${key_path}"
                    else
                        echo -e "域名: ${domain} - 缺少证书或私钥。"
                    fi
                done
            fi
            # The panel's configured certificate may live outside /root/cert
            # (e.g. certbot under /etc/letsencrypt) — show it too (#5070).
            local panel_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
            if [[ -n "${panel_cert}" && "${panel_cert}" != /root/cert/* ]]; then
                echo -e "面板证书（自定义路径）: ${panel_cert}"
                if [[ -f "${panel_cert}" ]] && command -v openssl > /dev/null 2>&1; then
                    local panel_sans=$(openssl x509 -in "${panel_cert}" -noout -ext subjectAltName 2> /dev/null \
                        | grep -Eo 'DNS:[^,[:space:]]+' | cut -d: -f2 | tr '\n' ' ')
                    [[ -n "${panel_sans}" ]] && echo -e "\t包含域名: ${panel_sans}"
                fi
            fi
            ssl_cert_issue_main
            ;;
        5)
            echo -e "${green}\t1.${plain} 使用 /root/cert 中的证书"
            echo -e "${green}\t2.${plain} 手动输入证书文件路径（如 certbot、/etc/letsencrypt/...）"
            read -rp "请选择: " pathChoice
            if [[ "$pathChoice" == "2" ]]; then
                read -rp "证书文件路径（fullchain）: " webCertFile
                read -rp "私钥文件路径: " webKeyFile
                if [[ -f "${webCertFile}" && -f "${webKeyFile}" ]]; then
                    ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
                    echo "面板证书路径已设置:"
                    echo "  - 证书文件: $webCertFile"
                    echo "  - 私钥文件: $webKeyFile"
                    restart
                else
                    echo "未找到证书或私钥文件。"
                fi
                ssl_cert_issue_main
                return
            fi
            local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2> /dev/null)
            if [ -z "$domains" ]; then
                echo "未找到证书。"
            else
                echo "可用域名:"
                echo "$domains"
                read -rp "请选择要为面板设置证书路径的域名: " domain

                if echo "$domains" | grep -qw "$domain"; then
                    local webCertFile="/root/cert/${domain}/fullchain.pem"
                    local webKeyFile="/root/cert/${domain}/privkey.pem"

                    if [[ -f "${webCertFile}" && -f "${webKeyFile}" ]]; then
                        ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
                        echo "已为域名设置面板证书路径: $domain"
                        echo "  - 证书文件: $webCertFile"
                        echo "  - 私钥文件: $webKeyFile"
                        # Register the acme.sh install-cert hook so auto-renewal copies the
                        # renewed cert to these paths and reloads the panel. Without it acme.sh
                        # renews but never updates /root/cert, silently serving a stale cert.
                        if command -v ~/.acme.sh/acme.sh &> /dev/null && ~/.acme.sh/acme.sh --list 2> /dev/null | awk '{print $1}' | grep -Fxq "${domain}"; then
                            ~/.acme.sh/acme.sh --installcert --force -d "${domain}" \
                                --key-file "${webKeyFile}" \
                                --fullchain-file "${webCertFile}" \
                                --reloadcmd "ww restart" 2>&1 || true
                            echo "已注册 acme.sh 自动续期钩子: ${domain}."
                        fi
                        restart
                    else
                        echo "未找到该域名的证书或私钥: $domain."
                    fi
                else
                    echo "输入的域名无效。"
                fi
            fi
            ssl_cert_issue_main
            ;;
        6)
            echo -e "${yellow}为 IP 地址申请 Let's Encrypt SSL 证书${plain}"
            echo -e "将使用 shortlived 配置为服务器 IP 申请证书。"
            echo -e "${yellow}证书有效期约 6 天，通过 acme.sh 定时任务自动续期。${plain}"
            echo -e "${yellow}80 端口必须开放且可从公网访问。${plain}"
            confirm "是否继续？" "y"
            if [[ $? == 0 ]]; then
                ssl_cert_issue_for_ip
            fi
            ssl_cert_issue_main
            ;;

        *)
            echo -e "${red}无效选项，请输入正确的数字。${plain}\n"
            ssl_cert_issue_main
            ;;
    esac
}

ssl_cert_issue_for_ip() {
    LOGI "开始为服务器 IP 自动申请 SSL 证书..."
    LOGI "使用 Let's Encrypt shortlived 配置（有效期约 6 天，自动续期）"

    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')

    # Get server IP
    local URL_lists=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
        "https://check-host.net/ip"
    )
    local server_ip=""
    for ip_address in "${URL_lists[@]}"; do
        local response=$(curl -s -w "\n%{http_code}" --max-time 3 "${ip_address}" 2> /dev/null)
        local http_code=$(echo "$response" | tail -n1)
        local ip_result=$(echo "$response" | head -n-1 | tr -d '[:space:]"')
        if [[ "${http_code}" == "200" && "${ip_result}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            server_ip="${ip_result}"
            break
        fi
    done

    if [[ -n "$server_ip" ]]; then
        LOGI "检测到服务器 IP: ${server_ip}"
        if ! confirm "${server_ip} 是本机对外的公网 IPv4 地址吗？" "y"; then
            server_ip=""
        fi
    else
        LOGI "无法自动检测服务器公网 IP。"
    fi

    while [[ -z "$server_ip" ]]; do
        read -rp "请输入服务器的公网 IPv4 地址: " server_ip
        server_ip="${server_ip// /}"
        if [[ ! "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            LOGE "IPv4 地址无效，请重试。"
            server_ip=""
        fi
    done

    LOGI "正在为服务器 IP 申请证书: ${server_ip}"

    # Ask for optional IPv6
    local ipv6_addr=""
    read -rp "是否需要包含 IPv6 地址？（留空跳过）: " ipv6_addr
    ipv6_addr="${ipv6_addr// /}" # Trim whitespace

    # check for acme.sh first
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        LOGI "未找到 acme.sh，正在安装..."
        install_acme
        if [ $? -ne 0 ]; then
            LOGE "acme.sh 安装失败"
            return 1
        fi
    fi

    # install socat
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update > /dev/null 2>&1 && apt-get install socat -y > /dev/null 2>&1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf makecache -y > /dev/null 2>&1 && dnf -y install socat > /dev/null 2>&1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum makecache -y > /dev/null 2>&1 && yum -y install socat > /dev/null 2>&1
            else
                dnf makecache -y > /dev/null 2>&1 && dnf -y install socat > /dev/null 2>&1
            fi
            ;;
        arch | manjaro | parch)
            pacman -Sy --noconfirm socat > /dev/null 2>&1
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper refresh > /dev/null 2>&1 && zypper -q install -y socat > /dev/null 2>&1
            ;;
        alpine)
            apk add socat curl openssl > /dev/null 2>&1
            ;;
        *)
            LOGW "Unsupported OS for automatic socat installation"
            ;;
    esac

    # Create certificate directory
    certPath="/root/cert/ip"
    mkdir -p "$certPath"

    # Build domain arguments
    local domain_args="-d ${server_ip}"
    if [[ -n "$ipv6_addr" ]] && is_ipv6 "$ipv6_addr"; then
        domain_args="${domain_args} -d ${ipv6_addr}"
        LOGI "已包含 IPv6 地址: ${ipv6_addr}"
    fi

    # Choose port for HTTP-01 listener (default 80, allow override)
    local WebPort=""
    read -rp "用于 ACME HTTP-01 验证的端口（默认 80）: " WebPort
    WebPort="${WebPort:-80}"
    if ! [[ "${WebPort}" =~ ^[0-9]+$ ]] || ((WebPort < 1 || WebPort > 65535)); then
        LOGE "端口无效，将使用默认端口 80。"
        WebPort=80
    fi
    LOGI "使用端口 ${WebPort} 为该 IP 申请证书: ${server_ip}"
    if [[ "${WebPort}" -ne 80 ]]; then
        LOGI "提示：Let's Encrypt 仍会访问 80 端口，请将外部 80 端口转发到 ${WebPort} 以完成验证。"
    fi

    while true; do
        if is_port_in_use "${WebPort}"; then
            LOGI "端口 ${WebPort} 当前已被占用。"

            local alt_port=""
            read -rp "请输入用于 acme.sh 独立验证的其他端口（留空则终止）: " alt_port
            alt_port="${alt_port// /}"
            if [[ -z "${alt_port}" ]]; then
                LOGE "端口 ${WebPort} 被占用，无法继续申请证书。"
                return 1
            fi
            if ! [[ "${alt_port}" =~ ^[0-9]+$ ]] || ((alt_port < 1 || alt_port > 65535)); then
                LOGE "端口无效。"
                return 1
            fi
            WebPort="${alt_port}"
            continue
        else
            LOGI "端口 ${WebPort} 空闲，可用于独立验证。"
            break
        fi
    done

    # Reload command - restarts panel after renewal
    local reloadCmd="systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null"

    # issue the certificate for IP with shortlived profile
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
    ~/.acme.sh/acme.sh --issue \
        ${domain_args} \
        --standalone \
        --server letsencrypt \
        --certificate-profile shortlived \
        --days 6 \
        --httpport ${WebPort} \
        --force

    if [ $? -ne 0 ]; then
        LOGE "为该 IP 申请证书失败: ${server_ip}"
        LOGE "请确认端口 ${WebPort} 已开放且服务器可从公网访问"
        # Cleanup acme.sh data for both IPv4 and IPv6 if specified
        rm -rf ~/.acme.sh/${server_ip} ~/.acme.sh/${server_ip}_ecc 2> /dev/null
        [[ -n "$ipv6_addr" ]] && rm -rf ~/.acme.sh/${ipv6_addr} ~/.acme.sh/${ipv6_addr}_ecc 2> /dev/null
        rm -rf ${certPath} 2> /dev/null
        return 1
    else
        LOGI "已成功为该 IP 申请证书: ${server_ip}"
    fi

    # Install the certificate
    # Note: acme.sh may report "Reload error" and exit non-zero if reloadcmd fails,
    # but the cert files are still installed. We check for files instead of exit code.
    ~/.acme.sh/acme.sh --installcert --force -d ${server_ip} \
        --key-file "${certPath}/privkey.pem" \
        --fullchain-file "${certPath}/fullchain.pem" \
        --reloadcmd "${reloadCmd}" 2>&1 || true

    # Verify certificate files exist (don't rely on exit code - reloadcmd failure causes non-zero)
    if [[ ! -f "${certPath}/fullchain.pem" || ! -f "${certPath}/privkey.pem" ]]; then
        LOGE "安装后未找到证书文件"
        # Cleanup acme.sh data for both IPv4 and IPv6 if specified
        rm -rf ~/.acme.sh/${server_ip} ~/.acme.sh/${server_ip}_ecc 2> /dev/null
        [[ -n "$ipv6_addr" ]] && rm -rf ~/.acme.sh/${ipv6_addr} ~/.acme.sh/${ipv6_addr}_ecc 2> /dev/null
        rm -rf ${certPath} 2> /dev/null
        return 1
    fi

    LOGI "证书文件安装成功"

    # enable auto-renew
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade > /dev/null 2>&1
    chmod 600 $certPath/privkey.pem 2> /dev/null
    chmod 644 $certPath/fullchain.pem 2> /dev/null

    # Prompt user to set panel paths after successful certificate installation
    local webCertFile="${certPath}/fullchain.pem"
    local webKeyFile="${certPath}/privkey.pem"

    read -rp "是否将该证书设置给面板使用？(y/n): " setPanel
    if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
        if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
            ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
            LOGI "已为该 IP 设置面板证书路径: $server_ip"
            LOGI "  - 证书文件: $webCertFile"
            LOGI "  - 私钥文件: $webKeyFile"
            LOGI "  - 有效期: 约 6 天（由 acme.sh 定时任务自动续期）"
            echo -e "${green}访问地址: https://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
            LOGI "面板将重启以应用 SSL 证书..."
            restart
        else
            LOGE "错误：未找到该 IP 的证书或私钥文件: $server_ip."
            return 1
        fi
    else
        LOGI "已跳过面板证书路径设置。"
    fi

    return 0
}

ssl_cert_issue() {
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    # check for acme.sh first
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        echo "未找到 acme.sh，将自动安装"
        install_acme
        if [ $? -ne 0 ]; then
            LOGE "acme.sh 安装失败，请检查日志"
            exit 1
        fi
    fi

    # install socat
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update > /dev/null 2>&1 && apt-get install socat -y > /dev/null 2>&1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf makecache -y > /dev/null 2>&1 && dnf -y install socat > /dev/null 2>&1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum makecache -y > /dev/null 2>&1 && yum -y install socat > /dev/null 2>&1
            else
                dnf makecache -y > /dev/null 2>&1 && dnf -y install socat > /dev/null 2>&1
            fi
            ;;
        arch | manjaro | parch)
            pacman -Sy --noconfirm socat > /dev/null 2>&1
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper refresh > /dev/null 2>&1 && zypper -q install -y socat > /dev/null 2>&1
            ;;
        alpine)
            apk add socat curl openssl > /dev/null 2>&1
            ;;
        *)
            LOGW "Unsupported OS for automatic socat installation"
            ;;
    esac
    if [ $? -ne 0 ]; then
        LOGE "socat 安装失败，请检查日志"
        exit 1
    else
        LOGI "socat 安装成功..."
    fi

    # get the domain here, and we need to verify it
    local domain=""
    while true; do
        read -rp "请输入你的域名: " domain
        domain="${domain// /}" # Trim whitespace

        if [[ -z "$domain" ]]; then
            LOGE "域名不能为空，请重试。"
            continue
        fi

        if ! is_domain "$domain"; then
            LOGE "域名格式无效: ${domain}，请输入正确的域名。"
            continue
        fi

        break
    done
    LOGD "你的域名是: ${domain}，正在检测..."
    SSL_ISSUED_DOMAIN="${domain}"

    # detect existing certificate and reuse it only if its files are actually
    # present and non-empty. acme.sh stores ECC certs under ${domain}_ecc and RSA
    # certs under ${domain}; a failed issuance can leave a domain entry in --list
    # with no usable cert files, which must not be reused (it produces a 0-byte
    # fullchain.pem). Broken partial state is cleaned up so issuance can proceed.
    local cert_exists=0
    if ~/.acme.sh/acme.sh --list 2> /dev/null | awk '{print $1}' | grep -Fxq "${domain}"; then
        local acmeCertDir=""
        if [[ -s ~/.acme.sh/${domain}_ecc/fullchain.cer && -s ~/.acme.sh/${domain}_ecc/${domain}.key ]]; then
            acmeCertDir=~/.acme.sh/${domain}_ecc
        elif [[ -s ~/.acme.sh/${domain}/fullchain.cer && -s ~/.acme.sh/${domain}/${domain}.key ]]; then
            acmeCertDir=~/.acme.sh/${domain}
        fi
        if [[ -n "${acmeCertDir}" ]]; then
            cert_exists=1
            local certInfo=$(~/.acme.sh/acme.sh --list 2> /dev/null | grep -F "${domain}")
            LOGI "检测到 ${domain} 已有证书，将直接复用。"
            [[ -n "${certInfo}" ]] && LOGI "${certInfo}"
        else
            LOGW "Found incomplete acme.sh state for ${domain} (no valid certificate files); cleaning it up and re-issuing."
            rm -rf ~/.acme.sh/${domain} ~/.acme.sh/${domain}_ecc
        fi
    fi
    if [[ ${cert_exists} -eq 0 ]]; then
        LOGI "域名检测通过，可以开始申请证书..."
    fi

    # create a directory for the certificate
    certPath="/root/cert/${domain}"
    if [ ! -d "$certPath" ]; then
        mkdir -p "$certPath"
    else
        rm -rf "$certPath"
        mkdir -p "$certPath"
    fi

    # get the port number for the standalone server
    local WebPort=80
    read -rp "请选择要使用的端口（默认 80）: " WebPort
    if [[ -z ${WebPort} ]]; then
        WebPort=80
    elif [[ ! ${WebPort} =~ ^[1-9][0-9]*$ || ${WebPort} -gt 65535 ]]; then
        LOGE "输入的 ${WebPort} 无效，将使用默认端口 80。"
        WebPort=80
    fi
    LOGI "将使用端口 ${WebPort} 申请证书，请确保该端口已开放。"

    if [[ ${cert_exists} -eq 0 ]]; then
        # issue the certificate
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
        ~/.acme.sh/acme.sh --issue -d ${domain} $(acme_listen_flag) --standalone --httpport ${WebPort} --force
        if [ $? -ne 0 ]; then
            LOGE "证书申请失败，请检查日志。"
            rm -rf ~/.acme.sh/${domain} ~/.acme.sh/${domain}_ecc
            exit 1
        else
            LOGE "证书申请成功，正在安装证书..."
        fi
    else
        LOGI "使用已有证书，正在安装证书..."
    fi

    reloadCmd="ww restart"

    LOGI "ACME 默认 --reloadcmd 为: ${yellow}ww restart"
    LOGI "该命令会在每次申请和续期证书时执行。"
    read -rp "是否修改 ACME 的 --reloadcmd？(y/n): " setReloadcmd
    if [[ "$setReloadcmd" == "y" || "$setReloadcmd" == "Y" ]]; then
        echo -e "\n${green}\t1.${plain} 预设: systemctl reload nginx ; ww restart"
        echo -e "${green}\t2.${plain} 自定义命令"
        echo -e "${green}\t0.${plain} 保持默认 reloadcmd"
        read -rp "请选择: " choice
        case "$choice" in
            1)
                LOGI "reloadcmd 为: systemctl reload nginx ; ww restart"
                reloadCmd="systemctl reload nginx ; ww restart"
                ;;
            2)
                LOGD "建议将 ww restart 放在最后，这样其他服务失败时不会报错"
                read -rp "请输入你的 reloadcmd（例如: systemctl reload nginx ; ww restart）: " reloadCmd
                LOGI "你的 reloadcmd 为: ${reloadCmd}"
                ;;
            *)
                LOGI "保持默认 reloadcmd"
                ;;
        esac
    fi

    # install the certificate
    local installOutput=""
    installOutput=$(~/.acme.sh/acme.sh --installcert --force -d ${domain} \
        --key-file /root/cert/${domain}/privkey.pem \
        --fullchain-file /root/cert/${domain}/fullchain.pem --reloadcmd "${reloadCmd}" 2>&1)
    local installRc=$?
    echo "${installOutput}"

    local installWroteFiles=0
    if echo "${installOutput}" | grep -q "Installing key to:" && echo "${installOutput}" | grep -q "Installing full chain to:"; then
        installWroteFiles=1
    fi

    if [[ -f "/root/cert/${domain}/privkey.pem" && -f "/root/cert/${domain}/fullchain.pem" && (${installRc} -eq 0 || ${installWroteFiles} -eq 1) ]]; then
        LOGI "证书安装成功，正在开启自动续期..."
    else
        LOGE "证书安装失败，已退出。"
        if [[ ${cert_exists} -eq 0 ]]; then
            rm -rf ~/.acme.sh/${domain} ~/.acme.sh/${domain}_ecc
        fi
        exit 1
    fi

    # enable auto-renew
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    if [ $? -ne 0 ]; then
        LOGE "自动续期设置失败，证书信息如下:"
        ls -lah cert/*
        chmod 600 $certPath/privkey.pem
        chmod 644 $certPath/fullchain.pem
        exit 1
    else
        LOGI "自动续期设置成功，证书信息如下:"
        ls -lah cert/*
        chmod 600 $certPath/privkey.pem
        chmod 644 $certPath/fullchain.pem
    fi

    # Prompt user to set panel paths after successful certificate installation
    read -rp "是否将该证书设置给面板使用？(y/n): " setPanel
    if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
        local webCertFile="/root/cert/${domain}/fullchain.pem"
        local webKeyFile="/root/cert/${domain}/privkey.pem"

        if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
            ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
            LOGI "已为域名设置面板证书路径: $domain"
            LOGI "  - 证书文件: $webCertFile"
            LOGI "  - 私钥文件: $webKeyFile"
            echo -e "${green}访问地址: https://${domain}:${existing_port}${existing_webBasePath}${plain}"
            restart
        else
            LOGE "错误：未找到该域名的证书或私钥文件: $domain。"
        fi
    else
        LOGI "已跳过面板证书路径设置。"
    fi
}

ssl_cert_issue_CF() {
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    LOGI "****** 使用说明 ******"
    LOGI "请按以下步骤完成操作:"
    LOGI "1. 准备 Cloudflare API Token（推荐，权限 Zone:DNS:Edit）或 Global API Key + 注册邮箱。"
    LOGI "2. 准备域名。"
    LOGI "3. 证书申请成功后，会提示是否将证书设置给面板（可选）。"
    LOGI "4. 脚本在安装后还支持 SSL 证书自动续期。"

    confirm "确认以上信息并继续吗？[y/n]" "y"

    if [ $? -eq 0 ]; then
        # Check for acme.sh first
        if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
            echo "未找到 acme.sh，将自动安装。"
            install_acme
            if [ $? -ne 0 ]; then
                LOGE "acme.sh 安装失败，请检查日志。"
                exit 1
            fi
        fi

        CF_Domain=""

        LOGD "请设置域名:"
        read -rp "请输入域名: " CF_Domain
        LOGD "域名已设置为: ${CF_Domain}"

        # Cloudflare API credentials: an API Token (recommended, scoped to a
        # single zone) or the account-wide Global API Key. acme.sh reads
        # CF_Token for tokens, or CF_Key + CF_Email for the Global Key.
        CF_KeyType=""
        read -rp "使用 Cloudflare API Token 还是 Global API Key？(t/g) [默认 t]: " CF_KeyType
        CF_KeyType=${CF_KeyType:-t}

        if [[ "$CF_KeyType" == "g" || "$CF_KeyType" == "G" ]]; then
            CF_GlobalKey=""
            CF_AccountEmail=""
            LOGD "请设置 Global API Key:"
            read -rp "请输入 Key: " CF_GlobalKey
            LOGD "请设置注册邮箱:"
            read -rp "请输入邮箱: " CF_AccountEmail
            export CF_Key="${CF_GlobalKey}"
            export CF_Email="${CF_AccountEmail}"
        else
            CF_ApiToken=""
            LOGD "请设置 API Token:"
            read -rp "请输入 Token: " CF_ApiToken
            export CF_Token="${CF_ApiToken}"
        fi

        # Set the default CA to Let's Encrypt
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
        if [ $? -ne 0 ]; then
            LOGE "默认 CA Let'sEncrypt 设置失败，脚本退出..."
            exit 1
        fi

        # Issue the certificate using Cloudflare DNS
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${CF_Domain} -d *.${CF_Domain} --log --force
        if [ $? -ne 0 ]; then
            LOGE "证书申请失败，脚本退出..."
            exit 1
        else
            LOGI "证书申请成功，正在安装..."
        fi

        # Install the certificate
        certPath="/root/cert/${CF_Domain}"
        if [ -d "$certPath" ]; then
            rm -rf ${certPath}
        fi

        mkdir -p ${certPath}
        if [ $? -ne 0 ]; then
            LOGE "创建目录失败: ${certPath}"
            exit 1
        fi

        reloadCmd="ww restart"

        LOGI "ACME 默认 --reloadcmd 为: ${yellow}ww restart"
        LOGI "该命令会在每次申请和续期证书时执行。"
        read -rp "是否修改 ACME 的 --reloadcmd？(y/n): " setReloadcmd
        if [[ "$setReloadcmd" == "y" || "$setReloadcmd" == "Y" ]]; then
            echo -e "\n${green}\t1.${plain} 预设: systemctl reload nginx ; ww restart"
            echo -e "${green}\t2.${plain} 自定义命令"
            echo -e "${green}\t0.${plain} 保持默认 reloadcmd"
            read -rp "请选择: " choice
            case "$choice" in
                1)
                    LOGI "reloadcmd 为: systemctl reload nginx ; ww restart"
                    reloadCmd="systemctl reload nginx ; ww restart"
                    ;;
                2)
                    LOGD "建议将 ww restart 放在最后，这样其他服务失败时不会报错"
                    read -rp "请输入你的 reloadcmd（例如: systemctl reload nginx ; ww restart）: " reloadCmd
                    LOGI "你的 reloadcmd 为: ${reloadCmd}"
                    ;;
                *)
                    LOGI "保持默认 reloadcmd"
                    ;;
            esac
        fi
        ~/.acme.sh/acme.sh --installcert --force -d ${CF_Domain} -d *.${CF_Domain} \
            --key-file ${certPath}/privkey.pem \
            --fullchain-file ${certPath}/fullchain.pem --reloadcmd "${reloadCmd}"

        if [ $? -ne 0 ]; then
            LOGE "证书安装失败，脚本退出..."
            exit 1
        else
            LOGI "证书安装成功，正在开启自动续期..."
        fi

        # Enable auto-update
        ~/.acme.sh/acme.sh --upgrade --auto-upgrade
        if [ $? -ne 0 ]; then
            LOGE "自动续期设置失败，脚本退出..."
            exit 1
        else
            LOGI "证书已安装并已开启自动续期，详细信息如下:"
            ls -lah ${certPath}/*
            chmod 600 ${certPath}/privkey.pem
            chmod 644 ${certPath}/fullchain.pem
        fi

        # Prompt user to set panel paths after successful certificate installation
        read -rp "是否将该证书设置给面板使用？(y/n): " setPanel
        if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
            local webCertFile="${certPath}/fullchain.pem"
            local webKeyFile="${certPath}/privkey.pem"

            if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
                ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
                LOGI "已为域名设置面板证书路径: $CF_Domain"
                LOGI "  - 证书文件: $webCertFile"
                LOGI "  - 私钥文件: $webKeyFile"
                echo -e "${green}访问地址: https://${CF_Domain}:${existing_port}${existing_webBasePath}${plain}"
                restart
            else
                LOGE "错误：未找到该域名的证书或私钥文件: $CF_Domain。"
            fi
        else
            LOGI "已跳过面板证书路径设置。"
        fi
    else
        show_menu
    fi
}

run_speedtest() {
    # Check if Speedtest is already installed
    if ! command -v speedtest &> /dev/null; then
        # If not installed, determine installation method
        if command -v snap &> /dev/null; then
            # Use snap to install Speedtest
            echo "正在通过 snap 安装 Speedtest..."
            snap install speedtest
        else
            # Fallback to using package managers
            local pkg_manager=""
            local speedtest_install_script=""

            if command -v dnf &> /dev/null; then
                pkg_manager="dnf"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh"
            elif command -v yum &> /dev/null; then
                pkg_manager="yum"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh"
            elif command -v apt-get &> /dev/null; then
                pkg_manager="apt-get"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh"
            elif command -v apt &> /dev/null; then
                pkg_manager="apt"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh"
            fi

            if [[ -z $pkg_manager ]]; then
                echo "错误：未找到包管理器，可能需要手动安装 Speedtest。"
                return 1
            else
                echo "正在通过 $pkg_manager 安装 Speedtest..."
                curl -s $speedtest_install_script | bash
                $pkg_manager install -y speedtest
            fi
        fi
    fi

    speedtest
}

ip_validation() {
    ipv6_regex="^(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))$"
    ipv4_regex="^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)$"
}

iplimit_main() {
    echo -e "\n${green}\t1.${plain} 安装 Fail2ban 并配置 IP 限制"
    echo -e "${green}\t2.${plain} 修改封禁时长"
    echo -e "${green}\t3.${plain} 解封所有 IP"
    echo -e "${green}\t4.${plain} 封禁日志"
    echo -e "${green}\t5.${plain} 封禁指定 IP"
    echo -e "${green}\t6.${plain} 解封指定 IP"
    echo -e "${green}\t7.${plain} 实时日志"
    echo -e "${green}\t8.${plain} 服务状态"
    echo -e "${green}\t9.${plain} 重启服务"
    echo -e "${green}\t10.${plain} 卸载 Fail2ban 与 IP 限制"
    echo -e "${green}\t0.${plain} 返回主菜单"
    read -rp "请选择: " choice
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            confirm "确认安装 Fail2ban 与 IP 限制吗？" "y"
            if [[ $? == 0 ]]; then
                install_iplimit
            else
                iplimit_main
            fi
            ;;
        2)
            read -rp "请输入新的封禁时长（分钟）[默认 30]: " NUM
            if [[ $NUM =~ ^[0-9]+$ ]]; then
                create_iplimit_jails ${NUM}
                if [[ $release == "alpine" ]]; then
                    rc-service fail2ban restart
                else
                    systemctl restart fail2ban
                fi
            else
                echo -e "${red}${NUM} 不是数字！请重试。${plain}"
            fi
            iplimit_main
            ;;
        3)
            confirm "确认解封 IP 限制中的所有用户吗？" "y"
            if [[ $? == 0 ]]; then
                fail2ban-client reload --restart --unban 3x-ipl
                truncate -s 0 "${iplimit_banned_log_path}"
                echo -e "${green}已成功解封所有用户。${plain}"
                iplimit_main
            else
                echo -e "${yellow}已取消。${plain}"
            fi
            iplimit_main
            ;;
        4)
            show_banlog
            iplimit_main
            ;;
        5)
            read -rp "请输入要封禁的 IP 地址: " ban_ip
            ip_validation
            if [[ $ban_ip =~ $ipv4_regex || $ban_ip =~ $ipv6_regex ]]; then
                fail2ban-client set 3x-ipl banip "$ban_ip"
                echo -e "${green}IP 地址 ${ban_ip} 已成功封禁。${plain}"
            else
                echo -e "${red}IP 地址格式无效！请重试。${plain}"
            fi
            iplimit_main
            ;;
        6)
            read -rp "请输入要解封的 IP 地址: " unban_ip
            ip_validation
            if [[ $unban_ip =~ $ipv4_regex || $unban_ip =~ $ipv6_regex ]]; then
                fail2ban-client set 3x-ipl unbanip "$unban_ip"
                echo -e "${green}IP 地址 ${unban_ip} 已成功解封。${plain}"
            else
                echo -e "${red}IP 地址格式无效！请重试。${plain}"
            fi
            iplimit_main
            ;;
        7)
            tail -f /var/log/fail2ban.log
            iplimit_main
            ;;
        8)
            service fail2ban status
            iplimit_main
            ;;
        9)
            if [[ $release == "alpine" ]]; then
                rc-service fail2ban restart
            else
                systemctl restart fail2ban
            fi
            iplimit_main
            ;;
        10)
            remove_iplimit
            iplimit_main
            ;;
        *)
            echo -e "${red}无效选项，请输入正确的数字。${plain}\n"
            iplimit_main
            ;;
    esac
}

setup_fail2ban_iplimit() {
    # Honor the same toggle the panel uses (isFail2BanEnabled): enabled when the
    # var is unset or exactly "true"; any other explicit value means the operator
    # opted out, so do nothing rather than install a fail2ban the panel ignores.
    if [[ -n "${XUI_ENABLE_FAIL2BAN+x}" && "${XUI_ENABLE_FAIL2BAN}" != "true" ]]; then
        echo -e "${yellow}XUI_ENABLE_FAIL2BAN=${XUI_ENABLE_FAIL2BAN}，已跳过 Fail2ban 配置。${plain}\n"
        return 0
    fi

    if ! command -v fail2ban-client &> /dev/null; then
        echo -e "${green}未安装 Fail2ban，正在安装...！${plain}\n"

        # Install fail2ban together with nftables. Recent fail2ban packages
        # default to `banaction = nftables-multiport` in /etc/fail2ban/jail.conf,
        # but the `nftables` package isn't pulled in as a dependency on most
        # minimal server images (Debian 12+, Ubuntu 24+, fresh RHEL-family).
        # Without `nft` in PATH the default sshd jail fails to ban with
        #   stderr: '/bin/sh: 1: nft: not found'
        # even though our own 3x-ipl jail uses iptables. Bundling the binary
        # at install time prevents that confusing log spam for new installs.
        case "${release}" in
            ubuntu)
                apt-get update
                if [[ "${os_version}" -ge 2400 ]]; then
                    apt-get install python3-pip -y
                    python3 -m pip install pyasynchat --break-system-packages
                fi
                apt-get install fail2ban nftables -y
                ;;
            debian)
                apt-get update
                if [ "$os_version" -ge 12 ]; then
                    apt-get install -y python3-systemd
                fi
                apt-get install -y fail2ban nftables
                ;;
            armbian)
                apt-get update && apt-get install fail2ban nftables -y
                ;;
            fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
                if [[ "${release}" != "fedora" ]] && ! dnf repolist enabled 2> /dev/null | grep -qiw epel; then
                    dnf install -y epel-release \
                        || dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E %rhel).noarch.rpm" \
                        || echo -e "${yellow}无法启用 EPEL 源；该发行版的 fail2ban 仅在 EPEL 中提供。${plain}"
                fi
                dnf makecache -y && dnf -y install fail2ban nftables
                ;;
            centos)
                if [[ "${VERSION_ID}" =~ ^7 ]]; then
                    yum makecache -y && yum install epel-release -y
                    yum -y install fail2ban nftables
                else
                    dnf makecache -y && dnf -y install fail2ban nftables
                fi
                ;;
            arch | manjaro | parch)
                pacman -Sy --noconfirm fail2ban nftables
                ;;
            alpine)
                apk add fail2ban nftables
                ;;
            *)
                echo -e "${red}不支持的操作系统，请检查脚本并手动安装所需软件包。${plain}\n"
                return 1
                ;;
        esac

        if ! command -v fail2ban-client &> /dev/null; then
            echo -e "${red}Fail2ban 安装失败。${plain}\n"
            return 1
        fi

        echo -e "${green}Fail2ban 安装成功！${plain}\n"
    else
        echo -e "${yellow}Fail2ban 已安装。${plain}\n"
    fi

    echo -e "${green}正在配置 IP 限制...${plain}\n"

    # make sure there's no conflict for jail files
    iplimit_remove_conflicts

    # Check if log file exists
    if ! test -f "${iplimit_banned_log_path}"; then
        touch ${iplimit_banned_log_path}
    fi

    # Check if service log file exists so fail2ban won't return error
    if ! test -f "${iplimit_log_path}"; then
        touch ${iplimit_log_path}
    fi

    # Create the iplimit jail files
    # we didn't pass the bantime here to use the default value
    create_iplimit_jails

    # Launching fail2ban
    if [[ $release == "alpine" ]]; then
        if [[ $(rc-service fail2ban status | grep -F 'status: started' -c) == 0 ]]; then
            rc-service fail2ban start
        else
            rc-service fail2ban restart
        fi
        rc-update add fail2ban
    else
        if ! systemctl is-active --quiet fail2ban; then
            systemctl start fail2ban
        else
            systemctl restart fail2ban
        fi
        systemctl enable fail2ban
    fi

    echo -e "${green}IP 限制安装并配置成功！${plain}\n"
    return 0
}

# install_iplimit is the interactive (menu) entry point: it runs the shared
# setup and then returns to the menu. The non-interactive installer path uses
# setup_fail2ban_iplimit directly via `x-ui setup-fail2ban`.
install_iplimit() {
    setup_fail2ban_iplimit
    before_show_menu
}

remove_iplimit() {
    echo -e "${green}\t1.${plain} 仅删除 IP 限制配置"
    echo -e "${green}\t2.${plain} 卸载 Fail2ban 与 IP 限制"
    echo -e "${green}\t0.${plain} 返回主菜单"
    read -rp "请选择: " num
    case "$num" in
        1)
            rm -f /etc/fail2ban/filter.d/3x-ipl.conf
            rm -f /etc/fail2ban/action.d/3x-ipl.conf
            rm -f /etc/fail2ban/jail.d/3x-ipl.conf
            if [[ $release == "alpine" ]]; then
                rc-service fail2ban restart
            else
                systemctl restart fail2ban
            fi
            echo -e "${green}IP 限制已删除！${plain}\n"
            before_show_menu
            ;;
        2)
            rm -rf /etc/fail2ban
            if [[ $release == "alpine" ]]; then
                rc-service fail2ban stop
            else
                systemctl stop fail2ban
            fi
            case "${release}" in
                ubuntu | debian | armbian)
                    apt-get remove -y fail2ban
                    apt-get purge -y fail2ban -y
                    apt-get autoremove -y
                    ;;
                fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
                    dnf remove fail2ban -y
                    dnf autoremove -y
                    ;;
                centos)
                    if [[ "${VERSION_ID}" =~ ^7 ]]; then
                        yum remove fail2ban -y
                        yum autoremove -y
                    else
                        dnf remove fail2ban -y
                        dnf autoremove -y
                    fi
                    ;;
                arch | manjaro | parch)
                    pacman -Rns --noconfirm fail2ban
                    ;;
                alpine)
                    apk del fail2ban
                    ;;
                *)
                    echo -e "${red}不支持的操作系统，请手动卸载 Fail2ban。${plain}\n"
                    exit 1
                    ;;
            esac
            echo -e "${green}Fail2ban 与 IP 限制已删除！${plain}\n"
            before_show_menu
            ;;
        0)
            show_menu
            ;;
        *)
            echo -e "${red}无效选项，请输入正确的数字。${plain}\n"
            remove_iplimit
            ;;
    esac
}

show_banlog() {
    local system_log="/var/log/fail2ban.log"

    echo -e "${green}正在检查封禁日志...${plain}\n"

    if [[ $release == "alpine" ]]; then
        if [[ $(rc-service fail2ban status | grep -F 'status: started' -c) == 0 ]]; then
            echo -e "${red}Fail2ban 服务未运行！${plain}\n"
            return 1
        fi
    else
        if ! systemctl is-active --quiet fail2ban; then
            echo -e "${red}Fail2ban 服务未运行！${plain}\n"
            return 1
        fi
    fi

    if [[ -f "$system_log" ]]; then
        echo -e "${green}fail2ban.log 中最近的封禁记录:${plain}"
        grep "3x-ipl" "$system_log" | grep -E "Ban|Unban" | tail -n 10 || echo -e "${yellow}未找到最近的封禁记录${plain}"
        echo ""
    fi

    if [[ -f "${iplimit_banned_log_path}" ]]; then
        echo -e "${green}3X-IPL 封禁日志记录:${plain}"
        if [[ -s "${iplimit_banned_log_path}" ]]; then
            grep -v "INIT" "${iplimit_banned_log_path}" | tail -n 10 || echo -e "${yellow}未找到封禁记录${plain}"
        else
            echo -e "${yellow}封禁日志文件为空${plain}"
        fi
    else
        echo -e "${red}未找到封禁日志文件: ${iplimit_banned_log_path}${plain}"
    fi

    echo -e "\n${green}当前 jail 状态:${plain}"
    fail2ban-client status 3x-ipl || echo -e "${yellow}无法获取 jail 状态${plain}"
}

create_iplimit_jails() {
    # Use default bantime if not passed => 30 minutes
    local bantime="${1:-30}"

    # Uncomment 'allowipv6 = auto' in fail2ban.conf
    sed -i 's/#allowipv6 = auto/allowipv6 = auto/g' /etc/fail2ban/fail2ban.conf

    # On Debian 12+ and Ubuntu 22.04+ fail2ban's default backend should be changed to systemd
    if [[ ( "${release}" == "debian" && ${os_version} -ge 12 ) || ( "${release}" == "ubuntu" && ${os_version} -ge 2200 ) ]]; then
        sed -i '0,/action =/s/backend = auto/backend = systemd/' /etc/fail2ban/jail.conf
    fi

    cat << EOF > /etc/fail2ban/jail.d/3x-ipl.conf
[3x-ipl]
enabled=true
backend=auto
filter=3x-ipl
action=3x-ipl
logpath=${iplimit_log_path}
maxretry=1
findtime=32
bantime=${bantime}m
EOF

    cat << EOF > /etc/fail2ban/filter.d/3x-ipl.conf
[Definition]
datepattern = ^%%Y/%%m/%%d %%H:%%M:%%S
failregex   = \[LIMIT_IP\]\s*Email\s*=\s*<F-USER>.+</F-USER>\s*\|\|\s*Disconnecting OLD IP\s*=\s*<ADDR>\s*\|\|\s*Timestamp\s*=\s*\d+
ignoreregex =
EOF

    # Ports to exempt from the ban so an over-limit proxy client can never lock
    # the administrator out of SSH or the panel. The ban still covers every other
    # TCP and UDP port (including all Xray inbounds, e.g. UDP-based Hysteria2), so
    # IP-limit keeps working for inbounds added later without regenerating these files.
    local ssh_ports
    ssh_ports=$(grep -oP '^[[:space:]]*Port[[:space:]]+\K[0-9]+' /etc/ssh/sshd_config 2>/dev/null | paste -sd, -)
    [[ -z "${ssh_ports}" ]] && ssh_ports="22"
    local panel_port
    panel_port=$(${xui_folder}/x-ui setting -show true 2>/dev/null | grep -Eo 'port: .+' | awk '{print $2}')
    local exempt_ports="${ssh_ports}"
    [[ -n "${panel_port}" ]] && exempt_ports="${exempt_ports},${panel_port}"

    cat << EOF > /etc/fail2ban/action.d/3x-ipl.conf
[INCLUDES]
before = iptables-allports.conf

[Definition]
actionstart = <iptables> -N f2b-<name>
              <iptables> -A f2b-<name> -j <returntype>
              <iptables> -I <chain> -j f2b-<name>

actionstop = <iptables> -D <chain> -j f2b-<name>
             <actionflush>
             <iptables> -X f2b-<name>

actioncheck = <iptables> -n -L <chain> | grep -q 'f2b-<name>[ \t]'

actionban = <iptables> -I f2b-<name> 1 -s <ip> -p tcp -m multiport ! --dports <exemptports> -j <blocktype>
            <iptables> -I f2b-<name> 1 -s <ip> -p udp -m multiport ! --dports <exemptports> -j <blocktype>
            echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   BAN   [Email] = <F-USER> [IP] = <ip> banned for <bantime> seconds." >> ${iplimit_banned_log_path}

actionunban = <iptables> -D f2b-<name> -s <ip> -p tcp -m multiport ! --dports <exemptports> -j <blocktype>
              <iptables> -D f2b-<name> -s <ip> -p udp -m multiport ! --dports <exemptports> -j <blocktype>
              echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   UNBAN   [Email] = <F-USER> [IP] = <ip> unbanned." >> ${iplimit_banned_log_path}

[Init]
name = default
chain = INPUT
exemptports = ${exempt_ports}
EOF

    echo -e "${green}已创建 IP 限制 jail 文件，封禁时长 ${bantime} 分钟。${plain}"
}

iplimit_remove_conflicts() {
    local jail_files=(
        /etc/fail2ban/jail.conf
        /etc/fail2ban/jail.local
    )

    for file in "${jail_files[@]}"; do
        # Check for [3x-ipl] config in jail file then remove it
        if test -f "${file}" && grep -qw '3x-ipl' ${file}; then
            sed -i "/\[3x-ipl\]/,/^$/d" ${file}
            echo -e "${yellow}正在清除 jail (${file}) 中 [3x-ipl] 的冲突配置！${plain}\n"
        fi
    done
}

SSH_port_forwarding() {
    local URL_lists=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
        "https://check-host.net/ip"
    )
    local server_ip=""
    for ip_address in "${URL_lists[@]}"; do
        local response=$(curl -s -w "\n%{http_code}" --max-time 3 "${ip_address}" 2> /dev/null)
        local http_code=$(echo "$response" | tail -n1)
        local ip_result=$(echo "$response" | head -n-1 | tr -d '[:space:]"')
        if [[ "${http_code}" == "200" && "${ip_result}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            server_ip="${ip_result}"
            break
        fi
    done

    if [[ -z "$server_ip" ]]; then
        echo -e "${yellow}无法自动检测服务器公网 IP。${plain}"
        while [[ -z "$server_ip" ]]; do
            read -rp "请输入服务器的公网 IPv4 地址: " server_ip
            server_ip="${server_ip// /}"
            if [[ ! "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo -e "${red}IPv4 地址无效，请重试。${plain}"
                server_ip=""
            fi
        done
    fi

    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    local existing_listenIP=$(${xui_folder}/x-ui setting -getListen true | grep -Eo 'listenIP: .+' | awk '{print $2}')
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep -Eo 'cert: .+' | awk '{print $2}')
    local existing_key=$(${xui_folder}/x-ui setting -getCert true | grep -Eo 'key: .+' | awk '{print $2}')

    local config_listenIP=""
    local listen_choice=""

    if [[ -n "$existing_cert" && -n "$existing_key" ]]; then
        echo -e "${green}面板已启用 SSL，连接安全。${plain}"
        before_show_menu
    fi
    if [[ -z "$existing_cert" && -z "$existing_key" && (-z "$existing_listenIP" || "$existing_listenIP" == "0.0.0.0") ]]; then
        echo -e "\n${red}警告：未找到证书和私钥！面板未加密。${plain}"
        echo "请申请证书或配置 SSH 端口转发。"
    fi

    if [[ -n "$existing_listenIP" && "$existing_listenIP" != "0.0.0.0" && (-z "$existing_cert" && -z "$existing_key") ]]; then
        echo -e "\n${green}当前 SSH 端口转发配置:${plain}"
        echo -e "标准 SSH 命令:"
        echo -e "${yellow}ssh -L 2222:${existing_listenIP}:${existing_port} root@${server_ip}${plain}"
        echo -e "\n如使用 SSH 密钥:"
        echo -e "${yellow}ssh -i <sshkeypath> -L 2222:${existing_listenIP}:${existing_port} root@${server_ip}${plain}"
        echo -e "\n连接后可通过以下地址访问面板:"
        echo -e "${yellow}http://localhost:2222${existing_webBasePath}${plain}"
    fi

    echo -e "\n请选择:"
    echo -e "${green}1.${plain} 设置监听 IP"
    echo -e "${green}2.${plain} 清除监听 IP"
    echo -e "${green}0.${plain} 返回主菜单"
    read -rp "请选择: " num

    case "$num" in
        1)
            if [[ -z "$existing_listenIP" || "$existing_listenIP" == "0.0.0.0" ]]; then
                echo -e "\n未配置监听 IP，请选择:"
                echo -e "1. 使用默认 IP (127.0.0.1)"
                echo -e "2. 自定义 IP"
                read -rp "请选择（1 或 2）: " listen_choice

                config_listenIP="127.0.0.1"
                [[ "$listen_choice" == "2" ]] && read -rp "请输入要监听的 IP: " config_listenIP

                ${xui_folder}/x-ui setting -listenIP "${config_listenIP}" > /dev/null 2>&1
                echo -e "${green}监听 IP 已设置为 ${config_listenIP}.${plain}"
                echo -e "\n${green}SSH 端口转发配置:${plain}"
                echo -e "标准 SSH 命令:"
                echo -e "${yellow}ssh -L 2222:${config_listenIP}:${existing_port} root@${server_ip}${plain}"
                echo -e "\n如使用 SSH 密钥:"
                echo -e "${yellow}ssh -i <sshkeypath> -L 2222:${config_listenIP}:${existing_port} root@${server_ip}${plain}"
                echo -e "\n连接后可通过以下地址访问面板:"
                echo -e "${yellow}http://localhost:2222${existing_webBasePath}${plain}"
                restart
            else
                config_listenIP="${existing_listenIP}"
                echo -e "${green}当前监听 IP 已经是 ${config_listenIP}.${plain}"
            fi
            ;;
        2)
            ${xui_folder}/x-ui setting -listenIP 0.0.0.0 > /dev/null 2>&1
            echo -e "${green}监听 IP 已清除。${plain}"
            restart
            ;;
        0)
            show_menu
            ;;
        *)
            echo -e "${red}无效选项，请输入正确的数字。${plain}\n"
            SSH_port_forwarding
            ;;
    esac
}

# PostgreSQL service management (for panels configured with XUI_DB_TYPE=postgres).

postgresql_installed() {
    command -v pg_lsclusters > /dev/null 2>&1 || command -v psql > /dev/null 2>&1 || command -v postgres > /dev/null 2>&1
}

# Prints "VER CLUSTER" of the first configured cluster on Debian-style installs (e.g. "16 main").
pg_cluster_info() {
    if command -v pg_lsclusters > /dev/null 2>&1; then
        pg_lsclusters 2> /dev/null | awk '$1 ~ /^[0-9]+$/ {print $1, $2; exit}'
    fi
}

# Resolves the systemd unit used to manage the PostgreSQL server.
pg_systemd_unit() {
    local info ver cluster
    info="$(pg_cluster_info)"
    if [[ -n "$info" ]]; then
        ver="${info%% *}"
        cluster="${info##* }"
        echo "postgresql@${ver}-${cluster}"
    else
        echo "postgresql"
    fi
}

postgresql_status() {
    if ! postgresql_installed; then
        LOGE "系统中似乎未安装 PostgreSQL。"
        return 1
    fi
    if command -v pg_lsclusters > /dev/null 2>&1; then
        pg_lsclusters
    else
        systemctl status "$(pg_systemd_unit)" --no-pager
    fi
    echo ""
    if command -v ss > /dev/null 2>&1; then
        local listening
        listening=$(ss -ltnp 2> /dev/null | grep ':5432')
        if [[ -n "$listening" ]]; then
            echo -e "${green}PostgreSQL 正在监听 5432 端口:${plain}"
            echo "$listening"
        else
            echo -e "${red}5432 端口无监听 - 数据库未运行。${plain}"
        fi
    fi
}

postgresql_start() {
    pg_require_installed || return 1
    if [[ $release == "alpine" ]]; then
        rc-service postgresql start
    else
        systemctl start "$(pg_systemd_unit)"
    fi
    sleep 1
    postgresql_status
}

postgresql_stop() {
    pg_require_installed || return 1
    if [[ $release == "alpine" ]]; then
        rc-service postgresql stop
    else
        systemctl stop "$(pg_systemd_unit)"
    fi
    LOGI "已发送 PostgreSQL 停止信号。"
}

postgresql_restart() {
    pg_require_installed || return 1
    if [[ $release == "alpine" ]]; then
        rc-service postgresql restart
    else
        systemctl restart "$(pg_systemd_unit)"
    fi
    sleep 1
    postgresql_status
}

postgresql_enable() {
    pg_require_installed || return 1
    if [[ $release == "alpine" ]]; then
        rc-update add postgresql default
    else
        systemctl enable "$(pg_systemd_unit)"
    fi
    if [[ $? == 0 ]]; then
        LOGI "已设置 PostgreSQL 开机自启。"
    else
        LOGE "设置 PostgreSQL 开机自启失败。"
    fi
}

postgresql_log() {
    pg_require_installed || return 1
    local info ver cluster logfile
    info="$(pg_cluster_info)"
    if [[ -n "$info" ]]; then
        ver="${info%% *}"
        cluster="${info##* }"
        logfile="/var/log/postgresql/postgresql-${ver}-${cluster}.log"
    fi
    if [[ -n "$logfile" && -f "$logfile" ]]; then
        tail -n 40 "$logfile"
    elif command -v journalctl > /dev/null 2>&1; then
        journalctl -u "$(pg_systemd_unit)" -n 40 --no-pager
    else
        LOGE "未找到 PostgreSQL 日志。"
    fi
}

pg_require_installed() {
    if ! postgresql_installed; then
        LOGE "未安装 PostgreSQL，请先使用本菜单选项 1（安装 PostgreSQL）。"
        return 1
    fi
}

# Completely removes the PostgreSQL server and ALL of its databases from the system.
# Gated behind an explicit confirmation because this is system-wide and irreversible:
# any other application sharing this PostgreSQL instance loses its data too. Mirrors the
# package names used by pg_install_local() so the right packages are removed per distro.
purge_postgresql() {
    echo ""
    echo -e "${yellow}该面板此前使用 PostgreSQL。${plain}"
    echo -e "${red}警告:${plain} 此操作会删除 PostgreSQL 服务以及本机上的${red}所有${plain}数据库，"
    echo -e "包括其他应用使用的数据库，且无法恢复。"
    confirm "是否同时清除 PostgreSQL 并删除其所有数据？" "n"
    if [[ $? != 0 ]]; then
        LOGI "已保留 PostgreSQL，其数据未被删除。"
        return 0
    fi

    if [[ $release == "alpine" ]]; then
        rc-service postgresql stop 2> /dev/null
        rc-update del postgresql 2> /dev/null
    else
        systemctl stop "$(pg_systemd_unit)" 2> /dev/null
        systemctl disable "$(pg_systemd_unit)" 2> /dev/null
    fi

    case "${release}" in
        ubuntu | debian | armbian)
            apt-get -y --purge remove 'postgresql*'
            apt-get -y autoremove --purge
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf remove -y postgresql postgresql-server postgresql-contrib
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum remove -y postgresql postgresql-server postgresql-contrib
            else
                dnf remove -y postgresql postgresql-server postgresql-contrib
            fi
            ;;
        arch | manjaro | parch)
            pacman -Rns --noconfirm postgresql
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper -q remove -y postgresql postgresql-server postgresql-contrib
            ;;
        alpine)
            apk del postgresql postgresql-contrib postgresql-client
            ;;
        *)
            LOGE "不支持自动清除 PostgreSQL 的发行版: ${release}，请手动卸载。"
            return 1
            ;;
    esac

    rm -rf /var/lib/postgresql /var/lib/pgsql /var/lib/postgres /etc/postgresql
    LOGI "PostgreSQL 已被清除。"
}

# RHEL-family initdb writes pg_hba.conf host rules with ident auth, which
# compares the OS username against the Postgres role and always rejects the
# randomly generated panel role over TCP (#5806). Prepend password-auth rules
# scoped to the panel database; first match wins, and md5 also accepts
# scram-sha-256-stored verifiers, so this works on every supported distro.
# Mirrors pg_ensure_hba_password_auth() from install.sh.
pg_ensure_hba_password_auth() {
    local pg_db="$1"
    local hba_file
    hba_file=$(sudo -u postgres psql -tAc 'SHOW hba_file' 2> /dev/null | tr -d '[:space:]')
    [[ -n "${hba_file}" && -f "${hba_file}" ]] || return 0
    grep -Eq "^host[[:space:]]+${pg_db}[[:space:]]" "${hba_file}" && return 0
    local tmp
    tmp=$(mktemp) || return 1
    {
        echo "# 由 3x-ui 添加：允许面板数据库使用密码登录。"
        echo "host    ${pg_db}    all    127.0.0.1/32    md5"
        echo "host    ${pg_db}    all    ::1/128         md5"
        cat "${hba_file}"
    } > "${tmp}" || {
        rm -f "${tmp}"
        return 1
    }
    cat "${tmp}" > "${hba_file}" || {
        rm -f "${tmp}"
        return 1
    }
    rm -f "${tmp}"
    sudo -u postgres psql -tAc 'SELECT pg_reload_conf()' > /dev/null 2>&1 || true
}

# Installs a local PostgreSQL server and creates a dedicated xui user/database.
# Progress goes to stderr; on success the connection DSN is printed to stdout so
# callers can capture it. Mirrors install_postgres_local() from install.sh, so the
# panel can be set up without re-running the remote install script.
pg_install_local() {
    local pg_user pg_pass pg_db pg_host pg_port
    pg_pass=$(gen_random_string 24)
    pg_db="xui"
    pg_host="127.0.0.1"
    pg_port="5432"

    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update >&2 && apt-get install -y -q postgresql >&2 || return 1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf install -y -q postgresql-server postgresql-contrib >&2 || return 1
            [[ -d /var/lib/pgsql/data && -f /var/lib/pgsql/data/PG_VERSION ]] || postgresql-setup --initdb >&2 || return 1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum install -y postgresql-server postgresql-contrib >&2 || return 1
            else
                dnf install -y -q postgresql-server postgresql-contrib >&2 || return 1
            fi
            [[ -d /var/lib/pgsql/data && -f /var/lib/pgsql/data/PG_VERSION ]] || postgresql-setup --initdb >&2 || return 1
            ;;
        arch | manjaro | parch)
            pacman -Sy --noconfirm postgresql >&2 || return 1
            if [[ ! -f /var/lib/postgres/data/PG_VERSION ]]; then
                sudo -u postgres initdb -D /var/lib/postgres/data >&2 || return 1
            fi
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper -q install -y postgresql-server postgresql-contrib >&2 || return 1
            if [[ ! -f /var/lib/pgsql/data/PG_VERSION ]]; then
                install -d -o postgres -g postgres -m 700 /var/lib/pgsql/data >&2 || return 1
                su - postgres -c "initdb -D /var/lib/pgsql/data" >&2 || return 1
            fi
            ;;
        alpine)
            apk add --no-cache postgresql postgresql-contrib >&2 || return 1
            if [[ ! -f /var/lib/postgresql/data/PG_VERSION ]]; then
                /etc/init.d/postgresql setup >&2 || return 1
            fi
            rc-update add postgresql default >&2 2> /dev/null || true
            rc-service postgresql start >&2 || return 1
            ;;
        *)
            echo -e "${red}不支持自动安装 PostgreSQL 的发行版: ${release}${plain}" >&2
            return 1
            ;;
    esac

    if [[ "${release}" != "alpine" ]]; then
        systemctl enable --now postgresql >&2 || return 1
    fi

    local i
    for i in 1 2 3 4 5; do
        sudo -u postgres psql -tAc 'SELECT 1' > /dev/null 2>&1 && break
        sleep 1
    done

    local existing_owner=""
    existing_owner=$(sudo -u postgres psql -tAc \
        "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='${pg_db}'" 2> /dev/null \
        | tr -d '[:space:]')
    if [[ -n "${existing_owner}" && "${existing_owner}" != "postgres" ]]; then
        pg_user="${existing_owner}"
    else
        pg_user=$(gen_random_string 8)
    fi

    sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${pg_user}'" 2> /dev/null \
        | grep -q 1 \
        || sudo -u postgres psql -c "CREATE USER \"${pg_user}\" WITH PASSWORD '${pg_pass}';" >&2 || return 1

    sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${pg_db}'" 2> /dev/null \
        | grep -q 1 \
        || sudo -u postgres psql -c "CREATE DATABASE \"${pg_db}\" OWNER \"${pg_user}\";" >&2 || return 1

    sudo -u postgres psql -c "ALTER USER \"${pg_user}\" WITH PASSWORD '${pg_pass}';" >&2 || return 1

    pg_ensure_hba_password_auth "${pg_db}" \
        || echo -e "${yellow}警告：无法更新 pg_hba.conf，PostgreSQL 可能拒绝面板的 TCP 登录（ident 认证）。${plain}" >&2

    local pg_pass_enc
    pg_pass_enc=$(printf '%s' "${pg_pass}" | sed -e 's/%/%25/g' -e 's/:/%3A/g' -e 's/@/%40/g' -e 's|/|%2F|g' -e 's/?/%3F/g' -e 's/#/%23/g')

    echo "postgres://${pg_user}:${pg_pass_enc}@${pg_host}:${pg_port}/${pg_db}?sslmode=disable"
    return 0
}

# Installs the PostgreSQL client tools (pg_dump/pg_restore) used by in-panel backup.
pg_ensure_client() {
    if command -v pg_dump > /dev/null 2>&1 && command -v pg_restore > /dev/null 2>&1; then
        return 0
    fi
    echo -e "${yellow}正在安装 PostgreSQL 客户端工具（pg_dump/pg_restore）...${plain}" >&2
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update >&2 && apt-get install -y -q postgresql-client >&2 || return 1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf install -y -q postgresql >&2 || return 1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum install -y postgresql >&2 || return 1
            else
                dnf install -y -q postgresql >&2 || return 1
            fi
            ;;
        arch | manjaro | parch)
            pacman -Sy --noconfirm postgresql >&2 || return 1
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper -q install -y postgresql >&2 || return 1
            ;;
        alpine)
            apk add --no-cache postgresql-client >&2 || return 1
            ;;
        *)
            return 1
            ;;
    esac
    command -v pg_dump > /dev/null 2>&1 && command -v pg_restore > /dev/null 2>&1
}

# Prints the major version of the installed pg_restore, or nothing when absent.
pg_client_major() {
    command -v pg_restore > /dev/null 2>&1 || return 1
    pg_restore --version 2> /dev/null | grep -oE '[0-9]+' | head -n 1
}

# Installs or upgrades the PostgreSQL client tools (pg_dump/pg_restore) so their
# major version is at least $1 (e.g. 17); with no argument any installed version
# is accepted. Falls back to the official PostgreSQL package repository when the
# distribution one is too old. Restoring a panel backup made by a newer pg_dump
# needs this:   x-ui pgclient <major>
pg_upgrade_client() {
    local want="$1" have
    if [[ -n "$want" && ! "$want" =~ ^[0-9]+$ ]]; then
        LOGE "PostgreSQL 主版本号 '${want}' 无效（应为数字，如 17）。"
        return 1
    fi
    have=$(pg_client_major)
    if [[ -n "$have" ]]; then
        if [[ -z "$want" || "$have" -ge "$want" ]]; then
            LOGI "PostgreSQL 客户端工具已安装（版本 ${have}）。"
            return 0
        fi
        LOGI "已安装的 PostgreSQL 客户端工具版本为 ${have}，需要 ${want} 或更高版本。"
    fi
    if [[ "${running_in_docker}" == "true" ]]; then
        LOGI "注意：容器内安装的软件包在容器重建后会丢失。"
    fi
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update >&2 || return 1
            if [[ -z "$want" ]]; then
                apt-get install -y -q postgresql-client >&2 || return 1
            elif ! apt-get install -y -q "postgresql-client-${want}" >&2; then
                LOGI "发行版仓库中没有 postgresql-client-${want}，正在添加 PostgreSQL 官方 apt 源..."
                apt-get install -y -q postgresql-common ca-certificates >&2 || return 1
                /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y >&2 || return 1
                apt-get install -y -q "postgresql-client-${want}" >&2 || return 1
            fi
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol | centos)
            local pkg_mgr="dnf"
            command -v dnf > /dev/null 2>&1 || pkg_mgr="yum"
            if [[ -z "$want" ]]; then
                "$pkg_mgr" install -y -q postgresql >&2 || return 1
            elif ! "$pkg_mgr" install -y -q "postgresql${want}" >&2; then
                local elver
                elver=$(rpm -E %rhel 2> /dev/null)
                if [[ ! "$elver" =~ ^[0-9]+$ ]]; then
                    LOGE "无法确定 Enterprise Linux 版本，请手动安装 PostgreSQL ${want} 客户端工具。"
                    return 1
                fi
                LOGI "已启用的仓库中没有 postgresql${want}，正在添加 PostgreSQL 官方 yum 源..."
                "$pkg_mgr" install -y "https://download.postgresql.org/pub/repos/yum/reporpms/EL-${elver}-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm" >&2 || return 1
                if [[ "$pkg_mgr" == "dnf" ]]; then
                    dnf -qy module disable postgresql >&2 || true
                fi
                "$pkg_mgr" install -y -q "postgresql${want}" >&2 || return 1
            fi
            ;;
        arch | manjaro | parch)
            pacman -Sy --noconfirm postgresql >&2 || return 1
            ;;
        opensuse-tumbleweed | opensuse-leap)
            if [[ -z "$want" ]] || ! zypper -q install -y "postgresql${want}" >&2; then
                zypper -q install -y postgresql >&2 || return 1
            fi
            ;;
        alpine)
            if [[ -z "$want" ]] || ! apk add --no-cache "postgresql${want}-client" >&2; then
                apk add --no-cache postgresql-client >&2 || return 1
            fi
            ;;
        *)
            LOGE "不支持的系统 '${release}'，请手动安装 PostgreSQL 客户端工具。"
            return 1
            ;;
    esac
    hash -r 2> /dev/null
    have=$(pg_client_major)
    if [[ -n "$want" && ( -z "$have" || "$have" -lt "$want" ) && -x "/usr/pgsql-${want}/bin/pg_restore" ]]; then
        ln -sf "/usr/pgsql-${want}/bin/pg_dump" /usr/local/bin/pg_dump
        ln -sf "/usr/pgsql-${want}/bin/pg_restore" /usr/local/bin/pg_restore
        hash -r 2> /dev/null
        have=$(pg_client_major)
    fi
    if [[ -z "$have" ]]; then
        LOGE "安装后仍无法使用 pg_dump/pg_restore。"
        return 1
    fi
    if [[ -n "$want" && "$have" -lt "$want" ]]; then
        LOGE "安装后 PostgreSQL 客户端工具版本为 ${have}，但需要 ${want} 或更高版本，请手动安装。"
        return 1
    fi
    LOGI "PostgreSQL 客户端工具已就绪（版本 ${have}）。"
    return 0
}

# Writes XUI_DB_TYPE/XUI_DB_DSN into the service env file, preserving other entries.
pg_write_env() {
    local dsn="$1" envfile
    envfile="$(xui_env_file_path)"
    install -d -m 755 "$(dirname "$envfile")"
    touch "$envfile"
    sed -i '/^XUI_DB_TYPE=/d; /^XUI_DB_DSN=/d' "$envfile"
    {
        echo "XUI_DB_TYPE=postgres"
        echo "XUI_DB_DSN=${dsn}"
    } >> "$envfile"
    chmod 600 "$envfile"
}

pg_install_server_action() {
    if postgresql_installed; then
        LOGI "系统中似乎已安装 PostgreSQL。"
        confirm "仍要继续配置吗？（确保 xui 数据库/用户存在）" "n" || return 0
    fi
    LOGI "正在安装 PostgreSQL 服务并创建专用用户/数据库..."
    local dsn
    dsn=$(pg_install_local)
    if [[ $? -ne 0 || -z "$dsn" ]]; then
        LOGE "PostgreSQL 安装失败。"
        return 1
    fi
    PG_LAST_DSN="$dsn"
    pg_ensure_client || LOGE "无法安装 pg_dump/pg_restore（面板数据库备份可能不可用）。"
    echo ""
    LOGI "PostgreSQL 已安装并就绪。"
    echo -e "${green}连接 DSN:${plain} ${dsn}"
    echo -e "${yellow}可使用选项 2 迁移 SQLite 数据并将面板切换到 PostgreSQL。${plain}"
}

# Copies the current SQLite data into PostgreSQL, then switches the panel over.
migrate_to_postgres() {
    if [[ ! -x "${xui_folder}/x-ui" ]]; then
        LOGE "面板尚未安装。"
        return 1
    fi
    echo ""
    echo -e "${yellow}此操作会将当前 SQLite 数据复制到 PostgreSQL 数据库，${plain}"
    echo -e "${yellow}然后将面板切换到 PostgreSQL 并重启。${plain}"
    echo -e "${red}目标数据库中已有的面板表将被清空并覆盖。${plain}"
    confirm "是否继续？" "n" || return 0

    local dsn="" pg_mode
    if [[ -n "$PG_LAST_DSN" ]]; then
        echo -e "本次会话中已创建 PostgreSQL 数据库:"
        echo -e "  ${green}${PG_LAST_DSN}${plain}"
        confirm "迁移到该数据库吗？" "y" && dsn="$PG_LAST_DSN"
    fi

    if [[ -z "$dsn" ]]; then
        echo ""
        echo -e "${green}\t1.${plain} 本机安装 PostgreSQL 并创建专用用户/库（推荐）"
        echo -e "${green}\t2.${plain} 使用已有 PostgreSQL 服务（输入 DSN）"
        read -rp "请选择 [1]: " pg_mode
        pg_mode="${pg_mode:-1}"
        if [[ "$pg_mode" == "2" ]]; then
            while [[ -z "$dsn" ]]; do
                read -rp "请输入 PostgreSQL DSN（postgres://user:pass@host:port/dbname?sslmode=disable）: " dsn
                dsn="${dsn// /}"
            done
        else
            LOGI "正在本机安装 PostgreSQL（可能需要一些时间）..."
            dsn=$(pg_install_local)
            if [[ $? -ne 0 || -z "$dsn" ]]; then
                LOGE "PostgreSQL 安装失败，已中止迁移。"
                return 1
            fi
            PG_LAST_DSN="$dsn"
        fi
    fi

    pg_ensure_client || LOGE "无法安装 pg_dump/pg_restore（面板内数据库备份/恢复可能不可用）。"

    LOGI "正在停止面板以获取一致性快照..."
    stop 0 > /dev/null 2>&1

    echo ""
    LOGI "正在将数据迁移到 PostgreSQL..."
    if ! ${xui_folder}/x-ui migrate-db --dsn "$dsn"; then
        LOGE "迁移失败，面板未切换到 PostgreSQL。"
        start 0 > /dev/null 2>&1
        return 1
    fi

    pg_write_env "$dsn"
    LOGI "已将数据库配置写入 $(xui_env_file_path) (XUI_DB_TYPE=postgres)."
    LOGI "正在以 PostgreSQL 模式重启面板..."
    restart 0
    sleep 1
    if check_status; then
        LOGI "迁移完成，面板现已运行在 PostgreSQL 上。"
    else
        LOGE "面板未能启动，请查看日志（主菜单选项 17），SQLite 数据仍完好保留。"
    fi
}

postgresql_menu() {
    echo -e "${green}\t1.${plain} ${green}安装${plain} PostgreSQL（服务端 + 客户端 + xui 库）"
    echo -e "${green}\t2.${plain} 迁移 SQLite ${green}->${plain} PostgreSQL"
    echo -e "${green}\t3.${plain} 状态（集群与 5432 端口）"
    echo -e "${green}\t4.${plain} ${green}启动${plain} PostgreSQL"
    echo -e "${green}\t5.${plain} ${red}停止${plain} PostgreSQL"
    echo -e "${green}\t6.${plain} 重启 PostgreSQL"
    echo -e "${green}\t7.${plain} ${green}启用${plain} 开机自启"
    echo -e "${green}\t8.${plain} 查看 PostgreSQL 日志"
    echo -e "${green}\t9.${plain} SQLite ${green}.db <-> .dump${plain} 转换"
    echo -e "${green}\t10.${plain} 安装/升级客户端工具（pg_dump/pg_restore）"
    echo -e "${green}\t0.${plain} 返回主菜单"
    read -rp "请选择: " choice
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            pg_install_server_action
            postgresql_menu
            ;;
        2)
            migrate_to_postgres
            postgresql_menu
            ;;
        3)
            postgresql_status
            postgresql_menu
            ;;
        4)
            postgresql_start
            postgresql_menu
            ;;
        5)
            postgresql_stop
            postgresql_menu
            ;;
        6)
            postgresql_restart
            postgresql_menu
            ;;
        7)
            postgresql_enable
            postgresql_menu
            ;;
        8)
            postgresql_log
            postgresql_menu
            ;;
        9)
            migrate_db_prompt
            postgresql_menu
            ;;
        10)
            read -rp "需要的 PostgreSQL 主版本号（留空则不限）: " pg_client_ver
            pg_upgrade_client "$pg_client_ver"
            postgresql_menu
            ;;
        *)
            echo -e "${red}无效选项，请输入正确的数字。${plain}\n"
            postgresql_menu
            ;;
    esac
}

# Convert between the panel's SQLite database and a portable .dump (SQL text)
# file using the bundled x-ui binary. With no arguments it dumps the installed
# panel database; an optional second argument overrides the output path.
#   x-ui migrateDB [file.db|file.dump] [output]
migrate_db() {
    local input="$1" output="$2"
    local default_db="/etc/x-ui/x-ui.db"
    local bin="${xui_folder}/x-ui"

    [[ -z "$input" ]] && input="$default_db"

    if [[ ! -x "$bin" ]]; then
        LOGE "未在 ${bin} 找到面板程序，是否已安装面板？"
        return 1
    fi

    if ! "$bin" migrate-db -h 2>&1 | grep -q -- '-dump'; then
        LOGE "当前面板版本尚不支持 .db <-> .dump 转换。"
        LOGE "请先更新面板（ww update）到支持 'migrate-db --dump/--restore' 的版本。"
        return 1
    fi

    if [[ ! -f "$input" ]]; then
        LOGE "未找到输入文件: ${input}"
        echo -e "用法: ${green}ww migrateDB [file.db|file.dump] [输出文件]${plain}"
        return 1
    fi

    local mode
    case "$input" in
        *.db | *.sqlite | *.sqlite3)
            mode="dump"
            ;;
        *.dump | *.sql)
            mode="restore"
            ;;
        *)
            if head -c 16 "$input" | grep -q "SQLite format 3"; then
                mode="dump"
            else
                mode="restore"
            fi
            ;;
    esac

    if [[ "$mode" == "dump" ]]; then
        [[ -z "$output" ]] && output="${input%.*}.dump"
        if [[ -f "$output" ]]; then
            confirm "输出文件 ${output} 已存在并将被覆盖，是否继续？" "n" || return 0
        fi
        LOGI "正在将 SQLite 数据库导出为 SQL 文本:"
        echo -e "  ${green}${input}${plain} -> ${green}${output}${plain}"
        if "$bin" migrate-db --src "$input" --dump "$output"; then
            LOGI "完成，已写入 ${output}。"
        else
            LOGE "导出失败。"
            return 1
        fi
    else
        [[ -z "$output" ]] && output="${input%.*}.db"
        if [[ "$output" == "$default_db" ]] && check_status > /dev/null 2>&1; then
            LOGE "面板正在运行，拒绝恢复到正在使用的数据库（${default_db}）。"
            LOGE "请先停止面板（ww stop）或选择其他输出路径。"
            return 1
        fi
        if [[ -f "$output" ]]; then
            confirm "输出文件 ${output} 已存在并将被覆盖，是否继续？" "n" || return 0
            rm -f "$output"
        fi
        LOGI "正在从 SQL 文本重建 SQLite 数据库:"
        echo -e "  ${green}${input}${plain} -> ${green}${output}${plain}"
        if "$bin" migrate-db --restore "$input" --out "$output"; then
            LOGI "完成，已创建 ${output}。"
        else
            LOGE "恢复失败。"
            rm -f "$output"
            return 1
        fi
    fi
}

# Interactive wrapper around migrate_db for the menu: prompts for the paths and
# lets migrate_db auto-detect the direction.
migrate_db_prompt() {
    local default_db="/etc/x-ui/x-ui.db"
    local input output
    echo -e "在 SQLite ${green}.db${plain} 与可移植的 ${green}.dump${plain} 之间转换（自动判断方向）。"
    read -rp "输入文件 [${default_db}]: " input
    input="${input:-$default_db}"
    read -rp "输出文件（留空则在输入文件旁自动命名）: " output
    migrate_db "$input" "$output"
}

show_usage() {
    echo -e "┌────────────────────────────────────────────────────────────────┐
│  ${blue}ww 控制菜单用法（子命令）:${plain}                                  │
│                                                              │
│  ${blue}ww${plain}                        - 面板管理脚本菜单                │
│  ${blue}ww start${plain}                  - 启动面板                        │
│  ${blue}ww stop${plain}                   - 停止面板                        │
│  ${blue}ww restart${plain}                - 重启面板                        │
│  ${blue}ww restart-xray${plain}           - 重启 Xray                       │
│  ${blue}ww status${plain}                 - 查看当前状态                    │
│  ${blue}ww settings${plain}               - 查看当前设置                    │
│  ${blue}ww enable${plain}                 - 设置开机自启                    │
│  ${blue}ww disable${plain}                - 取消开机自启                    │
│  ${blue}ww log${plain}                    - 查看日志                        │
│  ${blue}ww banlog${plain}                 - 查看 Fail2ban 封禁日志          │
│  ${blue}ww update${plain}                 - 更新面板                        │
│  ${blue}ww update-dev${plain}             - 更新到开发版（最新）            │
│  ${blue}ww update-all-geofiles${plain}    - 更新全部 geo 文件               │
│  ${blue}ww migrateDB [文件]${plain}       - .db <-> .dump 转换（SQLite）    │
│  ${blue}ww pgclient [版本]${plain}        - 升级 pg_dump/pg_restore 工具    │
│  ${blue}ww legacy${plain}                 - 安装指定历史版本                │
│  ${blue}ww install${plain}                - 安装面板                        │
│  ${blue}ww uninstall${plain}              - 卸载面板                        │
└────────────────────────────────────────────────────────────────┘"
}

show_menu() {
    echo -e "
╔────────────────────────────────────────────────╗
│  ${green}3X-UI 面板管理脚本（快捷命令: ww）${plain}          │
│  ${green}0.${plain} 退出脚本                                 │
│────────────────────────────────────────────────│
│  ${green}1.${plain} 安装面板                                 │
│  ${green}2.${plain} 更新面板                                 │
│  ${green}3.${plain} 更新到开发版（最新提交）                 │
│  ${green}4.${plain} 更新菜单脚本                             │
│  ${green}5.${plain} 安装指定历史版本                         │
│  ${green}6.${plain} 卸载面板                                 │
│────────────────────────────────────────────────│
│  ${green}7.${plain} 重置用户名与密码                         │
│  ${green}8.${plain} 重置面板访问路径                         │
│  ${green}9.${plain} 重置面板设置                             │
│  ${green}10.${plain} 修改面板端口                            │
│  ${green}11.${plain} 查看当前设置                            │
│────────────────────────────────────────────────│
│  ${green}12.${plain} 启动面板                                │
│  ${green}13.${plain} 停止面板                                │
│  ${green}14.${plain} 重启面板                                │
│  ${green}15.${plain} 重启 Xray                               │
│  ${green}16.${plain} 查看运行状态                            │
│  ${green}17.${plain} 日志管理                                │
│────────────────────────────────────────────────│
│  ${green}18.${plain} 设置开机自启                            │
│  ${green}19.${plain} 取消开机自启                            │
│────────────────────────────────────────────────│
│  ${green}20.${plain} SSL 证书管理                            │
│  ${green}21.${plain} Cloudflare SSL 证书                     │
│  ${green}22.${plain} IP 限制管理                             │
│  ${green}23.${plain} 防火墙管理                              │
│  ${green}24.${plain} SSH 端口转发管理                        │
│  ${green}25.${plain} PostgreSQL 管理                         │
│────────────────────────────────────────────────│
│  ${green}26.${plain} 开启 BBR                                │
│  ${green}27.${plain} 更新 Geo 文件                           │
│  ${green}28.${plain} Ookla 测速                              │
╚────────────────────────────────────────────────╝
"
    show_status
    echo && read -rp "请输入你的选择 [0-28]: " num

    case "${num}" in
        0)
            exit 0
            ;;
        1)
            check_uninstall && install
            ;;
        2)
            check_install && update
            ;;
        3)
            check_install && update_dev
            ;;
        4)
            check_install && update_menu
            ;;
        5)
            check_install && legacy_version
            ;;
        6)
            check_install && uninstall
            ;;
        7)
            check_install && reset_user
            ;;
        8)
            check_install && reset_webbasepath
            ;;
        9)
            check_install && reset_config
            ;;
        10)
            check_install && set_port
            ;;
        11)
            check_install && check_config
            ;;
        12)
            check_install && start
            ;;
        13)
            check_install && stop
            ;;
        14)
            check_install && restart
            ;;
        15)
            check_install && restart_xray
            ;;
        16)
            check_install && status
            ;;
        17)
            check_install && show_log
            ;;
        18)
            check_install && enable
            ;;
        19)
            check_install && disable
            ;;
        20)
            ssl_cert_issue_main
            ;;
        21)
            ssl_cert_issue_CF
            ;;
        22)
            iplimit_main
            ;;
        23)
            firewall_menu
            ;;
        24)
            SSH_port_forwarding
            ;;
        25)
            postgresql_menu
            ;;
        26)
            bbr_menu
            ;;
        27)
            update_geo
            ;;
        28)
            run_speedtest
            ;;
        *)
            LOGE "请输入正确的数字 [0-28]"
            ;;
    esac
}

if [[ $# > 0 ]]; then
    case $1 in
        "start")
            check_install 0 && start 0
            ;;
        "stop")
            check_install 0 && stop 0
            ;;
        "restart")
            check_install 0 && restart 0
            ;;
        "restart-xray")
            check_install 0 && restart_xray 0
            ;;
        "status")
            check_install 0 && status 0
            ;;
        "settings")
            check_install 0 && check_config 0
            ;;
        "enable")
            check_install 0 && enable 0
            ;;
        "disable")
            check_install 0 && disable 0
            ;;
        "log")
            check_install 0 && show_log 0
            ;;
        "banlog")
            check_install 0 && show_banlog 0
            ;;
        "setup-fail2ban")
            setup_fail2ban_iplimit
            ;;
        "update")
            check_install 0 && update 0
            ;;
        "update-dev")
            check_install 0 && update_dev 0
            ;;
        "legacy")
            check_install 0 && legacy_version 0
            ;;
        "install")
            check_uninstall 0 && install 0
            ;;
        "uninstall")
            check_install 0 && uninstall 0
            ;;
        "update-all-geofiles")
            geo_updated=0
            if check_install 0 && update_all_geofiles 0; then
                [[ $geo_updated -eq 0 ]] || restart 0
            fi
            ;;
        "migrateDB")
            migrate_db "$2" "$3"
            ;;
        "pgclient")
            pg_upgrade_client "$2"
            ;;
        *) show_usage ;;
    esac
else
    show_menu
fi

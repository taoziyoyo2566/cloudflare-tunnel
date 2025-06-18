#!/bin/bash

# Cloudflare Tunnel 管理脚本
# 作者: Claude Assistant
# 功能: 创建、配置和管理 Cloudflare Tunnel

set -e

# 配置变量
CONFIG_DIR="/etc/cloudflared"
CONFIG_FILE="$CONFIG_DIR/config.yml"
CREDENTIALS_DIR="/root/.cloudflared"
SERVICE_NAME="cloudflared"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        exit 1
    fi
}

# 检查cloudflared是否安装
check_cloudflared() {
    if ! command -v cloudflared &> /dev/null; then
        log_warning "cloudflared未安装，是否安装? (y/n)"
        read -r install_choice
        if [[ $install_choice == "y" || $install_choice == "Y" ]]; then
            install_cloudflared
        else
            log_error "cloudflared未安装，退出脚本"
            exit 1
        fi
    fi
}

# 安装cloudflared
install_cloudflared() {
    log_info "开始安装cloudflared..."
    
    # 检测系统架构
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64)
            ARCH="arm64"
            ;;
        armv7l)
            ARCH="arm"
            ;;
        *)
            log_error "不支持的架构: $ARCH"
            exit 1
            ;;
    esac
    
    # 下载并安装
    wget -O cloudflared.deb "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb"
    dpkg -i cloudflared.deb
    rm cloudflared.deb
    
    log_success "cloudflared安装完成"
}

# 创建新的tunnel
create_tunnel() {
    echo
    log_info "=== 创建新的Tunnel ==="
    
    read -p "请输入Tunnel名称: " tunnel_name
    if [[ -z "$tunnel_name" ]]; then
        log_error "Tunnel名称不能为空"
        return 1
    fi
    
    log_info "创建Tunnel: $tunnel_name"
    cloudflared tunnel create "$tunnel_name"
    
    # 创建配置目录
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$CREDENTIALS_DIR"
    
    # 获取tunnel ID
    tunnel_id=$(cloudflared tunnel list | grep "$tunnel_name" | awk '{print $1}')
    
    if [[ -z "$tunnel_id" ]]; then
        log_error "无法获取Tunnel ID"
        return 1
    fi
    
    log_success "Tunnel创建成功，ID: $tunnel_id"
    
    # 创建基础配置文件
    create_config_file "$tunnel_name"
    
    log_info "是否要添加域名配置? (y/n)"
    read -r add_domain
    if [[ $add_domain == "y" || $add_domain == "Y" ]]; then
        add_ingress_rule
    fi
}

# 创建配置文件
create_config_file() {
    local tunnel_name="$1"
    
    cat > "$CONFIG_FILE" << EOF
tunnel: $tunnel_name
credentials-file: $CREDENTIALS_DIR/$tunnel_name.json
ingress:
  - service: http_status:404
EOF
    
    log_success "配置文件已创建: $CONFIG_FILE"
}

# 列出所有tunnel
list_tunnels() {
    echo
    log_info "=== 当前所有Tunnel ==="
    cloudflared tunnel list
}

# 查看当前配置
show_config() {
    echo
    log_info "=== 当前配置文件内容 ==="
    if [[ -f "$CONFIG_FILE" ]]; then
        cat "$CONFIG_FILE"
    else
        log_warning "配置文件不存在: $CONFIG_FILE"
    fi
}

# 添加入口规则
add_ingress_rule() {
    echo
    log_info "=== 添加入口规则 ==="
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "配置文件不存在，请先创建Tunnel"
        return 1
    fi
    
    read -p "请输入域名 (例: example.com): " hostname
    if [[ -z "$hostname" ]]; then
        log_error "域名不能为空"
        return 1
    fi
    
    read -p "请输入本地服务地址 (例: http://127.0.0.1:8080): " service
    if [[ -z "$service" ]]; then
        log_error "服务地址不能为空"
        return 1
    fi
    
    log_info "是否需要特殊配置? (y/n)"
    read -r special_config
    
    origin_request=""
    if [[ $special_config == "y" || $special_config == "Y" ]]; then
        echo "请选择特殊配置:"
        echo "1) 忽略TLS验证 (noTLSVerify)"
        echo "2) 自定义超时时间"
        echo "3) 跳过"
        read -p "请选择 (1-3): " config_choice
        
        case $config_choice in
            1)
                origin_request="    originRequest:\n      noTLSVerify: true"
                ;;
            2)
                read -p "请输入超时时间(秒): " timeout
                origin_request="    originRequest:\n      connectTimeout: ${timeout}s"
                ;;
        esac
    fi
    
    # 备份当前配置
    cp "$CONFIG_FILE" "$CONFIG_FILE.backup"
    
    # 创建临时文件
    temp_file=$(mktemp)
    
    # 重新生成配置文件
    head -n -1 "$CONFIG_FILE" > "$temp_file"
    
    if [[ -n "$origin_request" ]]; then
        echo -e "  - hostname: $hostname\n    service: $service\n$origin_request" >> "$temp_file"
    else
        echo "  - hostname: $hostname" >> "$temp_file"
        echo "    service: $service" >> "$temp_file"
    fi
    
    echo "  - service: http_status:404" >> "$temp_file"
    
    mv "$temp_file" "$CONFIG_FILE"
    
    log_success "入口规则已添加"
    
    # 显示新配置
    echo
    log_info "更新后的配置:"
    cat "$CONFIG_FILE"
}

# 删除入口规则
remove_ingress_rule() {
    echo
    log_info "=== 删除入口规则 ==="
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "配置文件不存在"
        return 1
    fi
    
    # 显示当前规则
    log_info "当前入口规则:"
    grep -n "hostname:" "$CONFIG_FILE" | cat -n
    
    read -p "请输入要删除的域名: " hostname_to_remove
    if [[ -z "$hostname_to_remove" ]]; then
        log_error "域名不能为空"
        return 1
    fi
    
    # 备份配置
    cp "$CONFIG_FILE" "$CONFIG_FILE.backup"
    
    # 删除指定的规则块
    python3 -c "
import yaml
import sys

with open('$CONFIG_FILE', 'r') as f:
    config = yaml.safe_load(f)

new_ingress = []
for rule in config['ingress']:
    if 'hostname' not in rule or rule['hostname'] != '$hostname_to_remove':
        new_ingress.append(rule)

config['ingress'] = new_ingress

with open('$CONFIG_FILE', 'w') as f:
    yaml.dump(config, f, default_flow_style=False)
"
    
    log_success "入口规则已删除"
}

# 启动tunnel服务
start_tunnel() {
    echo
    log_info "=== 启动Tunnel服务 ==="
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "配置文件不存在，请先创建Tunnel"
        return 1
    fi
    
    # 安装服务
    cloudflared service install
    
    # 启动服务
    systemctl start "$SERVICE_NAME"
    systemctl enable "$SERVICE_NAME"
    
    log_success "Tunnel服务已启动并设置为开机自启"
    
    # 显示状态
    systemctl status "$SERVICE_NAME" --no-pager
}

# 停止tunnel服务
stop_tunnel() {
    echo
    log_info "=== 停止Tunnel服务 ==="
    
    systemctl stop "$SERVICE_NAME"
    systemctl disable "$SERVICE_NAME"
    
    log_success "Tunnel服务已停止"
}

# 重启tunnel服务
restart_tunnel() {
    echo
    log_info "=== 重启Tunnel服务 ==="
    
    systemctl restart "$SERVICE_NAME"
    
    log_success "Tunnel服务已重启"
    
    # 显示状态
    systemctl status "$SERVICE_NAME" --no-pager
}

# 查看服务状态
show_status() {
    echo
    log_info "=== Tunnel服务状态 ==="
    systemctl status "$SERVICE_NAME" --no-pager
    
    echo
    log_info "=== 最近日志 ==="
    journalctl -u "$SERVICE_NAME" --no-pager -n 20
}

# 删除tunnel
delete_tunnel() {
    echo
    log_info "=== 删除Tunnel ==="
    
    # 列出现有tunnel
    list_tunnels
    
    read -p "请输入要删除的Tunnel名称: " tunnel_name
    if [[ -z "$tunnel_name" ]]; then
        log_error "Tunnel名称不能为空"
        return 1
    fi
    
    log_warning "即将删除Tunnel: $tunnel_name"
    read -p "确认删除? (y/N): " confirm
    if [[ $confirm != "y" && $confirm != "Y" ]]; then
        log_info "操作已取消"
        return 0
    fi
    
    # 停止服务
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    
    # 删除tunnel
    cloudflared tunnel delete "$tunnel_name"
    
    # 删除配置文件
    rm -f "$CONFIG_FILE"
    rm -f "$CREDENTIALS_DIR/$tunnel_name.json"
    
    log_success "Tunnel已删除"
}

# 测试连接
test_tunnel() {
    echo
    log_info "=== 测试Tunnel连接 ==="
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "配置文件不存在"
        return 1
    fi
    
    log_info "运行连接测试..."
    cloudflared tunnel run --config "$CONFIG_FILE" &
    tunnel_pid=$!
    
    sleep 5
    
    # 检查进程是否还在运行
    if kill -0 $tunnel_pid 2>/dev/null; then
        log_success "Tunnel连接测试成功"
        kill $tunnel_pid
    else
        log_error "Tunnel连接测试失败"
    fi
}

# 备份配置
backup_config() {
    echo
    log_info "=== 备份配置 ==="
    
    backup_dir="/root/cloudflared_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    if [[ -f "$CONFIG_FILE" ]]; then
        cp "$CONFIG_FILE" "$backup_dir/"
    fi
    
    if [[ -d "$CREDENTIALS_DIR" ]]; then
        cp -r "$CREDENTIALS_DIR" "$backup_dir/"
    fi
    
    log_success "配置已备份到: $backup_dir"
}

# 主菜单
show_menu() {
    echo
    echo "=================================="
    echo "   Cloudflare Tunnel 管理脚本"
    echo "=================================="
    echo "1)  创建新的Tunnel"
    echo "2)  列出所有Tunnel"
    echo "3)  查看当前配置"
    echo "4)  添加入口规则"
    echo "5)  删除入口规则"
    echo "6)  启动Tunnel服务"
    echo "7)  停止Tunnel服务"
    echo "8)  重启Tunnel服务"
    echo "9)  查看服务状态"
    echo "10) 测试Tunnel连接"
    echo "11) 删除Tunnel"
    echo "12) 备份配置"
    echo "0)  退出"
    echo "=================================="
}

# 主函数
main() {
    check_root
    check_cloudflared
    
    while true; do
        show_menu
        read -p "请选择操作 (0-12): " choice
        
        case $choice in
            1) create_tunnel ;;
            2) list_tunnels ;;
            3) show_config ;;
            4) add_ingress_rule ;;
            5) remove_ingress_rule ;;
            6) start_tunnel ;;
            7) stop_tunnel ;;
            8) restart_tunnel ;;
            9) show_status ;;
            10) test_tunnel ;;
            11) delete_tunnel ;;
            12) backup_config ;;
            0) 
                log_info "退出脚本"
                exit 0
                ;;
            *)
                log_error "无效选择，请重新输入"
                ;;
        esac
        
        echo
        read -p "按Enter键继续..."
    done
}

# 执行主函数
main "$@"

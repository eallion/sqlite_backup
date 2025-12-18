#!/bin/bash

# SQLite 备份工具部署脚本
# 用法: ./deploy.sh [安装目录]

set -e

# 获取安装目录
INSTALL_DIR="${1:-/opt/sqlite-backup}"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 打印函数
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为 root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_warn "建议使用 root 用户运行此脚本以安装到系统目录"
        read -p "是否继续? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# 安装依赖
install_dependencies() {
    print_info "检查并安装依赖..."

    # 检查 sqlite3
    if ! command -v sqlite3 >/dev/null 2>&1; then
        print_warn "sqlite3 未安装，正在安装..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y sqlite3
        elif command -v yum >/dev/null 2>&1; then
            yum install -y sqlite3
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y sqlite3
        else
            print_error "无法自动安装 sqlite3，请手动安装"
            exit 1
        fi
    else
        print_info "sqlite3 已安装"
    fi

    # 检查 python3
    if ! command -v python3 >/dev/null 2>&1; then
        print_error "python3 未安装，请先安装 python3"
        exit 1
    fi

    # 检查 tar
    if ! command -v tar >/dev/null 2>&1; then
        print_error "tar 未安装，请先安装 tar"
        exit 1
    fi

    # 检查 xz
    if ! command -v xz >/dev/null 2>&1; then
        print_warn "xz 未安装，正在安装..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get install -y xz-utils
        elif command -v yum >/dev/null 2>&1; then
            yum install -y xz
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y xz
        else
            print_error "无法自动安装 xz，请手动安装"
            exit 1
        fi
    fi
}

# 安装 rclone（可选）
install_rclone() {
    print_info "是否安装 rclone 用于云存储支持?"
    read -p "安装 rclone? (y/N): " install_rclone
    if [[ "$install_rclone" =~ ^[Yy]$ ]]; then
        if ! command -v rclone >/dev/null 2>&1; then
            print_info "正在安装 rclone..."
            curl -s https://rclone.org/install.sh | sudo bash
        else
            print_info "rclone 已安装"
        fi
    fi
}

# 创建目录
create_directories() {
    print_info "创建安装目录: $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
}

# 复制文件
copy_files() {
    print_info "复制文件到安装目录..."

    # 获取当前脚本目录
    CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # 复制必需文件
    cp "$CURRENT_DIR/sqlite_backup.sh" "$INSTALL_DIR/"
    cp "$CURRENT_DIR/init_config.sh" "$INSTALL_DIR/"
    cp "$CURRENT_DIR/config.json" "$INSTALL_DIR/config.json.example" 2>/dev/null || true
    cp "$CURRENT_DIR/README.md" "$INSTALL_DIR/" 2>/dev/null || true
    cp "$CURRENT_DIR/RCLONE_SETUP.md" "$INSTALL_DIR/" 2>/dev/null || true

    # 设置权限
    chmod +x "$INSTALL_DIR/sqlite_backup.sh"
    chmod +x "$INSTALL_DIR/init_config.sh"
}

# 创建 systemd 服务文件（可选）
create_systemd_service() {
    print_info "是否创建 systemd 服务用于定时备份?"
    read -p "创建 systemd 服务? (y/N): " create_service

    if [[ "$create_service" =~ ^[Yy]$ ]]; then
        # 创建服务文件
        cat > /etc/systemd/system/sqlite-backup.service << EOF
[Unit]
Description=SQLite Database Backup
After=network.target

[Service]
Type=oneshot
User=root
ExecStart=$INSTALL_DIR/sqlite_backup.sh all
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

        # 创建定时器文件
        cat > /etc/systemd/system/sqlite-backup.timer << EOF
[Unit]
Description=SQLite Database Backup Timer
Requires=sqlite-backup.service

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

        # 重载 systemd
        systemctl daemon-reload

        print_info "systemd 服务已创建"
        print_info "启用服务: systemctl enable --now sqlite-backup.timer"
        print_info "查看状态: systemctl status sqlite-backup.timer"
    fi
}

# 创建 crontab（可选）
create_crontab() {
    print_info "是否创建 crontab 定时任务?"
    read -p "创建 crontab? (y/N): " create_cron

    if [[ "$create_cron" =~ ^[Yy]$ ]]; then
        read -p "备份时间 (例如 2:30 表示每天凌晨 2:30) [2:30]: " backup_time
        backup_time="${backup_time:-2:30}"

        # 解析时间
        hour=$(echo "$backup_time" | cut -d: -f1)
        minute=$(echo "$backup_time" | cut -d: -f2)

        # 添加到 crontab
        (crontab -l 2>/dev/null; echo "$minute $hour * * * $INSTALL_DIR/sqlite_backup.sh all >/dev/null 2>&1") | crontab -

        print_info "crontab 已添加: 每天 $backup_time 执行备份"
        print_info "查看 crontab: crontab -l"
    fi
}

# 显示安装完成信息
show_completion_info() {
    print_info "安装完成！"
    echo ""
    echo "安装目录: $INSTALL_DIR"
    echo "主脚本: $INSTALL_DIR/sqlite_backup.sh"
    echo ""
    echo "下一步:"
    echo "1. 初始化配置:"
    echo "   $INSTALL_DIR/sqlite_backup.sh init"
    echo "   或"
    echo "   $INSTALL_DIR/init_config.sh --help"
    echo ""
    echo "2. 添加数据库:"
    echo "   $INSTALL_DIR/sqlite_backup.sh auto"
    echo ""
    echo "3. 手动备份测试:"
    echo "   $INSTALL_DIR/sqlite_backup.sh all"
    echo ""
    echo "4. 查看帮助:"
    echo "   $INSTALL_DIR/sqlite_backup.sh help"
}

# 主函数
main() {
    print_info "开始部署 SQLite 备份工具..."

    # 检查参数
    if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
        echo "SQLite 备份工具部署脚本"
        echo ""
        echo "用法: $0 [安装目录]"
        echo ""
        echo "示例:"
        echo "  $0 /opt/sqlite-backup"
        echo "  $0 /usr/local/sqlite-backup"
        echo ""
        exit 0
    fi

    # 执行安装步骤
    check_root
    install_dependencies
    install_rclone
    create_directories
    copy_files

    # 创建定时任务（二选一）
    create_systemd_service
    if [ $? -ne 0 ]; then
        create_crontab
    fi

    show_completion_info
}

# 运行主函数
main "$@"
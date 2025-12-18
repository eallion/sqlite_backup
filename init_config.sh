#!/bin/bash

# 使用参数化配置的初始化脚本
# 用法: ./init_config.sh [选项]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd"
CONFIG_FILE="$SCRIPT_DIR/config.json"

# 默认值
ENABLE_RCLONE=false
RCLONE_REMOTE="s3"
RCLONE_PATH="sqlite-backups"
KEEP_LOCAL=true
RETENTION_DAYS=30
BACKUP_DIR=""

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --enable-rclone)
            ENABLE_RCLONE=true
            shift
            ;;
        --remote)
            RCLONE_REMOTE="$2"
            shift 2
            ;;
        --path)
            RCLONE_PATH="$2"
            shift 2
            ;;
        --no-keep-local)
            KEEP_LOCAL=false
            shift
            ;;
        --days)
            RETENTION_DAYS="$2"
            shift 2
            ;;
        --dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        *)
            echo "未知参数: $1"
            exit 1
            ;;
    esac
done

# 显示配置
echo "===== SQLite 备份配置 ====="
echo "rclone S3 上传: $([ "$ENABLE_RCLONE" = true ] && echo "启用" || echo "禁用")"
if [ "$ENABLE_RCLONE" = true ]; then
    echo "  远程名称: $RCLONE_REMOTE"
    echo "  路径前缀: $RCLONE_PATH"
    echo "  保留本地: $([ "$KEEP_LOCAL" = true ] && echo "是" || echo "否")"
fi
echo "备份保留天数: $RETENTION_DAYS 天"
echo "本地备份目录: ${BACKUP_DIR:-默认(./backups)}"
echo ""

# 询问确认
read -p "继续初始化配置? (Y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "取消初始化"
    exit 0
fi

# 备份现有配置
if [ -f "$CONFIG_FILE" ]; then
    backup_file="${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    echo "备份现有配置到: $backup_file"
    cp "$CONFIG_FILE" "$backup_file"
fi

# 创建配置
python3 -c "
import json

config = {
    'databases': [],
    'settings': {
        'sqlite_backup_dir': '$BACKUP_DIR',
        'rclone': {
            'enabled': True if '$ENABLE_RCLONE' == 'true' else False,
            'remote': '$RCLONE_REMOTE',
            'path': '$RCLONE_PATH',
            'keep_local': True if '$KEEP_LOCAL' == 'true' else False
        },
        'retention_days': int('$RETENTION_DAYS')
    }
}

with open('$CONFIG_FILE', 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
"

echo ""
echo "✓ 配置文件已创建: $CONFIG_FILE"
echo ""
echo "下一步:"
echo "1. 运行 './sqlite_backup.sh auto' 自动发现数据库"
echo "2. 或运行 './sqlite_backup.sh edit' 手动编辑配置"
echo "3. 然后运行 './sqlite_backup.sh all' 开始备份"
#!/bin/bash

# ===================================================================
# SQLite 备份脚本 - 统一版本
# 支持本地备份和 rclone 上传到 S3
# 用法: ./sqlite_backup.sh <数据库名称> <数据库路径>
# ===================================================================

# --- 获取脚本目录 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 查找配置文件 - 优先使用脚本所在目录，否则使用当前工作目录
if [ -f "$SCRIPT_DIR/config.json" ]; then
    CONFIG_FILE="$SCRIPT_DIR/config.json"
elif [ -f "$(pwd)/config.json" ]; then
    CONFIG_FILE="$(pwd)/config.json"
else
    CONFIG_FILE="$SCRIPT_DIR/config.json"
fi

# --- 读取配置 ---
read_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "错误: 配置文件不存在: $CONFIG_FILE"
        echo "请先运行: $0 init"
        exit 1
    fi

    # 使用 python 读取 JSON 配置
    python3 -c "
import json
import sys
import os

try:
    with open('$CONFIG_FILE', 'r') as f:
        config = json.load(f)

    # 设置环境变量供子进程使用
    settings = config.get('settings', {})

    script_dir = os.path.dirname(os.path.abspath('$CONFIG_FILE'))
    sqlite_dir = settings.get('sqlite_backup_dir') or os.path.join(script_dir, 'backups')
    print(f'export SQLITE_BACKUP_DIR=\"{sqlite_dir}\"')

    if settings.get('rclone', {}).get('enabled', False):
        rclone_config = settings['rclone']
        print(f'export RCLONE_REMOTE=\"{rclone_config.get(\"remote\", \"s3\")}\"')
        print(f'export RCLONE_PATH=\"{rclone_config.get(\"path\", \"sqlite-backups\")}\"')
        print(f'export KEEP_LOCAL=\"{str(rclone_config.get(\"keep_local\", True)).lower()}\"')
        print('export USE_RCLONE=true')
    else:
        print('export USE_RCLONE=false')

    print(f'export RETENTION_DAYS={settings.get(\"retention_days\", 30)}')

except Exception as e:
    print(f'Error reading config: {e}', file=sys.stderr)
    sys.exit(1)
"
}

# --- 初始化配置 ---
init_config() {
    echo "初始化配置文件..."

    # 检测是否是交互模式
    if [ -t 0 ] && [ -t 1 ]; then
        # 交互模式 - 标准输入和输出都是终端
        interactive=true
    else
        # 非交互模式 - 可能是管道或重定向
        interactive=false
    fi

    # 检查是否是交互模式
    if [ "$interactive" = true ]; then
        # 交互模式
        if [ -f "$CONFIG_FILE" ]; then
            echo "配置文件已存在: $CONFIG_FILE"
            # 备份现有配置
            local backup_file="${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
            echo "备份现有配置到: $backup_file"
            cp "$CONFIG_FILE" "$backup_file"

            read -p "是否要重新初始化? (y/N): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo "取消初始化"
                exit 0
            fi
        fi

        # 交互式配置
        echo ""
        echo "===== 配置 SQLite 备份目录 ====="
        read -p "本地备份目录 (留空使用默认 ./backups): " backup_dir
        echo ""

        # 配置 rclone
        echo "===== 配置 rclone S3 上传 ====="
        read -p "是否启用 rclone 上传到 S3? (y/N): " confirm_rclone
        echo
    else
        # 非交互模式 - 使用默认配置
        if [ -f "$CONFIG_FILE" ]; then
            echo "配置文件已存在，使用默认配置重新初始化..."
        fi

        # 使用默认配置
        backup_dir=""
        rclone_enabled="false"
        rclone_remote="s3"
        rclone_path="sqlite-backups"
        keep_local="true"
        retention_days="30"

        # 直接跳到创建配置
        create_config ""
        return
    fi

    local rclone_enabled="false"
    local rclone_remote="s3"
    local rclone_path="sqlite-backups"
    local keep_local="true"

    if [[ "$confirm_rclone" =~ ^[Yy]$ ]]; then
        rclone_enabled="true"

        # 检查是否安装了 rclone
        if ! command -v rclone >/dev/null 2>&1; then
            echo "⚠️  警告: 未检测到 rclone，请先安装 rclone"
            echo "   安装命令: curl https://rclone.org/install.sh | sudo bash"
            echo ""
        fi

        # 获取 rclone 远程列表
        echo "可用的 rclone 远程:"
        if command -v rclone >/dev/null 2>&1 && [ -f "${HOME:-/root}/.config/rclone/rclone.conf" ]; then
            rclone listremotes 2>/dev/null | sed 's/:$//' | while read -r remote; do
                echo "  - $remote"
            done
        else
            echo "  (未找到 rclone 配置，请先运行: rclone config)"
        fi
        echo ""

        read -p "输入要使用的远程名称 (默认: s3): " input_remote
        rclone_remote="${input_remote:-s3}"

        read -p "输入 S3 路径前缀 (默认: sqlite-backups): " input_path
        rclone_path="${input_path:-sqlite-backups}"

        echo ""
        read -p "上传后是否保留本地备份文件? (Y/n): " confirm_keep
        if [[ ! "$confirm_keep" =~ ^[Nn]$ ]]; then
            keep_local="true"
        else
            keep_local="false"
        fi
    fi

    # 配置保留天数
    echo ""
    read -p "备份保留天数 (默认: 30): " input_days
    local retention_days="${input_days:-30}"

    # 配置自定义扫描目录
    echo ""
    echo "配置自定义扫描目录 (可选，按回车跳过):"
    local scan_dirs=()
    local add_more="y"

    while [[ "$add_more" =~ ^[Yy]$ ]]; do
        read -p "请输入要扫描的目录路径 (按回车跳过): " input_dir
        if [ -n "$input_dir" ]; then
            if [ -d "$input_dir" ]; then
                scan_dirs+=("$input_dir")
                echo "  ✓ 已添加: $input_dir"
            else
                echo "  ⚠️  警告: 目录不存在: $input_dir"
            fi
        fi

        if [ ${#scan_dirs[@]} -gt 0 ]; then
            read -p "是否继续添加目录? (y/N): " add_more
            [[ ! "$add_more" =~ ^[Yy]$ ]] && break
        else
            break
        fi
    done

    # 将扫描目录保存到临时文件
    local temp_scan_dirs_file=$(mktemp)
    for dir in "${scan_dirs[@]}"; do
        echo "$dir" >> "$temp_scan_dirs_file"
    done
    create_config "$temp_scan_dirs_file"
    rm -f "$temp_scan_dirs_file"
}

# 创建配置文件的通用函数
create_config() {
    local scan_dirs_file="$1"
    local scan_dirs_array=()

    # 从文件中读取扫描目录
    if [ -n "$scan_dirs_file" ] && [ -f "$scan_dirs_file" ]; then
        while IFS= read -r dir; do
            [ -n "$dir" ] && scan_dirs_array+=("$dir")
        done < "$scan_dirs_file"
    fi

    # 备份现有配置（如果有）
    if [ -f "$CONFIG_FILE" ]; then
        local backup_file="${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
        echo "备份现有配置到: $backup_file"
        cp "$CONFIG_FILE" "$backup_file"
    fi

    # 将数组转换为 Python 可接受的 JSON 数组格式
    local scan_dirs_python="["
    for i in "${!scan_dirs_array[@]}"; do
        if [ $i -gt 0 ]; then
            scan_dirs_python+=", "
        fi
        scan_dirs_python+="\"${scan_dirs_array[$i]}\""
    done
    scan_dirs_python+="]"

    # 创建配置
    python3 -c "
import json

rclone_enabled_str = '$rclone_enabled'
keep_local_str = '$keep_local'
scan_dirs = $scan_dirs_python

config = {
    'databases': [],
    'settings': {
        'sqlite_backup_dir': '$backup_dir',
        'scan_dirs': scan_dirs,
        'rclone': {
            'enabled': True if rclone_enabled_str == 'true' else False,
            'remote': '$rclone_remote',
            'path': '$rclone_path',
            'keep_local': True if keep_local_str == 'true' else False
        },
        'retention_days': $retention_days
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
}

# --- 自动发现数据库 ---
discover_databases() {
    echo "正在自动发现 SQLite 数据库..." >&2

    # 获取要扫描的目录列表
    local workspace_dirs=()

    # 1. 第一优先级：扫描 Docker 容器对应的数据目录
    echo "检查 Docker 容器..." >&2
    if command -v docker >/dev/null 2>&1; then
        # 直接获取 Docker 容器的挂载目录并添加到数组
        local docker_mounts=$(docker ps -a --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}} {{end}}{{end}}' 2>/dev/null)
        for mount_dir in $docker_mounts; do
            [ -n "$mount_dir" ] && [ -d "$mount_dir" ] && workspace_dirs+=("$mount_dir")
        done
    fi

    # 2. 第二优先级：脚本所在目录及其子目录
    workspace_dirs+=("$SCRIPT_DIR")

    # 3. 第三优先级：脚本所在目录的兄弟目录及其子目录
    local parent_dir=$(dirname "$SCRIPT_DIR")
    if [ "$parent_dir" != "/" ]; then
        for sibling_dir in "$parent_dir"/*; do
            # 跳过脚本目录本身（已经添加）
            [ "$sibling_dir" = "$SCRIPT_DIR" ] && continue
            # 只添加实际存在的目录
            [ -d "$sibling_dir" ] && workspace_dirs+=("$sibling_dir")
        done
    fi

    # 4. 第四优先级：自定义扫描目录
    if [ -f "$CONFIG_FILE" ]; then
        local custom_dirs_file=$(mktemp)
        python3 -c "
import json
try:
    with open('$CONFIG_FILE', 'r') as f:
        config = json.load(f)
        scan_dirs = config.get('settings', {}).get('scan_dirs', [])
        for dir in scan_dirs:
            print(dir)
except Exception as e:
    pass
" 2>/dev/null > "$custom_dirs_file"

        if [ -s "$custom_dirs_file" ]; then
            echo "使用自定义扫描目录:" >&2
            while IFS= read -r dir; do
                echo "  - $dir" >&2
                workspace_dirs+=("$dir")
            done < "$custom_dirs_file"
        fi
        rm -f "$custom_dirs_file"
    fi

    # 5. 第五优先级：Docker volume 目录
    local docker_volume_dirs="/var/lib/docker/volumes"
    if [ -d "$docker_volume_dirs" ]; then
        workspace_dirs+=("$docker_volume_dirs")
    fi

    local found=()

    for workspace_dir in "${workspace_dirs[@]}"; do
        # 使用 eval 展开通配符
        for actual_dir in $(eval echo "$workspace_dir" 2>/dev/null); do
            [ ! -d "$actual_dir" ] && continue

            # 跳过垃圾箱和临时目录（使用 basename 进行精确匹配）
            local dir_basename=$(basename "$actual_dir")
            [[ "$dir_basename" =~ ^(Trash|\.trash|tmp|temp|cache|backups)$ ]] && continue
            [[ "$actual_dir" =~ (\.local/share) ]] && continue

            echo "扫描目录: $actual_dir" >&2

            # 查找 Docker Compose 文件
            local compose_files=$(find "$actual_dir" -type f \( -name "docker-compose.yml" -o -name "docker-compose.yaml" -o -name "compose.yml" -o -name "compose.yaml" \) 2>/dev/null)

            if [ -n "$compose_files" ]; then
                # 有 Docker Compose 文件，按项目扫描
                echo "$compose_files" | while read -r compose_file; do
                    local project_dir=$(dirname "$compose_file")
                    local project_name=$(basename "$project_dir")

                    # 跳过备份目录本身
                    [[ "$project_dir" =~ (backups|\.trash|Trash) ]] && continue

                    # 扫描数据库文件
                    find "$project_dir" -maxdepth 5 -type f \( -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" \) 2>/dev/null | while read -r db_file; do
                        # 跳过临时文件和垃圾箱文件（检查文件名和父目录名）
                        local file_basename=$(basename "$db_file")
                        local parent_dirname=$(basename "$(dirname "$db_file")")
                        [[ "$file_basename" =~ (cache|tmp|temp|journal|-wal|-shm) ]] && continue
                        [[ "$parent_dirname" =~ (cache|tmp|temp|\.git|node_modules|__pycache__|\.trash|Trash) ]] && continue
                        [[ "$db_file" =~ (files/) ]] && continue

                        # 检查文件大小
                        [ $(stat -c%s "$db_file" 2>/dev/null || echo 0) -lt 1024 ] && continue

                        local db_name=$(basename "$db_file" | sed 's/\.(db|sqlite3?)$//')
                        local service_name="${project_name}_${db_name}"

                        echo "$service_name|$db_file"
                    done
                done
            else
                # 没有 Docker Compose 项目，直接扫描 SQLite 数据库
                # 直接在扫描目录中查找 SQLite 数据库
                find "$actual_dir" -maxdepth 3 -type f \( -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" \) 2>/dev/null | while read -r db_file; do
                    # 跳过临时文件和垃圾箱文件（检查文件名和父目录名）
                    local file_basename=$(basename "$db_file")
                    local parent_dirname=$(basename "$(dirname "$db_file")")
                    [[ "$file_basename" =~ (cache|tmp|temp|journal|-wal|-shm) ]] && continue
                    [[ "$parent_dirname" =~ (cache|tmp|temp|\.git|node_modules|__pycache__|\.trash|Trash) ]] && continue
                    [[ "$db_file" =~ (files/) ]] && continue

                    # 跳过备份目录中的文件
                    [[ "$db_file" =~ (backups/) ]] && continue

                    # 检查文件大小
                    [ $(stat -c%s "$db_file" 2>/dev/null || echo 0) -lt 1024 ] && continue

                    # 提取项目名称和数据库文件名
                    local dir_name=$(basename "$(dirname "$db_file")")
                    local db_name=$(basename "$db_file" | sed 's/\.(db|sqlite3?)$//')

                    # 如果目录名是数据目录，使用父目录名作为项目名
                    if [[ "$dir_name" =~ ^(data|db|database|sqlite|storage)$ ]]; then
                        local parent_dir=$(basename "$(dirname "$(dirname "$db_file")")")
                        echo "${parent_dir}_${db_name}|$db_file"
                    else
                        echo "${dir_name}_${db_name}|$db_file"
                    fi
                done
            fi
        done
    done
}

# --- 添加发现的数据库到配置 ---
auto_discover() {
    local discovered=$(discover_databases | sort -u)

    if [ -z "$discovered" ]; then
        echo "未发现任何 SQLite 数据库"
        return 1
    fi

    echo "发现的数据库："
    echo "$discovered" | while IFS='|' read -r name path; do
        echo "  - $name: $path"
    done

    echo
    read -p "是否要将这些数据库添加到配置文件? (y/N): " confirm
    echo

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 备份现有配置
        [ -f "$CONFIG_FILE" ] && cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"

        # 生成新的 JSON 配置
        python3 -c "
import json
import os

# 读取现有配置
config = {'databases': [], 'settings': {}}
if os.path.exists('$CONFIG_FILE'):
    with open('$CONFIG_FILE', 'r') as f:
        config = json.load(f)

# 处理发现的数据库
discovered = '''$discovered'''.strip()
for line in discovered.split('\n'):
    if '|' in line:
        name, path = line.split('|', 1)
        # 检查是否已存在
        exists = any(db['name'] == name and db['path'] == path for db in config['databases'])
        if not exists:
            config['databases'].append({
                'name': name,
                'path': path,
                'enabled': True
            })

# 保存配置
with open('$CONFIG_FILE', 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)

print(f'已添加 {len([db for db in config[\"databases\"] if \"enabled\" in db and db[\"enabled\"]])} 个数据库到配置文件')
"
    fi
}

# --- 列出配置的数据库 ---
list_databases() {
    echo "配置的数据库："
    python3 -c "
import json

with open('$CONFIG_FILE', 'r') as f:
    config = json.load(f)

databases = config.get('databases', [])
if not databases:
    print('  (无数据库配置)')
else:
    for i, db in enumerate(databases, 1):
        status = '启用' if db.get('enabled', True) else '禁用'
        print(f'  {i}. {db[\"name\"]} - {db[\"path\"]} ({status})')
"
}

# --- 执行备份 ---
backup_database() {
    local db_name="$1"
    local db_path="$2"

    # 读取配置并设置环境变量
    eval "$(read_config)"

    # 提取项目名称
    local project_name="$db_name"

    # 尝试从数据库路径中提取项目名称
    local dir_name=$(basename "$(dirname "$db_path")")
    local parent_dir=$(basename "$(dirname "$(dirname "$db_path")")")

    # 如果数据库名称是 项目名_数据库格式，使用项目名
    if [[ "$db_name" == *"_"* ]]; then
        project_name="${db_name%_*}"
    # 如果数据库所在目录名是常见的数据库名，使用父目录名作为项目名
    elif [[ "$dir_name" =~ ^(data|db|database|sqlite|storage)$ ]]; then
        project_name="$parent_dir"
    # 否则使用目录名作为项目名
    else
        project_name="$dir_name"
    fi

    # 清理项目名称中的特殊字符
    project_name=$(echo "$project_name" | sed 's/[^a-zA-Z0-9_-]//g')

    # 创建备份目录结构
    mkdir -p "$SQLITE_BACKUP_DIR/$project_name"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)

    # 备份文件名
    local backup_filename="${db_name}_sqlite_${TIMESTAMP}.sqlite3"
    local temp_backup_path="/tmp/${backup_filename}"
    local final_backup_file="${SQLITE_BACKUP_DIR}/${project_name}/${db_name}_sqlite_${TIMESTAMP}.tar.xz"
    local s3_path="${RCLONE_PATH}/${project_name}"

    echo "======================================================"
    echo "备份 SQLite 数据库: $db_name"
    echo "项目名称: $project_name"
    echo "数据库路径: $db_path"
    echo "备份文件: $final_backup_file"
    [ "$USE_RCLONE" = "true" ] && echo "将上传到: ${RCLONE_REMOTE}:${s3_path}/"
    echo "======================================================"

    # 检查 sqlite3
    if ! command -v sqlite3 >/dev/null 2>&1; then
        echo "错误: sqlite3 未安装"
        return 1
    fi

    # 处理 WAL 模式
    if [ -f "${db_path}-wal" ] || [ "$(sqlite3 "$db_path" "PRAGMA journal_mode;" 2>/dev/null | tr '[:upper:]' '[:lower:]')" = "wal" ]; then
        echo "检测到 WAL 模式，执行检查点..."
        if ! sqlite3 "$db_path" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1; then
            echo "⚠️ 检查点失败，尝试使用强制模式..."
            sqlite3 "$db_path" "PRAGMA wal_checkpoint(RESTART);" >/dev/null 2>&1
        fi

        # 等待一小段时间让检查点完成
        sleep 1
    fi

    # 创建备份
    echo "创建一致性备份..."
    # 使用超时和详细的错误信息
    local backup_output
    if ! backup_output=$(sqlite3 "$db_path" ".timeout 30000" ".backup '$temp_backup_path'" 2>&1); then
        echo "错误: 备份失败"
        echo "详细信息: $backup_output"
        echo "数据库路径: $db_path"
        echo "临时备份路径: $temp_backup_path"
        echo "数据库状态: $(sqlite3 "$db_path" "PRAGMA journal_mode;" 2>/dev/null || echo "未知")"
        echo "数据库大小: $(stat -c%s "$db_path" 2>/dev/null || echo "未知")"
        return 1
    fi

    # 压缩
    echo "压缩备份文件..."
    if ! tar -C "$(dirname "$temp_backup_path")" -c "$backup_filename" | xz -c -3 > "$final_backup_file"; then
        echo "错误: 压缩失败"
        rm -f "$temp_backup_path"
        return 1
    fi

    # 清理临时文件
    rm -f "$temp_backup_path"

    # 上传到 S3（如果启用）
    if [ "$USE_RCLONE" = "true" ]; then
        if command -v rclone >/dev/null 2>&1; then
            echo "上传到 S3..."
            # 确保远程目录存在
            rclone mkdir "${RCLONE_REMOTE}:${s3_path}" 2>/dev/null || true
            if rclone copy "$final_backup_file" "${RCLONE_REMOTE}:${s3_path}/" --progress; then
                echo "✓ 上传成功"
            else
                echo "⚠️ 上传失败，但本地备份已完成"
            fi
        else
            echo "⚠️ rclone 未安装，跳过上传"
        fi
    fi

    # 清理本地文件（如果配置了不保留）
    if [ "$USE_RCLONE" = "true" ] && [ "$KEEP_LOCAL" = "false" ]; then
        rm -f "$final_backup_file"
        echo "✓ 本地备份文件已删除"
    else
        echo "✓ 备份完成"
        echo "文件大小: $(du -sh "$final_backup_file" | cut -f1)"
    fi

    # 清理旧备份
    echo "清理 ${RETENTION_DAYS} 天前的旧备份..."
    # 清理本地备份
    find "$SQLITE_BACKUP_DIR/$project_name" -name "${db_name}_sqlite_*.tar.xz" -mtime +$RETENTION_DAYS -delete 2>/dev/null
    # 如果项目目录为空，删除项目目录
    rmdir "$SQLITE_BACKUP_DIR/$project_name" 2>/dev/null || true

    # 清理 S3 上的旧备份
    if [ "$USE_RCLONE" = "true" ] && command -v rclone >/dev/null 2>&1; then
        rclone delete "${RCLONE_REMOTE}:${s3_path}/" --min-age ${RETENTION_DAYS}d --include "${db_name}_sqlite_*.tar.xz" 2>/dev/null
        # 检查项目目录是否为空，如果为空则删除
        local file_count=$(rclone ls "${RCLONE_REMOTE}:${s3_path}/" 2>/dev/null | wc -l)
        if [ "$file_count" -eq 0 ]; then
            rclone rmdir "${RCLONE_REMOTE}:${s3_path}/" 2>/dev/null || true
        fi
    fi

    return 0
}

# --- 批量备份 ---
backup_all() {
    # 读取配置
    python3 -c "
import json
import sys

try:
    with open('$CONFIG_FILE', 'r') as f:
        config = json.load(f)

    databases = config.get('databases', [])
    for db in databases:
        if db.get('enabled', True):
            print(f'{db[\"name\"]}|{db[\"path\"]}')
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
" | while IFS='|' read -r name path; do
        [ -z "$name" ] && continue
        echo
        backup_database "$name" "$path"
        echo "----------------------------------------"
    done
}

# --- 配置 rclone ---
configure_rclone() {
    echo "===== 配置 rclone S3 上传 ====="

    # 读取现有配置
    local rclone_enabled="false"
    local rclone_remote="s3"
    local rclone_path="sqlite-backups"
    local keep_local="true"

    if [ -f "$CONFIG_FILE" ]; then
        rclone_enabled=$(python3 -c "
import json
with open('$CONFIG_FILE', 'r') as f:
    config = json.load(f)
rclone = config.get('settings', {}).get('rclone', {})
print(rclone.get('enabled', False))
")

        rclone_remote=$(python3 -c "
import json
with open('$CONFIG_FILE', 'r') as f:
    config = json.load(f)
rclone = config.get('settings', {}).get('rclone', {})
print(rclone.get('remote', 's3'))
")

        rclone_path=$(python3 -c "
import json
with open('$CONFIG_FILE', 'r') as f:
    config = json.load(f)
rclone = config.get('settings', {}).get('rclone', {})
print(rclone.get('path', 'sqlite-backups'))
")

        keep_local=$(python3 -c "
import json
with open('$CONFIG_FILE', 'r') as f:
    config = json.load(f)
rclone = config.get('settings', {}).get('rclone', {})
print(rclone.get('keep_local', True))
")
    fi

    # 询问是否启用
    if [ "$rclone_enabled" = "True" ]; then
        echo "当前状态: rclone 已启用"
        echo "  远程名称: $rclone_remote"
        echo "  路径前缀: $rclone_path"
        echo "  保留本地: $keep_local"
        echo ""
        read -p "是否要重新配置? (y/N): " confirm_reconfig
        if [[ ! "$confirm_reconfig" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi

    # 检查是否安装了 rclone
    if ! command -v rclone >/dev/null 2>&1; then
        echo "⚠️  警告: 未检测到 rclone"
        echo "   安装命令: curl https://rclone.org/install.sh | sudo bash"
        echo ""
        read -p "是否继续配置? (y/N): " confirm_continue
        if [[ ! "$confirm_continue" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi

    # 获取远程列表
    echo "可用的 rclone 远程:"
    if command -v rclone >/dev/null 2>&1 && [ -f "${HOME:-/root}/.config/rclone/rclone.conf" ]; then
        rclone listremotes 2>/dev/null | sed 's/:$//' | while read -r remote; do
            echo "  - $remote"
        done
    else
        echo "  (未找到 rclone 配置，请先运行: rclone config)"
    fi
    echo ""

    # 输入配置
    read -p "输入要使用的远程名称 (默认: s3): " input_remote
    rclone_remote="${input_remote:-s3}"

    read -p "输入 S3 路径前缀 (默认: sqlite-backups): " input_path
    rclone_path="${input_path:-sqlite-backups}"

    echo ""
    read -p "上传后是否保留本地备份文件? (Y/n): " confirm_keep_local
    if [[ ! "$confirm_keep_local" =~ ^[Nn]$ ]]; then
        keep_local="true"
    else
        keep_local="false"
    fi

    # 更新配置
    python3 -c "
import json

# 读取现有配置
with open('$CONFIG_FILE', 'r') as f:
    config = json.load(f)

# 确保 settings 和 rclone 存在
if 'settings' not in config:
    config['settings'] = {}
if 'rclone' not in config['settings']:
    config['settings']['rclone'] = {}

# 更新 rclone 配置
config['settings']['rclone']['enabled'] = True
config['settings']['rclone']['remote'] = '$rclone_remote'
config['settings']['rclone']['path'] = '$rclone_path'
keep_local_str = '$keep_local'
config['settings']['rclone']['keep_local'] = True if keep_local_str == 'true' else False

# 保存配置
with open('$CONFIG_FILE', 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)

print('配置已更新')
"

    echo ""
    echo "✓ rclone 配置已更新"
    echo "  远程名称: $rclone_remote"
    echo "  路径前缀: $rclone_path"
    echo "  保留本地: $keep_local"
}

# --- 显示帮助 ---
show_help() {
    echo "SQLite 备份脚本"
    echo ""
    echo "用法: $0 <命令> [参数]"
    echo ""
    echo "命令:"
    echo "  init                  初始化配置文件"
    echo "  rclone                配置 rclone S3 上传"
    echo "  discover              自动发现数据库"
    echo "  auto                  自动发现并添加到配置"
    echo "  list                  列出配置的数据库"
    echo "  backup <name> <path>  备份单个数据库"
    echo "  all                   备份所有启用的数据库"
    echo "  edit                  编辑配置文件"
    echo "  help                  显示此帮助"
    echo ""
    echo "配置文件: $CONFIG_FILE"
}

# --- 主函数 ---
main() {
    case "${1:-help}" in
        init)
            init_config
            ;;
        rclone)
            configure_rclone
            ;;
        discover)
            discover_databases
            ;;
        auto)
            auto_discover
            ;;
        list)
            list_databases
            ;;
        backup)
            if [ $# -lt 3 ]; then
                echo "错误: 缺少参数"
                echo "用法: $0 backup <名称> <路径>"
                exit 1
            fi
            backup_database "$2" "$3"
            ;;
        all|"")
            backup_all
            ;;
        edit)
            ${EDITOR:-nano} "$CONFIG_FILE"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            echo "错误: 未知命令 $1"
            show_help
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"
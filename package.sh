#!/bin/bash

# SQLite 备份工具打包脚本

set -e

# 获取版本
VERSION=$(date +%Y%m%d_%H%M%S)
PACKAGE_NAME="sqlite-backup-${VERSION}"
BUILD_DIR="build"

# 颜色定义
GREEN='\033[0;32m'
NC='\033[0m'

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

# 清理旧的构建
clean() {
    print_info "清理旧的构建目录..."
    rm -rf "$BUILD_DIR"
    rm -f *.tar.gz
}

# 创建构建目录
prepare() {
    print_info "创建构建目录..."
    mkdir -p "$BUILD_DIR/$PACKAGE_NAME"
}

# 复制文件
copy_files() {
    print_info "复制文件..."
    cp sqlite_backup.sh "$BUILD_DIR/$PACKAGE_NAME/"
    cp init_config.sh "$BUILD_DIR/$PACKAGE_NAME/"
    cp deploy.sh "$BUILD_DIR/$PACKAGE_NAME/"
    cp README.md "$BUILD_DIR/$PACKAGE_NAME/" 2>/dev/null || true
    cp RCLONE_SETUP.md "$BUILD_DIR/$PACKAGE_NAME/" 2>/dev/null || true

    # 创建示例配置
    cat > "$BUILD_DIR/$PACKAGE_NAME/config.json.example" << 'EOF'
{
  "databases": [
    {
      "name": "example_database",
      "path": "/path/to/your/database.db",
      "enabled": true
    }
  ],
  "settings": {
    "sqlite_backup_dir": "./backups",
    "rclone": {
      "enabled": false,
      "remote": "s3",
      "path": "sqlite-backups",
      "keep_local": true
    },
    "retention_days": 30
  }
}
EOF
}

# 创建安装说明
create_install_guide() {
    print_info "创建安装说明..."
    cat > "$BUILD_DIR/$PACKAGE_NAME/INSTALL.md" << 'EOF'
# 安装说明

## 快速安装

1. 解压文件：
```bash
tar -xzf sqlite-backup-*.tar.gz
cd sqlite-backup-*
```

2. 运行部署脚本（推荐）：
```bash
sudo ./deploy.sh
```

或手动安装：

3. 复制文件到目标目录：
```bash
sudo cp *.sh /opt/sqlite-backup/
sudo chmod +x /opt/sqlite-backup/*.sh
```

4. 初始化配置：
```bash
cd /opt/sqlite-backup
./sqlite_backup.sh init
```

## 手动安装依赖

### Ubuntu/Debian
```bash
sudo apt-get update
sudo apt-get install sqlite3 xz-utils python3
```

### CentOS/RHEL
```bash
sudo yum install sqlite3 xz python3
```

## 配置

1. 初始化配置：
```bash
./sqlite_backup.sh init
```

2. 添加数据库（自动发现）：
```bash
./sqlite_backup.sh auto
```

3. 或手动编辑配置：
```bash
./sqlite_backup.sh edit
```

## 测试

运行备份测试：
```bash
./sqlite_backup.sh all
```

## 设置定时任务

使用 systemd（推荐）：
```bash
sudo ./deploy.sh
```

或使用 crontab：
```bash
crontab -e
# 添加：0 2 * * * /opt/sqlite-backup/sqlite_backup.sh all
```
EOF
}

# 创建压缩包
create_package() {
    print_info "创建压缩包..."
    cd "$BUILD_DIR"
    tar -czf "../${PACKAGE_NAME}.tar.gz" "$PACKAGE_NAME"
    cd ..

    # 计算大小
    SIZE=$(du -h "${PACKAGE_NAME}.tar.gz" | cut -f1)

    print_info "包已创建: ${PACKAGE_NAME}.tar.gz (大小: $SIZE)"
}

# 清理
cleanup() {
    print_info "清理临时文件..."
    rm -rf "$BUILD_DIR"
}

# 主函数
main() {
    print_info "开始打包 SQLite 备份工具..."

    clean
    prepare
    copy_files
    create_install_guide
    create_package
    cleanup

    print_info "打包完成！"
    ls -lh *.tar.gz
}

# 运行
main "$@"
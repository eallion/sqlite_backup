# SQLite 备份工具

一个强大、灵活的 SQLite 数据库备份解决方案，支持本地备份和通过 rclone 上传到 S3 兼容的云存储。

## 特性

- ✅ **便携性** - 无硬编码路径，可在任何服务器上运行
- ✅ **配置文件管理** - 使用 JSON 配置文件管理所有数据库
- ✅ **自动发现** - 自动扫描项目中的 SQLite 数据库
- ✅ **云存储支持** - 集成 rclone，支持 S3、阿里云 OSS、腾讯云 COS 等
- ✅ **WAL 模式支持** - 自动处理 WAL 模式数据库
- ✅ **自动清理** - 自动清理过期的备份文件
- ✅ **一键部署** - 提供自动化部署脚本

## 文件说明

- [`sqlite_backup.sh`](sqlite_backup.sh) - 主备份脚本（包含所有功能）
- [`deploy.sh`](deploy.sh) - 一键部署脚本（安装依赖、创建服务）
- [`init_config.sh`](init_config.sh) - 参数化初始化脚本
- [`config.json`](config.json) - 配置文件（需要初始化创建）
- [`package.sh`](package.sh) - 打包分发脚本

## 快速开始

### 安装

#### 方法1：使用部署脚本（推荐）
```bash
# 下载项目
git clone <repository-url> sqlite-backup
cd sqlite-backup

# 运行部署脚本
sudo ./deploy.sh

# 或者指定安装目录
sudo ./deploy.sh /opt/sqlite-backup
```

部署脚本会自动：
- 安装必要的依赖（sqlite3、xz、python3）
- 可选安装 rclone
- 复制文件到目标目录
- 创建 systemd 服务或 crontab 定时任务

#### 方法2：手动安装
1. 复制文件到目标目录
2. 安装依赖：
   ```bash
   # Ubuntu/Debian
   sudo apt-get install sqlite3 xz-utils python3

   # CentOS/RHEL
   sudo yum install sqlite3 xz python3
   ```
3. 设置权限：`chmod +x *.sh`

### 初始化配置

```bash
./sqlite_backup.sh init
```

初始化过程中会询问：
- 本地备份目录（可选）
- 是否启用 rclone S3 上传
- 如果启用，会显示可用的 rclone 远程列表供选择
- 备份保留天数

### 2. 配置 rclone（可选）

如果初始化时未配置 rclone，可以后续单独配置：

```bash
./sqlite_backup.sh rclone
```

### 3. 自动发现数据库（推荐）

```bash
# 查看发现的数据库
./sqlite_backup.sh discover

# 自动添加到配置文件
./sqlite_backup.sh auto
```

### 4. 管理配置

```bash
# 列出所有配置的数据库
./sqlite_backup.sh list

# 手动编辑配置文件
./sqlite_backup.sh edit
```

配置文件示例：
```json
{
    "databases": [
        {
            "name": "myapp",
            "path": "/path/to/database.db",
            "enabled": true
        }
    ],
    "settings": {
        "sqlite_backup_dir": "",
        "rclone": {
            "enabled": true,
            "remote": "s3",
            "path": "sqlite-backups",
            "keep_local": true
        },
        "retention_days": 30
    }
}
```

### 5. 执行备份

```bash
# 备份所有启用的数据库
./sqlite_backup.sh all

# 备份单个数据库
./sqlite_backup.sh backup myapp /path/to/database.db
```

## 配置说明

### 数据库配置

```json
"databases": [
    {
        "name": "数据库名称",      // 用于命名备份文件
        "path": "/path/to/db",     // 数据库完整路径
        "enabled": true           // 是否启用备份
    }
]
```

### 全局设置

```json
"settings": {
    "sqlite_backup_dir": "",     // 本地备份目录（空值使用脚本目录下的 backups）
    "rclone": {
        "enabled": false,         // 是否启用 rclone 上传
        "remote": "s3",          // rclone 远程名称
        "path": "sqlite-backups", // S3 路径前缀
        "keep_local": true       // 是否保留本地文件
    },
    "retention_days": 30         // 备份保留天数
}
```

## rclone 集成

### 1. 安装 rclone

```bash
curl https://rclone.org/install.sh | sudo bash
```

### 2. 配置 rclone

```bash
rclone config
# 按提示添加 S3 兼容存储
```

### 3. 启用 S3 上传

编辑 `config.json`，设置 `rclone.enabled` 为 `true`：

```json
{
    "settings": {
        "rclone": {
            "enabled": true,
            "remote": "s3",
            "path": "sqlite-backups",
            "keep_local": true
        }
    }
}
```

## 常用命令

```bash
# 初始化配置（交互式）
./sqlite_backup.sh init

# 配置 rclone（交互式）
./sqlite_backup.sh rclone

# 列出配置的数据库
./sqlite_backup.sh list

# 自动发现数据库
./sqlite_backup.sh discover

# 自动发现并添加
./sqlite_backup.sh auto

# 备份所有数据库
./sqlite_backup.sh all

# 备份指定数据库
./sqlite_backup.sh backup name /path/to/db

# 编辑配置
./sqlite_backup.sh edit

# 显示帮助
./sqlite_backup.sh help
```

## 定时任务

### Crontab 配置

```bash
crontab -e
```

添加每日备份任务（凌晨 2 点）：

```bash
# SQLite 数据库备份 - 每天 02:00
0 2 * * * /path/to/backup/sqlite_backup.sh all >/dev/null 2>&1

# 如果需要日志输出
0 2 * * * /path/to/backup/sqlite_backup.sh all >> /var/log/sqlite_backup.log 2>&1
```

## 备份格式

### 本地备份结构
```
backups/
├── project1/               # 项目名称目录
│   ├── project1_app_sqlite_20231218_020000.tar.xz
│   ├── project1_app_sqlite_20231217_020000.tar.xz
│   └── project1_db_sqlite_20231218_020000.tar.xz
├── project2/
│   └── project2_user_sqlite_20231218_020000.tar.xz
└── project3/
    └── project3_sqlite_20231218_020000.tar.xz
```

### S3 备份结构
```
s3:sqlite-backups/
├── project1/               # 项目名称目录
│   ├── project1_app_sqlite_20231218_020000.tar.xz
│   └── project1_db_sqlite_20231218_020000.tar.xz
├── project2/
│   └── project2_user_sqlite_20231218_020000.tar.xz
└── project3/
    └── project3_sqlite_20231218_020000.tar.xz
```

### 备份文件命名
- 文件格式：`{数据库名}_sqlite_{时间戳}.tar.xz`
- 时间戳格式：YYYYMMDD_HHMMSS
- 压缩格式：tar.xz（高压缩率）
- 保留时间：默认 30 天（可配置）

### 项目名称提取规则
- 如果数据库名称包含下划线（_），使用第一部分作为项目名
  - 例如：`project1_app` → 项目名：`project1`
  - 例如：`myapp_user_db` → 项目名：`myapp`
- 如果数据库名称不包含下划线，使用完整名称作为项目名
  - 例如：`maindb` → 项目名：`maindb`

## 注意事项

1. **数据库锁定**：备份时会短暂锁定数据库，建议在低峰期执行
2. **WAL 模式**：脚本自动处理 WAL 模式的检查点操作
3. **权限要求**：需要有读取数据库文件和写入备份目录的权限
4. **依赖**：需要安装 `sqlite3` 命令

## 故障排除

### 查看日志

备份过程中的错误信息会显示在控制台，可以重定向到日志文件：

```bash
./sqlite_backup.sh all 2>&1 | tee backup.log
```

### 常见问题

1. **sqlite3 命令未找到**
   ```bash
   # Ubuntu/Debian
   sudo apt-get install sqlite3

   # CentOS/RHEL
   sudo yum install sqlite
   ```

2. **配置文件错误**
   ```bash
   # 验证 JSON 格式
   python3 -m json.tool config.json
   ```

3. **rclone 上传失败**
   - 检查 rclone 配置：`rclone config show`
   - 测试连接：`rclone lsd s3:`

## 恢复备份数据

```bash
# 1. 解压备份文件
tar -xJf myapp_sqlite_20231218_020000.tar.xz

# 2. 恢复数据库
cp myapp_sqlite_20231218_020000.sqlite3 /path/to/restore.db

# 3. 验证备份
sqlite3 /path/to/restore.db "PRAGMA integrity_check;"
```
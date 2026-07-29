# update-xray-for-3xui

适用于 **Ubuntu** 的 3x-ui / x-ui Xray-core Pre-release 自动更新脚本。

脚本会先检查运行环境、依赖和当前 Xray 版本。只有检测到依赖缺失时才会运行 `apt-get update`，只有检测到远程版本较新时才会下载、安装并重启服务。

## 项目信息

- GitHub 用户：[`1731134683x`](https://github.com/1731134683x)
- 项目仓库：[`1731134683x/update-xray-for-3xui`](https://github.com/1731134683x/update-xray-for-3xui)
- 主脚本：[`update-xray.sh`](https://github.com/1731134683x/update-xray-for-3xui/blob/main/update-xray.sh)
- RAW 地址：`https://raw.githubusercontent.com/1731134683x/update-xray-for-3xui/main/update-xray.sh`

## 文件说明

- `update-xray.sh`：Xray-core Pre-release 检测与更新命令。

## 主要特性

- 仅支持 Ubuntu，执行前自动检测系统。
- 自动识别以下架构：
  - `x86_64`
  - `aarch64`
  - `armv7l`
- 自动获取 Xray-core 最新 Pre-release 版本。
- 自动检测本地 Xray 版本，相同则直接退出。
- 依赖齐全时完全跳过 `apt-get update` 和 `apt-get install`。
- 只安装实际缺失的依赖包。
- 只有确认需要更新后才检测和安装 `unzip`。
- 单次运行中 `apt-get update` 最多执行一次。
- 下载后检查 ZIP 完整性和 Xray 二进制文件可执行性。
- 更新前自动备份当前 Xray 文件。
- 自动检测并重启 `x-ui`、`3x-ui` 或 `xray` 服务。
- 服务重启失败时自动尝试回滚。

## 系统要求

- Ubuntu
- root 权限
- 使用 systemd
- 已安装 x-ui 或 3x-ui
- 默认 Xray 目录存在：

```text
/usr/local/x-ui/bin
```

脚本支持的下载架构对应关系：

| 系统架构 | Xray 下载标识 | 安装文件标识 |
| --- | --- | --- |
| `x86_64` | `64` | `amd64` |
| `aarch64` | `arm64-v8a` | `arm64` |
| `armv7l` | `arm32-v7a` | `armv7` |

## 使用方法

### 一键运行（推荐）

使用 root 用户执行：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/1731134683x/update-xray-for-3xui/main/update-xray.sh)
```

普通用户可以通过 `sudo` 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/1731134683x/update-xray-for-3xui/main/update-xray.sh | sudo bash
```

### 下载后运行

```bash
curl -fLo update-xray.sh https://raw.githubusercontent.com/1731134683x/update-xray-for-3xui/main/update-xray.sh
sudo bash update-xray.sh
```

### 克隆仓库后运行

```bash
git clone https://github.com/1731134683x/update-xray-for-3xui.git
cd update-xray-for-3xui
sudo bash update-xray.sh
```

> 脚本需要 root 权限。执行前建议先阅读脚本内容，并确认服务器能够访问 GitHub。

## 执行流程

脚本按照以下顺序运行：

1. 检查是否使用 root 用户。
2. 检查当前系统是否为 Ubuntu。
3. 检查目标目录、CPU 架构和 systemd 服务。
4. 检测 `curl`、`jq`、`ca-certificates`：
   - 全部已安装：跳过所有 APT 操作。
   - 存在缺失：刷新一次 APT 索引，并只安装缺失包。
5. 获取最新 Xray-core Pre-release 版本。
6. 检测当前 Xray 版本：
   - 版本相同：立即退出。
   - 未安装、无法识别或版本不同：继续更新。
7. 确认需要更新后，再检测并按需安装 `unzip`。
8. 下载对应架构的 Xray ZIP 文件。
9. 验证压缩包完整性和二进制文件版本。
10. 备份现有 Xray 文件。
11. 安装新版 Xray。
12. 重启检测到的服务；失败时尝试回滚。

## APT 更新策略

旧命令会在每次运行时无条件执行：

```bash
apt-get update
apt-get install -y curl unzip jq ca-certificates
```

现在脚本会先使用 `dpkg-query` 检测依赖包状态。

当下面的包都已经安装时：

```text
curl
jq
ca-certificates
unzip
```

脚本不会运行 `apt-get update` 或 `apt-get install`。

需要注意：`apt-get update` 只刷新软件包索引，并不会升级系统中的软件包；本脚本仍然将其限制为仅在依赖缺失时执行。

## 默认更新路径

脚本会更新以下文件：

```text
/usr/local/x-ui/bin/xray
/usr/local/x-ui/bin/xray-linux-<架构>
```

例如 AMD64 系统对应：

```text
/usr/local/x-ui/bin/xray-linux-amd64
```

## 备份与回滚

每次正式安装前，脚本会创建带时间戳的备份目录：

```text
/usr/local/x-ui/bin/backup-YYYYMMDD-HHMMSS
```

可能备份的文件包括：

```text
xray
xray-linux-amd64
xray-linux-arm64
xray-linux-armv7
```

具体文件取决于当前服务器架构和原文件是否存在。

如果服务重启失败，脚本会尝试将备份文件恢复到原位置，然后再次启动服务。

## 服务检测

脚本依次检测以下 systemd 服务：

```text
x-ui.service
3x-ui.service
xray.service
```

检测到第一个有效服务后，会在更新完成时重启它。

如果没有检测到服务，Xray 文件仍会被更新，但脚本不会自动重启服务。此时需要根据实际安装方式手动重启面板或 Xray。

常用检查命令：

```bash
systemctl status x-ui
systemctl status 3x-ui
systemctl status xray
```

## 查看当前版本

```bash
/usr/local/x-ui/bin/xray version
```

如果当前版本使用另一种参数格式，可以尝试：

```bash
/usr/local/x-ui/bin/xray -version
```

## 常见问题

### 1. 提示目标目录不存在

错误示例：

```text
目标目录不存在: /usr/local/x-ui/bin
```

请确认 x-ui / 3x-ui 已安装，并检查实际 Xray 目录。如果安装位置不同，需要修改脚本中的：

```bash
TARGET_DIR="/usr/local/x-ui/bin"
```

### 2. 无法获取最新版本

通常是服务器无法访问 GitHub API。可以检查：

```bash
curl -I https://api.github.com
```

### 3. 下载失败

确认服务器可以访问 GitHub Release，并检查 DNS、防火墙或代理配置。

### 4. 服务重启失败

查看对应服务日志：

```bash
journalctl -u x-ui -n 100 --no-pager
journalctl -u 3x-ui -n 100 --no-pager
journalctl -u xray -n 100 --no-pager
```

脚本会尝试自动回滚，但仍建议检查服务状态和日志。

### 5. 当前已经是最新版

脚本会显示当前版本和远程版本，然后正常退出，不会下载文件、安装 `unzip` 或重启服务。

## 安全提示

- 本脚本更新的是 **Pre-release（预发布）版本**，可能存在尚未完全验证的问题。
- 建议先在测试服务器运行，再用于生产环境。
- 执行前建议额外备份面板配置和 Xray 配置文件。
- 不要删除备份目录，直到确认新版本运行稳定。
- 脚本需要 root 权限，请在确认内容可信后执行。

## 自定义

### 修改 Xray 安装目录

编辑：

```bash
TARGET_DIR="/usr/local/x-ui/bin"
```

### 修改服务候选列表

编辑 `detect_service` 函数中的：

```bash
local candidates=("x-ui" "3x-ui" "xray")
```

## 免责声明

请自行承担运行预发布版本以及替换 Xray 二进制文件可能带来的风险。生产环境使用前应完成备份和兼容性测试。



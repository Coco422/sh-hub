#!/bin/bash

# =========================================================
# Cursor Remote Server 离线部署脚本（增强版）
# 功能：
# 1. 自动获取本地 Cursor 版本
# 2. 下载对应 Cursor Server
# 3. 上传并部署到远程服务器（支持无外网环境）
# =========================================================

set -e  # 任意命令失败立即退出

# ==================== 基础配置 ====================

# 当前脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 本地下载目录
LOCAL_DOWNLOAD_DIR="$SCRIPT_DIR/cursor_downloads"

# 默认配置（支持环境变量覆盖）
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_PORT="${REMOTE_PORT:-22}"
REMOTE_USER="${REMOTE_USER:-root}"
REMOTE_OS="linux"

# ==================== 工具函数 ====================

# 彩色输出
print() {
    case $1 in
        green) echo -e "\033[32m$2\033[0m" ;;
        red) echo -e "\033[31m$2\033[0m" ;;
        yellow) echo -e "\033[33m$2\033[0m" ;;
        blue) echo -e "\033[34m$2\033[0m" ;;
        *) echo "$2" ;;
    esac
}

# 检查命令是否存在
check_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        print red "❌ 缺少依赖: $1"
        exit 1
    }
}

# ==================== 交互输入 ====================

init_remote_config() {
    print blue "🔧 配置远程服务器信息"

    # 主机
    if [ -z "$REMOTE_HOST" ]; then
        read -p "请输入远程主机: " REMOTE_HOST
    fi

    # 端口
    read -p "请输入端口 (默认: $REMOTE_PORT): " input_port
    REMOTE_PORT=${input_port:-$REMOTE_PORT}

    # 用户
    read -p "请输入用户名 (默认: $REMOTE_USER): " input_user
    REMOTE_USER=${input_user:-$REMOTE_USER}

    if [ -z "$REMOTE_HOST" ]; then
        print red "❌ 远程主机不能为空"
        exit 1
    fi

    print green "✔ 远程配置:"
    echo "Host: $REMOTE_HOST"
    echo "Port: $REMOTE_PORT"
    echo "User: $REMOTE_USER"
}

# ==================== 获取 Cursor 版本 ====================

get_cursor_version() {
    check_cmd cursor

    print blue "📦 获取 Cursor 版本信息..."

    local version_info
    version_info=$(cursor --version)

    CURSOR_VERSION=$(echo "$version_info" | sed -n '1p')
    CURSOR_COMMIT=$(echo "$version_info" | sed -n '2p')
    CURSOR_ARCH=$(echo "$version_info" | sed -n '3p')

    print green "✔ 版本: $CURSOR_VERSION"
    print green "✔ Commit: $CURSOR_COMMIT"
    print green "✔ 本地架构: $CURSOR_ARCH"
}

# ==================== 检测远程架构 ====================

detect_remote_arch() {
    print blue "🔍 检测远程服务器架构..."

    local arch
    arch=$(ssh -p "$REMOTE_PORT" "${REMOTE_USER}@${REMOTE_HOST}" "uname -m")

    case $arch in
        x86_64) REMOTE_ARCH="x64" ;;
        aarch64|arm64) REMOTE_ARCH="arm64" ;;
        *)
            print red "❌ 不支持的架构: $arch"
            exit 1
            ;;
    esac

    print green "✔ 远程架构: $REMOTE_ARCH ($arch)"
}

# ==================== 下载 Server ====================

download_server() {
    mkdir -p "$LOCAL_DOWNLOAD_DIR"

    DOWNLOAD_URL="https://cursor.blob.core.windows.net/remote-releases/${CURSOR_VERSION}-${CURSOR_COMMIT}/vscode-reh-${REMOTE_OS}-${REMOTE_ARCH}.tar.gz"

    DOWNLOAD_PATH="$LOCAL_DOWNLOAD_DIR/cursor-${CURSOR_COMMIT}.tar.gz"

    print yellow "⬇ 下载地址:"
    echo "$DOWNLOAD_URL"

    if [ -f "$DOWNLOAD_PATH" ]; then
        print yellow "⚠ 已存在，跳过下载"
        return
    fi

    curl -L "$DOWNLOAD_URL" -o "$DOWNLOAD_PATH"

    print green "✔ 下载完成: $DOWNLOAD_PATH"
}

# ==================== 部署到远程 ====================

deploy_remote() {
    print blue "🚀 开始部署到远程服务器..."

    SSH="ssh -p $REMOTE_PORT ${REMOTE_USER}@${REMOTE_HOST}"
    SCP="scp -P $REMOTE_PORT"

    REMOTE_DIR="~/.cursor-server/cli/servers/Stable-${CURSOR_COMMIT}/server"

    # 创建目录
    $SSH "mkdir -p $REMOTE_DIR"

    # 上传
    print yellow "📤 上传文件..."
    $SCP "$DOWNLOAD_PATH" "${REMOTE_USER}@${REMOTE_HOST}:~/cursor-server.tar.gz"

    # 解压
    print yellow "📦 解压文件..."
    $SSH "tar -xzf ~/cursor-server.tar.gz -C $REMOTE_DIR --strip-components=1"

    # 清理
    $SSH "rm -f ~/cursor-server.tar.gz"

    print green "✔ 部署完成!"
    print green "📍 路径: $REMOTE_DIR"
}

# ==================== 主流程 ====================

main() {
    check_cmd curl
    check_cmd ssh
    check_cmd scp

    init_remote_config
    get_cursor_version
    detect_remote_arch
    download_server

    print blue "确认部署到 $REMOTE_USER@$REMOTE_HOST ? [y/N]"
    read -r confirm

    if [[ $confirm =~ ^[Yy]$ ]]; then
        deploy_remote
    else
        print yellow "已取消部署"
    fi

    print green "🎉 完成"
}

main

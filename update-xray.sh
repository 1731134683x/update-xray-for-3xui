#!/bin/bash
# ============================================================
# update-xray-for-3xui — Xray-core Pre-release 自动更新脚本
# GitHub: https://github.com/1731134683x/update-xray-for-3xui
# 用法: sudo bash update-xray.sh
# ============================================================
set -Eeuo pipefail

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
NC="\033[0m"

TARGET_DIR="/usr/local/x-ui/bin"
XRAY_BIN="${TARGET_DIR}/xray"
SERVICE_NAME=""
APT_UPDATED=0

TMP_DIR="$(mktemp -d)"
ZIP_FILE="${TMP_DIR}/xray.zip"
BIN_FILE="${TMP_DIR}/xray"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

info() {
    echo -e "${YELLOW}>>> $*${NC}"
}

ok() {
    echo -e "${GREEN}[√] $*${NC}"
}

warn() {
    echo -e "${YELLOW}警告: $*${NC}"
}

die() {
    echo -e "${RED}错误: $*${NC}" >&2
    exit 1
}

check_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少必要命令: $1"
}


# 仅在依赖包缺失时刷新 APT 索引并安装，已安装则完全跳过 apt-get。
ensure_packages() {
    local missing=()
    local pkg

    for pkg in "$@"; do
        if ! dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -qx 'install ok installed'; then
            missing+=("${pkg}")
        fi
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        ok "所需依赖已安装，跳过 apt-get update"
        return 0
    fi

    warn "缺少依赖包: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    if [ "${APT_UPDATED}" -eq 0 ]; then
        info "仅因存在缺失依赖，开始刷新 APT 索引..."
        apt-get update || die "apt-get update 失败"
        APT_UPDATED=1
    else
        info "本次运行已刷新过 APT 索引，直接安装缺失依赖..."
    fi

    apt-get install -y --no-install-recommends "${missing[@]}" \
        || die "依赖安装失败: ${missing[*]}"

    ok "依赖安装完成: ${missing[*]}"
}

normalize_version() {
    echo "$1" | sed 's/^v//'
}

detect_service() {
    local candidates=("x-ui" "3x-ui" "xray")

    for svc in "${candidates[@]}"; do
        if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "^${svc}.service"; then
            SERVICE_NAME="${svc}"
            ok "检测到服务: ${SERVICE_NAME}.service"
            return 0
        fi

        if systemctl status "${svc}" >/dev/null 2>&1; then
            SERVICE_NAME="${svc}"
            ok "检测到服务: ${SERVICE_NAME}.service"
            return 0
        fi
    done

    SERVICE_NAME=""
    warn "未检测到 x-ui / 3x-ui / xray systemd 服务，更新完成后将跳过自动重启"
}

echo -e "${YELLOW}>>> 开始 Xray-core Pre-release 更新流程...${NC}"

# 1. 基础环境检测（此阶段不执行 apt-get）
detect_env() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 用户执行"


    [ -r /etc/os-release ] || die "无法识别操作系统"
    . /etc/os-release
    [ "${ID:-}" = "ubuntu" ] || die "仅支持 Ubuntu，当前系统: ${PRETTY_NAME:-unknown}"

    for cmd in apt-get dpkg-query systemctl uname mktemp install chmod cp mv sed grep awk head date mkdir rm; do
        check_cmd "$cmd"
    done

    [ -d "${TARGET_DIR}" ] || die "目标目录不存在: ${TARGET_DIR}，请确认 x-ui / 3x-ui 是否已安装"

    ARCH="$(uname -m)"
    case "${ARCH}" in
        x86_64)
            DL_ARCH="64"
            BIN_ARCH="amd64"
            ;;
        aarch64)
            DL_ARCH="arm64-v8a"
            BIN_ARCH="arm64"
            ;;
        armv7l)
            DL_ARCH="arm32-v7a"
            BIN_ARCH="armv7"
            ;;
        *)
            die "不支持的系统架构: ${ARCH}"
            ;;
    esac

    ok "架构检测通过: ${ARCH}，下载标识: ${DL_ARCH}，安装标识: ${BIN_ARCH}"

    detect_service
}

# 2. 获取最新 Pre-release 版本
get_version() {
    info "正在获取 Xray-core 最新 Pre-release 版本..."

    XRAY_VER="$(
        curl -fsSL \
            --connect-timeout 15 \
            --retry 5 \
            --retry-delay 3 \
            --retry-connrefused \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=30" \
        | jq -r '[.[] | select(.prerelease == true)][0].tag_name // empty'
    )"

    [ -n "${XRAY_VER}" ] || die "无法获取最新 Pre-release 版本号，请检查 GitHub API 连通性"

    REMOTE_VER="$(normalize_version "${XRAY_VER}")"

    ok "获取到最新 Pre-release 版本: ${XRAY_VER}"
}

# 3. 检测当前版本，版本一致则退出
check_current_version() {
    if [ ! -x "${XRAY_BIN}" ]; then
        warn "未找到当前 xray 可执行文件: ${XRAY_BIN}，将执行全新安装"
        return 0
    fi

    CURRENT_VER="$(
        "${XRAY_BIN}" version 2>/dev/null \
        | head -n 1 \
        | awk '{print $2}' \
        | sed 's/^v//'
    )"

    if [ -z "${CURRENT_VER}" ]; then
        CURRENT_VER="$(
            "${XRAY_BIN}" -version 2>/dev/null \
            | head -n 1 \
            | awk '{print $2}' \
            | sed 's/^v//'
        )"
    fi

    if [ -z "${CURRENT_VER}" ]; then
        warn "无法识别当前 xray 版本，将继续更新"
        return 0
    fi

    ok "当前已安装版本: ${CURRENT_VER}"
    ok "远程最新版本: ${REMOTE_VER}"

    if [ "${CURRENT_VER}" = "${REMOTE_VER}" ]; then
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}[√] 当前已是最新版本，无需更新${NC}"
        echo -e "${GREEN}当前版本: ${CURRENT_VER}${NC}"
        echo -e "${GREEN}远程版本: ${REMOTE_VER}${NC}"
        echo -e "${GREEN}========================================${NC}"
        exit 0
    fi

    info "发现新版本，将从 ${CURRENT_VER} 更新到 ${REMOTE_VER}"
}

# 4. 下载与验证
download_and_verify() {
    URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-${DL_ARCH}.zip"

    info "正在检测下载链接..."
    curl -fsIL \
        --connect-timeout 15 \
        --retry 3 \
        --retry-delay 3 \
        --retry-connrefused \
        "${URL}" >/dev/null || die "下载链接不可用: ${URL}"

    info "正在下载: ${URL}"

    curl -fL \
        --connect-timeout 20 \
        --max-time 600 \
        --retry 5 \
        --retry-delay 5 \
        --retry-connrefused \
        -o "${ZIP_FILE}.part" \
        "${URL}" || die "下载失败，请稍后重试或检查服务器到 GitHub 的网络"

    mv -f "${ZIP_FILE}.part" "${ZIP_FILE}"

    [ -s "${ZIP_FILE}" ] || die "下载文件为空"

    info "正在验证 ZIP 完整性..."
    unzip -tq "${ZIP_FILE}" >/dev/null || die "ZIP 文件不完整或已损坏"

    ok "ZIP 文件完整性验证通过"

    info "正在解压 xray 二进制文件..."
    unzip -oq "${ZIP_FILE}" xray -d "${TMP_DIR}" || die "解压 xray 失败"

    [ -f "${BIN_FILE}" ] || die "压缩包内未找到 xray 文件"

    chmod +x "${BIN_FILE}"

    info "正在测试新 xray 是否可运行..."
    if ! "${BIN_FILE}" version >/dev/null 2>&1 && ! "${BIN_FILE}" -version >/dev/null 2>&1; then
        die "新 xray 二进制文件无法运行，可能与当前系统不兼容"
    fi

    NEW_BIN_VER="$(
        "${BIN_FILE}" version 2>/dev/null \
        | head -n 1 \
        | awk '{print $2}' \
        | sed 's/^v//'
    )"

    if [ -n "${NEW_BIN_VER}" ] && [ "${NEW_BIN_VER}" != "${REMOTE_VER}" ]; then
        die "下载到的二进制版本异常，期望 ${REMOTE_VER}，实际 ${NEW_BIN_VER}"
    fi

    ok "二进制文件执行测试通过"
}

# 5. 安装与重启
install_xray() {
    BACKUP_DIR="${TARGET_DIR}/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "${BACKUP_DIR}"

    info "正在备份当前 xray..."
    [ -f "${TARGET_DIR}/xray" ] && cp -a "${TARGET_DIR}/xray" "${BACKUP_DIR}/xray"
    [ -f "${TARGET_DIR}/xray-linux-${BIN_ARCH}" ] && cp -a "${TARGET_DIR}/xray-linux-${BIN_ARCH}" "${BACKUP_DIR}/xray-linux-${BIN_ARCH}"

    ok "备份目录: ${BACKUP_DIR}"

    info "正在安装新 xray..."

    install -m 0755 "${BIN_FILE}" "${TARGET_DIR}/xray.new"
    install -m 0755 "${BIN_FILE}" "${TARGET_DIR}/xray-linux-${BIN_ARCH}.new"

    mv -f "${TARGET_DIR}/xray.new" "${TARGET_DIR}/xray"
    mv -f "${TARGET_DIR}/xray-linux-${BIN_ARCH}.new" "${TARGET_DIR}/xray-linux-${BIN_ARCH}"

    chmod +x "${TARGET_DIR}/xray" "${TARGET_DIR}/xray-linux-${BIN_ARCH}"

    if [ -n "${SERVICE_NAME}" ]; then
        info "正在重启 ${SERVICE_NAME} 服务..."

        if ! systemctl restart "${SERVICE_NAME}"; then
            echo -e "${RED}错误: ${SERVICE_NAME} 重启失败，正在尝试回滚...${NC}"

            [ -f "${BACKUP_DIR}/xray" ] && cp -a "${BACKUP_DIR}/xray" "${TARGET_DIR}/xray"
            [ -f "${BACKUP_DIR}/xray-linux-${BIN_ARCH}" ] && cp -a "${BACKUP_DIR}/xray-linux-${BIN_ARCH}" "${TARGET_DIR}/xray-linux-${BIN_ARCH}"

            systemctl restart "${SERVICE_NAME}" || true

            die "更新失败，已尝试回滚。请使用 systemctl status ${SERVICE_NAME} 查看原因"
        fi

        ok "${SERVICE_NAME} 服务重启成功"
    else
        warn "未找到可重启的 systemd 服务，已跳过自动重启"
        warn "请根据你的面板实际情况手动重启 x-ui / 3x-ui"
    fi

    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN} 更新成功！当前内核版本状态：${NC}"
    "${TARGET_DIR}/xray" version 2>/dev/null | head -n 2 || "${TARGET_DIR}/xray" -version 2>/dev/null | head -n 2
    echo -e "${GREEN}========================================${NC}"
}

detect_env

# 查询远程版本只需要 curl、jq 和 CA 证书；缺什么才安装什么。
ensure_packages curl jq ca-certificates
check_cmd curl
check_cmd jq

get_version
check_current_version

# 只有确认需要更新 Xray 后，才检测并安装 unzip。
ensure_packages unzip
check_cmd unzip

download_and_verify
install_xray

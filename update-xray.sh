#!/bin/bash
# ============================================================
# update-xray-for-3xui — Xray-core 自动更新脚本（自动比较 Stable / Pre-release，选取最新）
# GitHub: https://github.com/1731134683x/update-xray-for-3xui
# 用法: sudo bash update-xray.sh
# ============================================================
set -Eeuo pipefail

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
NC="\033[0m"

TARGET_DIR="/usr/local/x-ui/bin"
XRAY_BIN=""
VERSION_TIMEOUT=10
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

# 按版本号比较（入参为已去掉 v 前缀的版本号）：$1 比 $2 新时返回 0，相等或更旧返回非 0。
# 使用 GNU sort -V 做数字分段比较，避免字符串比较把 26.10.21 判成比 26.9.30 旧。
version_gt() {
    if [ "$1" = "$2" ]; then
        return 1
    fi

    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -n 1)" = "$1" ]
}


detect_xray_binary() {
    local candidate
    # 3x-ui 通常实际调用带架构后缀的文件，因此优先检测它。
    local candidates=(
        "${TARGET_DIR}/xray-linux-${BIN_ARCH}"
        "${TARGET_DIR}/xray"
    )

    for candidate in "${candidates[@]}"; do
        if [ -x "${candidate}" ]; then
            XRAY_BIN="${candidate}"
            ok "检测到当前 xray 文件: ${XRAY_BIN}"
            return 0
        fi
    done

    XRAY_BIN="${TARGET_DIR}/xray"
    warn "未找到已安装的 xray 可执行文件"
}

read_xray_version() {
    local binary="$1"
    local output

    # Xray 官方 CLI 使用 -version。增加超时，防止异常二进制长时间卡住。
    output="$(timeout -k 2s "${VERSION_TIMEOUT}s" "${binary}" -version 2>/dev/null)" || return $?

    printf '%s\n' "${output}" \
        | awk 'NR == 1 {gsub(/^v/, "", $2); print $2; exit}'
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

echo -e "${YELLOW}>>> 开始 Xray-core 更新流程（自动比较 Stable 与 Pre-release，选取最新版本）...${NC}"

# 1. 基础环境检测（此阶段不执行 apt-get）
detect_env() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 用户执行"


    [ -r /etc/os-release ] || die "无法识别操作系统"
    . /etc/os-release
    [ "${ID:-}" = "ubuntu" ] || die "仅支持 Ubuntu，当前系统: ${PRETTY_NAME:-unknown}"

    for cmd in apt-get dpkg-query systemctl uname mktemp install chmod cp mv sed grep awk head tail sort timeout date mkdir rm; do
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

    detect_xray_binary

    detect_service
}

# 2. 获取最新版本：同时查询 Stable 与 Pre-release，按版本号比较后取较新的一方
get_version() {
    local releases_json="${TMP_DIR}/releases.json"

    info "正在获取 Xray-core 最新 Stable / Pre-release 版本信息..."

    curl -fsSL \
        --connect-timeout 15 \
        --retry 5 \
        --retry-delay 3 \
        --retry-connrefused \
        -H "Accept: application/vnd.github+json" \
        -o "${releases_json}" \
        "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=30" \
        || die "无法获取 Xray-core 版本信息，请检查 GitHub API 连通性"

    [ -s "${releases_json}" ] || die "GitHub API 返回内容为空，请稍后重试"

    # 分别取出最新的正式版（Stable）与最新的预发布版（Pre-release）。
    # GitHub 返回的 releases 列表按发布时间倒序，因此每组的第一条就是该组最新版本。
    STABLE_TAG="$(jq -r '[.[] | select(.draft == false and .prerelease == false)][0].tag_name // empty' \
        "${releases_json}")" || die "解析 Stable 版本信息失败，GitHub API 可能触发速率限制"

    PRERELEASE_TAG="$(jq -r '[.[] | select(.draft == false and .prerelease == true)][0].tag_name // empty' \
        "${releases_json}")" || die "解析 Pre-release 版本信息失败，GitHub API 可能触发速率限制"

    STABLE_VER=""
    PRERELEASE_VER=""
    if [ -n "${STABLE_TAG}" ]; then
        STABLE_VER="$(normalize_version "${STABLE_TAG}")"
    fi
    if [ -n "${PRERELEASE_TAG}" ]; then
        PRERELEASE_VER="$(normalize_version "${PRERELEASE_TAG}")"
    fi

    [ -n "${STABLE_VER}" ] || [ -n "${PRERELEASE_VER}" ] \
        || die "无法获取 Xray-core 版本号，GitHub API 可能触发速率限制，请稍后重试"

    if [ -n "${STABLE_VER}" ] && [ -n "${PRERELEASE_VER}" ]; then
        ok "Stable 版本: ${STABLE_VER}，Pre-release 版本: ${PRERELEASE_VER}"

        # 版本号相同视为同一版本，优先使用正式版；否则直接取版本号更大的一方。
        if [ "${STABLE_VER}" = "${PRERELEASE_VER}" ] \
            || version_gt "${STABLE_VER}" "${PRERELEASE_VER}"; then
            XRAY_VER="${STABLE_TAG}"
            REMOTE_CHANNEL="Stable"
        else
            XRAY_VER="${PRERELEASE_TAG}"
            REMOTE_CHANNEL="Pre-release"
        fi
    elif [ -n "${STABLE_VER}" ]; then
        XRAY_VER="${STABLE_TAG}"
        REMOTE_CHANNEL="Stable"
        warn "未找到最新的 Pre-release 版本，仅使用 Stable 版本"
    else
        XRAY_VER="${PRERELEASE_TAG}"
        REMOTE_CHANNEL="Pre-release"
        warn "未找到最新的 Stable 版本，仅使用 Pre-release 版本"
    fi

    REMOTE_VER="$(normalize_version "${XRAY_VER}")"

    ok "选取最新版本: ${XRAY_VER}（${REMOTE_CHANNEL}）"
}

# 3. 检测当前版本，版本一致则退出
check_current_version() {
    if [ ! -x "${XRAY_BIN}" ]; then
        warn "未找到当前 xray 可执行文件，将执行全新安装"
        return 0
    fi

    if ! CURRENT_VER="$(read_xray_version "${XRAY_BIN}")"; then
        warn "读取当前 xray 版本失败或超过 ${VERSION_TIMEOUT} 秒，将继续更新"
        return 0
    fi

    if [ -z "${CURRENT_VER}" ]; then
        warn "无法识别当前 xray 版本，将继续更新"
        return 0
    fi

    ok "当前已安装版本: ${CURRENT_VER}"
    ok "远程最新版本: ${REMOTE_VER}（${REMOTE_CHANNEL}）"

    if [ "${CURRENT_VER}" = "${REMOTE_VER}" ]; then
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}[√] 当前已是最新版本，无需更新${NC}"
        echo -e "${GREEN}当前版本: ${CURRENT_VER}${NC}"
        echo -e "${GREEN}远程版本: ${REMOTE_VER}（${REMOTE_CHANNEL}）${NC}"
        echo -e "${GREEN}========================================${NC}"
        exit 0
    fi

    # 防止降级：当前版本比远程最新版本还新（例如手动安装的开发版）时保持现状。
    if version_gt "${CURRENT_VER}" "${REMOTE_VER}"; then
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}[√] 当前版本比远程最新版本更新，已跳过更新${NC}"
        echo -e "${GREEN}当前版本: ${CURRENT_VER}${NC}"
        echo -e "${GREEN}远程最新版本: ${REMOTE_VER}（${REMOTE_CHANNEL}）${NC}"
        echo -e "${GREEN}========================================${NC}"
        warn "如确需降级，请手动安装目标版本"
        exit 0
    fi

    info "发现新版本，将从 ${CURRENT_VER} 更新到 ${REMOTE_VER}（${REMOTE_CHANNEL}）"
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

    info "正在测试新 xray 是否可运行（最多 ${VERSION_TIMEOUT} 秒）..."

    if ! NEW_BIN_VER="$(read_xray_version "${BIN_FILE}")"; then
        die "新 xray 二进制文件执行失败或超过 ${VERSION_TIMEOUT} 秒，可能与当前系统不兼容"
    fi

    [ -n "${NEW_BIN_VER}" ] || die "无法识别新 xray 二进制文件的版本"

    if [ "${NEW_BIN_VER}" != "${REMOTE_VER}" ]; then
        die "下载到的二进制版本异常，期望 ${REMOTE_VER}，实际 ${NEW_BIN_VER}"
    fi

    ok "二进制文件执行测试通过: ${NEW_BIN_VER}"
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
    timeout -k 2s "${VERSION_TIMEOUT}s" "${TARGET_DIR}/xray" -version 2>/dev/null | head -n 2 || true
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

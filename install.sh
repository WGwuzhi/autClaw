#!/usr/bin/env bash
# autclaw-install-script
# =============================================================================
# autClaw 一键安装脚本
#
# 用法：
#   bash <(curl -fsSL https://raw.githubusercontent.com/WGwuzhi/autClaw/main/install.sh)
#
#   也可以下载后直接运行（脚本内部会自动通过 sudo 提升权限）：
#   curl -fsSLO https://raw.githubusercontent.com/WGwuzhi/autClaw/main/install.sh
#   bash install.sh
#
# 交互流程（只需输入序号）：
#   1. 选择安装方式：直装版 / Docker
#   2. 选择安装（或宿主机数据）目录
#   3. 选择是否安装 ffmpeg
#   4. 选择访问端口
#
# 脚本会自动完成：
#   - CPU 架构检测（amd64 / arm64）
#   - GitHub 加速源测速，拉取最新 release，失败时按顺序回退，直连始终兜底
#   - SHA256 校验 release bundle
#   - 直装版：安装 mise 与运行产物，注册 systemd 服务（无 systemd 时用 nohup）
#   - Docker：拉取官方镜像，预拉取运行产物，创建并启动容器
#   - ffmpeg：直装版通过系统包管理器安装；Docker 使用 :full 镜像
#
# 非交互用法（可选，任一项未设置时仍会弹出序号菜单）：
#   AUTCLAW_INSTALL_MODE=direct|docker
#   AUTCLAW_INSTALL_DIR=/opt/autclaw
#   AUTCLAW_INSTALL_FFMPEG=1|0
#   AUTCLAW_HTTP_PORT=8200
#   AUTCLAW_GITHUB_PROXY=https://your-proxy.example/       # 额外优先尝试的加速源
#   AUTCLAW_MISE_VERSION=2026.10.19                       # 默认与镜像内版本一致
#   AUTCLAW_MISE_COMMAND=/usr/local/bin/mise              # 指定已有的 mise
#   AUTCLAW_MISE_INSTALL_PATH=/usr/local/bin/mise         # 指定 mise 安装路径
#   AUTCLAW_IMAGE=...                                     # 覆盖 Docker 镜像
#   AUTCLAW_SKIP_PULL=1                                   # 使用本地已有镜像
#   AUTCLAW_NONINTERACTIVE=1                              # 缺少必填项时直接报错
#
# 说明：
#   - 直装版默认以 root 运行，与官方容器行为一致（插件需要执行外部命令/访问设备）。
#   - 直装版默认安装到 /opt/autclaw；程序的数据、dist、plugin、envs 都在该目录。
#   - Docker 模式的数据目录会挂载到容器内 /opt/autclaw。
# =============================================================================

set -Eeuo pipefail

if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  printf '需要 Bash 4 或更高版本\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------
APP_NAME="autClaw"
RELEASE_REPO="${AUTCLAW_RELEASE_REPO:-WGwuzhi/autClaw}"
RELEASE_BASE="${AUTCLAW_RELEASE_BASE:-https://github.com/${RELEASE_REPO}/releases}"
MISE_RELEASE_BASE="${AUTCLAW_MISE_RELEASE_BASE:-https://github.com/jdx/mise/releases/download}"
DEFAULT_INSTALL_DIR="/opt/autclaw"
DEFAULT_HTTP_PORT="8200"
DEFAULT_MISE_VERSION="2026.10.19"
SCRIPT_URL="${AUTCLAW_SCRIPT_URL:-https://raw.githubusercontent.com/WGwuzhi/autClaw/main/install.sh}"
CONTAINER_NAME="${AUTCLAW_CONTAINER_NAME:-autclaw}"
SERVICE_NAME="${AUTCLAW_SERVICE_NAME:-autclaw}"
IMAGE_SLIM="${AUTCLAW_IMAGE_SLIM:-nolan1121953/autclaw:latest}"
IMAGE_FULL="${AUTCLAW_IMAGE_FULL:-nolan1121953/autclaw:full}"

# ---------------------------------------------------------------------------
# 运行期变量
# ---------------------------------------------------------------------------
ARCH=""
MISE_ARCH=""
MISE_VERSION="${AUTCLAW_MISE_VERSION:-${DEFAULT_MISE_VERSION}}"
MISE_INSTALL_PATH="${AUTCLAW_MISE_INSTALL_PATH:-}"
MISE_BIN=""
GITHUB_PROXY="${AUTCLAW_GITHUB_PROXY:-}"
INSTALL_MODE="${AUTCLAW_INSTALL_MODE:-}"
INSTALL_DIR="${AUTCLAW_INSTALL_DIR:-}"
INSTALL_FFMPEG="${AUTCLAW_INSTALL_FFMPEG:-}"
HTTP_PORT="${AUTCLAW_HTTP_PORT:-}"
IMAGE="${AUTCLAW_IMAGE:-}"
WORK_DIR=""
LOG_FILE=""
BUNDLE_ROOT=""
BUNDLE_VERSION=""
SOURCES=()
SOURCES_SELECTED=0
PKG_MGR=""
PKG_UPDATED=0
SYSTEMD=0
UNIT_PATH=""
FFMPEG_OK=0
FFMPEG_AMR=0
MENU_INDEX=""

# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'
  C_BLUE=$'\033[1;34m'
  C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
  C_RED=$'\033[1;31m'
else
  C_RESET=""
  C_BLUE=""
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
fi

log()  { printf '%s[信息]%s %s\n' "${C_BLUE}" "${C_RESET}" "$*"; }
ok()   { printf '%s[完成]%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
warn() { printf '%s[警告]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
error(){ printf '%s[错误]%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }
die()  { error "$*"; exit 1; }

on_error() {
  local rc=$?
  error "命令执行失败（退出码 ${rc}，脚本第 ${BASH_LINENO[0]:-?} 行）"
}

print_banner() {
  cat <<'EOF'
============================================================
 autClaw 一键安装
 自动检测架构 / 选择目录 / 加速源测速 / 直连兜底
 支持直装版与 Docker，可选 ffmpeg
============================================================
EOF
}

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------
setup_logging() {
  LOG_FILE="${TMPDIR:-/tmp}/autclaw-install-$(date +%Y%m%d-%H%M%S).log"
  if command -v tee >/dev/null 2>&1; then
    exec > >(tee -a "${LOG_FILE}") 2>&1
  else
    LOG_FILE="(未启用)"
  fi
  log "安装日志: ${LOG_FILE}"
}

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "${WORK_DIR:-}" ] && [ -d "${WORK_DIR}" ]; then
    if [ "${rc}" -eq 0 ]; then
      rm -rf "${WORK_DIR}"
    else
      warn "安装未完成，临时文件保留在: ${WORK_DIR}"
    fi
  fi
  exit "${rc}"
}

normalize_dir() {
  local p="$1"
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  case "${p}" in
    "~") p="${HOME}" ;;
    "~/"*) p="${HOME}/${p#\~/}" ;;
  esac
  [ -n "${p}" ] || return 1
  if [[ "${p}" != /* ]]; then
    p="$(pwd)/${p}"
  fi
  if command -v readlink >/dev/null 2>&1 && readlink -m / >/dev/null 2>&1; then
    p="$(readlink -m "${p}")"
  fi
  while [ "${p%/}" != "${p}" ] && [ "${p}" != "/" ]; do
    p="${p%/}"
  done
  printf '%s' "${p}"
}

validate_install_dir() {
  local d="$1"
  if [ -z "${d}" ]; then
    error "安装目录不能为空"
    return 1
  fi
  if [ "${d}" = "/" ]; then
    error "不能把根目录 / 作为安装目录"
    return 1
  fi
  case "${d}" in
    *$'\n'*|*$'\r'*|*'"'*|*'$'*|*'`'*)
      error "安装目录包含不支持的字符（换行、双引号、$、反引号）"
      return 1
      ;;
  esac
  if [ -e "${d}" ] && [ ! -d "${d}" ]; then
    error "路径已存在但不是目录: ${d}"
    return 1
  fi
  if [ "${INSTALL_MODE}" = "docker" ]; then
    case "${d}" in
      *:*)
        error "Docker 模式的数据目录不能包含冒号"
        return 1
        ;;
    esac
  else
    case "${d}" in
      *%*)
        error "直装版安装目录不能包含 %（systemd 单元会解析该字符）"
        return 1
        ;;
    esac
  fi
  case "${d}" in
    /mnt/*)
      warn "目录位于 Windows 挂载盘（/mnt/...），可能存在权限和性能问题，建议使用 Linux 文件系统路径"
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# 交互菜单
# ---------------------------------------------------------------------------
choose_menu() {
  local title="$1"
  shift
  local -a opts=("$@")
  local i choice
  while true; do
    printf '\n%s\n' "${title}"
    for i in "${!opts[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "${opts[$i]}"
    done
    printf '请输入序号 [1]: '
    if ! read -r choice; then
      die "输入结束，安装取消"
    fi
    choice="${choice:-1}"
    if [[ "${choice}" =~ ^[0-9]+$ ]] && [ "${choice}" -ge 1 ] && [ "${choice}" -le "${#opts[@]}" ]; then
      MENU_INDEX="${choice}"
      return 0
    fi
    warn "无效选择，请输入 1-${#opts[@]}"
  done
}

valid_port() {
  [[ "${1}" =~ ^[0-9]+$ ]] && [ "${1}" -ge 1 ] && [ "${1}" -le 65535 ]
}

read_port_value() {
  local p
  while true; do
    printf '请输入端口号 [1-65535]: '
    if ! read -r p; then
      die "输入结束，安装取消"
    fi
    if valid_port "${p}"; then
      HTTP_PORT="${p}"
      return 0
    fi
    warn "端口必须是 1-65535 之间的整数"
  done
}

read_dir_value() {
  local p normalized
  local label="安装"
  if [ "${INSTALL_MODE}" = "docker" ]; then
    label="宿主机数据"
  fi
  while true; do
    printf '请输入%s绝对路径（例如 /data/autclaw）: ' "${label}"
    if ! read -r p; then
      die "输入结束，安装取消"
    fi
    if [ -z "${p}" ]; then
      warn "路径不能为空"
      continue
    fi
    normalized="$(normalize_dir "${p}")" || {
      warn "路径无效"
      continue
    }
    if validate_install_dir "${normalized}"; then
      INSTALL_DIR="${normalized}"
      return 0
    fi
  done
}

require_noninteractive() {
  if [ "${AUTCLAW_NONINTERACTIVE:-0}" = "1" ]; then
    die "$1"
  fi
}

# ---------------------------------------------------------------------------
# 平台与包管理器
# ---------------------------------------------------------------------------
detect_platform() {
  local kernel
  kernel="$(uname -s)"
  if [ "${kernel}" != "Linux" ]; then
    die "仅支持 Linux，当前系统: ${kernel}"
  fi
  case "$(uname -m)" in
    x86_64|amd64)
      ARCH="amd64"
      MISE_ARCH="x64"
      ;;
    aarch64|arm64)
      ARCH="arm64"
      MISE_ARCH="arm64"
      ;;
    *)
      die "不支持的 CPU 架构: $(uname -m)（仅支持 amd64 / arm64）"
      ;;
  esac
  ok "系统架构: $(uname -m) -> linux-${ARCH}"
}

detect_systemd() {
  SYSTEMD=0
  if [ "${AUTCLAW_FORCE_NO_SYSTEMD:-0}" = "1" ]; then
    warn "已设置 AUTCLAW_FORCE_NO_SYSTEMD=1，将使用 nohup 后台运行"
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    if systemctl list-unit-files >/dev/null 2>&1; then
      SYSTEMD=1
    fi
  fi
  if [ "${SYSTEMD}" -eq 1 ]; then
    log "检测到 systemd，将注册开机自启服务"
  else
    warn "未检测到可用的 systemd，将使用 nohup 后台运行（重启后需手动启动）"
  fi
}

detect_pkg_mgr() {
  if [ -n "${PKG_MGR}" ]; then
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt-get"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MGR="pacman"
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
  else
    return 1
  fi
  return 0
}

pkg_update_once() {
  [ "${PKG_UPDATED}" -eq 1 ] && return 0
  case "${PKG_MGR}" in
    apt-get)
      DEBIAN_FRONTEND=noninteractive apt-get update -qq
      ;;
    dnf)
      dnf -q makecache
      ;;
    yum)
      yum -q makecache
      ;;
    apk)
      apk update -q
      ;;
    pacman)
      pacman -Sy --noconfirm
      ;;
    zypper)
      zypper --non-interactive refresh
      ;;
    *)
      return 1
      ;;
  esac
  PKG_UPDATED=1
}

pkg_install() {
  local kind="$1"
  [ -n "${PKG_MGR}" ] || return 1
  pkg_update_once || warn "软件包索引更新失败，继续尝试安装"
  case "${PKG_MGR}:${kind}" in
    apt-get:base)
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        curl ca-certificates tar gzip coreutils xz-utils grep sed
      ;;
    apt-get:build)
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        gcc libc6-dev make
      ;;
    apt-get:ffmpeg)
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        ffmpeg libavcodec-extra \
        || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ffmpeg
      ;;
    dnf:base|yum:base)
      "${PKG_MGR}" install -y -q curl ca-certificates tar gzip coreutils xz grep sed
      ;;
    dnf:build|yum:build)
      "${PKG_MGR}" install -y -q gcc glibc-devel make
      ;;
    dnf:ffmpeg|yum:ffmpeg)
      "${PKG_MGR}" install -y -q ffmpeg
      ;;
    apk:base)
      apk add --no-cache curl ca-certificates tar gzip coreutils xz grep sed
      ;;
    apk:build)
      apk add --no-cache build-base
      ;;
    apk:ffmpeg)
      apk add --no-cache ffmpeg
      ;;
    pacman:base)
      pacman -S --noconfirm --needed curl ca-certificates tar gzip coreutils xz grep sed
      ;;
    pacman:build)
      pacman -S --noconfirm --needed gcc make
      ;;
    pacman:ffmpeg)
      pacman -S --noconfirm --needed ffmpeg
      ;;
    zypper:base)
      zypper --non-interactive install curl ca-certificates tar gzip coreutils xz grep sed
      ;;
    zypper:build)
      zypper --non-interactive install gcc glibc-devel make
      ;;
    zypper:ffmpeg)
      zypper --non-interactive install ffmpeg
      ;;
    *)
      warn "未知的包管理器/包类型: ${PKG_MGR}:${kind}"
      return 1
      ;;
  esac
}

ensure_base_tools() {
  local need_xz="${1:-1}"
  local -a required=(curl tar gzip sha256sum grep sed)
  if [ "${need_xz}" = "1" ]; then
    required+=(xz)
  fi
  local missing=()
  local c
  for c in "${required[@]}"; do
    command -v "${c}" >/dev/null 2>&1 || missing+=("${c}")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    return 0
  fi
  log "缺少基础工具: ${missing[*]}，尝试自动安装..."
  if ! detect_pkg_mgr; then
    warn "未检测到受支持的包管理器，无法安装: ${missing[*]}"
    return 1
  fi
  if ! pkg_install base; then
    warn "基础工具安装失败: ${missing[*]}"
    return 1
  fi
  hash -r
  for c in "${required[@]}"; do
    if ! command -v "${c}" >/dev/null 2>&1; then
      warn "安装后仍缺少命令: ${c}"
      return 1
    fi
  done
  ok "基础工具已就绪"
  return 0
}

ensure_build_tools() {
  local need_install=0
  command -v gcc >/dev/null 2>&1 || need_install=1
  command -v make >/dev/null 2>&1 || need_install=1
  if [ "${need_install}" -eq 0 ]; then
    local test_dir="${WORK_DIR:-${TMPDIR:-/tmp}}"
    local test_c="${test_dir}/.autclaw-c-test.c"
    local test_bin="${test_dir}/.autclaw-c-test"
    if printf '#include <stdio.h>\nint main(void){return 0;}\n' > "${test_c}" 2>/dev/null; then
      if gcc "${test_c}" -o "${test_bin}" >/dev/null 2>&1; then
        rm -f "${test_c}" "${test_bin}"
        return 0
      fi
      rm -f "${test_c}" "${test_bin}"
      warn "gcc 存在但无法编译 C 程序（可能缺少 libc 头文件），尝试安装编译工具"
      need_install=1
    else
      return 0
    fi
  fi
  log "安装 Go 插件编译所需工具（gcc / make / libc 头文件）..."
  if ! detect_pkg_mgr; then
    warn "未检测到包管理器，跳过编译工具安装"
    return 1
  fi
  if ! pkg_install build; then
    warn "编译工具安装失败；使用 cgo 的 Go 插件可能无法编译"
    return 1
  fi
  hash -r
  ok "编译工具已就绪"
  return 0
}

ensure_ffmpeg_in_standard_path() {
  local f p
  f="$(command -v ffmpeg 2>/dev/null || true)"
  p="$(command -v ffprobe 2>/dev/null || true)"
  [ -n "${f}" ] && [ -n "${p}" ] || return 1

  local need_link=0
  case "${f}" in
    /usr/bin/*|/usr/local/bin/*|/bin/*) ;;
    *) need_link=1 ;;
  esac
  case "${p}" in
    /usr/bin/*|/usr/local/bin/*|/bin/*) ;;
    *) need_link=1 ;;
  esac
  if [ "${need_link}" -eq 0 ]; then
    return 0
  fi
  [ "$(id -u)" -eq 0 ] || return 1

  case "${f}" in
    /*) ln -sf "${f}" /usr/local/bin/ffmpeg 2>/dev/null || true ;;
    *) return 1 ;;
  esac
  case "${p}" in
    /*) ln -sf "${p}" /usr/local/bin/ffprobe 2>/dev/null || true ;;
    *) return 1 ;;
  esac
  hash -r
  local svc_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  PATH="${svc_path}" command -v ffmpeg >/dev/null 2>&1 \
    && PATH="${svc_path}" command -v ffprobe >/dev/null 2>&1
}

ffmpeg_available() {
  command -v ffmpeg >/dev/null 2>&1 \
    && ffmpeg -version >/dev/null 2>&1 \
    && command -v ffprobe >/dev/null 2>&1 \
    && ffprobe -version >/dev/null 2>&1
}

# 微信 / 千寻语音（AMR）依赖 libopencore_amrnb，Debian/Ubuntu 由 libavcodec-extra 提供。
# 这里把编码器列表读进变量再匹配，避免 grep -q 提前退出触发 pipefail。
ffmpeg_amr_available() {
  command -v ffmpeg >/dev/null 2>&1 || return 1
  local encoders
  encoders="$(ffmpeg -hide_banner -encoders 2>/dev/null || true)"
  case "${encoders}" in
    *libopencore_amrnb*) return 0 ;;
  esac
  return 1
}

setup_ffmpeg_native() {
  if ffmpeg_available; then
    if ensure_ffmpeg_in_standard_path; then
      FFMPEG_OK=1
      ok "ffmpeg 已安装: $(command -v ffmpeg)"
      return 0
    fi
    warn "ffmpeg 存在但不在服务 PATH 中，且无法创建 /usr/local/bin 软链接"
    return 1
  fi
  log "安装 ffmpeg（用于语音/视频转码）..."
  if ! detect_pkg_mgr; then
    warn "未检测到包管理器，无法自动安装 ffmpeg"
    return 1
  fi
  if ! pkg_install ffmpeg; then
    warn "ffmpeg 安装失败"
  fi
  hash -r
  if ffmpeg_available; then
    if ensure_ffmpeg_in_standard_path; then
      FFMPEG_OK=1
      ok "ffmpeg 已安装: $(command -v ffmpeg)"
      return 0
    fi
    warn "ffmpeg 已安装但不在服务 PATH 中"
    return 1
  fi
  warn "ffmpeg 不可用，转码功能将不可用"
  return 1
}

verify_native_ffmpeg() {
  [ "${INSTALL_FFMPEG}" = "1" ] || return 0
  if ffmpeg_available && ensure_ffmpeg_in_standard_path; then
    FFMPEG_OK=1
    ok "ffmpeg / ffprobe 可用: $(command -v ffmpeg)"
    verify_native_amr
    return 0
  fi
  FFMPEG_OK=0
  warn "ffmpeg / ffprobe 不可用，转码功能将不可用"
  return 1
}

# ffmpeg 在但缺少 AMR 编码器时，apt 系自动补装 libavcodec-extra，其余系统给出提示。
verify_native_amr() {
  if ffmpeg_amr_available; then
    FFMPEG_AMR=1
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    log "未检测到 AMR 编码器，尝试补装 libavcodec-extra ..."
    pkg_update_once || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      libavcodec-extra >/dev/null 2>&1 || true
    hash -r
    if ffmpeg_amr_available; then
      FFMPEG_AMR=1
      ok "AMR 编码器已就绪（libavcodec-extra）"
      return 0
    fi
  fi

  FFMPEG_AMR=0
  warn "缺少 libopencore_amrnb 编码器：微信 / 千寻语音（AMR）转码不可用"
  warn "  Debian/Ubuntu 安装 libavcodec-extra；RHEL 系需 RPM Fusion 的完整 ffmpeg"
  return 1
}

# ---------------------------------------------------------------------------
# 下载源测速与 release bundle
# ---------------------------------------------------------------------------
select_download_sources() {
  if [ "${SOURCES_SELECTED}" -eq 1 ]; then
    return 0
  fi
  [ -n "${WORK_DIR}" ] || die "内部错误: WORK_DIR 未初始化"

  local test_path="${RELEASE_BASE}/latest/download/SHA256SUMS"
  local -a candidates=()
  local -a unique=()
  local c i seen=""

  if [ -n "${GITHUB_PROXY}" ]; then
    candidates+=("${GITHUB_PROXY%/}")
  fi
  candidates+=(
    "https://gh.jasonzeng.dev"
    "https://gh-proxy.com"
    "https://ghproxy.net"
    "https://ghfast.top"
    ""
  )

  for c in "${candidates[@]}"; do
    if [ -z "${c}" ]; then
      case " ${seen} " in
        *" __direct__ "*) continue ;;
      esac
      seen="${seen} __direct__"
      unique+=("")
    else
      case " ${seen} " in
        *" ${c} "*) continue ;;
      esac
      seen="${seen} ${c}"
      unique+=("${c}")
    fi
  done
  candidates=("${unique[@]}")

  local dir="${WORK_DIR}/speedtest"
  rm -rf "${dir}"
  mkdir -p "${dir}"
  log "正在测速 GitHub 下载源（共 ${#candidates[@]} 个，含直连兜底）..."

  i=0
  for c in "${candidates[@]}"; do
    local url
    if [ -z "${c}" ]; then
      url="${test_path}"
    else
      url="${c%/}/${test_path}"
    fi
    (
      local t
      if t="$(curl -fsSL --connect-timeout 3 --max-time 8 \
        -o "${dir}/${i}.body" -w '%{time_total}' "${url}" 2>/dev/null)"; then
        if grep -Eq '^[[:xdigit:]]{64}[[:space:]]+.*autclaw-bundle-linux-(amd64|arm64)\.tar\.gz$' \
          "${dir}/${i}.body"; then
          printf '%s %s\n' "${t}" "${i}" > "${dir}/${i}.ok"
        fi
      fi
    ) &
    i=$((i + 1))
  done
  wait || true

  local -a results=()
  local f
  for f in "${dir}"/*.ok; do
    [ -e "${f}" ] || continue
    results+=("$(<"${f}")")
  done

  local -a sorted=()
  local -A times=()
  local t idx label
  if [ "${#results[@]}" -gt 0 ]; then
    log "测速结果（秒，越小越快）:"
    while IFS=' ' read -r t idx; do
      [ -n "${idx:-}" ] || continue
      sorted+=("${idx}")
      times["${idx}"]="${t}"
      label="${candidates[$idx]}"
      [ -n "${label}" ] || label="GitHub 直连"
      log "  ${t}s  ${label}"
    done < <(printf '%s\n' "${results[@]}" | sort -n)
  fi

  SOURCES=()
  local added=""
  if [ "${#sorted[@]}" -gt 0 ]; then
    local best_idx="${sorted[0]}"
    for idx in "${sorted[@]}"; do
      SOURCES+=("${candidates[$idx]}")
      added="${added} ${idx}"
    done
    label="${candidates[$best_idx]}"
    [ -n "${label}" ] || label="GitHub 直连"
    ok "选择下载源: ${label} (${times[$best_idx]}s)"
  else
    warn "测速没有找到可用源，将依次尝试全部源（直连最后）"
  fi

  # 把测速失败但可能仍然可用的源追加进来；直连永远最后兜底。
  local direct_added=0
  for i in "${!candidates[@]}"; do
    case " ${added} " in
      *" ${i} "*) continue ;;
    esac
    if [ -z "${candidates[$i]}" ]; then
      direct_added=1
    else
      SOURCES+=("${candidates[$i]}")
      added="${added} ${i}"
    fi
  done
  if [ "${direct_added}" -eq 1 ]; then
    SOURCES+=("")
  fi

  SOURCES_SELECTED=1
  return 0
}

download_url() {
  local path="$1"
  local out="$2"
  local label="$3"
  local max_time="${4:-600}"
  local base url
  for base in "${SOURCES[@]}"; do
    if [ -z "${base}" ]; then
      url="${path}"
    else
      url="${base%/}/${path}"
    fi
    log "下载 ${label}: ${url}"
    rm -f "${out}"
    if curl -fSL --retry 2 --retry-delay 1 --connect-timeout 10 --max-time "${max_time}" \
      -o "${out}" "${url}"; then
      if [ -s "${out}" ]; then
        return 0
      fi
      warn "${label} 下载内容为空（${base:-GitHub 直连}）"
    else
      warn "${label} 下载失败（${base:-GitHub 直连}）"
    fi
  done
  rm -f "${out}"
  return 1
}

prepare_release_bundle() {
  [ -n "${WORK_DIR}" ] || die "内部错误: WORK_DIR 未初始化"

  local bundle_name="autclaw-bundle-linux-${ARCH}.tar.gz"
  local bundle_path="${WORK_DIR}/${bundle_name}"
  local sums_path="${WORK_DIR}/SHA256SUMS"
  local verify_dir="${WORK_DIR}/verify"
  local extract_dir="${WORK_DIR}/extract"
  local base url sums_url label verified=0

  select_download_sources

  for base in "${SOURCES[@]}"; do
    if [ -z "${base}" ]; then
      url="${RELEASE_BASE}/latest/download/${bundle_name}"
      sums_url="${RELEASE_BASE}/latest/download/SHA256SUMS"
      label="GitHub 直连"
    else
      url="${base%/}/${RELEASE_BASE}/latest/download/${bundle_name}"
      sums_url="${base%/}/${RELEASE_BASE}/latest/download/SHA256SUMS"
      label="${base}"
    fi

    log "下载 release bundle: ${url}"
    rm -f "${bundle_path}" "${sums_path}"
    rm -rf "${verify_dir}"
    mkdir -p "${verify_dir}"

    if ! curl -fSL --retry 2 --retry-delay 1 --connect-timeout 10 --max-time 900 \
      -o "${bundle_path}" "${url}"; then
      warn "bundle 下载失败（${label}），尝试下一个源"
      continue
    fi
    if ! curl -fsSL --connect-timeout 10 --max-time 60 -o "${sums_path}" "${sums_url}"; then
      warn "校验清单下载失败（${label}），尝试下一个源"
      continue
    fi
    if ! grep -Eq '^[[:xdigit:]]{64}[[:space:]]+.*autclaw-bundle-linux-(amd64|arm64)\.tar\.gz$' \
      "${sums_path}"; then
      warn "校验清单格式无效（${label}），尝试下一个源"
      continue
    fi
    if ! grep -Eq "[[:space:]]${bundle_name}$" "${sums_path}"; then
      warn "校验清单不包含 ${bundle_name}（${label}），尝试下一个源"
      continue
    fi

    cp -f "${bundle_path}" "${verify_dir}/${bundle_name}" || continue
    if ! grep -E "[[:space:]]${bundle_name}$" "${sums_path}" > "${verify_dir}/SHA256SUMS.one"; then
      warn "无法提取 bundle 校验行（${label}）"
      continue
    fi
    if ( cd "${verify_dir}" && sha256sum -c SHA256SUMS.one >/dev/null 2>&1 ); then
      verified=1
      ok "release bundle 下载并校验成功（${label}）"
      break
    fi
    warn "bundle 哈希校验失败（${label}），尝试下一个源"
  done

  if [ "${verified}" -ne 1 ]; then
    error "无法下载有效的 release bundle（已尝试全部下载源）。可设置 AUTCLAW_GITHUB_PROXY 指定加速源后重试。"
    return 1
  fi

  rm -rf "${extract_dir}"
  mkdir -p "${extract_dir}"
  if ! tar --no-same-owner -xzf "${bundle_path}" -C "${extract_dir}" 2>/dev/null; then
    rm -rf "${extract_dir}"
    mkdir -p "${extract_dir}"
    if ! tar -xzf "${bundle_path}" -C "${extract_dir}"; then
      error "release bundle 解压失败"
      return 1
    fi
  fi
  if [ "$(id -u)" -eq 0 ]; then
    chown -R root:root "${extract_dir}" 2>/dev/null || true
  fi

  if [ -d "${extract_dir}/autclaw" ]; then
    BUNDLE_ROOT="${extract_dir}/autclaw"
  else
    BUNDLE_ROOT="${extract_dir}"
  fi

  if [ ! -x "${BUNDLE_ROOT}/autclaw" ]; then
    error "release bundle 缺少可执行文件 autclaw"
    return 1
  fi
  if [ ! -f "${BUNDLE_ROOT}/dist/index.html" ]; then
    error "release bundle 缺少 dist/index.html"
    return 1
  fi
  if [ ! -d "${BUNDLE_ROOT}/plugin" ]; then
    error "release bundle 缺少 plugin 目录"
    return 1
  fi

  BUNDLE_VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "${BUNDLE_ROOT}/manifest.json" 2>/dev/null || true)"
  BUNDLE_VERSION="${BUNDLE_VERSION%%$'\n'*}"
  [ -n "${BUNDLE_VERSION}" ] || BUNDLE_VERSION="未知"
  ok "release 版本: ${BUNDLE_VERSION}"
  return 0
}

install_artifacts() {
  local source_root="$1"
  local target_dir="$2"
  local dist_new="${target_dir}/.dist.new"
  local dist_old="${target_dir}/.dist.old"
  local bin_new="${target_dir}/.autclaw.new"

  if [ ! -x "${source_root}/autclaw" ]; then
    error "运行产物缺少 autclaw: ${source_root}"
    return 1
  fi
  if [ ! -d "${source_root}/dist" ]; then
    error "运行产物缺少 dist: ${source_root}"
    return 1
  fi

  mkdir -p "${target_dir}" || return 1

  cp -f "${source_root}/autclaw" "${bin_new}" || {
    error "复制 autclaw 失败"
    return 1
  }
  chmod 0755 "${bin_new}" || return 1
  mv -f "${bin_new}" "${target_dir}/autclaw" || {
    error "替换 autclaw 失败"
    return 1
  }

  rm -rf "${dist_new}" "${dist_old}"
  cp -a "${source_root}/dist" "${dist_new}" || {
    error "复制 dist 失败"
    return 1
  }
  if [ -d "${target_dir}/dist" ]; then
    mv "${target_dir}/dist" "${dist_old}" || {
      error "暂存旧 dist 失败"
      rm -rf "${dist_new}"
      return 1
    }
  fi
  if ! mv "${dist_new}" "${target_dir}/dist"; then
    if [ -d "${dist_old}" ]; then
      mv "${dist_old}" "${target_dir}/dist" 2>/dev/null || true
    fi
    error "替换 dist 失败"
    return 1
  fi
  rm -rf "${dist_old}"

  mkdir -p "${target_dir}/plugin" || return 1
  if [ -d "${source_root}/plugin" ]; then
    cp -a "${source_root}/plugin/." "${target_dir}/plugin/" || {
      error "复制 plugin 失败"
      return 1
    }
  fi
  mkdir -p \
    "${target_dir}/plugin/adapters" \
    "${target_dir}/plugin/replies" \
    "${target_dir}/plugin/scripts" \
    "${target_dir}/plugin/scripts/middleware" || return 1

  if [ -f "${source_root}/manifest.json" ]; then
    cp -f "${source_root}/manifest.json" "${target_dir}/manifest.json" || return 1
  fi

  mkdir -p "${target_dir}/envs/mise" "${target_dir}/envs/packages" || return 1
  ok "运行产物已安装到: ${target_dir}"
  return 0
}

read_version_from_dir() {
  local dir="$1"
  local v=""
  if [ -f "${dir}/manifest.json" ]; then
    v="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      "${dir}/manifest.json" 2>/dev/null || true)"
    v="${v%%$'\n'*}"
  fi
  printf '%s' "${v:-未知}"
}

# ---------------------------------------------------------------------------
# mise
# ---------------------------------------------------------------------------
find_mise() {
  local p
  if [ -n "${AUTCLAW_MISE_COMMAND:-}" ] && [ -x "${AUTCLAW_MISE_COMMAND}" ]; then
    MISE_BIN="${AUTCLAW_MISE_COMMAND}"
    return 0
  fi
  if [ -n "${MISE_INSTALL_PATH}" ] && [ -x "${MISE_INSTALL_PATH}" ]; then
    MISE_BIN="${MISE_INSTALL_PATH}"
    return 0
  fi
  for p in /usr/local/bin/mise /usr/bin/mise; do
    if [ -x "${p}" ]; then
      MISE_BIN="${p}"
      return 0
    fi
  done
  # root 直装使用系统级 mise，避免依赖某个用户 home 下的安装。
  if [ "$(id -u)" -eq 0 ]; then
    return 1
  fi
  p="$(command -v mise 2>/dev/null || true)"
  if [ -n "${p}" ] && [ -x "${p}" ]; then
    MISE_BIN="${p}"
    return 0
  fi
  if [ -x "${HOME}/.local/bin/mise" ]; then
    MISE_BIN="${HOME}/.local/bin/mise"
    return 0
  fi
  return 1
}

install_mise() {
  if find_mise; then
    local v
    v="$("${MISE_BIN}" --version 2>/dev/null || true)"
    v="${v%%$'\n'*}"
    if [ -n "${v}" ]; then
      ok "已检测到 mise: ${MISE_BIN} (${v})"
      return 0
    fi
    warn "检测到的 mise 无法运行，将重新安装: ${MISE_BIN}"
    MISE_BIN=""
  fi

  local version="${MISE_VERSION#v}"
  if ! [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+)*$ ]]; then
    error "mise 版本格式非法: ${MISE_VERSION}"
    return 1
  fi

  local asset="mise-v${version}-linux-${MISE_ARCH}.tar.xz"
  local base="${MISE_RELEASE_BASE%/}/v${version}"
  local dir="${WORK_DIR}/mise"
  mkdir -p "${dir}" || return 1
  if [ "${#SOURCES[@]}" -eq 0 ]; then
    select_download_sources
  fi

  log "安装 mise ${version}（${asset}）..."
  if ! download_url "${base}/SHASUMS256.txt" "${dir}/SHASUMS256.txt" "mise 校验清单" 60; then
    error "mise 校验清单下载失败"
    return 1
  fi
  if ! grep -Fq "./${asset}" "${dir}/SHASUMS256.txt"; then
    error "mise 校验清单不包含 ${asset}"
    return 1
  fi
  if ! download_url "${base}/${asset}" "${dir}/${asset}" "mise" 600; then
    error "mise 下载失败"
    return 1
  fi
  if ! grep -F "./${asset}" "${dir}/SHASUMS256.txt" > "${dir}/${asset}.sha256"; then
    error "无法从 mise 校验清单提取 ${asset}"
    return 1
  fi
  if ! ( cd "${dir}" && sha256sum -c "${asset}.sha256" >/dev/null 2>&1 ); then
    error "mise 哈希校验失败"
    return 1
  fi
  if ! tar -xJf "${dir}/${asset}" -C "${dir}" mise/bin/mise; then
    error "mise 解压失败"
    return 1
  fi

  local target
  if [ -n "${MISE_INSTALL_PATH}" ]; then
    target="${MISE_INSTALL_PATH}"
  elif [ "$(id -u)" -eq 0 ]; then
    target="/usr/local/bin/mise"
  else
    target="${HOME}/.local/bin/mise"
  fi
  mkdir -p "$(dirname "${target}")" || return 1
  cp -f "${dir}/mise/bin/mise" "${target}" || return 1
  chmod 0755 "${target}" || return 1
  MISE_BIN="${target}"

  local installed
  installed="$("${MISE_BIN}" --version 2>/dev/null || true)"
  installed="${installed%%$'\n'*}"
  if [ -z "${installed}" ]; then
    error "mise 安装后无法运行: ${target}"
    return 1
  fi
  ok "mise 已安装: ${MISE_BIN} (${installed})"
  return 0
}

# ---------------------------------------------------------------------------
# 直装版
# ---------------------------------------------------------------------------
stop_existing_direct() {
  if [ -f "${INSTALL_DIR}/autclaw.pid" ]; then
    local pid
    pid="$(cat "${INSTALL_DIR}/autclaw.pid" 2>/dev/null || true)"
    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      log "停止旧的后台进程（PID ${pid}）..."
      kill "${pid}" 2>/dev/null || true
      local i=0
      while [ "${i}" -lt 10 ] && kill -0 "${pid}" 2>/dev/null; do
        sleep 1
        i=$((i + 1))
      done
      if kill -0 "${pid}" 2>/dev/null; then
        kill -9 "${pid}" 2>/dev/null || true
      fi
    fi
    rm -f "${INSTALL_DIR}/autclaw.pid"
  fi

  if [ "${SYSTEMD}" -eq 1 ] && [ -n "${UNIT_PATH}" ] && [ -f "${UNIT_PATH}" ]; then
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
      log "停止现有 systemd 服务 ${SERVICE_NAME} ..."
      systemctl stop "${SERVICE_NAME}" || warn "停止 systemd 服务失败"
    fi
  fi
}

write_systemd_unit() {
  UNIT_PATH="${AUTCLAW_SYSTEMD_DIR:-/etc/systemd/system}/${SERVICE_NAME}.service"
  local unit_dir
  unit_dir="$(dirname "${UNIT_PATH}")"
  mkdir -p "${unit_dir}" || return 1

  local mise_cmd="${MISE_BIN:-mise}"
  case "${mise_cmd}" in
    *$'\n'*|*$'\r'*|*'"'*|*'$'*|*'`'*)
      error "mise 路径包含 systemd 单元不支持的字符: ${mise_cmd}"
      return 1
      ;;
  esac
  local tmp="${UNIT_PATH}.tmp"
  if ! cat > "${tmp}" <<EOF
[Unit]
Description=${APP_NAME} service
Documentation=https://github.com/${RELEASE_REPO}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory="${INSTALL_DIR}"
ExecStart="${INSTALL_DIR}/autclaw"
Restart=always
RestartSec=3
TimeoutStopSec=20
KillMode=mixed
LimitNOFILE=1048576
Environment="HTTP_ADDR=:${HTTP_PORT}"
Environment="MISE_COMMAND=${mise_cmd}"
Environment="MISE_DATA_DIR=${INSTALL_DIR}/envs/mise"
Environment="MISE_CONFIG_DIR=${INSTALL_DIR}/envs/mise"
Environment="AUTCLAW_RUNTIME_PACKAGE_ROOT_DIR=${INSTALL_DIR}/envs/packages"
Environment="MISE_HIDE_UPDATE_WARNING=1"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="LANG=C.UTF-8"

[Install]
WantedBy=multi-user.target
EOF
  then
    error "写入 systemd 服务文件失败: ${UNIT_PATH}"
    rm -f "${tmp}"
    return 1
  fi
  chmod 0644 "${tmp}" || return 1
  mv -f "${tmp}" "${UNIT_PATH}" || return 1
  log "已写入 systemd 服务: ${UNIT_PATH}"
  return 0
}

start_nohup() {
  local log_path="${INSTALL_DIR}/autclaw.log"
  local pid_path="${INSTALL_DIR}/autclaw.pid"
  (
    cd "${INSTALL_DIR}" || exit 1
    export HTTP_ADDR=":${HTTP_PORT}"
    export MISE_COMMAND="${MISE_BIN:-mise}"
    export MISE_DATA_DIR="${INSTALL_DIR}/envs/mise"
    export MISE_CONFIG_DIR="${INSTALL_DIR}/envs/mise"
    export AUTCLAW_RUNTIME_PACKAGE_ROOT_DIR="${INSTALL_DIR}/envs/packages"
    export MISE_HIDE_UPDATE_WARNING=1
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    export LANG="${LANG:-C.UTF-8}"
    nohup "${INSTALL_DIR}/autclaw" >> "${log_path}" 2>&1 &
    echo $! > "${pid_path}"
  ) || return 1
  ok "已在后台启动，PID $(cat "${pid_path}" 2>/dev/null || echo '未知')，日志: ${log_path}"
  return 0
}

start_direct() {
  if [ "${SYSTEMD}" -eq 1 ]; then
    if ! write_systemd_unit; then
      return 1
    fi
    systemctl daemon-reload || warn "systemctl daemon-reload 失败"
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || warn "设置开机自启失败"
    if ! systemctl restart "${SERVICE_NAME}"; then
      warn "systemd 服务启动失败"
      systemctl status "${SERVICE_NAME}" --no-pager -l 2>/dev/null || true
      return 1
    fi
    ok "systemd 服务已启动: ${SERVICE_NAME}"
    return 0
  fi
  start_nohup
}

run_direct_install() {
  log "开始直装版安装..."

  if ! ensure_base_tools; then
    die "缺少必要工具，无法继续"
  fi

  local bundle_ok=0
  if prepare_release_bundle; then
    bundle_ok=1
  else
    if [ -x "${INSTALL_DIR}/autclaw" ] && [ -f "${INSTALL_DIR}/dist/index.html" ]; then
      warn "下载最新版本失败，继续使用已有安装（版本: $(read_version_from_dir "${INSTALL_DIR}")）"
      BUNDLE_VERSION="$(read_version_from_dir "${INSTALL_DIR}")"
    else
      die "下载 release bundle 失败，且没有可用的已有安装。可设置 AUTCLAW_GITHUB_PROXY 指定加速源后重试。"
    fi
  fi

  if ! install_mise; then
    die "mise 安装失败，无法安装运行时环境。可设置 AUTCLAW_MISE_VERSION 或 AUTCLAW_MISE_COMMAND 后重试。"
  fi

  if [ "${INSTALL_FFMPEG}" = "1" ]; then
    setup_ffmpeg_native || warn "ffmpeg 未配置成功，转码功能不可用"
  else
    log "未选择安装 ffmpeg，跳过"
  fi

  ensure_build_tools || true

  stop_existing_direct

  if [ "${bundle_ok}" -eq 1 ]; then
    if ! install_artifacts "${BUNDLE_ROOT}" "${INSTALL_DIR}"; then
      error "安装运行产物失败"
      if [ -x "${INSTALL_DIR}/autclaw" ]; then
        warn "尝试重新启动已有版本..."
        start_direct || true
      fi
      return 1
    fi
  else
    log "保留现有运行产物"
  fi

  if ! start_direct; then
    error "服务启动失败"
    print_summary failed
    return 1
  fi

  local timeout="${AUTCLAW_HEALTH_TIMEOUT:-120}"
  if ! wait_for_health direct "${timeout}"; then
    error "服务未在 ${timeout}s 内就绪"
    if [ "${SYSTEMD}" -eq 1 ]; then
      systemctl status "${SERVICE_NAME}" --no-pager -l 2>/dev/null || true
      command -v journalctl >/dev/null 2>&1 \
        && journalctl -u "${SERVICE_NAME}" -n 80 --no-pager 2>/dev/null || true
    else
      tail -n 80 "${INSTALL_DIR}/autclaw.log" 2>/dev/null || true
    fi
    print_summary failed
    return 1
  fi

  verify_native_ffmpeg || true
  print_summary ok
  return 0
}

# ---------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------
check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    die "未检测到 docker。请先安装 Docker：https://docs.docker.com/engine/install/"
  fi
  if ! docker info >/dev/null 2>&1; then
    die "Docker 守护进程不可用。请先启动 Docker（例如: systemctl start docker），并确认当前用户有权限。"
  fi
}

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]"
  else
    return 1
  fi
}

verify_docker_ffmpeg() {
  [ "${INSTALL_FFMPEG}" = "1" ] || return 0
  if docker exec "${CONTAINER_NAME}" sh -c \
    'command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1'; then
    FFMPEG_OK=1
    ok "容器内 ffmpeg / ffprobe 可用"
    verify_docker_amr
    return 0
  fi

  warn "容器内未找到 ffmpeg，尝试在容器内安装（重建容器后会丢失）..."
  if docker exec "${CONTAINER_NAME}" sh -c \
    'apt-get update && apt-get install -y --no-install-recommends ffmpeg libavcodec-extra && rm -rf /var/lib/apt/lists/*'; then
    if docker exec "${CONTAINER_NAME}" sh -c \
      'command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1'; then
      FFMPEG_OK=1
      ok "容器内 ffmpeg 已配置（注意：重建容器后需重新安装，推荐使用 :full 镜像）"
      verify_docker_amr
      return 0
    fi
  fi
  warn "容器内 ffmpeg 配置失败，转码功能不可用"
  return 1
}

verify_docker_amr() {
  if docker exec "${CONTAINER_NAME}" sh -c \
    'ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libopencore_amrnb'; then
    FFMPEG_AMR=1
    return 0
  fi
  FFMPEG_AMR=0
  warn "容器内缺少 libopencore_amrnb 编码器：微信 / 千寻语音（AMR）转码不可用（建议使用 :full 镜像）"
  return 1
}

run_docker_install() {
  log "开始 Docker 安装..."
  check_docker

  if [ -z "${IMAGE}" ]; then
    if [ "${INSTALL_FFMPEG}" = "1" ]; then
      IMAGE="${IMAGE_FULL}"
    else
      IMAGE="${IMAGE_SLIM}"
    fi
  fi
  log "使用镜像: ${IMAGE}"

  if [ "${AUTCLAW_SKIP_PULL:-0}" = "1" ]; then
    log "已设置 AUTCLAW_SKIP_PULL=1，跳过镜像拉取"
    if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
      die "本地不存在镜像 ${IMAGE}，无法跳过拉取"
    fi
  else
    if ! docker pull "${IMAGE}"; then
      die "镜像拉取失败。请检查网络或设置 AUTCLAW_IMAGE / AUTCLAW_SKIP_PULL。"
    fi
  fi

  if ensure_base_tools 0; then
    if prepare_release_bundle; then
      if ! install_artifacts "${BUNDLE_ROOT}" "${INSTALL_DIR}"; then
        warn "预下载产物写入数据目录失败，容器启动时会重新拉取"
      fi
    else
      warn "预下载 release bundle 失败，容器启动时会自行拉取"
      BUNDLE_VERSION="$(read_version_from_dir "${INSTALL_DIR}")"
    fi
  else
    warn "宿主机缺少下载工具，跳过预下载；容器启动时会自行拉取"
    BUNDLE_VERSION="$(read_version_from_dir "${INSTALL_DIR}")"
  fi

  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "${CONTAINER_NAME}"; then
    warn "检测到已有容器 ${CONTAINER_NAME}，将重建（数据目录 ${INSTALL_DIR} 保留）"
    if ! docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1; then
      die "删除旧容器失败"
    fi
  fi

  if port_in_use "${HTTP_PORT}"; then
    die "宿主机端口 ${HTTP_PORT} 已被占用，请换一个端口后重试"
  fi

  local -a args=(
    run -d
    --name "${CONTAINER_NAME}"
    --restart unless-stopped
    --network bridge
    -p "${HTTP_PORT}:8200"
    -e AUTCLAW_MACHINE_HOST_ROOT=/host
    -e AUTCLAW_RELEASE_TAG=latest
    --health-cmd "curl -f http://127.0.0.1:8200/healthz || exit 1"
    --health-interval 30s
    --health-timeout 5s
    --health-retries 3
    --health-start-period 15s
  )

  local volume="${INSTALL_DIR}:/opt/autclaw"
  if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
    volume="${volume}:Z"
  fi
  args+=(-v "${volume}")
  if [ -e /etc/machine-id ]; then
    args+=(-v "/etc/machine-id:/host/etc/machine-id:ro")
  fi
  if [ -d /sys/class/dmi/id ]; then
    args+=(-v "/sys/class/dmi/id:/host/sys/class/dmi/id:ro")
  fi
  args+=("${IMAGE}")

  log "启动容器..."
  if ! docker "${args[@]}"; then
    error "容器启动失败"
    docker ps -a --filter "name=${CONTAINER_NAME}" 2>/dev/null || true
    print_summary failed
    return 1
  fi

  local timeout="${AUTCLAW_HEALTH_TIMEOUT:-300}"
  if ! wait_for_health docker "${timeout}"; then
    error "容器未在 ${timeout}s 内就绪"
    docker ps -a --filter "name=${CONTAINER_NAME}" 2>/dev/null || true
    docker logs --tail 100 "${CONTAINER_NAME}" 2>/dev/null || true
    print_summary failed
    return 1
  fi

  verify_docker_ffmpeg || true
  print_summary ok
  return 0
}

# ---------------------------------------------------------------------------
# 健康检查与总结
# ---------------------------------------------------------------------------
wait_for_health() {
  local mode="$1"
  local timeout="${2:-120}"
  local waited=0
  local stopped_count=0
  local url="http://127.0.0.1:${HTTP_PORT}/healthz"

  printf '等待服务就绪'
  while [ "${waited}" -lt "${timeout}" ]; do
    if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 2 "${url}" >/dev/null 2>&1; then
      printf '\n'
      return 0
    fi

    if [ "${mode}" = "docker" ] && command -v docker >/dev/null 2>&1; then
      if docker exec "${CONTAINER_NAME}" curl -fsS --max-time 2 \
        "http://127.0.0.1:8200/healthz" >/dev/null 2>&1; then
        printf '\n'
        return 0
      fi
      local running
      running="$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || true)"
      if [ "${running}" = "true" ]; then
        stopped_count=0
      else
        stopped_count=$((stopped_count + 1))
        if [ "${stopped_count}" -ge 3 ]; then
          printf '\n'
          warn "容器未在运行"
          return 1
        fi
      fi
    elif [ "${mode}" = "direct" ] && [ "${SYSTEMD}" -eq 1 ]; then
      if systemctl is-failed --quiet "${SERVICE_NAME}" 2>/dev/null; then
        printf '\n'
        warn "systemd 服务进入 failed 状态"
        return 1
      fi
    elif [ "${mode}" = "direct" ] && [ "${SYSTEMD}" -eq 0 ]; then
      if [ -f "${INSTALL_DIR}/autclaw.pid" ]; then
        local pid
        pid="$(cat "${INSTALL_DIR}/autclaw.pid" 2>/dev/null || true)"
        if [ -n "${pid}" ] && ! kill -0 "${pid}" 2>/dev/null; then
          printf '\n'
          warn "后台进程已退出（PID ${pid}）"
          return 1
        fi
      fi
    fi

    printf '.'
    sleep 2
    waited=$((waited + 2))
  done
  printf '\n'
  return 1
}

host_ip() {
  local ips
  ips="$(hostname -I 2>/dev/null || true)"
  ips="$(printf '%s' "${ips}" | tr -s ' ' '\n' | sed -n '1p')"
  printf '%s' "${ips}"
}

print_summary() {
  local status="${1:-ok}"
  local safe_host
  safe_host="$(host_ip)"
  [ -n "${safe_host}" ] || safe_host="<服务器IP>"

  local svc_cmd log_cmd stop_cmd mode_label ffmpeg_label
  if [ "${INSTALL_MODE}" = "docker" ]; then
    mode_label="Docker"
    svc_cmd="docker ps --filter name=${CONTAINER_NAME}"
    log_cmd="docker logs -f ${CONTAINER_NAME}"
    stop_cmd="docker stop ${CONTAINER_NAME}"
  else
    mode_label="直装版"
    if [ "${SYSTEMD}" -eq 1 ]; then
      svc_cmd="systemctl status ${SERVICE_NAME}"
      log_cmd="journalctl -u ${SERVICE_NAME} -f"
      stop_cmd="systemctl stop ${SERVICE_NAME}"
    else
      svc_cmd="ps -ef | grep autclaw"
      log_cmd="tail -f ${INSTALL_DIR}/autclaw.log"
      stop_cmd="kill \$(cat ${INSTALL_DIR}/autclaw.pid)"
    fi
  fi

  if [ "${INSTALL_FFMPEG}" = "1" ]; then
    if [ "${FFMPEG_OK}" = "1" ]; then
      if [ "${FFMPEG_AMR}" = "1" ]; then
        ffmpeg_label="已配置（AMR 语音可用）"
      else
        ffmpeg_label="已配置（AMR 语音转码不可用）"
      fi
    else
      ffmpeg_label="安装失败（转码不可用）"
    fi
  else
    ffmpeg_label="未安装（按选择跳过）"
  fi

  local title="安装完成"
  if [ "${status}" != "ok" ]; then
    title="安装结束（服务未就绪）"
  fi

  cat <<EOF

============================================================
 ${APP_NAME} ${title}
============================================================
 安装方式 : ${mode_label}
 release  : ${BUNDLE_VERSION:-未知}
 数据目录 : ${INSTALL_DIR}
 访问地址 : http://127.0.0.1:${HTTP_PORT}
            http://${safe_host}:${HTTP_PORT}
 ffmpeg   : ${ffmpeg_label}
 服务状态 : ${svc_cmd}
 查看日志 : ${log_cmd}
 停止服务 : ${stop_cmd}
 安装日志 : ${LOG_FILE:-未启用}
============================================================
 首次启动会在后台安装 Node / Python / Go 运行时，插件相关功能可能稍后才可用。
 如果外部无法访问，请放行 TCP ${HTTP_PORT}（防火墙 / 云安全组）。
EOF
}

# ---------------------------------------------------------------------------
# root 与主流程
# ---------------------------------------------------------------------------
script_regular_path() {
  local self="${BASH_SOURCE[0]:-}"
  if [ -n "${self}" ] && [ -f "${self}" ] && [ -r "${self}" ]; then
    ( cd "$(dirname "${self}")" && printf '%s/%s\n' "$(pwd)" "$(basename "${self}")" )
    return 0
  fi
  return 1
}

# 通过管道 / 进程替换运行时，脚本没有可复用的本地文件；
# 重新拉取一份到临时文件，供 sudo 后的新进程执行。
fetch_install_script() {
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/autclaw-install.XXXXXX.sh")" || return 1

  local -a urls=()
  local -a bases=()
  [ -n "${AUTCLAW_SCRIPT_URL:-}" ] && urls+=("${AUTCLAW_SCRIPT_URL}")
  urls+=("${SCRIPT_URL}")
  if [ -n "${GITHUB_PROXY}" ]; then
    bases+=("${GITHUB_PROXY%/}")
  fi
  bases+=("" "https://gh.jasonzeng.dev" "https://gh-proxy.com" "https://ghproxy.net" "https://ghfast.top")

  local url base target
  for url in "${urls[@]}"; do
    for base in "${bases[@]}"; do
      target="${url}"
      if [ -n "${base}" ]; then
        target="${base}/${url}"
      fi
      if curl -fsSL --connect-timeout 5 --max-time 30 "${target}" -o "${tmp}" 2>/dev/null \
        && [ -s "${tmp}" ] && grep -q '^# autclaw-install-script$' "${tmp}"; then
        printf '%s\n' "${tmp}"
        return 0
      fi
    done
  done

  rm -f "${tmp}"
  return 1
}

ensure_root() {
  if [ "$(id -u)" -eq 0 ]; then
    if [ -n "${AUTCLAW_SELF_TEMP:-}" ]; then
      rm -f -- "${AUTCLAW_SELF_TEMP}" 2>/dev/null || true
      unset AUTCLAW_SELF_TEMP
    fi
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    die "需要 root 权限，但未找到 sudo。请以 root 用户运行。"
  fi

  if [ -n "${AUTCLAW_INSTALL_DIR:-}" ]; then
    AUTCLAW_INSTALL_DIR="$(normalize_dir "${AUTCLAW_INSTALL_DIR}" || printf '%s' "${AUTCLAW_INSTALL_DIR}")"
  fi

  local self
  if ! self="$(script_regular_path)"; then
    if ! command -v curl >/dev/null 2>&1; then
      die "需要 root 权限，且未找到 curl，无法自动获取安装脚本。请以 root 用户运行。"
    fi
    log "脚本通过管道运行，正在获取安装脚本副本以便提升权限..."
    self="$(fetch_install_script)" || die "需要 root 权限，且自动获取安装脚本失败。请下载后重试：curl -fsSLO ${SCRIPT_URL} && bash install.sh"
    export AUTCLAW_SELF_TEMP="${self}"
  fi

  log "需要 root 权限，正在通过 sudo 继续..."

  local -a env_args=()
  local name
  for name in \
    AUTCLAW_INSTALL_MODE AUTCLAW_INSTALL_DIR AUTCLAW_INSTALL_FFMPEG AUTCLAW_HTTP_PORT \
    AUTCLAW_GITHUB_PROXY AUTCLAW_RELEASE_REPO AUTCLAW_RELEASE_BASE \
    AUTCLAW_MISE_VERSION AUTCLAW_MISE_COMMAND AUTCLAW_MISE_INSTALL_PATH AUTCLAW_MISE_RELEASE_BASE \
    AUTCLAW_IMAGE AUTCLAW_IMAGE_SLIM AUTCLAW_IMAGE_FULL AUTCLAW_SKIP_PULL \
    AUTCLAW_SYSTEMD_DIR AUTCLAW_FORCE_NO_SYSTEMD AUTCLAW_NONINTERACTIVE \
    AUTCLAW_CONTAINER_NAME AUTCLAW_SERVICE_NAME AUTCLAW_HEALTH_TIMEOUT \
    AUTCLAW_SCRIPT_URL AUTCLAW_SELF_TEMP \
    HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY http_proxy https_proxy no_proxy all_proxy \
    DOCKER_HOST DOCKER_CONFIG TMPDIR; do
    if [ -n "${!name+x}" ]; then
      env_args+=("${name}=${!name}")
    fi
  done

  if [ -n "${AUTCLAW_SELF_TEMP:-}" ]; then
    local rc=0
    sudo env ${env_args[@]+"${env_args[@]}"} bash "${self}" "$@" || rc=$?
    rm -f -- "${self}" 2>/dev/null || true
    exit "${rc}"
  fi

  exec sudo env ${env_args[@]+"${env_args[@]}"} bash "${self}" "$@"
}

main() {
  ensure_root "$@"
  setup_logging
  trap cleanup EXIT
  trap on_error ERR

  print_banner
  detect_platform
  detect_pkg_mgr || true

  # 安装方式
  case "${INSTALL_MODE}" in
    "")
      ;;
    1|direct|native)
      INSTALL_MODE="direct"
      ;;
    2|docker)
      INSTALL_MODE="docker"
      ;;
    *)
      die "AUTCLAW_INSTALL_MODE 只能是 direct 或 docker"
      ;;
  esac
  if [ -z "${INSTALL_MODE}" ]; then
    require_noninteractive "非交互模式需要设置 AUTCLAW_INSTALL_MODE=direct|docker"
    choose_menu "请选择安装方式" \
      "直装版（二进制 + systemd，自动安装 mise）" \
      "Docker（拉取官方镜像，数据目录挂载到宿主机）"
    if [ "${MENU_INDEX}" -eq 1 ]; then
      INSTALL_MODE="direct"
    else
      INSTALL_MODE="docker"
    fi
  fi

  # 目录
  if [ -z "${INSTALL_DIR}" ]; then
    require_noninteractive "非交互模式需要设置 AUTCLAW_INSTALL_DIR"
    local dir_title="请选择安装目录"
    if [ "${INSTALL_MODE}" = "docker" ]; then
      dir_title="请选择宿主机数据目录"
    fi
    choose_menu "${dir_title}" \
      "${DEFAULT_INSTALL_DIR}（推荐）" \
      "/usr/local/autclaw" \
      "自定义路径"
    case "${MENU_INDEX}" in
      1) INSTALL_DIR="${DEFAULT_INSTALL_DIR}" ;;
      2) INSTALL_DIR="/usr/local/autclaw" ;;
      3) read_dir_value ;;
    esac
  else
    INSTALL_DIR="$(normalize_dir "${INSTALL_DIR}")" || die "安装目录无效"
  fi
  validate_install_dir "${INSTALL_DIR}" || die "安装目录无效: ${INSTALL_DIR}"

  # ffmpeg
  case "${INSTALL_FFMPEG}" in
    "")
      ;;
    1|true|yes|on|y)
      INSTALL_FFMPEG="1"
      ;;
    0|false|no|off|n)
      INSTALL_FFMPEG="0"
      ;;
    *)
      die "AUTCLAW_INSTALL_FFMPEG 只能是 1 或 0"
      ;;
  esac
  if [ -z "${INSTALL_FFMPEG}" ]; then
    require_noninteractive "非交互模式需要设置 AUTCLAW_INSTALL_FFMPEG=1|0"
    choose_menu "是否安装 ffmpeg（语音 / 视频转码）" \
      "安装（推荐，Docker 使用 :full 镜像）" \
      "不安装（飞书 / 微信 / 千寻音视频转码不可用）"
    if [ "${MENU_INDEX}" -eq 1 ]; then
      INSTALL_FFMPEG="1"
    else
      INSTALL_FFMPEG="0"
    fi
  fi
  if [ "${INSTALL_FFMPEG}" = "0" ]; then
    log "不安装 ffmpeg：飞书 / 微信 / 千寻的音视频转码不可用，QQ / Telegram 不受影响"
  fi

  # 端口
  if [ -z "${HTTP_PORT}" ]; then
    require_noninteractive "非交互模式需要设置 AUTCLAW_HTTP_PORT"
    choose_menu "请选择访问端口" "${DEFAULT_HTTP_PORT}（默认）" "自定义端口"
    if [ "${MENU_INDEX}" -eq 2 ]; then
      read_port_value
    else
      HTTP_PORT="${DEFAULT_HTTP_PORT}"
    fi
  fi
  valid_port "${HTTP_PORT}" || die "端口无效: ${HTTP_PORT}"

  cat <<EOF

------------------------------------------------------------
 安装方式 : $([ "${INSTALL_MODE}" = "docker" ] && echo "Docker" || echo "直装版")
 目录     : ${INSTALL_DIR}
 端口     : ${HTTP_PORT}
 ffmpeg   : $([ "${INSTALL_FFMPEG}" = "1" ] && echo "安装" || echo "不安装")
 架构     : linux-${ARCH}
------------------------------------------------------------
EOF

  mkdir -p "${INSTALL_DIR}" || die "无法创建目录: ${INSTALL_DIR}"
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/autclaw-install.XXXXXX")"
  UNIT_PATH="${AUTCLAW_SYSTEMD_DIR:-/etc/systemd/system}/${SERVICE_NAME}.service"

  if [ "${INSTALL_MODE}" = "direct" ]; then
    detect_systemd
    run_direct_install
  else
    run_docker_install
  fi
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" || ( -z "${BASH_SOURCE[0]:-}" && "${0##*/}" == "bash" ) ]]; then
  main "$@"
fi

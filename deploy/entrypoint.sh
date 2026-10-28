#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="/opt/autclaw"
BINARY_PATH="${DATA_DIR}/autclaw"
DIST_DIR="${DATA_DIR}/dist"
PLUGIN_DIR="${DATA_DIR}/plugin"
RELEASE_TAG="${AUTCLAW_RELEASE_TAG:-latest}"
RELEASE_REPO="WGwuzhi/autClaw"

GITHUB_PROXY_BASE_URL="${DEPENDENCY_URL_REPLACEMENTS_GITHUB_DEFAULT:-}"

should_fetch_bundle() {
  [[ ! -f "${BINARY_PATH}" || ! -f "${DIST_DIR}/index.html" ]]
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "" ;;
  esac
}

resolve_target_base_url() {
  local release_base_url
  if [[ "${RELEASE_REPO}" =~ ^https?:// ]]; then
    release_base_url="${RELEASE_REPO%/}"
  else
    release_base_url="https://github.com/${RELEASE_REPO}/releases"
  fi

  if [[ "${RELEASE_TAG}" == "latest" ]]; then
    if [[ "${release_base_url}" == */releases/download ]]; then
      echo "${release_base_url%/releases/download}/releases/latest/download"
    elif [[ "${release_base_url}" == */releases/latest/download ]]; then
      echo "${release_base_url}"
    else
      echo "${release_base_url}/latest/download"
    fi
  else
    if [[ "${release_base_url}" == */releases/download ]]; then
      echo "${release_base_url}/${RELEASE_TAG}"
    elif [[ "${release_base_url}" == */releases/latest/download ]]; then
      echo "${release_base_url%/releases/latest/download}/releases/download/${RELEASE_TAG}"
    else
      echo "${release_base_url}/download/${RELEASE_TAG}"
    fi
  fi
}

select_github_download_source() {
  local source_url="$1"
  local benchmark_dir base_url benchmark_url elapsed best index=0 milliseconds
  local -a candidates=(
    "https://gh.jasonzeng.dev/"
    "https://gh-proxy.com/"
    "https://ghproxy.net/"
    "https://ghfast.top/"
    ""
  )

  if [[ -n "${GITHUB_PROXY_BASE_URL}" ]]; then
    candidates=("${GITHUB_PROXY_BASE_URL}" "${candidates[@]}")
  fi

  benchmark_dir="$(mktemp -d)"
  echo "[entrypoint] 正在测速 GitHub 下载源"
  for base_url in "${candidates[@]}"; do
    benchmark_url="${source_url}"
    if [[ -n "${base_url}" ]]; then
      benchmark_url="${base_url%/}/${source_url}"
    fi
    (
      if elapsed="$(curl -fsSL --connect-timeout 3 --max-time 8 \
        -o "${benchmark_dir}/${index}.body" -w '%{time_total}' "${benchmark_url}" 2>/dev/null)" \
        && grep -Eq '^[[:xdigit:]]{64}[[:space:]]+' "${benchmark_dir}/${index}.body"; then
        printf '%s|%s\n' "${elapsed}" "${base_url}"
      fi
    ) > "${benchmark_dir}/${index}.result" &
    index=$((index + 1))
  done

  wait || true
  best="$(sort -n "${benchmark_dir}"/*.result | head -n 1)"
  rm -rf "${benchmark_dir}"

  if [[ -z "${best}" ]]; then
    GITHUB_PROXY_BASE_URL=""
    echo "[entrypoint] 测速均失败，使用 GitHub 官方源兜底"
    return
  fi

  IFS='|' read -r elapsed GITHUB_PROXY_BASE_URL <<< "${best}"
  milliseconds="$(awk -v seconds="${elapsed}" 'BEGIN {printf "%.0f", seconds * 1000}')"
  echo "[entrypoint] 选择下载源: ${GITHUB_PROXY_BASE_URL:-GitHub 官方源} (${milliseconds} ms)"
}

download_file() {
  local source_url="$1"
  local target_file="$2"
  local label="$3"
  local proxy_url=""

  if [[ -n "${GITHUB_PROXY_BASE_URL}" && "${source_url}" =~ ^https:// ]]; then
    proxy_url="${GITHUB_PROXY_BASE_URL%/}/${source_url}"
    echo "[entrypoint] 通过代理下载 ${label}: ${proxy_url}"
    if curl -fSL "${proxy_url}" -o "${target_file}"; then
      return 0
    fi
    echo "[entrypoint] ${label} 代理下载失败，回退直连源"
  fi

  echo "[entrypoint] 通过直连源下载 ${label}: ${source_url}"
  curl -fSL "${source_url}" -o "${target_file}"
}

fetch_runtime_bundle() {
  local arch bundle_name target_base_url bundle_url sha_url
  local tmp_bundle tmp_sha verify_dir extract_dir bundle_root plugin_source_dir

  arch="$(detect_arch)"
  if [[ -z "${arch}" ]]; then
    echo "[entrypoint] 不支持的架构: $(uname -m)"
    exit 1
  fi

  bundle_name="${AUTCLAW_BUNDLE_NAME:-autclaw-bundle-linux-${arch}.tar.gz}"
  target_base_url="$(resolve_target_base_url)"
  bundle_url="${target_base_url}/${bundle_name}"
  sha_url="${target_base_url}/SHA256SUMS"

  echo "[entrypoint] 运行产物缺失，准备首次拉取 release bundle"
  echo "[entrypoint] release 仓库: ${RELEASE_REPO}"
  echo "[entrypoint] release 版本: ${RELEASE_TAG}"
  echo "[entrypoint] 目标架构: ${arch}"
  echo "[entrypoint] 目标包名: ${bundle_name}"

  select_github_download_source "${sha_url}"

  tmp_bundle="$(mktemp)"
  tmp_sha="$(mktemp)"
  verify_dir="$(mktemp -d)"
  extract_dir="$(mktemp -d)"

  download_file "${bundle_url}" "${tmp_bundle}" "release bundle"
  download_file "${sha_url}" "${tmp_sha}" "校验清单"

  cp "${tmp_bundle}" "${verify_dir}/${bundle_name}"
  cp "${tmp_sha}" "${verify_dir}/SHA256SUMS"

  (
    cd "${verify_dir}" \
      && awk -v name="${bundle_name}" 'NF >= 2 && $2 == name {found=1} END {exit(found ? 0 : 1)}' SHA256SUMS
  ) || {
    echo "[entrypoint] 校验清单不包含 ${bundle_name}"
    exit 1
  }

  (
    cd "${verify_dir}" \
      && sha256sum -c --ignore-missing SHA256SUMS --status
  ) || {
    echo "[entrypoint] 哈希校验失败"
    exit 1
  }

  tar -xzf "${tmp_bundle}" -C "${extract_dir}"
  if [[ -d "${extract_dir}/autclaw" ]]; then
    bundle_root="${extract_dir}/autclaw"
  else
    bundle_root="${extract_dir}"
  fi

  if [[ ! -f "${bundle_root}/autclaw" ]]; then
    echo "[entrypoint] release bundle 缺少 autclaw"
    exit 1
  fi
  if [[ ! -d "${bundle_root}/dist" ]]; then
    echo "[entrypoint] release bundle 缺少 dist"
    exit 1
  fi
  plugin_source_dir="${bundle_root}/plugin"
  if [[ ! -d "${plugin_source_dir}" ]]; then
    echo "[entrypoint] release bundle 缺少 plugin"
    exit 1
  fi

  install -m 0755 "${bundle_root}/autclaw" "${BINARY_PATH}"
  rm -rf "${DIST_DIR}"
  cp -a "${bundle_root}/dist" "${DIST_DIR}"
  mkdir -p "${PLUGIN_DIR}"
  cp -af "${plugin_source_dir}/." "${PLUGIN_DIR}/"

  rm -f "${tmp_bundle}" "${tmp_sha}"
  rm -rf "${verify_dir}" "${extract_dir}"
  echo "[entrypoint] 首次 release bundle 拉取完成"
}

mkdir -p "${DATA_DIR}" "$(dirname "${BINARY_PATH}")"

if should_fetch_bundle; then
  fetch_runtime_bundle
fi

if [[ $# -gt 0 ]]; then
  exec "$@"
fi

exec "${BINARY_PATH}"

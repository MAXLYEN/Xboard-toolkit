#!/usr/bin/env bash
# xboard-toolkit 共用函数库
# 被 xt 和各 cmd/*.sh source，不单独执行

# ---------- 全局 ----------
XT_REPO_OWNER="${XT_REPO_OWNER:-MAXLYEN}"
XT_REPO_NAME="${XT_REPO_NAME:-xboard-toolkit}"
XT_REF="${XT_REF:-main}"
XT_HOME="${XT_HOME:-/opt/xboard-toolkit}"
XT_CONF="${XT_CONF:-/etc/xboard-toolkit.conf}"
XT_LOGDIR="${XT_LOGDIR:-/var/log/xboard-toolkit}"
XT_DRY_RUN="${XT_DRY_RUN:-0}"

# ---------- 下载源 ----------
# 格式：名称|URL 模板，%REF% 和 %PATH% 会被替换
# 想加自己的镜像，在 /etc/xboard-toolkit.conf 里设 XT_SOURCES_EXTRA
XT_SOURCES_DEFAULT="
github|https://raw.githubusercontent.com/%OWNER%/%REPO%/%REF%/%PATH%
jsdelivr|https://cdn.jsdelivr.net/gh/%OWNER%/%REPO%@%REF%/%PATH%
"

# ---------- 颜色（非 tty 自动关闭） ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[36m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_RST=""
fi

_ts() { date -u '+%H:%M:%S'; }
log_info()  { printf '%s[=]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
log_ok()    { printf '%s[✓]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
log_warn()  { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
log_error() { printf '%s[✗]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
log_step()  { printf '\n%s▶ %s%s\n' "$C_BLU" "$*" "$C_RST"; }
log_dim()   { printf '%s    %s%s\n' "$C_DIM" "$*" "$C_RST"; }

die() { log_error "$*"; exit 1; }

# ---------- 通用工具 ----------
have() { command -v "$1" >/dev/null 2>&1; }

need_root() {
    [ "$(id -u)" -eq 0 ] || die "需要 root 权限（当前用户 $(id -un)）"
}

# dry-run 包装：run <命令...>
run() {
    if [ "$XT_DRY_RUN" = "1" ]; then
        log_dim "[dry-run] $*"
        return 0
    fi
    "$@"
}

# 包安装，自动适配 apt/dnf/yum
pkg_install() {
    local pkgs=("$@")
    [ ${#pkgs[@]} -eq 0 ] && return 0
    if [ "$XT_DRY_RUN" = "1" ]; then
        log_dim "[dry-run] 安装: ${pkgs[*]}"
        return 0
    fi
    export DEBIAN_FRONTEND=noninteractive
    if have apt-get; then
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq "${pkgs[@]}" >/dev/null 2>&1
    elif have dnf; then
        dnf install -y -q "${pkgs[@]}" >/dev/null 2>&1
    elif have yum; then
        yum install -y -q "${pkgs[@]}" >/dev/null 2>&1
    else
        log_warn "未识别的包管理器，请手动安装: ${pkgs[*]}"
        return 1
    fi
}

# 确保若干命令存在，缺失则安装（命令名==包名时可省略第二参）
ensure_cmd() {
    local cmd="$1" pkg="${2:-$1}"
    have "$cmd" && return 0
    log_info "缺少 $cmd，安装 $pkg"
    pkg_install "$pkg" || return 1
    have "$cmd"
}

# ---------- 幂等写入 ----------
# write_idempotent <目标路径> <内容> [权限]
#   不存在        → 新建
#   存在且内容相同 → 跳过
#   存在且内容不同 → 备份旧版后替换
write_idempotent() {
    local target="$1" content="$2" mode="${3:-0644}"
    local tmp; tmp=$(mktemp)
    printf '%s\n' "$content" > "$tmp"

    if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
        log_dim "未变更: $target"
        rm -f "$tmp"; return 0
    fi

    if [ "$XT_DRY_RUN" = "1" ]; then
        log_dim "[dry-run] 将写入 $target"
        [ -f "$target" ] && diff -u "$target" "$tmp" | head -20 || true
        rm -f "$tmp"; return 0
    fi

    mkdir -p "$(dirname "$target")"
    if [ -f "$target" ]; then
        local bak="${target}.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$target" "$bak"
        log_info "已备份旧版: $bak"
    fi
    mv "$tmp" "$target"
    chmod "$mode" "$target"
    log_ok "已写入: $target"
}

# 确保某行存在于文件中（不存在则追加）
ensure_line() {
    local file="$1" line="$2"
    [ -f "$file" ] || { run touch "$file"; }
    grep -qxF "$line" "$file" 2>/dev/null && return 0
    if [ "$XT_DRY_RUN" = "1" ]; then
        log_dim "[dry-run] 追加到 $file: $line"
        return 0
    fi
    printf '%s\n' "$line" >> "$file"
}

# ---------- 多源下载 ----------
# 返回可用的源模板；XT_SOURCE 可强制指定单一源
_xt_sources() {
    if [ -n "${XT_SOURCE:-}" ]; then
        printf 'manual|%s\n' "$XT_SOURCE"
        return
    fi
    printf '%s\n' "$XT_SOURCES_DEFAULT" | sed '/^\s*$/d'
    [ -n "${XT_SOURCES_EXTRA:-}" ] && printf '%s\n' "$XT_SOURCES_EXTRA" | sed '/^\s*$/d'
    return 0
}

_xt_expand() {
    local tpl="$1" path="$2"
    tpl="${tpl//%OWNER%/$XT_REPO_OWNER}"
    tpl="${tpl//%REPO%/$XT_REPO_NAME}"
    tpl="${tpl//%REF%/$XT_REF}"
    tpl="${tpl//%PATH%/$path}"
    printf '%s' "$tpl"
}

# xt_fetch <仓库内相对路径> <输出文件>
# 依次尝试各源，先落盘再校验，绝不边下边执行
xt_fetch() {
    local path="$1" out="$2" name tpl url tmp
    tmp=$(mktemp)
    while IFS='|' read -r name tpl; do
        [ -z "$name" ] && continue
        url=$(_xt_expand "$tpl" "$path")
        if curl -fsSL --connect-timeout 8 --max-time 60 -o "$tmp" "$url" 2>/dev/null; then
            if [ -s "$tmp" ]; then
                # 关键：语法校验能可靠地识别下载截断
                if [[ "$path" == *.sh || "$path" == cmd/* || "$path" == xt ]]; then
                    if ! bash -n "$tmp" 2>/dev/null; then
                        log_warn "[$name] 下载内容语法异常（可能被截断），换源重试"
                        continue
                    fi
                fi
                mv "$tmp" "$out"
                log_dim "$path ← $name"
                return 0
            fi
        fi
        log_dim "$name 源不可用，尝试下一个"
    done < <(_xt_sources)
    rm -f "$tmp"
    log_error "所有下载源均失败: $path"
    return 1
}

# ---------- 日志落盘 ----------
xt_start_log() {
    local tag="$1"
    [ "$XT_DRY_RUN" = "1" ] && return 0
    mkdir -p "$XT_LOGDIR"
    XT_LOGFILE="$XT_LOGDIR/${tag}-$(date -u +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$XT_LOGFILE") 2>&1
    log_dim "日志: $XT_LOGFILE"
}

# ---------- 配置文件 ----------
xt_load_conf() {
    # shellcheck disable=SC1090
    [ -f "$XT_CONF" ] && . "$XT_CONF"
    return 0
}

xt_save_conf_kv() {
    local key="$1" val="$2"
    touch "$XT_CONF"; chmod 600 "$XT_CONF"
    if grep -q "^${key}=" "$XT_CONF" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$XT_CONF"
    else
        printf '%s="%s"\n' "$key" "$val" >> "$XT_CONF"
    fi
}

# ---------- 错误定位 ----------
xt_enable_traps() {
    set -Eeuo pipefail
    trap 'log_error "失败于 ${BASH_SOURCE[0]}:${LINENO} → ${BASH_COMMAND}"' ERR
}

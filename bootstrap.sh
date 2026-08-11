#!/usr/bin/env bash
# xboard-toolkit 引导安装
#
# 用法（先落盘再执行，不要用 curl | bash —— 下载中断会执行半截脚本）：
#   curl -fsSL https://raw.githubusercontent.com/MAXLYEN/xboard-toolkit/main/bootstrap.sh -o /tmp/xt.sh
#   bash /tmp/xt.sh
#
# 可选环境变量：
#   XT_REF=v1                指定版本（分支或 tag），默认 main
#   XT_SOURCE='https://你的镜像/%OWNER%/%REPO%/%REF%/%PATH%'   强制指定源
#   XT_SOURCES_EXTRA='mine|https://你的镜像/%PATH%'            追加备用源

set -Eeuo pipefail

XT_REPO_OWNER="${XT_REPO_OWNER:-MAXLYEN}"
XT_REPO_NAME="${XT_REPO_NAME:-xboard-toolkit}"
XT_REF="${XT_REF:-main}"
XT_HOME="${XT_HOME:-/opt/xboard-toolkit}"
BIN_LINK="/usr/local/bin/xt"
IS_UPDATE=0

for a in "$@"; do
    case "$a" in
        --update) IS_UPDATE=1 ;;
        --force)  FORCE=1 ;;
    esac
done

# 文件清单从仓库的 MANIFEST 拉取，不写死在这里。
# 写死的话，新增文件永远装不上——本地这份 bootstrap 是旧的，
# 它不知道仓库里多了什么（v1.1.0 的 clean.sh 就是这么丢的）。
MANIFEST=()
FORCE=0

C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_RED=$'\033[31m'
C_BLU=$'\033[36m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
[ -t 1 ] || { C_GRN=""; C_YEL=""; C_RED=""; C_BLU=""; C_DIM=""; C_RST=""; }

info() { printf '%s[=]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%s[✗]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
dim()  { printf '%s    %s%s\n' "$C_DIM" "$*" "$C_RST"; }
die()  { err "$*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "需要 root 权限"
command -v curl >/dev/null 2>&1 || die "需要 curl，请先安装"

# ---------- 下载源 ----------
SOURCES_DEFAULT="github|https://raw.githubusercontent.com/%OWNER%/%REPO%/%REF%/%PATH%
jsdelivr|https://cdn.jsdelivr.net/gh/%OWNER%/%REPO%@%REF%/%PATH%"

list_sources() {
    if [ -n "${XT_SOURCE:-}" ]; then
        printf 'manual|%s\n' "$XT_SOURCE"
        return
    fi
    printf '%s\n' "$SOURCES_DEFAULT"
    [ -n "${XT_SOURCES_EXTRA:-}" ] && printf '%s\n' "$XT_SOURCES_EXTRA"
    return 0
}

expand() {
    local t="$1" p="$2"
    t="${t//%OWNER%/$XT_REPO_OWNER}"; t="${t//%REPO%/$XT_REPO_NAME}"
    t="${t//%REF%/$XT_REF}";          t="${t//%PATH%/$p}"
    printf '%s' "$t"
}

# 探测哪个源可用，选定后整轮安装都用它，避免混用不同版本
PICKED_NAME=""; PICKED_TPL=""
probe_sources() {
    local name tpl url
    while IFS='|' read -r name tpl; do
        [ -z "$name" ] && continue
        url=$(expand "$tpl" "VERSION")
        if curl -fsSL --connect-timeout 6 --max-time 15 -o /dev/null "$url" 2>/dev/null; then
            PICKED_NAME="$name"; PICKED_TPL="$tpl"
            ok "下载源: $name"
            return 0
        fi
        dim "$name 不可用"
    done < <(list_sources)
    return 1
}

fetch_one() {
    local path="$1" out="$2" url tmp
    url=$(expand "$PICKED_TPL" "$path")
    tmp=$(mktemp)
    curl -fsSL --connect-timeout 8 --max-time 60 -o "$tmp" "$url" || { rm -f "$tmp"; return 1; }
    [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
    # 语法校验：能可靠识别下载截断，比只看退出码靠谱
    case "$path" in
        VERSION) : ;;
        *) bash -n "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; } ;;
    esac
    mv "$tmp" "$out"
}

# ---------- 主流程 ----------
if [ "$IS_UPDATE" = "1" ]; then
    info "更新 xboard-toolkit（ref=$XT_REF）"
else
    info "安装 xboard-toolkit（ref=$XT_REF）"
fi

probe_sources || die "所有下载源都不可用。可用 XT_SOURCE 手动指定，例如：
  XT_SOURCE='https://你的镜像/%OWNER%/%REPO%/%REF%/%PATH%' bash $0"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# 先取清单，再按清单下载
if fetch_one "MANIFEST" "$STAGE/MANIFEST"; then
    mapfile -t MANIFEST < <(grep -vE '^\s*(#|$)' "$STAGE/MANIFEST")
    dim "清单: ${#MANIFEST[@]} 个文件"
else
    warn "仓库里没有 MANIFEST，回退到内置清单"
    MANIFEST=(VERSION xt lib/common.sh cmd/prep.sh cmd/dest.sh cmd/node.sh cmd/doctor.sh cmd/batch.sh cmd/clean.sh)
fi

info "下载 ${#MANIFEST[@]} 个文件"
FAILED=0
for f in "${MANIFEST[@]}"; do
    mkdir -p "$STAGE/$(dirname "$f")"
    if fetch_one "$f" "$STAGE/$f"; then
        dim "$f"
    else
        err "下载失败: $f"; FAILED=1
    fi
done
[ "$FAILED" = "0" ] || die "有文件下载失败，已中止（未改动现有安装）"

# 全部下载成功才动现有目录，避免装到一半坏掉
if [ -d "$XT_HOME" ] && [ "$IS_UPDATE" = "1" ]; then
    OLD_VER=$(cat "$XT_HOME/VERSION" 2>/dev/null || echo "?")
    NEW_VER=$(cat "$STAGE/VERSION")

    # 不能只比版本号。忘记改 VERSION 是很容易犯的错，
    # 那样改过的文件永远推不下去，而且现象是"提示已最新"，极具误导性。
    # 文件都只有几十 KB，直接逐个比内容，谁变了更新谁。
    MISSING=0
    CHANGED=0
    for f in "${MANIFEST[@]}"; do
        if [ ! -e "$XT_HOME/$f" ]; then
            MISSING=$((MISSING+1)); dim "新增: $f"
        elif ! cmp -s "$STAGE/$f" "$XT_HOME/$f"; then
            CHANGED=$((CHANGED+1)); dim "已变更: $f"
        fi
    done

    if [ "$MISSING" -eq 0 ] && [ "$CHANGED" -eq 0 ] && [ "$FORCE" = "0" ]; then
        ok "已是最新（$OLD_VER），所有文件内容一致，无需更新"
        exit 0
    fi

    [ "$MISSING" -gt 0 ] && info "新增 $MISSING 个文件"
    [ "$CHANGED" -gt 0 ] && info "变更 $CHANGED 个文件"
    if [ "$OLD_VER" = "$NEW_VER" ] && [ "$CHANGED" -gt 0 ]; then
        warn "文件有变更但 VERSION 仍是 $NEW_VER —— 大概是忘了改版本号，本次仍会更新"
    fi
    BAK="${XT_HOME}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$XT_HOME" "$BAK"
    info "旧版本 $OLD_VER 已备份到 $BAK"

    # 只保留最近 KEEP 份，其余自动清理（工具箱才几十 KB，留太多没意义）
    KEEP="${XT_BACKUP_KEEP:-3}"
    mapfile -t OLD_BAKS < <(ls -1dt "${XT_HOME}".bak.* 2>/dev/null | tail -n +$((KEEP+1)))
    if [ "${#OLD_BAKS[@]}" -gt 0 ]; then
        for b in "${OLD_BAKS[@]}"; do rm -rf "$b"; done
        info "已清理 ${#OLD_BAKS[@]} 份过期备份（保留最近 $KEEP 份）"
    fi
fi

mkdir -p "$XT_HOME"
cp -a "$STAGE/." "$XT_HOME/"
chmod +x "$XT_HOME/xt" "$XT_HOME"/cmd/*.sh
cp -a "$0" "$XT_HOME/bootstrap.sh" 2>/dev/null || true
chmod +x "$XT_HOME/bootstrap.sh" 2>/dev/null || true

ln -sf "$XT_HOME/xt" "$BIN_LINK"

# 记录本次使用的源和版本，后续 xt update 沿用
CONF="/etc/xboard-toolkit.conf"
touch "$CONF"; chmod 600 "$CONF"
grep -q '^XT_REF=' "$CONF" 2>/dev/null \
    && sed -i "s|^XT_REF=.*|XT_REF=\"$XT_REF\"|" "$CONF" \
    || printf 'XT_REF="%s"\n' "$XT_REF" >> "$CONF"

ok "安装完成: $(cat "$XT_HOME/VERSION")"
echo
echo "  可用命令："
echo "    xt prep        系统准备"
echo "    xt dest        伪装域名检测"
echo "    xt node        安装节点端"
echo "    xt doctor      一键体检"
echo "    xt help        全部命令"
echo

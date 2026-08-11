#!/usr/bin/env bash
# xt node —— 安装 / 绑定 xboard-node（machine 模式）

# shellcheck disable=SC1091
. "${XT_HOME:-/opt/xboard-toolkit}/lib/common.sh"
xt_enable_traps
xt_load_conf
need_root

PANEL="${PANEL_URL:-}"
TOKEN=""
MACHINE_ID=""
SKIP_PREP_CHECK=0

while [ $# -gt 0 ]; do
    case "$1" in
        --panel)      PANEL="$2"; shift 2 ;;
        --token)      TOKEN="$2"; shift 2 ;;
        --machine-id) MACHINE_ID="$2"; shift 2 ;;
        --no-precheck) SKIP_PREP_CHECK=1; shift ;;
        -h|--help)
            cat <<EOF
用法: xt node --token <TOKEN> --machine-id <N> [--panel <URL>]

  --panel        面板地址。省略时读取 ${XT_CONF} 里的 PANEL_URL
  --token        服务器 Token，从面板「服务器详情」页获取
  --machine-id   面板里该服务器的 SID
  --no-precheck  跳过时间同步预检

首次使用可先固化面板地址，之后就不用每次传：
  echo 'PANEL_URL="https://panel.example.com"' >> ${XT_CONF}
EOF
            exit 0 ;;
        *) die "未知选项: $1" ;;
    esac
done

[ -n "$PANEL" ]      || die "缺少 --panel（或在 $XT_CONF 里设 PANEL_URL）"
[ -n "$TOKEN" ]      || die "缺少 --token"
[ -n "$MACHINE_ID" ] || die "缺少 --machine-id"

xt_start_log node

# ---------- 预检：时间同步 ----------
if [ "$SKIP_PREP_CHECK" = "0" ]; then
    log_step "预检"
    if have chronyc && chronyc tracking 2>/dev/null | grep -q "Leap status *: *Normal"; then
        log_ok "时间已同步"
    else
        log_error "时间未同步，Reality 握手会失败"
        log_dim "先跑 xt prep，或用 --no-precheck 强行继续"
        exit 1
    fi

    if curl -fsS -o /dev/null --connect-timeout 8 "$PANEL" 2>/dev/null; then
        log_ok "面板可达: $PANEL"
    else
        log_warn "面板不可达，安装仍会继续，但节点可能连不上"
    fi
fi

# ---------- 安装或追加绑定 ----------
log_step "xboard-node"

已绑定() {
    # xbctl list 列格式: ID / MODE / PANEL / TARGET / SERVICE / HEALTH
    # 同时比对面板地址和 machine_id，避免 machine-id=1 误匹配到其他数字字段
    xbctl list 2>/dev/null | awk -v p="$PANEL" -v t="machine_id=$MACHINE_ID" \
        '$3==p && $4==t {found=1} END{exit !found}'
}

if have xbctl; then
    log_info "xboard-node 已安装"
    if 已绑定; then
        log_ok "machine-id $MACHINE_ID 已绑定到 $PANEL，跳过"
    else
        log_info "追加绑定 machine-id $MACHINE_ID"
        run xbctl bind add-machine --panel "$PANEL" --token "$TOKEN" --machine-id "$MACHINE_ID"
    fi
    run xbctl service restart
else
    log_info "全新安装"
    INSTALLER=$(mktemp)
    # 先落盘再执行：管道执行时下载中断会跑半截脚本
    if ! curl -fsSL --connect-timeout 10 --max-time 120 \
            -o "$INSTALLER" \
            https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh; then
        die "下载 xboard-node 安装脚本失败"
    fi
    bash -n "$INSTALLER" 2>/dev/null || die "安装脚本语法异常，可能下载被截断"
    # 注意：纯净 Debian 没有 sudo，这里直接以 root 跑，不用官方示例里的 sudo
    run bash "$INSTALLER" --mode machine \
        --panel "$PANEL" --token "$TOKEN" --machine-id "$MACHINE_ID"
    rm -f "$INSTALLER"
fi

# ---------- 验证 ----------
log_step "验证"
[ "$XT_DRY_RUN" = "1" ] && { log_dim "[dry-run] 跳过验证"; exit 0; }

sleep 4
xbctl list 2>/dev/null | sed 's/^/    /' || true

HEALTH=$(curl -fsS --max-time 5 http://127.0.0.1:65530/healthz 2>/dev/null || echo "")
if grep -q '"ok"' <<<"$HEALTH"; then
    log_ok "健康检查通过"
else
    log_error "健康检查未通过: ${HEALTH:-无响应}"
    log_dim "journalctl -u xboard-node -n 40 --no-pager"
    exit 1
fi

if 已绑定; then
    log_ok "绑定确认: machine_id=$MACHINE_ID → $PANEL"
else
    log_error "绑定未生效，检查 token 和 machine-id 是否正确"
    exit 1
fi

# 记住面板地址，下次不用再传
xt_save_conf_kv PANEL_URL "$PANEL"

echo
log_ok "节点端就绪。接着去面板「新增节点到此服务器」建节点"
log_dim "建完看日志确认内核启动: journalctl -u xboard-node -f --no-pager"
log_dim "提示：节点没有用户时内核不会启动，这是正常行为"

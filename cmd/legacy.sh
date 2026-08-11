#!/usr/bin/env bash
# xt legacy —— 检测并清理遗留代理程序
#
# 只报不处理是不够的：XrayR 和 xboard-node 抢同一个端口时，
# 两边会反复互抢，日志里双方都写着 "started"，客户端却间歇性超时，
# 极难定位。发现冲突就该能一键处理掉。
#
# 但也不能一律删：端口不冲突的程序（比如 x-ui 跑在 50000-60000）
# 可能还在正常服役，误删会造成真实损失。所以默认只删「有冲突的」。

# shellcheck disable=SC1091
. "${XT_HOME:-/opt/xboard-toolkit}/lib/common.sh"
xt_load_conf
need_root

# 已知的遗留代理程序：服务名|配置与程序目录（空格分隔）
KNOWN_SERVICES="
XrayR|/etc/XrayR /usr/local/XrayR
xrayr|/etc/XrayR /usr/local/XrayR
x-ui|/etc/x-ui /usr/local/x-ui /usr/bin/x-ui
v2ray|/etc/v2ray /usr/local/etc/v2ray /usr/local/bin/v2ray
v2ray-core|/etc/v2ray /usr/local/etc/v2ray
xray|/etc/xray /usr/local/etc/xray
trojan|/etc/trojan /usr/local/etc/trojan
trojan-go|/etc/trojan-go /usr/local/etc/trojan-go
hysteria|/etc/hysteria /usr/local/etc/hysteria
hysteria-server|/etc/hysteria /usr/local/etc/hysteria
sing-box|/etc/sing-box /usr/local/etc/sing-box
"

REMOVE_TARGET=""
REMOVE_ALL=0
REMOVE_CONFLICTING=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --remove)             REMOVE_TARGET="$2"; shift 2 ;;
        --remove-all)         REMOVE_ALL=1; shift ;;
        --remove-conflicting) REMOVE_CONFLICTING=1; shift ;;
        -y|--yes)             ASSUME_YES=1; shift ;;
        -h|--help)
            cat <<EOF
用法: xt legacy [选项]

不带选项时只检测并列出，不做任何改动。

  --remove <服务名>      删除指定的一个
  --remove-conflicting   只删除与 xboard-node 端口冲突的（推荐）
  --remove-all           删除检测到的全部（谨慎）
  -y, --yes              跳过确认
  --dry-run              只显示将要做什么（全局选项）

删除动作包含：停止服务 → 禁用开机自启 → 备份配置目录 →
删除程序与配置 → daemon-reload → 重启 xboard-node → 验证内核启动

配置目录会先备份到 /root/legacy-backup-<时间戳>/，不会直接销毁。
EOF
            exit 0 ;;
        *) die "未知选项: $1" ;;
    esac
done

# ---------- 探测 ----------
log_step "检测遗留代理程序"

# xboard-node 当前对外监听的端口（排除回环上的健康检查口）
XB_PORTS=$(ss -tulnp 2>/dev/null \
    | awk '/xboard-node/ && $5 !~ /^(127\.0\.0\.1|\[::1\]):/ { n=split($5,a,":"); print a[n] }' \
    | sort -un | tr '\n' ' ')
# 面板下发但尚未成功监听的端口（内核启动失败时能捞到）
FAILED_PORTS=$(journalctl -u xboard-node --since "6 hours ago" --no-pager 2>/dev/null \
    | grep -oE "listen tcp [0-9.]*:[0-9]+: bind: address already in use" \
    | grep -oE ':[0-9]+:' | tr -d ':' | sort -un | tr '\n' ' ')

[ -n "${XB_PORTS// /}" ]     && log_dim "xboard-node 已监听: $XB_PORTS"
[ -n "${FAILED_PORTS// /}" ] && log_warn "xboard-node 曾因端口被占启动失败: $FAILED_PORTS"

FOUND=()
CONFLICTING=()

while IFS='|' read -r svc paths; do
    [ -z "$svc" ] && continue
    systemctl is-active --quiet "$svc" 2>/dev/null || continue

    pid=$(systemctl show -p MainPID --value "$svc" 2>/dev/null || echo 0)
    ports=$(ss -tulnp 2>/dev/null | grep -F "pid=$pid," \
            | awk '{ n=split($5,a,":"); print a[n] }' | sort -un | tr '\n' ' ')

    conflict=""
    for p in $ports; do
        grep -qw "$p" <<<"$FAILED_PORTS" && conflict="$p"
    done
    # 端口相同也算冲突（当前是它抢到了）
    for p in $ports; do
        grep -qw "$p" <<<"$XB_PORTS" && conflict="$p"
    done

    FOUND+=("$svc")
    if [ -n "$conflict" ]; then
        CONFLICTING+=("$svc")
        printf '  %s✗%s %-16s 端口: %-24s %s与 xboard-node 冲突 (%s)%s\n' \
            "$C_RED" "$C_RST" "$svc" "${ports:-未监听}" "$C_RED" "$conflict" "$C_RST"
    else
        printf '  %s!%s %-16s 端口: %-24s %s无冲突%s\n' \
            "$C_YEL" "$C_RST" "$svc" "${ports:-未监听}" "$C_DIM" "$C_RST"
    fi
done <<< "$KNOWN_SERVICES"

if [ "${#FOUND[@]}" -eq 0 ]; then
    log_ok "没有检测到遗留代理程序"
    exit 0
fi

echo
if [ "${#CONFLICTING[@]}" -gt 0 ]; then
    log_error "${#CONFLICTING[@]} 个程序与 xboard-node 抢端口"
    log_dim "这类冲突是竞态：谁先抢到端口谁监听，双方日志都写 started，"
    log_dim "客户端却间歇性超时。必须处理掉。"
    echo
    echo "    xt legacy --remove-conflicting"
else
    log_info "检测到 ${#FOUND[@]} 个遗留程序，但都不与 xboard-node 冲突"
    log_dim "不冲突不代表安全：这些面板会自己管理入站端口，"
    log_dim "哪天在里面加个入站就可能撞上。确认不用了就删掉。"
    echo
    echo "    xt legacy --remove <服务名>"
fi
echo

# ---------- 决定要删哪些 ----------
TO_REMOVE=()
if [ -n "$REMOVE_TARGET" ]; then
    printf '%s\n' "${FOUND[@]}" | grep -qx "$REMOVE_TARGET" \
        || die "未检测到正在运行的服务: $REMOVE_TARGET"
    TO_REMOVE=("$REMOVE_TARGET")
elif [ "$REMOVE_CONFLICTING" = "1" ]; then
    [ "${#CONFLICTING[@]}" -gt 0 ] || { log_ok "没有冲突项，无事可做"; exit 0; }
    TO_REMOVE=("${CONFLICTING[@]}")
elif [ "$REMOVE_ALL" = "1" ]; then
    TO_REMOVE=("${FOUND[@]}")
else
    exit 0
fi

log_step "将要删除"
for s in "${TO_REMOVE[@]}"; do printf '    · %s\n' "$s"; done

if [ "$XT_DRY_RUN" = "1" ]; then
    echo; log_info "[dry-run] 到此为止"; exit 0
fi

if [ "$ASSUME_YES" = "0" ]; then
    echo
    printf '确认删除？输入 %syes%s 继续: ' "$C_YEL" "$C_RST"
    read -r ANS
    [ "$ANS" = "yes" ] || { log_info "已取消"; exit 0; }
fi

# ---------- 执行 ----------
BACKUP="/root/legacy-backup-$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP"

for svc in "${TO_REMOVE[@]}"; do
    log_step "清理 $svc"
    paths=$(grep "^${svc}|" <<<"$KNOWN_SERVICES" | head -1 | cut -d'|' -f2)

    systemctl stop "$svc" 2>/dev/null && log_ok "已停止" || log_warn "停止失败（可能已停）"
    systemctl disable "$svc" 2>/dev/null >/dev/null && log_ok "已禁用开机自启" || true

    for pth in $paths; do
        if [ -e "$pth" ]; then
            cp -a "$pth" "$BACKUP/" 2>/dev/null && log_dim "已备份 $pth"
            rm -rf "$pth" && log_ok "已删除 $pth"
        fi
    done

    for unit in "/etc/systemd/system/${svc}.service" "/lib/systemd/system/${svc}.service"; do
        [ -f "$unit" ] && { cp -a "$unit" "$BACKUP/" 2>/dev/null; rm -f "$unit"; log_ok "已删除 $unit"; }
    done
done

systemctl daemon-reload
log_info "配置已备份到 $BACKUP"

# ---------- 重启并验证 ----------
log_step "重启 xboard-node 并验证"
systemctl restart xboard-node
sleep 6

FAIL=0
for svc in "${TO_REMOVE[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        printf '  %s✗%s %-24s 仍在运行\n' "$C_RED" "$C_RST" "$svc"; FAIL=$((FAIL+1))
    else
        printf '  %s✓%s %-24s 已停止并移除\n' "$C_GRN" "$C_RST" "$svc"
    fi
done

NEWERR=$(journalctl -u xboard-node --since "1 min ago" --no-pager 2>/dev/null \
         | grep -E "failed to start kernel|address already in use" | tail -3)
if [ -n "$NEWERR" ]; then
    printf '  %s✗%s %-24s 内核仍启动失败\n' "$C_RED" "$C_RST" "xboard-node"
    sed 's/^/      /' <<<"$NEWERR"
    FAIL=$((FAIL+1))
else
    printf '  %s✓%s %-24s 内核启动正常\n' "$C_GRN" "$C_RST" "xboard-node"
fi

NOW_PORTS=$(ss -tulnp 2>/dev/null \
    | awk '/xboard-node/ && $5 !~ /^(127\.0\.0\.1|\[::1\]):/ { n=split($5,a,":"); print a[n] }' \
    | sort -un | tr '\n' ' ')
printf '  %s=%s %-24s %s\n' "$C_BLU" "$C_RST" "当前对外监听" "${NOW_PORTS:-无}"

echo
if [ "$FAIL" -eq 0 ]; then
    log_ok "清理完成，xboard-node 工作正常"
    log_dim "确认无误后可删除备份: rm -rf $BACKUP"
    exit 0
else
    log_error "有 $FAIL 项未通过，需手动检查"
    exit 1
fi

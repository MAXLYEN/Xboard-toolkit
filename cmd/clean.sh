#!/usr/bin/env bash
# xt clean —— 清理工具箱自身留下的一切，并在清理后自检
#
# 默认只删工具箱自己的文件，不动系统设置（IPv6 / BBR / limits / chrony），
# 因为那些改动可能已经被别的东西依赖，静默回退比留着更危险。
# 想连系统改动一起回退，加 --revert-system。
#
# 全程不碰 xboard-node —— 那是独立组件，删了你的节点就没了。

# shellcheck disable=SC1091
. "${XT_HOME:-/opt/xboard-toolkit}/lib/common.sh"
xt_load_conf
need_root

REVERT_SYSTEM=0
ASSUME_YES=0
KEEP_LOGS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --revert-system) REVERT_SYSTEM=1; shift ;;
        --keep-logs)     KEEP_LOGS=1; shift ;;
        -y|--yes)        ASSUME_YES=1; shift ;;
        -h|--help)
            cat <<EOF
用法: xt clean [选项]

  --revert-system   同时回退系统改动（IPv6 关闭 / BBR / limits.conf /
                    chrony 的 -4 / xboard-node 的 NOFILE drop-in）
  --keep-logs       保留 ${XT_LOGDIR}
  -y, --yes         跳过确认
  --dry-run         只列出将要删除的内容（全局选项）

不会动的东西:
  · xboard-node 服务与配置（独立组件，删了节点就没了）
  · ufw 规则
  · 已部署的节点数据
EOF
            exit 0 ;;
        *) die "未知选项: $1" ;;
    esac
done

XT_BIN="/usr/local/bin/xt"
DROPIN="/etc/systemd/system/xboard-node.service.d/override.conf"

# ---------- 1. 盘点 ----------
log_step "盘点将要清理的内容"

TARGETS=()
add_target() { [ -e "$1" ] && TARGETS+=("$1"); }

add_target "$XT_HOME"
add_target "$XT_BIN"
add_target "$XT_CONF"
[ "$KEEP_LOGS" = "0" ] && add_target "$XT_LOGDIR"
while IFS= read -r b; do [ -n "$b" ] && TARGETS+=("$b"); done \
    < <(ls -1d "${XT_HOME}".bak.* 2>/dev/null || true)

if [ "${#TARGETS[@]}" -eq 0 ]; then
    log_warn "没有找到任何工具箱文件，可能已经清理过了"
else
    for t in "${TARGETS[@]}"; do
        printf '    %s  %s\n' "$(du -sh "$t" 2>/dev/null | cut -f1 || echo '?')" "$t"
    done
fi

SYS_ITEMS=()
if [ "$REVERT_SYSTEM" = "1" ]; then
    grep -q "disable_ipv6" /etc/sysctl.conf 2>/dev/null && SYS_ITEMS+=("sysctl: IPv6 禁用项")
    grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null && SYS_ITEMS+=("sysctl: BBR 设置")
    grep -q "xboard-toolkit" /etc/security/limits.conf 2>/dev/null && SYS_ITEMS+=("limits.conf: nofile 段")
    grep -q '^DAEMON_OPTS=.*-4' /etc/default/chrony 2>/dev/null && SYS_ITEMS+=("chrony: -4 参数")
    [ -f "$DROPIN" ] && SYS_ITEMS+=("systemd drop-in: $DROPIN")

    if [ "${#SYS_ITEMS[@]}" -gt 0 ]; then
        echo
        log_warn "同时回退以下系统改动："
        for s in "${SYS_ITEMS[@]}"; do printf '    · %s\n' "$s"; done
        echo
        log_warn "回退 BBR 和 IPv6 可能影响这台机器上的其他服务，确认没有依赖再继续"
    fi
fi

echo
log_info "不会动: xboard-node 服务 / ufw 规则 / 节点数据"

[ "${#TARGETS[@]}" -eq 0 ] && [ "${#SYS_ITEMS[@]}" -eq 0 ] && { echo; log_ok "无事可做"; exit 0; }

# ---------- 2. 确认 ----------
if [ "$XT_DRY_RUN" = "1" ]; then
    echo
    log_info "[dry-run] 到此为止，未实际删除任何内容"
    exit 0
fi

if [ "$ASSUME_YES" = "0" ]; then
    echo
    printf '确认清理？输入 %syes%s 继续: ' "$C_YEL" "$C_RST"
    read -r ANS
    [ "$ANS" = "yes" ] || { log_info "已取消"; exit 0; }
fi

# ---------- 3. 回退系统改动 ----------
if [ "$REVERT_SYSTEM" = "1" ]; then
    log_step "回退系统改动"

    if grep -q "disable_ipv6" /etc/sysctl.conf 2>/dev/null; then
        cp -a /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%Y%m%d%H%M%S)"
        sed -i '/net\.ipv6\.conf\.\(all\|default\)\.disable_ipv6=1/d' /etc/sysctl.conf
        log_ok "已移除 IPv6 禁用项（重启后生效，或 sysctl -w 手动开启）"
    fi

    if grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
        sed -i '/net\.core\.default_qdisc=fq/d;/net\.ipv4\.tcp_congestion_control=bbr/d' /etc/sysctl.conf
        log_ok "已移除 BBR 设置（当前生效值需重启或手动改回）"
    fi

    if grep -q "xboard-toolkit" /etc/security/limits.conf 2>/dev/null; then
        cp -a /etc/security/limits.conf "/etc/security/limits.conf.bak.$(date +%Y%m%d%H%M%S)"
        sed -i '/# xboard-toolkit/,+2d' /etc/security/limits.conf
        log_ok "已移除 limits.conf 中的 nofile 段"
    fi

    if grep -q '^DAEMON_OPTS=.*-4' /etc/default/chrony 2>/dev/null; then
        sed -i 's/^DAEMON_OPTS="-4 \(.*\)"/DAEMON_OPTS="\1"/' /etc/default/chrony
        systemctl restart chrony >/dev/null 2>&1 || true
        log_ok "已移除 chrony 的 -4 参数"
    fi

    if [ -f "$DROPIN" ]; then
        rm -f "$DROPIN"
        rmdir "$(dirname "$DROPIN")" 2>/dev/null || true
        systemctl daemon-reload
        log_ok "已移除 xboard-node 的 NOFILE drop-in（未重启服务）"
    fi

    sysctl -p >/dev/null 2>&1 || true
fi

# ---------- 4. 删文件 ----------
log_step "删除工具箱文件"
for t in "${TARGETS[@]}"; do
    rm -rf "$t" && log_ok "已删除 $t"
done

# ---------- 5. 自检 ----------
log_step "清理后自检"

FAIL=0
chk() {
    local desc="$1" path="$2"
    if [ -e "$path" ]; then
        printf '  %s✗%s %-34s %s\n' "$C_RED" "$C_RST" "$desc" "仍存在: $path"
        FAIL=$((FAIL+1))
    else
        printf '  %s✓%s %-34s %s\n' "$C_GRN" "$C_RST" "$desc" "已清除"
    fi
}

chk "安装目录"       "$XT_HOME"
chk "可执行软链"     "$XT_BIN"
chk "配置文件"       "$XT_CONF"
[ "$KEEP_LOGS" = "0" ] && chk "日志目录" "$XT_LOGDIR"

REMAIN=$(ls -1d "${XT_HOME}".bak.* 2>/dev/null | wc -l)
if [ "$REMAIN" -eq 0 ]; then
    printf '  %s✓%s %-34s %s\n' "$C_GRN" "$C_RST" "备份目录" "已清除"
else
    printf '  %s✗%s %-34s %s\n' "$C_RED" "$C_RST" "备份目录" "仍有 $REMAIN 份"
    FAIL=$((FAIL+1))
fi

if command -v xt >/dev/null 2>&1; then
    printf '  %s✗%s %-34s %s\n' "$C_RED" "$C_RST" "xt 命令" "PATH 里仍能找到: $(command -v xt)"
    FAIL=$((FAIL+1))
else
    printf '  %s✓%s %-34s %s\n' "$C_GRN" "$C_RST" "xt 命令" "已不可用"
fi

if [ "$REVERT_SYSTEM" = "1" ]; then
    echo
    grep -q "disable_ipv6" /etc/sysctl.conf 2>/dev/null \
        && { printf '  %s✗%s %-34s\n' "$C_RED" "$C_RST" "sysctl IPv6 项"; FAIL=$((FAIL+1)); } \
        || printf '  %s✓%s %-34s %s\n' "$C_GRN" "$C_RST" "sysctl IPv6 项" "已移除"
    grep -q "xboard-toolkit" /etc/security/limits.conf 2>/dev/null \
        && { printf '  %s✗%s %-34s\n' "$C_RED" "$C_RST" "limits.conf 段"; FAIL=$((FAIL+1)); } \
        || printf '  %s✓%s %-34s %s\n' "$C_GRN" "$C_RST" "limits.conf 段" "已移除"
    chk "systemd drop-in" "$DROPIN"
fi

# 节点端应该完好无损
echo
if systemctl is-active --quiet xboard-node 2>/dev/null; then
    printf '  %s✓%s %-34s %s\n' "$C_GRN" "$C_RST" "xboard-node" "仍在运行（未受影响）"
elif systemctl list-unit-files 2>/dev/null | grep -q '^xboard-node.service'; then
    printf '  %s!%s %-34s %s\n' "$C_YEL" "$C_RST" "xboard-node" "已安装但未运行，检查是否与本次清理无关"
else
    printf '  %s=%s %-34s %s\n' "$C_BLU" "$C_RST" "xboard-node" "本机未安装"
fi

# ---------- 6. 结果 ----------
echo
if [ "$FAIL" -eq 0 ]; then
    log_ok "清理完成，自检全部通过"
    echo
    echo "  想重新安装："
    echo "    curl -fsSL https://raw.githubusercontent.com/${XT_REPO_OWNER}/${XT_REPO_NAME}/main/bootstrap.sh -o /tmp/xt.sh"
    echo "    bash /tmp/xt.sh"
    echo
    exit 0
else
    log_error "自检发现 $FAIL 项未清理干净，需手动处理"
    exit 1
fi

#!/usr/bin/env bash
# xt doctor —— 一键体检
# 每一项都对应一个实际踩过的坑，见教程附录 A

# shellcheck disable=SC1091
. "${XT_HOME:-/opt/xboard-toolkit}/lib/common.sh"
xt_load_conf

PASS=0; WARN=0; FAIL=0

chk_ok()   { printf '  %s✓%s %-34s %s\n' "$C_GRN" "$C_RST" "$1" "${2:-}"; PASS=$((PASS+1)); }
chk_warn() { printf '  %s!%s %-34s %s\n' "$C_YEL" "$C_RST" "$1" "${2:-}"; WARN=$((WARN+1)); }
chk_fail() { printf '  %s✗%s %-34s %s\n' "$C_RED" "$C_RST" "$1" "${2:-}"; FAIL=$((FAIL+1)); }

echo
printf '%s══ xboard-toolkit 体检 ══%s  %s\n' "$C_BLU" "$C_RST" "$(hostname)"

# ---------- 时间 ----------
log_step "时间同步（Reality 强依赖，偏差 >1 分钟即无法握手）"
if have chronyc; then
    if chronyc tracking 2>/dev/null | grep -q "Leap status *: *Normal"; then
        REF=$(chronyc tracking 2>/dev/null | awk -F': *' '/Reference ID/{print $2}')
        chk_ok "NTP 已同步" "$REF"
    else
        chk_fail "NTP 未同步" "Reality 会握手失败 → xt prep"
    fi
else
    chk_fail "未安装 chrony" "→ xt prep"
fi
echo "    系统时区: $(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo '?')  UTC: $(date -u '+%F %T')"
log_dim "时区若为 UTC，crontab 里的时间也按 UTC 算，别按本地时间设"

# ---------- IPv6 ----------
log_step "IPv6"
if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
    chk_ok "有全局 IPv6 地址"
elif sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null | grep -q 1; then
    chk_ok "无 IPv6 出口，已在内核层关闭"
else
    chk_warn "无 IPv6 出口但未关闭" "AAAA 连接会白等 300~400ms → xt prep"
fi

# ---------- 网络 ----------
log_step "网络"
CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')
[ "$CC" = "bbr" ] && chk_ok "拥塞控制" "$CC" || chk_warn "拥塞控制" "$CC（建议 bbr）"

NOFILE=$(ulimit -n)
[ "$NOFILE" -ge 65535 ] 2>/dev/null && chk_ok "文件描述符上限" "$NOFILE" \
    || chk_warn "文件描述符上限" "$NOFILE（建议 65535）"

# ---------- 节点端 ----------
log_step "节点端"
if have xbctl; then
    if systemctl is-active --quiet xboard-node; then
        chk_ok "xboard-node 服务运行中"
    else
        chk_fail "xboard-node 未运行" "systemctl status xboard-node"
    fi

    H=$(curl -fsS --max-time 5 http://127.0.0.1:65530/healthz 2>/dev/null || echo "")
    grep -q '"ok"' <<<"$H" && chk_ok "健康检查" "ok" || chk_fail "健康检查" "${H:-无响应}"

    echo
    xbctl list 2>/dev/null | sed 's/^/    /' || true

    # 内核未启动时端口不监听，属正常
    LISTEN=$(ss -tulnp 2>/dev/null | grep -c 'xboard-node' || true)
    if [ "${LISTEN:-0}" -gt 0 ]; then
        chk_ok "有入站端口在监听" "$LISTEN 个"
    else
        chk_warn "没有入站端口在监听" "节点无用户时内核不启动，属正常"
    fi
else
    chk_warn "未安装 xboard-node" "面板机不装节点端是正常的"
fi

# ---------- 面板连通性 ----------
if [ -n "${PANEL_URL:-}" ]; then
    log_step "面板"
    CODE=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 8 "$PANEL_URL" 2>/dev/null || echo "000")
    case "$CODE" in
        200|302) chk_ok "面板可达" "$PANEL_URL ($CODE)" ;;
        000)     chk_fail "面板不可达" "$PANEL_URL" ;;
        502)     chk_fail "面板 502" "反代通了但后端没应答" ;;
        *)       chk_warn "面板返回 $CODE" "$PANEL_URL" ;;
    esac
fi

# ---------- 防火墙 ----------
log_step "防火墙"
if have ufw; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        chk_ok "ufw 已启用"
        ufw status 2>/dev/null | grep -E '^[0-9]+' | sed 's/^/    /' | head -12
    else
        chk_warn "ufw 已安装但未启用" "ufw enable（先确认放行了 22）"
    fi
else
    chk_warn "未安装 ufw" "确认云厂商安全组已配置"
fi

# 节点端在监听但防火墙没放行的端口
if have xbctl && have ufw; then
    while read -r p; do
        [ -z "$p" ] && continue
        if ! ufw status 2>/dev/null | grep -qE "^${p}(/tcp|/udp)?\s"; then
            chk_warn "端口 $p 未在 ufw 放行" "节点端正在监听它"
        fi
    done < <(ss -tulnp 2>/dev/null | grep 'xboard-node' | grep -oE ':[0-9]+ ' | tr -d ': ' | sort -u)
fi

# Docker 会把 FORWARD 默认策略改成 DROP，DNAT 中转会被静默丢包
if have docker && have iptables; then
    if iptables -L FORWARD -n 2>/dev/null | head -1 | grep -q "policy DROP"; then
        chk_warn "FORWARD 默认策略为 DROP" "若用 DNAT 端口转发中转，需显式放行"
    fi
fi

# ---------- 汇总 ----------
echo
printf '%s══ 汇总 ══%s  通过 %s%d%s  警告 %s%d%s  失败 %s%d%s\n' \
    "$C_BLU" "$C_RST" "$C_GRN" "$PASS" "$C_RST" "$C_YEL" "$WARN" "$C_RST" "$C_RED" "$FAIL" "$C_RST"
echo
[ "$FAIL" -gt 0 ] && exit 1
exit 0

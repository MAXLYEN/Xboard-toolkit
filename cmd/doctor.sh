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

# 当前 shell 的值只是参考。真正要紧的是守护进程实际生效的限制——
# systemd 服务不读 /etc/security/limits.conf，得看 /proc/<pid>/limits
SHELL_NOFILE=$(ulimit -n)
if systemctl list-unit-files 2>/dev/null | grep -q '^xboard-node.service'; then
    SVC_NOFILE=$(svc_nofile xboard-node)
    if [ "$SVC_NOFILE" = "-" ]; then
        chk_warn "节点端 NOFILE" "服务未运行，无法读取"
    elif [ "$SVC_NOFILE" -ge 65535 ] 2>/dev/null; then
        chk_ok "节点端 NOFILE" "$SVC_NOFILE"
    else
        chk_warn "节点端 NOFILE" "$SVC_NOFILE（建议 65535）→ xt prep"
    fi
    log_dim "登录会话 ulimit -n = $SHELL_NOFILE（与守护进程无关，仅供参考）"
else
    [ "$SHELL_NOFILE" -ge 65535 ] 2>/dev/null && chk_ok "文件描述符上限" "$SHELL_NOFILE" \
        || chk_warn "文件描述符上限" "$SHELL_NOFILE（建议 65535）"
fi

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

    # 只统计对外监听。65530 健康检查端口绑在回环，不算也不该放行。
    PUB_PORTS=$(ss -tulnp 2>/dev/null \
        | awk '/xboard-node/ && $5 !~ /^(127\.0\.0\.1|\[::1\]):/ { n=split($5,a,":"); print a[n] }' \
        | sort -un | tr '\n' ' ')
    HEALTH_PORT="${HEALTH_PORT:-65530}"
    NODE_PORTS=$(tr ' ' '\n' <<<"$PUB_PORTS" | grep -v "^${HEALTH_PORT}$" | tr '\n' ' ')
    if [ -n "${NODE_PORTS// /}" ]; then
        chk_ok "节点入站端口" "$NODE_PORTS"
    else
        chk_warn "没有节点入站端口在监听" "节点无用户时内核不启动；也可能是启动失败，见下"
    fi
    # 内核启动失败是最常见的"节点在线但连不上"根因，日志里翻出来
    KERR=$(journalctl -u xboard-node --since "1 hour ago" --no-pager 2>/dev/null \
           | grep -E "failed to start kernel|machine node exited with error" | tail -3)
    if [ -n "$KERR" ]; then
        chk_fail "内核启动失败" "最近 1 小时内有报错"
        sed 's/^/      /' <<<"$KERR"

        # 端口被占是其中最常见的一种，直接指出是谁占的
        BUSY=$(grep -oE "listen tcp [0-9.]*:[0-9]+: bind: address already in use" <<<"$KERR" \
               | grep -oE ':[0-9]+:' | tr -d ':' | head -1)
        if [ -n "$BUSY" ]; then
            OCC=$(ss -tulnp 2>/dev/null | awk -v p=":$BUSY" '$5 ~ p"$" {print}' | head -1)
            echo
            chk_fail "端口 $BUSY 被占用" "$(grep -oE 'users:\(\("[^"]+"' <<<"$OCC" | grep -oE '"[^"]+"' | tr -d '\"')"
            sed 's/^/      /' <<<"$OCC"
            log_dim "常见占用者: XrayR / x-ui / v2ray / 独立 sing-box —— 停掉它或给节点换端口"
        fi
    fi

    # 主动扫一遍常见的老代理程序，它们和 xboard-node 抢端口
    for svc in XrayR xrayr x-ui v2ray v2ray-core trojan hysteria; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            chk_warn "检测到 $svc 正在运行" "可能与 xboard-node 抢端口"
        fi
    done
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

# 节点端对外监听、但防火墙没放行的端口
# ufw 规则里既有单端口也有 10000:11000 这种范围，两种都要能匹配
ufw_allows_port() {
    local port="$1" spec lo hi
    while read -r spec _; do
        spec="${spec%%/*}"
        case "$spec" in
            *:*)
                lo="${spec%%:*}"; hi="${spec##*:}"
                [ "$port" -ge "$lo" ] 2>/dev/null && [ "$port" -le "$hi" ] 2>/dev/null && return 0
                ;;
            [0-9]*)
                [ "$spec" = "$port" ] && return 0
                ;;
        esac
    done < <(grep -E '^[0-9]' <<<"$UFW_STATUS")
    return 1
}

if have xbctl && have ufw; then
    UFW_STATUS=$(ufw status 2>/dev/null || true)
    # 健康端口不参与"应该放行"的判断——它本来就不该对外开
    HEALTH_PORT="${HEALTH_PORT:-65530}"
    for p in $PUB_PORTS; do
        [ -z "$p" ] && continue
        [ "$p" = "$HEALTH_PORT" ] && continue
        ufw_allows_port "$p" || chk_warn "端口 $p 未在 ufw 放行" "节点端对外监听它"
    done

    if grep -qw "$HEALTH_PORT" <<<"$PUB_PORTS" && ufw_allows_port "$HEALTH_PORT"; then
        chk_fail "健康端口 $HEALTH_PORT 已对公网放行" "立即收回: ufw delete allow $HEALTH_PORT"
    fi

    # 健康检查端口本应只绑回环。出现在对外列表里说明它绑到了 0.0.0.0，
    # 等于把内部接口摆在公网上，只靠防火墙兜底。
    if grep -qw "65530" <<<"$PUB_PORTS"; then
        chk_warn "健康端口 65530 绑在公网地址" "应只绑 127.0.0.1，确认 ufw 未放行它"
    fi
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

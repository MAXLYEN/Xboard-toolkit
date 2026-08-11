#!/usr/bin/env bash
# xt prep —— 节点机系统准备
# 顺序有讲究：先处理 IPv6，再配时间同步。反过来的话 chrony 会守着
# 一堆不可达的 IPv6 NTP 源不放，表现为 Leap status 永远 Not synchronised。

# shellcheck disable=SC1091
. "${XT_HOME:-/opt/xboard-toolkit}/lib/common.sh"
xt_enable_traps
xt_load_conf
need_root

SKIP_BBR=0; SKIP_IPV6=0; NTP_WAIT=60
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-bbr)  SKIP_BBR=1; shift ;;
        --skip-ipv6) SKIP_IPV6=1; shift ;;
        --ntp-wait)  NTP_WAIT="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
用法: xt prep [选项]
  --skip-bbr      不动拥塞控制
  --skip-ipv6     不关闭 IPv6（即使检测到无 IPv6 出口）
  --ntp-wait <秒> 等待 NTP 同步的上限，默认 60
EOF
            exit 0 ;;
        *) die "未知选项: $1" ;;
    esac
done

xt_start_log prep

# ---------- 1. 基础工具 ----------
log_step "基础工具"
for c in curl wget openssl; do ensure_cmd "$c" "$c" >/dev/null || log_warn "$c 安装失败"; done
have ca-certificates || pkg_install ca-certificates >/dev/null 2>&1 || true
log_ok "基础工具就绪"

# ---------- 2. IPv6 ----------
log_step "IPv6"
if [ "$SKIP_IPV6" = "1" ]; then
    log_info "按要求跳过"
elif ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
    log_ok "检测到全局 IPv6 地址，保持启用"
else
    log_warn "无 IPv6 出口"
    log_dim "DNS 仍会返回 AAAA，内核不关掉的话每次连接要等 300~400ms 失败再回退"
    ensure_line /etc/sysctl.conf "net.ipv6.conf.all.disable_ipv6=1"
    ensure_line /etc/sysctl.conf "net.ipv6.conf.default.disable_ipv6=1"
    run sysctl -p >/dev/null 2>&1 || true
    log_ok "已在内核层关闭 IPv6"
fi

# ---------- 3. 时间同步（Reality 强依赖） ----------
log_step "时间同步"
if ! have chronyd && ! have chronyc; then
    log_info "安装 chrony（Debian 上会替换 systemd-timesyncd，属正常）"
    pkg_install chrony
fi

# 关掉 IPv6 之后必须让 chrony 只走 IPv4，否则它会守着不可达的 v6 源
if [ -f /etc/default/chrony ]; then
    if ! grep -q '^DAEMON_OPTS=.*-4' /etc/default/chrony; then
        if grep -q '^DAEMON_OPTS=' /etc/default/chrony; then
            run sed -i 's/^DAEMON_OPTS="\(.*\)"/DAEMON_OPTS="-4 \1"/' /etc/default/chrony
        else
            ensure_line /etc/default/chrony 'DAEMON_OPTS="-4 -F 1"'
        fi
        log_info "chrony 已限定 IPv4"
    fi
fi

run systemctl enable --now chrony >/dev/null 2>&1 || run systemctl enable --now chronyd >/dev/null 2>&1 || true
run systemctl restart chrony >/dev/null 2>&1 || run systemctl restart chronyd >/dev/null 2>&1 || true

if [ "$XT_DRY_RUN" = "1" ]; then
    log_dim "[dry-run] 跳过 NTP 等待"
else
    log_info "等待同步（最多 ${NTP_WAIT} 秒）"
    synced=0
    for _ in $(seq $((NTP_WAIT/5))); do
        if chronyc tracking 2>/dev/null | grep -q "Leap status *: *Normal"; then
            synced=1; break
        fi
        sleep 5
    done
    if [ "$synced" = "1" ]; then
        log_ok "NTP 已同步"
        chronyc tracking 2>/dev/null | grep -E "Reference ID|System time|Leap status" | sed 's/^/    /'
    else
        log_error "NTP 未同步 —— Reality 握手会失败"
        log_dim "排查：chronyc sources -v ／ 确认 UDP 123 出站未被拦截"
        chronyc sources -v 2>/dev/null | head -12 | sed 's/^/    /' || true
    fi
fi

# ---------- 4. BBR ----------
log_step "拥塞控制"
if [ "$SKIP_BBR" = "1" ]; then
    log_info "按要求跳过"
elif sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    log_ok "BBR 已启用"
else
    ensure_line /etc/sysctl.conf "net.core.default_qdisc=fq"
    ensure_line /etc/sysctl.conf "net.ipv4.tcp_congestion_control=bbr"
    run sysctl -p >/dev/null 2>&1 || true
    log_ok "已启用 BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
fi

# ---------- 5. 文件描述符 ----------
log_step "文件描述符上限"

# 登录会话（PAM）
if grep -q "xboard-toolkit" /etc/security/limits.conf 2>/dev/null; then
    log_ok "limits.conf 已配置（登录会话）"
else
    ensure_line /etc/security/limits.conf "# xboard-toolkit"
    ensure_line /etc/security/limits.conf "* soft nofile 65535"
    ensure_line /etc/security/limits.conf "* hard nofile 65535"
    log_ok "limits.conf 已设为 65535（对登录会话生效）"
fi

# 守护进程：systemd 不读 limits.conf，必须单独下 drop-in
apply_nofile_dropin xboard-node 65535
log_dim "limits.conf 只管登录会话，systemd 服务要靠 drop-in —— 两处都要设"

echo
log_ok "系统准备完成。下一步：xt dest 选伪装域名，或 xt node 装节点端"

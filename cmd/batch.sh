#!/usr/bin/env bash
# xt batch —— 批量操作多台机器（在控制机上运行）
#
# 清单文件格式（默认 /root/deploy/nodes.txt）：
#   # 主机地址          machine_id  token                备注
#   node1.example.com   1           AbCdEf...            英国-1
#   node2.example.com   2           GhIjKl...            日本-1
#
# token 每台不同，从面板「服务器详情」页复制。
# 该文件含凭据，权限务必 600。

# shellcheck disable=SC1091
. "${XT_HOME:-/opt/xboard-toolkit}/lib/common.sh"
xt_load_conf

SUB="${1:-}"; [ $# -gt 0 ] && shift || true

LIST="${LIST:-/root/deploy/nodes.txt}"
CONCURRENCY="${CONCURRENCY:-4}"
PANEL="${PANEL_URL:-}"
LOGDIR="${XT_LOGDIR}/batch-$(date -u +%Y%m%d-%H%M%S)"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)

usage() {
    cat <<EOF
用法: xt batch <子命令> [选项]

子命令:
  bootstrap    在所有机器上安装 xboard-toolkit 自身
  prep         批量系统准备
  deploy       批量安装节点端（读取清单里的 token 和 machine_id）
  dest         批量检测伪装域名，汇总成一份对照表
  doctor       批量体检
  run "<命令>" 在所有机器上执行任意命令

选项:
  --list <文件>       机器清单，默认 $LIST
  --concurrency <N>   并发数，默认 $CONCURRENCY
  --panel <URL>       面板地址，默认取配置文件里的 PANEL_URL

注意: 需先配好控制机到各节点的 SSH 免密（ssh-copy-id root@主机）
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --list)        LIST="$2"; shift 2 ;;
        --concurrency) CONCURRENCY="$2"; shift 2 ;;
        --panel)       PANEL="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)             BATCH_ARG="$1"; shift ;;
    esac
done

[ -n "$SUB" ] || { usage; exit 1; }
[ -f "$LIST" ] || die "清单文件不存在: $LIST"
mkdir -p "$LOGDIR"

# 清单含 token，检查权限
PERM=$(stat -c '%a' "$LIST" 2>/dev/null || echo "?")
[ "$PERM" = "600" ] || log_warn "清单权限是 $PERM，里面有 token，建议 chmod 600 $LIST"

read_list() { grep -vE '^\s*(#|$)' "$LIST"; }
TOTAL=$(read_list | wc -l)
log_info "清单 $LIST，共 $TOTAL 台，并发 $CONCURRENCY"
log_dim "日志目录: $LOGDIR"

# ---------- 每台机器执行的动作 ----------
do_one() {
    local host="$1" mid="$2" token="$3" note="${4:-}"
    local log="$LOGDIR/${host}.log"
    local rc=0

    {
        echo "=== $(date -u '+%F %T') $host (machine_id=$mid ${note}) ==="
        case "$SUB" in
            bootstrap)
                ssh "${SSH_OPTS[@]}" "root@$host" \
                    "curl -fsSL --connect-timeout 10 -o /tmp/xt.sh \
                     'https://raw.githubusercontent.com/${XT_REPO_OWNER}/${XT_REPO_NAME}/${XT_REF}/bootstrap.sh' \
                     && bash -n /tmp/xt.sh && bash /tmp/xt.sh"
                ;;
            prep)
                ssh "${SSH_OPTS[@]}" "root@$host" "xt prep"
                ;;
            deploy)
                ssh "${SSH_OPTS[@]}" "root@$host" \
                    "xt node --panel '$PANEL' --token '$token' --machine-id '$mid'"
                ;;
            dest)
                ssh "${SSH_OPTS[@]}" "root@$host" "xt dest --samples 5"
                ;;
            doctor)
                ssh "${SSH_OPTS[@]}" "root@$host" "xt doctor"
                ;;
            run)
                ssh "${SSH_OPTS[@]}" "root@$host" "${BATCH_ARG}"
                ;;
            *)
                echo "未知子命令: $SUB"; exit 2
                ;;
        esac
    } > "$log" 2>&1 || rc=$?

    if [ $rc -eq 0 ]; then
        printf '  \033[32m✓\033[0m %-32s %s\n' "$host" "$note"
    else
        printf '  \033[31m✗\033[0m %-32s %s  (rc=%s, %s)\n' "$host" "$note" "$rc" "$log"
    fi
    return 0
}
export -f do_one
export SUB LOGDIR PANEL XT_REPO_OWNER XT_REPO_NAME XT_REF BATCH_ARG
export SSH_OPTS_STR="${SSH_OPTS[*]}"

[ "$SUB" = "deploy" ] && [ -z "$PANEL" ] && die "deploy 需要 --panel 或配置文件里的 PANEL_URL"

echo
read_list | xargs -P "$CONCURRENCY" -n 4 bash -c 'do_one "$0" "$1" "$2" "${3:-}"'

# ---------- 汇总 ----------
echo
OK=$(grep -lc . "$LOGDIR"/*.log 2>/dev/null | wc -l)
log_info "完成，日志在 $LOGDIR"

if [ "$SUB" = "dest" ]; then
    echo
    log_step "各机器推荐的 dest"
    for f in "$LOGDIR"/*.log; do
        h=$(basename "$f" .log)
        d=$(grep -A2 "dest / SNI" "$f" 2>/dev/null | grep -oE '→ +\S+' | awk '{print $2}' | head -1)
        printf '  %-32s %s\n' "$h" "${d:-（未取到，看日志）}"
    done
    echo
    log_dim "尽量给每台选不同的 dest，避免 N 台形成统一模式"
fi

if [ "$SUB" = "doctor" ]; then
    echo
    log_step "体检异常汇总"
    grep -l '✗' "$LOGDIR"/*.log 2>/dev/null | while read -r f; do
        echo "  $(basename "$f" .log):"
        grep '✗' "$f" | sed 's/^/      /'
    done || log_ok "全部通过"
fi

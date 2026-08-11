#!/usr/bin/env bash
# xt dest —— Reality 伪装域名（dest/SNI）检测与推荐
#
# 判定：TLS1.3 + h2 + X25519
#   强制 -groups X25519 之后握手成功，本身就证明服务端支持经典 X25519。
#   不解析密钥交换字段——字段名随 openssl 版本变化（1.1.1 是 Server Temp Key，
#   3.5+ 是 Negotiated TLS1.3 group，且默认协商后量子混合组 X25519MLKEM768）。
#
# 推荐：得分 = 基准延迟 + 抖动÷2 + 类型惩罚，分越低越好

# shellcheck disable=SC1091
. "${XT_HOME:-/opt/xboard-toolkit}/lib/common.sh"
xt_load_conf

SAMPLES=${SAMPLES:-5}
TMO=${TMO:-5}
LIST_FILE=""
JSON_OUT=0

while [ $# -gt 0 ]; do
    case "$1" in
        --samples) SAMPLES="$2"; shift 2 ;;
        --timeout) TMO="$2"; shift 2 ;;
        --list)    LIST_FILE="$2"; shift 2 ;;
        --json)    JSON_OUT=1; shift ;;
        -h|--help)
            cat <<EOF
用法: xt dest [选项]
  --samples <N>   每个域名采样次数，默认 5
  --timeout <秒>  单次握手超时，默认 5
  --list <文件>   自定义候选域名列表，每行一个（# 开头为注释）
  --json          额外输出 JSON，便于批量汇总
EOF
            exit 0 ;;
        *) die "未知选项: $1" ;;
    esac
done

ensure_cmd openssl openssl >/dev/null || die "需要 openssl"

DOMAINS=(
  www.microsoft.com c.s-microsoft.com go.microsoft.com azure.microsoft.com
  visualstudio.microsoft.com res-1.cdn.office.net
  ms-python.gallerycdn.vsassets.io ms-vscode.gallerycdn.vsassets.io
  www.bing.com r.bing.com th.bing.com
  ts1.tc.mm.bing.net ts2.tc.mm.bing.net ts3.tc.mm.bing.net ts4.tc.mm.bing.net
  www.xbox.com assets-xbxweb.xbox.com
  www.apple.com apps.apple.com ocsp2.apple.com is1-ssl.mzstatic.com
  www.icloud.com statici.icloud.com
  t0.m.awsstatic.com s0.awsstatic.com d1.awsstatic.com
  vs.aws.amazon.com d2c.aws.amazon.com
  www.intel.com intel.com downloadmirror.intel.com
  www.nvidia.com images.nvidia.com www.amd.com download.amd.com
  www.oracle.com www.sony.com electronics.sony.com
  www.tesla.com digitalassets.tesla.com
  ds-aksb-a.akamaihd.net s.go-mpulse.net assets.adobedtm.com
  tags.tiqcdn.com rum.hlx.page
)

# ---- 推荐算法的三档分类 ----
# 排除：遥测 / 标签管理 / 埋点端点。延迟往往很好，但它们不是"网站"，
#       流量模式（短连接、固定间隔、无后续请求）和浏览器访问差别明显
EXCLUDE="rum.hlx.page tags.tiqcdn.com s.go-mpulse.net assets.adobedtm.com ds-aksb-a.akamaihd.net"

# A 档：独立厂商主站。有真实网页、有持续浏览行为、不属于任何大 CDN 品牌
TIER_A="www.amd.com www.intel.com intel.com www.nvidia.com www.oracle.com www.sony.com electronics.sony.com www.tesla.com"

# B 档：巨头主站。同样是真站点，但用的人多、更容易被批量关联
TIER_B="www.apple.com apps.apple.com www.icloud.com www.microsoft.com www.bing.com www.xbox.com"

# 其余：CDN / 资源子域 / OCSP 端点，能用但优先级最低

penalty_of() {
    case " $EXCLUDE " in *" $1 "*) echo 9999; return ;; esac
    case " $TIER_A "   in *" $1 "*) echo 0;    return ;; esac
    case " $TIER_B "   in *" $1 "*) echo 15;   return ;; esac
    echo 40
}

tier_name() {
    case " $EXCLUDE " in *" $1 "*) echo "排除"; return ;; esac
    case " $TIER_A "   in *" $1 "*) echo "A";    return ;; esac
    case " $TIER_B "   in *" $1 "*) echo "B";    return ;; esac
    echo "C"
}

# 自定义列表覆盖内置候选
if [ -n "$LIST_FILE" ]; then
    [ -f "$LIST_FILE" ] || die "列表文件不存在: $LIST_FILE"
    mapfile -t DOMAINS < <(grep -vE '^\s*(#|$)' "$LIST_FILE")
    log_info "使用自定义列表: $LIST_FILE（${#DOMAINS[@]} 个域名）"
fi

RESULTS=$(mktemp)
echo "检测中（${#DOMAINS[@]} 个域名，每个采样 ${SAMPLES} 次）..."

for d in "${DOMAINS[@]}"; do
    # 两个关键点：
    # 1. 合并 stderr，握手信息分散在两个流里
    # 2. 强制 -groups X25519：OpenSSL 3.5+ 默认优先协商后量子混合组
    #    X25519MLKEM768。不强制的话，测到的是"客户端偏好"而非"服务端能力"。
    #    强制之后握手能成功，本身就证明服务端支持经典 X25519——
    #    不必再解析密钥交换字段（该字段名随 openssl 版本变化，不可靠）
    out=$(timeout "$TMO" openssl s_client -connect "$d:443" -servername "$d" \
            -tls1_3 -alpn h2 -groups X25519 </dev/null 2>&1)

    if ! grep -q "CONNECTED" <<<"$out"; then
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" 99999 99999 "$d" "FAIL" "-" "" 99999 >> "$RESULTS"
        continue
    fi

    if grep -qE 'New, TLSv1\.3|Protocol *: *TLSv1\.3' <<<"$out"; then
        tls="TLSv1.3"
    else
        tls=$(grep -oE 'New, TLSv[0-9.]+' <<<"$out" | head -1 | grep -oE 'TLSv[0-9.]+')
        [ -z "$tls" ] && tls="-"
    fi

    alpn=$(grep -oE 'ALPN protocol: *[a-z0-9/.]+' <<<"$out" | head -1 | awk '{print $3}')
    [ -z "$alpn" ] && alpn="-"

    # 采样：取最小值当基准延迟，最大最小之差当抖动
    best=99999; worst=0; succ=0
    for _ in $(seq "$SAMPLES"); do
        t1=$(date +%s%3N)
        timeout "$TMO" openssl s_client -connect "$d:443" -servername "$d" \
            -tls1_3 -groups X25519 </dev/null &>/dev/null || continue
        t2=$(date +%s%3N); dt=$((t2-t1)); succ=$((succ+1))
        [ "$dt" -lt "$best" ] && best=$dt
        [ "$dt" -gt "$worst" ] && worst=$dt
    done

    verdict=""
    [ "$tls" = "TLSv1.3" ] && [ "$alpn" = "h2" ] && [ "$succ" -eq "$SAMPLES" ] && verdict="OK"

    if [ "$succ" -eq 0 ]; then
        jitter=99999; score=99999
    else
        jitter=$((worst-best))
        # 打分：基准延迟 + 抖动的一半 + 域名类型惩罚。分越低越好。
        score=$(( best + jitter/2 + $(penalty_of "$d") ))
    fi

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$best" "$jitter" "$d" "$tls" "$alpn" "$verdict" "$score" >> "$RESULTS"
done

echo
echo "===== 合格候选（TLS1.3 + h2 + X25519，${SAMPLES}/${SAMPLES} 次全通） ====="
printf "%-42s %-8s %-6s %-8s %-6s %s\n" "DOMAIN" "延迟" "抖动" "类型" "得分" "备注"
awk -F'\t' '$6=="OK"' "$RESULTS" | sort -t$'\t' -k7 -n | while IFS=$'\t' read -r best jit d tls alpn v score; do
    t=$(tier_name "$d")
    note=""; [ "$t" = "排除" ] && note="遥测端点，不推荐"
    printf "%-42s %-8s %-6s %-8s %-6s %s\n" "$d" "${best}ms" "${jit}ms" "$t" "$score" "$note"
done

echo
echo "===== 不合格 ====="
printf "%-42s %-8s %-6s %s\n" "DOMAIN" "TLS" "ALPN" "原因"
awk -F'\t' '$6!="OK"' "$RESULTS" | sort -t$'\t' -k1 -n | while IFS=$'\t' read -r best jit d tls alpn v score; do
    if   [ "$tls" = "FAIL" ]; then reason="握手失败（可能不支持 X25519）"
    elif [ "$alpn" != "h2" ]; then reason="不协商 h2"
    else reason="采样有失败，不稳定"; fi
    printf "%-42s %-8s %-6s %s\n" "$d" "$tls" "$alpn" "$reason"
done

echo
echo "=================== 最终推荐 ==================="
PICK=$(awk -F'\t' '$6=="OK" && $7<9999' "$RESULTS" | sort -t$'\t' -k7 -n | head -1)
if [ -z "$PICK" ]; then
    echo "没有合格候选。检查这台机器的出站是否受限，或换一批候选域名。"
else
    p_best=$(cut -f1 <<<"$PICK"); p_jit=$(cut -f2 <<<"$PICK")
    p_dom=$(cut -f3 <<<"$PICK");  p_score=$(cut -f7 <<<"$PICK")
    echo
    echo "    dest / SNI  →  $p_dom"
    echo
    echo "    基准延迟 ${p_best}ms ／ 抖动 ${p_jit}ms ／ 类型 $(tier_name "$p_dom") 档 ／ 综合得分 ${p_score}"
    echo
    echo "  打分规则：基准延迟 + 抖动÷2 + 类型惩罚（A档 +0，B档 +15，C档 +40，遥测端点排除）"
    echo "  多台机器部署时，各自跑一遍并尽量选不同的 dest，避免形成统一模式。"
fi
echo "==============================================="

rm -f "$RESULTS"

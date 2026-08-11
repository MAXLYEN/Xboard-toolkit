# xboard-toolkit

Xboard + Xboard-Node 多节点部署运维工具箱。把重复的部署动作收成几条命令，并把踩过的坑固化成自动检查。

## 安装

**不要用 `curl | bash`。**下载中断时 bash 会执行已收到的那半截脚本，比粘贴被截断更隐蔽。先落盘、校验、再执行：

```bash
curl -fsSL https://raw.githubusercontent.com/MAXLYEN/xboard-toolkit/main/bootstrap.sh -o /tmp/xt.sh
bash /tmp/xt.sh
```

安装到 `/opt/xboard-toolkit`，软链 `xt` 到 `/usr/local/bin`。

## 命令

| 命令 | 作用 |
|---|---|
| `xt prep` | 系统准备：时间同步、IPv6、BBR、文件描述符 |
| `xt dest` | Reality 伪装域名检测，按延迟+抖动+类型打分推荐一个 |
| `xt node` | 安装/绑定 xboard-node（machine 模式），幂等 |
| `xt doctor` | 一键体检，覆盖全部已知易错点 |
| `xt batch` | 批量操作多台机器 |
| `xt update` | 更新工具箱自身 |
| `xt clean` | 一键清理工具箱留下的一切，并在清理后自检 |

全局选项：`--dry-run`、`--ref <tag|branch>`、`--source <URL模板>`

## 典型流程

```bash
# 节点机
xt prep
xt dest                                     # 记下推荐的 dest
xt node --panel https://panel.example.com \
        --token <服务器Token> --machine-id 3
xt doctor
```

面板侧「新增节点到此服务器」，dest/SNI 填上一步的推荐值。

## 批量

清单 `/root/deploy/nodes.txt`（**权限 600**，含 token）：

```
# 主机地址          machine_id  token        备注
node1.example.com   1           AbCdEf...    英国-1
node2.example.com   2           GhIjKl...    日本-1
```

```bash
xt batch bootstrap                 # 各机器装工具箱
xt batch prep                      # 批量系统准备
xt batch dest                      # 汇总各机器的 dest 推荐
xt batch deploy --panel https://panel.example.com
xt batch doctor                    # 汇总异常
```

需先配好 SSH 免密：`ssh-copy-id root@主机`。

## 卸载

```bash
xt clean --dry-run          # 先看会删什么
xt clean                    # 删工具箱自己的文件
xt clean --revert-system    # 连系统改动一起回退
```

默认**只删工具箱自己的文件**（安装目录、软链、配置、日志、备份），不动 IPv6 / BBR / limits.conf / chrony 这些系统设置——它们可能已经被别的东西依赖，静默回退比留着更危险。要一起回退就加 `--revert-system`。

**全程不碰 xboard-node**，那是独立组件。清理后自检会确认它仍在运行。

删完会逐项自检并报告，有残留返回非零码。

## 下载源

默认按顺序探测 GitHub raw → jsDelivr，选中第一个可用的，整轮安装都用它，避免混用不同版本。

**手动指定单一源：**

```bash
XT_SOURCE='https://你的镜像/%OWNER%/%REPO%/%REF%/%PATH%' bash /tmp/xt.sh
```

**追加备用源**（写进 `/etc/xboard-toolkit.conf`，会排在内置源之后）：

```bash
XT_SOURCES_EXTRA='mine|https://你的镜像/%OWNER%/%REPO%/%REF%/%PATH%'
```

模板占位符：`%OWNER%` `%REPO%` `%REF%` `%PATH%`

## 版本锁定

默认跟 `main`。生产建议锁 tag，避免 main 上的改动直接影响所有机器：

```bash
XT_REF=v1.0.0 bash /tmp/xt.sh
xt update --ref v1.0.1            # 明确升级
```

文件清单在仓库的 `MANIFEST` 里，`bootstrap.sh` 按它下载——新增文件只要往清单加一行。

`xt update` 会先拉取最新的 `bootstrap.sh` 再执行，保证清单逻辑的改动能传播下去。版本号相同时还会校验本地文件是否齐全，缺文件会强制重装（`--force` 可无条件重装）。

`bootstrap.sh` 会先把全部文件下载校验完，再动现有安装目录，且旧版本自动备份到 `/opt/xboard-toolkit.bak.<时间戳>`。

## 配置文件

`/etc/xboard-toolkit.conf`，权限 600：

```bash
PANEL_URL="https://panel.example.com"
XT_REF="main"
```

**不要把服务器 Token 写进去**——它每台不同，装的时候传一次即可。

## 设计约定

- **先落盘再执行**，任何远程脚本都要过 `bash -n` 语法校验，能可靠识别下载截断
- **幂等**：`write_idempotent` 统一处理"不存在则新建 / 相同则跳过 / 不同则备份后替换"
- **错误定位**：`set -Eeuo pipefail` + ERR trap，失败时打印文件名、行号、出错的具体命令
- **`--dry-run`** 在所有会改系统的命令上可用

## 许可

MIT

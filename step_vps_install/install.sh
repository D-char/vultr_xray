#!/usr/bin/env bash
if [ -z "${XRAY_SELFHEAL:-}" ] && [ -f "$0" ] && LC_ALL=C grep -q $'\r' "$0" 2>/dev/null; then t=$(mktemp /tmp/xray-install.XXXXXX.sh) && tr -d '\r' < "$0" > "$t" && chmod 700 "$t" && echo "[..] 检测到 CRLF 换行（Windows 格式），已转换后继续" && exec env XRAY_SELFHEAL=1 bash "$t" "$@"; fi  # crlf-guard
# ============================================================================
#  Xray 服务端一键安装（VLESS + Vision + Reality）
#
#  使用场景：你已经在 Vultr / 任何云上手动开好了一台 Linux，并且把这个文件
#            传到了服务器上。直接在服务器上跑它，装完给你一条 vless:// 链接。
#
#  适用系统：Ubuntu 20.04 / 22.04 / 24.04，Debian 11 / 12
#  要求    ：root（非 root 会自动尝试 sudo）
#
#  用法：
#     bash install.sh                 # 默认 SNI=www.microsoft.com 端口=443
#     bash install.sh --port 8443     # 443 不通时换端口
#     bash install.sh -y              # 不询问，直接装（适合重复执行）
#     bash install.sh --force         # 已装过也重装（会生成新链接，旧链接失效）
#     bash install.sh --no-lockdown   # 装完不封口（默认会把 22 等公网入口关掉）
#     bash install.sh --help
#
#  也可以用环境变量：SNI=xxx PORT=8443 bash install.sh
#
#  装完会做两次自检：本机真握手 + 用生成出来的那条链接真代理一次。
#  任一不过就报错退出，不会给你一条假链接。
# ============================================================================
# 维护提示：上面第 2 行的 crlf-guard 必须留在 set -euo pipefail 之前。
# 这个文件是手动上传的，容易被 Windows 编辑器 / WinSCP 文本模式存成 CRLF，
# 那样 `set -euo pipefail` 自己就会先报 "invalid option name" 退出，
# 后面的自愈代码根本没机会执行。guard 那一行把 \r 落在行尾注释里，所以能活。
#
# 注意：自愈只在 `bash install.sh` 这种方式下有效。文件是 CRLF 时 ./install.sh
# 会先死在 shebang 上（内核把 "bash\r" 当成解释器路径去 exec），那时一行 bash
# 代码都还没跑，guard 救不了。
# ============================================================================
set -euo pipefail

SNI="${SNI:-www.microsoft.com}"
PORT="${PORT:-443}"
ASSUME_YES=0
FORCE=0
LOCKDOWN=1          # 1 = 装完把公网入口关掉，只留 Xray 端口
IP_OVERRIDE=""

# 下面解析参数会把 $@ shift 空，非 root 提权重跑时要靠这份原始参数（见 root 段）
ORIG_ARGS=("$@")

# ------------------------------------------------------------------ 小工具
# 输出被重定向（ssh 远程执行、管道、写日志）时不上色，否则那些 \033[..m
# 会原样出现在别人的终端里变成乱码。
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  c_reset=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'
  c_yel=$'\033[33m'; c_cya=$'\033[36m'; c_dim=$'\033[90m'
else
  c_reset=""; c_red=""; c_grn=""; c_yel=""; c_cya=""; c_dim=""
fi

say()  { printf '\n%s==> %s%s\n' "$c_cya" "$*" "$c_reset"; }
ok()   { printf '    %s[OK]%s %s\n' "$c_grn" "$c_reset" "$*"; }
warn() { printf '    %s[!!]%s %s\n' "$c_yel" "$c_reset" "$*"; }
bad()  { printf '    %s[XX]%s %s\n' "$c_red" "$c_reset" "$*"; }
dim()  { printf '         %s%s%s\n' "$c_dim" "$*" "$c_reset"; }
die()  { bad "$*"; exit 1; }

usage() {
  cat <<'USAGE'
  Xray 服务端一键安装（VLESS + Vision + Reality）
  适用：Ubuntu 20.04/22.04/24.04、Debian 11/12，需 root（非 root 自动用 sudo）

  用法:
    bash install.sh                 默认 SNI=www.microsoft.com，端口 443
    bash install.sh --port 8443     换监听端口（443 不通时用）
    bash install.sh --sni example.com
    bash install.sh --ip 1.2.3.4    手动指定链接里的公网 IP
    bash install.sh -y              不询问，直接装
    bash install.sh --force         已装过也重装（会生成新链接，旧链接失效）
    bash install.sh --no-lockdown   装完不封口（默认装完只留 Xray 端口，关掉 22）
    bash install.sh -h              显示这段帮助

  默认行为: 装完会用 ufw 把公网入口关掉，只放行 Xray 那个端口。当前这条 SSH
  连接不会断，但之后再也连不进来（要用 Vultr 的 View Console 才能进）。
  机器是「用完就 destroy」的话这是最省事的选择；要留机器长期用就加 --no-lockdown。

  也可以用环境变量: SNI=example.com PORT=8443 bash install.sh

  装完会自检两次：真的 Reality 握手 + 用这条链接真的代理一次。
  任一不过都会报错退出，不会给你一条「看起来正常但用不了」的链接。
USAGE
  exit 0
}

# ------------------------------------------------------------------ 参数
while [ $# -gt 0 ]; do
  case "$1" in
    --sni)   [ $# -ge 2 ] || die "--sni 后面要跟域名，比如 --sni www.apple.com"; SNI="$2"; shift 2 ;;
    --sni=*) SNI="${1#*=}";      shift   ;;
    --port)  [ $# -ge 2 ] || die "--port 后面要跟端口号，比如 --port 8443"; PORT="$2"; shift 2 ;;
    --port=*)PORT="${1#*=}";     shift   ;;
    --ip)    [ $# -ge 2 ] || die "--ip 后面要跟 IP，比如 --ip 1.2.3.4"; IP_OVERRIDE="$2"; shift 2 ;;
    --ip=*)  IP_OVERRIDE="${1#*=}"; shift ;;
    -y|--yes)  ASSUME_YES=1; shift ;;
    --force|-f) FORCE=1;     shift ;;
    --no-lockdown) LOCKDOWN=0; shift ;;
    --lockdown)    LOCKDOWN=1; shift ;;
    -h|--help) usage ;;
    *) die "不认识的参数: $1（用 --help 看用法）" ;;
  esac
done

# ------------------------------------------------------------------ root
if [ "$(id -u)" -ne 0 ]; then
  # 转成绝对路径再交给 sudo，避免某些 sudoers 配置会切目录
  SELF="$0"
  if [ -f "$0" ]; then
    SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  else
    # curl ... | bash / bash <(curl ...) 这类管道方式下，$0 是 "bash" 或 /dev/fd/63，
    # 提权重跑根本拿不到脚本原文，硬跑只会得到 "bash: bash: No such file or directory"。
    die "需要 root。用管道方式（curl | bash）没法提权重跑自己，请先落盘再执行：
       curl -fsSL <脚本地址> -o /tmp/install.sh && sudo bash /tmp/install.sh"
  fi
  if command -v sudo >/dev/null 2>&1; then
    # 必须传 ORIG_ARGS 而不是 "$@"：走到这里时 $@ 已经被上面那个参数解析循环
    # shift 光了，传 "$@" 等于「一个参数都没传」，--port/-y/--force 会全部静默丢失
    # （最坑的是 --force 丢了，已装过的机器会直接 die「非交互模式下不覆盖」）。
    # 也不用 sudo -E：有些 sudoers 没给 SETENV，-E 会被直接拒；显式带环境变量更稳。
    if sudo -n true 2>/dev/null; then
      echo "[..] 需要 root，用免密 sudo 重新执行"
      exec sudo -n env SNI="$SNI" PORT="$PORT" bash "$SELF" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
    fi
    if [ -t 0 ]; then
      echo "[..] 需要 root，改用 sudo 重新执行（会要密码）"
      exec sudo env SNI="$SNI" PORT="$PORT" bash "$SELF" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
    fi
    # 远程执行时没有终端，sudo 要密码就会卡死在这里
    die "需要 root：当前是 $(id -un)，sudo 需要密码但没有终端。请用 root 登录后再跑"
  fi
  die "请用 root 运行（当前用户 $(id -un) 且没有 sudo）"
fi

# ------------------------------------------------------------------ 预检
say "0/7：环境预检"

if [ ! -r /etc/os-release ]; then
  die "读不到 /etc/os-release，判断不了系统类型"
fi
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ok "系统: ${PRETTY_NAME:-$ID}" ;;
  *)
    warn "系统是 ${PRETTY_NAME:-${ID:-未知}}，本脚本只在 Ubuntu / Debian 上验证过"
    dim "如果下面 apt-get 不存在就会直接失败"
    ;;
esac

command -v apt-get >/dev/null 2>&1 || \
  die "找不到 apt-get。请在 Vultr 上重装成 Ubuntu 22.04/24.04 或 Debian 12"
ok "apt-get 可用"

command -v systemctl >/dev/null 2>&1 || die "找不到 systemctl（不是 systemd 系统？）"
ok "systemd 可用"

case "$PORT" in ''|*[!0-9]*) die "端口必须是数字，现在是「${PORT}」" ;; esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  die "端口超出范围 1-65535：${PORT}"
fi
ok "端口: ${PORT}"

case "$SNI" in
  *.*) : ;;
  *) die "SNI 要写成域名，比如 www.microsoft.com，现在是「${SNI}」" ;;
esac
case "$SNI" in
  *[!A-Za-z0-9.-]*)
    die "SNI 只允许字母 / 数字 / 点 / 连字符，现在是「${SNI}」（它要写进 JSON，也会作为 TLS 的 SNI 字段发出去）" ;;
esac
ok "SNI: ${SNI}"

if [ "$PORT" -eq 22 ]; then
  die "端口 22 是 SSH，Reality 占它会把你自己锁在门外。换一个：--port 443"
fi

# 已经装过：默认不覆盖，免得你手上的旧链接莫名其妙失效
if [ -f /usr/local/etc/xray/config.json ] && [ "$FORCE" -eq 0 ]; then
  say "检测到已经装过 Xray"
  if [ -f /root/node.txt ]; then
    dim "现有的链接（在 /root/node.txt）："
    grep -m1 '^vless://' /root/node.txt 2>/dev/null | sed 's/^/         /' || true
  fi
  warn "重装会生成新的 UUID / 密钥，旧链接立即失效"
  if [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
    printf '         确定重装？[y/N] '
    read -r ans || ans=""
    case "$ans" in
      [yY]*) ASSUME_YES=1 ;;   # 已经确认过一次，下面不再问「回车开始」
      *) echo "已取消"; exit 0 ;;
    esac
  else
    die "已经装过 Xray，不覆盖。确实要重装请加 --force"
  fi
fi

# ------------------------------------------------------------------ 确认
echo ""
echo "  ============================================================"
echo "   监听端口 : ${PORT}"
echo "   伪装域名 : ${SNI}"
echo "   证书      : 不需要（Reality 借 ${SNI} 的真实证书）"
if [ "$LOCKDOWN" -eq 1 ]; then
  echo "   装完封口 : 只留 ${PORT}/tcp，22 等公网入口全部关闭"
  echo "              （之后进机器只能用 Vultr 的 View Console）"
else
  echo "   装完封口 : 不做（--no-lockdown，22 端口保持开放）"
fi
echo "  ============================================================"
echo "   接下来会自动做：装依赖 -> 装 Xray -> 写配置 -> 启动"
echo "                  -> 本机握手自检 -> 生成节点链接 -> 封口"
echo ""

if [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
  printf '   回车开始，Ctrl+C 取消 '
  read -r _ || true
fi

# ------------------------------------------------------------------ 1 校时
say "1/7：校时"
# Reality 依赖 TLS，握手对时间敏感，误差超过 60 秒就连不上
timedatectl set-ntp true 2>/dev/null || true
ok "已开启 NTP（时区 $(timedatectl show -p Timezone --value 2>/dev/null || echo 未知)）"

# ------------------------------------------------------------------ 2 端口
say "2/7：检查端口 ${PORT}"
# 重跑时先停掉自己，否则下面会把上一轮的自己当成"端口被占"
systemctl stop xray 2>/dev/null || true

# 只看监听套接字的「本地地址:端口」那一列，比 grep ":443 " 靠列间距判断更可靠。
# 返回 0=被占 1=空闲 2=没法判断（连 ss / netstat 都没有）
port_in_use() {
  if command -v ss >/dev/null 2>&1; then
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}\$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}\$"
  else
    return 2
  fi
}

PSTATE=0
port_in_use || PSTATE=$?
case "$PSTATE" in
  0)
    bad "端口 ${PORT} 被占用了，占用的进程如下："
    (ss -lntp 2>/dev/null || netstat -lntp 2>/dev/null) \
      | grep -E "[:.]${PORT}[[:space:]]" | sed 's/^/         /' || true
    dim "常见是 nginx / apache / 另一个 xray。停掉它，或者换端口：--port 8443"
    exit 1 ;;
  1)
    ok "端口空闲" ;;
  *)
    warn "系统里既没有 ss 也没有 netstat，跳过端口占用检查" ;;
esac

# ------------------------------------------------------------------ 3 安装
say "3/7：安装依赖 + Xray"
export DEBIAN_FRONTEND=noninteractive

# 刚开机的机器 cloud-init 可能还在跑 apt，直接装会撞 dpkg 锁失败。
# 等它收尾，再给 apt 一个等锁上限。
timeout 180 cloud-init status --wait >/dev/null 2>&1 || true
APT_OPTS="-o DPkg::Lock::Timeout=180 -o Dpkg::Options::=--force-confold"

dim "apt-get update ..."
apt-get $APT_OPTS update -qq || die "apt-get update 失败，检查服务器网络 / DNS"
apt-get $APT_OPTS install -y -qq curl ca-certificates openssl ufw || die "装依赖包失败"
ok "依赖就绪"

dim "安装 Xray（从 GitHub 拉官方脚本）..."
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install \
  || die "Xray 安装脚本执行失败（大概率是拉不到 GitHub）"
command -v xray >/dev/null 2>&1 || die "Xray 装完了但找不到 xray 命令"
ok "Xray: $(xray version 2>/dev/null | head -1 || echo 已安装)"

# ------------------------------------------------------------------ 4 密钥
say "4/7：生成 UUID / 密钥对 / ShortID"
UUID=$(xray uuid) || die "xray uuid 执行失败"

# xray x25519 的输出标签在不同版本间变过（Public key / Password / PublicKey），
# 所以先按标签取，取不到再按"43 位 base64url token"兜底，最后统一校验格式。
# 每处命令替换都加 || true：set -e + pipefail 下，grep 匹配不到会直接退出脚本。
is_key() { printf '%s' "$1" | grep -qE '^[A-Za-z0-9_-]{43}$'; }

KEYS=$(xray x25519 2>/dev/null || true)
PRIV=$(printf '%s\n' "$KEYS" | grep -iE 'private'         | head -1 | sed 's/.*: *//' | tr -d ' \r' || true)
PUB=$(printf '%s\n'  "$KEYS" | grep -iE 'public|password' | head -1 | sed 's/.*: *//' | tr -d ' \r' || true)

if ! is_key "$PRIV" || ! is_key "$PUB"; then
  TOKENS=$(printf '%s\n' "$KEYS" | grep -oE '[A-Za-z0-9_-]{43}' | head -2 || true)
  PRIV=$(printf '%s\n' "$TOKENS" | sed -n '1p' || true)
  PUB=$(printf '%s\n'  "$TOKENS" | sed -n '2p' || true)
fi
if ! is_key "$PUB" && is_key "$PRIV"; then
  # 这里必须按标签取，不能倒退回去用「43 位 token + tail -1」：当前版本会多打一行
  # "Hash32: <64 位 hex>"，hex 全部落在 [A-Za-z0-9_-] 里，tail -1 取到的是它的前
  # 43 位——一个格式完全合法、但根本不对的公钥，而 6a 的转发自检照样会绿。
  PUB=$(xray x25519 -i "$PRIV" 2>/dev/null \
    | grep -iE 'public|password' | head -1 | sed 's/.*: *//' | tr -d ' \r' || true)
fi
if ! is_key "$PRIV" || ! is_key "$PUB"; then
  bad "密钥解析失败，xray x25519 的原始输出是："
  printf '%s\n' "$KEYS" | sed 's/^/         /'
  exit 1
fi

SID=$(openssl rand -hex 8)
ok "UUID: ${UUID}"
ok "ShortID: ${SID}"

# ------------------------------------------------------------------ 5 配置
say "5/7：写入配置并启动"
mkdir -p /usr/local/etc/xray

# 覆盖前留一份旧配置：--force 重装后悔了还能翻回来（空配置 {} 不值得备份）
if grep -q '"inbounds"' /usr/local/etc/xray/config.json 2>/dev/null; then
  BAK="/root/xray-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BAK"
  cp -a /usr/local/etc/xray/config.json "$BAK/" 2>/dev/null || true
  cp -a /root/node.txt "$BAK/" 2>/dev/null || true
  dim "旧配置已备份到 ${BAK}/"
fi

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${UUID}", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${SNI}:443",
          "xver": 0,
          "serverNames": [ "${SNI}" ],
          "privateKey": "${PRIV}",
          "shortIds": [ "${SID}" ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ]
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF

# 官方安装器把服务跑在 xray 用户下（systemd 里 User=xray），配置必须它读得到。
# 正常路径下 installer 已经建了 640 root:xray，但这里显式设一遍：万一 umask 是 077
# 或者目录被重建过，配置会变成 root:root 600，service 起不来而且日志里看不出原因。
if chown root:xray /usr/local/etc/xray/config.json 2>/dev/null; then
  chmod 640 /usr/local/etc/xray/config.json
else
  chmod 644 /usr/local/etc/xray/config.json   # 没有 xray 组（老版本安装器用 nobody）就退化成可读
fi

# 配置写错的话 xray 会直接起不来，先让 xray 自己检查一遍
if ! xray run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1; then
  bad "配置文件没通过 Xray 的语法检查："
  xray run -test -config /usr/local/etc/xray/config.json 2>&1 | sed 's/^/         /'
  exit 1
fi
ok "配置语法正确"

systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
sleep 2
if ! systemctl is-active --quiet xray; then
  bad "Xray 启动失败，日志如下："
  journalctl -u xray -n 40 --no-pager | sed 's/^/         /'
  exit 1
fi
ok "Xray 正在运行"

# 开 BBR，高丢包线路上吞吐会好很多。
# 写 /etc/sysctl.d/ 而不是往 /etc/sysctl.conf 追加，并且装完回读验证——旧写法在云镜像上
# 有两个坑：值可能已经写在 sysctl.d 里（于是 grep 认为不用开），或者 sysctl -p 因为
# /etc/sysctl.conf 里别处的坏行整份失败（BBR 压根没生效，而 || true 把错误吞了）。
if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" != "bbr" ]; then
  modprobe tcp_bbr 2>/dev/null || true
  printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-xray-bbr.conf
  sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-xray-bbr.conf >/dev/null 2>&1 || true
fi
CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
if [ "$CC" = "bbr" ]; then
  ok "拥塞控制: bbr"
else
  warn "BBR 没开起来（当前: ${CC:-未知}），不影响能不能连，只影响吞吐"
fi

# 防火墙放行（云厂商的安全组要另外在控制台开）
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
  ok "ufw 已放行 ${PORT}/tcp"
else
  dim "ufw 未启用，跳过防火墙配置"
fi

# ------------------------------------------------------------------ 6 自检
say "6/7：自检（本机真握手 + 用刚生成的链接真代理一次）"

# --- 6a：端口在听、Reality 在转发、服务器能出网 -------------------------------
# Reality 对"没带正确密钥"的 TLS 连接会原样转发给 target，所以能拿到
# 2xx/3xx/4xx 就证明这三件事。但它证明不了"密钥对不对"——鉴权失败时也是这个表现，
# 那正是 6b 要验的东西。
SELFTEST=""
for i in 1 2 3; do
  # 注意不要写 `|| echo 000`：curl 失败时 -w 已经吐出 "000"，再 echo 一次会拼成
  # "000000"，失败分支就会打出一句 HTTP 000000 的怪话。
  SELFTEST=$(curl -k -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    --resolve "${SNI}:${PORT}:127.0.0.1" "https://${SNI}:${PORT}/" 2>/dev/null || true)
  [ -n "$SELFTEST" ] || SELFTEST="000"
  case "$SELFTEST" in 2*|3*|4*) break ;; esac
  [ "$i" -lt 3 ] && sleep 2 || true
done

case "$SELFTEST" in
  2*|3*|4*)
    ok "握手成功（HTTP ${SELFTEST}），Reality 转发正常"
    ;;
  *)
    bad "握手失败（HTTP ${SELFTEST}）——服务起来了，但 Reality 没工作"
    dim "可能原因：服务器没有外网 / ${SNI} 解析不了 / 端口被中间设备拦"
    echo "     Xray 最近的日志："
    journalctl -u xray -n 30 --no-pager | sed 's/^/         /' || true
    exit 1
    ;;
esac

# --- 6b：用这条链接里的 UUID / 公钥 / ShortID / SNI 真的走一遍 -----------------
# 6a 拿到 4xx 也可能是"鉴权失败被转发给了 microsoft"，所以它证明不了 pbk/sid 是对的。
# 这里起一个临时 Xray 客户端（本机 socks5），用和 vless:// 完全相同的凭据去连，
# 真能通过它上网，才说明发给你那条链接是可用的。
CTPORT=$(( 20000 + RANDOM % 10000 ))
[ "$CTPORT" -eq "$PORT" ] && CTPORT=$(( CTPORT + 1 ))
CTCFG=/tmp/xray-selftest-client.json
CTLOG=/tmp/xray-selftest-client.log

cat > "$CTCFG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "listen": "127.0.0.1", "port": ${CTPORT}, "protocol": "socks", "settings": { "udp": false } }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          { "address": "127.0.0.1", "port": ${PORT},
            "users": [ { "id": "${UUID}", "encryption": "none", "flow": "xtls-rprx-vision" } ] }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "${SNI}",
          "fingerprint": "chrome",
          "publicKey": "${PUB}",
          "shortId": "${SID}"
        }
      }
    }
  ]
}
EOF

xray run -c "$CTCFG" >"$CTLOG" 2>&1 &
CTPID=$!
sleep 2
CTCODE=""
for i in 1 2 3; do
  CTCODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
    --socks5-hostname "127.0.0.1:${CTPORT}" "https://www.gstatic.com/generate_204" 2>/dev/null || true)
  [ -n "$CTCODE" ] || CTCODE="000"
  case "$CTCODE" in 200|204) break ;; esac
  [ "$i" -lt 3 ] && sleep 2 || true
done
kill "$CTPID" 2>/dev/null || true
rm -f "$CTCFG"

case "$CTCODE" in
  200|204)
    ok "链接可用（临时客户端经 socks5 代理请求成功）"
    rm -f "$CTLOG"
    ;;
  *)
    bad "链接不可用（HTTP ${CTCODE}）——转发是通的，但拿这条链接连不上"
    dim "多半是 UUID / 公钥 / ShortID / flow 对不上。临时客户端日志："
    tail -n 20 "$CTLOG" 2>/dev/null | sed 's/^/         /' || true
    rm -f "$CTLOG"
    exit 1
    ;;
esac

# ------------------------------------------------------------------ 7 链接
say "7/7：生成节点链接"
if [ -n "$IP_OVERRIDE" ]; then
  PUBIP="$IP_OVERRIDE"
else
  PUBIP=$(curl -fsS4 --max-time 10 https://api.ipify.org  2>/dev/null \
       || curl -fsS4 --max-time 10 https://ifconfig.me    2>/dev/null \
       || hostname -I 2>/dev/null | awk '{print $1}')
fi
[ -n "$PUBIP" ] || die "取不到公网 IP，可以用 --ip 手动指定"

LINK="vless://${UUID}@${PUBIP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp&headerType=none#VPS-${PUBIP}"

cat > /root/node.txt <<EOF
节点链接（导入 v2rayN / v2rayNG）:
${LINK}

服务器   : ${PUBIP}:${PORT}
UUID     : ${UUID}
公钥 pbk : ${PUB}
ShortID  : ${SID}
SNI      : ${SNI}
流控     : xtls-rprx-vision
指纹 fp  : chrome
安装时间 : $(date '+%Y-%m-%d %H:%M:%S')
EOF
chmod 600 /root/node.txt

echo ""
echo "============================================================"
echo " 安装完成，且已通过握手 + 代理自检"
echo " 节点链接（同时保存在 /root/node.txt）："
echo "============================================================"
echo ""
echo "${LINK}"
echo ""
echo " 客户端: Windows -> v2rayN | Android -> v2rayNG"
echo "         iOS -> Shadowrocket / Streisand | macOS -> Nekoray"
echo ""
echo " 注意: 这里只证明服务器端装好了。从国内能不能连上，"
echo "       要回本地导入这条链接实测。"
echo "============================================================"
echo ""

# ------------------------------------------------------------------ 封口
# 「建机器 -> 用 -> destroy」这种用法下，最省事也最彻底的防爆破做法：装完就把
# 公网入口关掉，只留 Xray 那一个端口。ufw 自带的规则里有 conntrack ESTABLISHED
# 放行，所以你现在这条 SSH 连接不会断——只是新连接（包括爆破脚本）进不来了。
# 之后要再动这台机器：Vultr 控制台的 View Console 走宿主机通道，不受 ufw 影响。
if [ "$LOCKDOWN" -eq 1 ]; then
  say "封口：只保留 ${PORT}/tcp，关掉 22 等公网入口"
  command -v ufw >/dev/null 2>&1 || \
    apt-get $APT_OPTS install -y -qq ufw >/dev/null 2>&1 || true

  if command -v ufw >/dev/null 2>&1; then
    ufw --force default deny incoming  >/dev/null 2>&1 || true
    ufw --force default allow outgoing >/dev/null 2>&1 || true
    ufw --force delete allow 22/tcp    >/dev/null 2>&1 || true   # 清掉可能存在的旧放行
    ufw deny 22/tcp                    >/dev/null 2>&1 || true
    ufw allow "${PORT}/tcp"            >/dev/null 2>&1 || true
    ufw --force enable                 >/dev/null 2>&1 || true

    if ufw status 2>/dev/null | grep -q "Status: active"; then
      ok "ufw 已启用，只放行 ${PORT}/tcp"
      ufw status 2>/dev/null | sed -n '2,10p' | sed 's/^/         /' || true
      dim "现在 SSH 已经连不进来了。要再操作这台机器，用 Vultr 的 View Console"
      dim "（宿主机通道，不经过 ufw；root 密码照样能登）"
      dim "用完了直接在面板上 Destroy Instance 即可"
    else
      warn "ufw 没能启用，22 端口仍然对外开放"
      dim "手动执行一次：ufw default deny incoming && ufw allow ${PORT}/tcp && ufw --force enable"
    fi
  else
    warn "装不上 ufw，跳过封口，22 端口仍然对外开放"
  fi
else
  dim "--no-lockdown：跳过封口，22 端口保持对外开放"
fi

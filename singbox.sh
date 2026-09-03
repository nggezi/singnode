#!/bin/sh
#
# singbox.sh - OpenWrt(泛) 一键安装/卸载 sing-box Shadowsocks-2022 服务端
#
# 用法:
#   sh singbox.sh           # 安装/更新 sing-box 并输出 ss:// 链接
#   sh singbox.sh uninstall # 一键卸载
#
# 可选环境变量:
#   SINGBOX_DOMAIN=example.com   用域名生成链接(路由器有域名时推荐)
#   SINGBOX_ARCH=amd64           手动指定 sing-box 资产架构后缀
#   SINGBOX_VERSION=1.13.14      固定安装版本(默认取 GitHub 最新稳定版)
#   GH_MIRROR=https://ghfast.top 手动指定 GitHub 加速前缀
#
set -u

SING_BOX_VERSION=""
PORT=""
PASSWORD=""
HOST=""
REGION="unknown"
DL=""

CONF_DIR="/etc/sing-box"
CONF_FILE="$CONF_DIR/config.json"
STATE_FILE="$CONF_DIR/node.state"
BIN_FILE="/usr/bin/sing-box"
INIT_FILE="/etc/init.d/sing-box"
FW_NAME="singbox"
FIREWALL_RULE_NAME="Allow-Sing-Box"
SS_METHOD="2022-blake3-aes-256-gcm"
TMP_DIR="/tmp/singbox-setup.$$"

log_info() { printf '[INFO] %s\n' "$*"; }
log_ok()   { printf '[ OK ] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*"; }
log_err()  { printf '[FAIL] %s\n' "$*" >&2; }

fail() {
  log_err "$*"
  cleanup
  exit 1
}

cleanup() {
  [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 1' INT TERM

need_cmd() {
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      fail "缺少必需命令: $c (此脚本需运行在 OpenWrt 及其衍生系统上)"
    fi
  done
}

# ---------------------------------------------------------------------------
# HTTP 封装:优先 curl,退化到 wget
# ---------------------------------------------------------------------------
setup_downloader() {
  if command -v curl >/dev/null 2>&1; then
    DL=curl
    return 0
  fi
  if command -v wget >/dev/null 2>&1 &&
     wget -q -T 8 -O /dev/null https://github.com 2>/dev/null; then
    DL=wget
    return 0
  fi
  # 兜底:尝试自动安装 curl
  if command -v opkg >/dev/null 2>&1; then
    log_info "未找到可用的 HTTPS 下载器,尝试 opkg 安装 curl ..."
    opkg update >/dev/null 2>&1 || true
    opkg install curl >/dev/null 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then
    log_info "未找到可用的 HTTPS 下载器,尝试 apk 安装 curl ..."
    apk update >/dev/null 2>&1 || true
    apk add curl >/dev/null 2>&1 || true
  fi
  if command -v curl >/dev/null 2>&1; then
    DL=curl
    return 0
  fi
  fail "系统没有 HTTPS 下载工具(curl 或带 SSL 的 wget)。请先执行: opkg update && opkg install curl"
}

http_get() {
  # $1=url $2=connect/总超时(秒)
  local t="${2:-10}"
  case "$DL" in
    curl) curl -fsSL --connect-timeout 6 --max-time "$t" "$1" 2>/dev/null ;;
    wget) wget -q -T "$t" -O - "$1" 2>/dev/null ;;
  esac
}

http_download() {
  # $1=url $2=输出文件
  case "$DL" in
    curl) curl -fL --connect-timeout 8 --max-time 600 --retry 1 --retry-delay 2 -o "$2" "$1" 2>/dev/null ;;
    wget) wget -q -T 120 -O "$2" "$1" 2>/dev/null ;;
  esac
}

# ---------------------------------------------------------------------------
# 架构检测
# ---------------------------------------------------------------------------
detect_arch() {
  local mach
  if [ -n "${SINGBOX_ARCH:-}" ]; then
    log_info "按 SINGBOX_ARCH 手动指定架构: $SINGBOX_ARCH"
    ARCH="$SINGBOX_ARCH"
    return 0
  fi
  mach=$(uname -m 2>/dev/null | tr '[:upper:]' '[:lower:]')
  case "$mach" in
    x86_64|amd64)                  ARCH=amd64 ;;
    i386|i486|i586|i686|x86)       ARCH=386 ;;
    aarch64|arm64)                 ARCH=arm64 ;;
    armv7l|armv7)                  ARCH=armv7 ;;
    armv6l|armv6)                  ARCH=armv6 ;;
    armv5tel|armv5tejl|armv5)      ARCH=armv5 ;;
    mips64el|mips64le)             ARCH=mips64le ;;
    mips64)                        ARCH=mips64 ;;
    mipsel|mipsle)                 ARCH=mipsle ;;
    mips)                          ARCH=mips ;;
    loongarch64|loong64)           ARCH=loong64 ;;
    ppc64le|powerpc64le)           ARCH=ppc64le ;;
    *)
      fail "无法识别的机器架构: $mach (可用 SINGBOX_ARCH 环境变量手动指定,如 SINGBOX_ARCH=armv7)"
      ;;
  esac
  log_info "机器架构: $mach -> sing-box 资产: linux-$ARCH"
}

# 该架构下的资产候选名(按优先级;通用静态包优先,musl 次之)
asset_candidates() {
  case "$ARCH" in
    amd64)     echo "linux-amd64 linux-amd64-musl linux-amd64-glibc" ;;
    386)       echo "linux-386 linux-386-musl linux-386-glibc" ;;
    arm64)     echo "linux-arm64 linux-arm64-musl linux-arm64-glibc" ;;
    armv7)     echo "linux-armv7 linux-armv7-musl linux-armv7-glibc" ;;
    armv6)     echo "linux-armv6" ;;
    armv5)     echo "linux-armv5" ;;
    mipsle)    echo "linux-mipsle-softfloat linux-mipsle linux-mipsle-softfloat-musl linux-mipsle-glibc" ;;
    mips)      echo "linux-mips-softfloat" ;;
    mips64le)  echo "linux-mips64le linux-mips64le-softfloat linux-mips64le-glibc" ;;
    mips64)    echo "linux-mips64-softfloat" ;;
    loong64)   echo "linux-loong64 linux-loong64-musl linux-loong64-glibc" ;;
    ppc64le)   echo "linux-ppc64le" ;;
    *)         echo "linux-$ARCH" ;;
  esac
}

# ---------------------------------------------------------------------------
# 国内外检测: 优先 IP 地理库,失败时按 GitHub 可达性兜底
# ---------------------------------------------------------------------------
probe_geo_country() {
  local body code
  # api.ip.sb
  body=$(http_get "https://api.ip.sb/geoip" 8) && {
    code=$(printf '%s' "$body" | sed -n 's/.*"country_code"[[:space:]]*:[[:space:]]*"\([A-Za-z][A-Za-z]\)".*/\1/p' | head -1)
    [ -n "$code" ] && { echo "$code"; return 0; }
  }
  # ip-api.com (HTTP,返回 countryCode)
  body=$(http_get "http://ip-api.com/json/?fields=countryCode" 8) && {
    code=$(printf '%s' "$body" | sed -n 's/.*"countryCode"[[:space:]]*:[[:space:]]*"\([A-Za-z][A-Za-z]\)".*/\1/p' | head -1)
    [ -n "$code" ] && { echo "$code"; return 0; }
  }
  return 1
}

github_reachable() {
  case "$DL" in
    curl) curl -fsS -o /dev/null --connect-timeout 5 --max-time 8 https://github.com 2>/dev/null ;;
    wget) wget -q -T 8 -O /dev/null https://github.com 2>/dev/null ;;
  esac
}

detect_region() {
  local country
  country=$(probe_geo_country)
  if [ -n "$country" ]; then
    if [ "$country" = "CN" ]; then
      REGION=domestic
      log_info "IP 归属: 中国 -> 按国内环境处理,优先使用镜像站"
    else
      REGION=foreign
      log_info "IP 归属: $country -> 按国外环境处理,优先直连 GitHub"
    fi
    return 0
  fi
  log_warn "IP 地理探测失败,改用 GitHub 可达性判断 ..."
  if github_reachable; then
    REGION=foreign
    log_info "GitHub 可达 -> 按国外环境处理"
  else
    REGION=domestic
    log_info "GitHub 不可达 -> 按国内环境处理,优先使用镜像站"
  fi
}

gh_base_list() {
  if [ -n "${GH_MIRROR:-}" ]; then
    echo "$GH_MIRROR"
    return 0
  fi
  if [ "$REGION" = "domestic" ]; then
    echo "https://ghfast.top https://gh-proxy.com https://ghproxy.net https://gh.llkk.cc https://mirror.ghproxy.com https://github.com"
  else
    echo "https://github.com https://ghfast.top https://gh-proxy.com https://ghproxy.net https://gh.llkk.cc"
  fi
}

gh_url() {
  # $1=镜像基址 $2=仓库相对路径
  case "$1" in
    https://github.com) printf '%s/%s' "$1" "$2" ;;
    *)                  printf '%s/%s' "${1%/}" "https://github.com/$2" ;;
  esac
}

# ---------------------------------------------------------------------------
# 获取最新版本号
# ---------------------------------------------------------------------------
resolve_version() {
  local api_tag page_tag base
  if [ -n "${SINGBOX_VERSION:-}" ]; then
    SING_BOX_VERSION=${SINGBOX_VERSION#v}
    log_info "按 SINGBOX_VERSION 指定版本: $SING_BOX_VERSION"
    return 0
  fi
  api_tag=$(http_get "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 12 |
            sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\(v[0-9][^"]*\)".*/\1/p' | head -1)
  if [ -n "$api_tag" ]; then
    SING_BOX_VERSION=${api_tag#v}
    log_info "最新版本(via GitHub API): $SING_BOX_VERSION"
    return 0
  fi
  # 兜底: 直接抓 releases/latest 页面里的 tag
  for base in $(gh_base_list); do
    page_tag=$(http_get "$(gh_url "$base" SagerNet/sing-box/releases/latest)" 20 |
               grep -o 'releases/tag/v[0-9][^" ]*' | head -1 |
               sed 's#.*/v##')
    if [ -n "$page_tag" ]; then
      SING_BOX_VERSION=${page_tag#v}
      log_info "最新版本(via 页面): $SING_BOX_VERSION"
      return 0
    fi
  done
  fail "无法获取 sing-box 最新版本号,请检查网络或设置 GH_MIRROR"
}

# ---------------------------------------------------------------------------
# 下载并安装
# ---------------------------------------------------------------------------
download_asset() {
  # $1=版本 $2=资产候选 $3=镜像基址 $4=输出文件
  local url
  url=$(gh_url "$3" "SagerNet/sing-box/releases/download/v$1/sing-box-$1-$2.tar.gz")
  log_info "下载: $url"
  http_download "$url" "$4"
}

fetch_and_extract() {
  local bases candidates ver cand base tarball bin
  ver="$SING_BOX_VERSION"
  candidates=$(asset_candidates)
  bases=$(gh_base_list)
  mkdir -p "$TMP_DIR"
  tarball="$TMP_DIR/singbox.tar.gz"
  for base in $bases; do
    for cand in $candidates; do
      if download_asset "$ver" "$cand" "$base" "$tarball"; then
        log_ok "下载完成: linux-$cand"
        if tar -xzf "$tarball" -C "$TMP_DIR" 2>/dev/null; then
          :
        elif gzip -dc "$tarball" 2>/dev/null | tar -xf - -C "$TMP_DIR" 2>/dev/null; then
          :
        else
          fail "解压失败: $tarball (tar 是否支持 gzip?)"
        fi
        bin=$(find "$TMP_DIR" -type f -name sing-box 2>/dev/null | head -1)
        [ -n "$bin" ] || fail "压缩包内未找到 sing-box 可执行文件"
        chmod 0755 "$bin"
        if ! "$bin" version >/dev/null 2>&1; then
          fail "下载的 sing-box 无法运行,可能架构选择有误(可用 SINGBOX_ARCH 强制指定)"
        fi
        mkdir -p "$(dirname "$BIN_FILE")"
        cp "$bin" "$BIN_FILE"
        chmod 0755 "$BIN_FILE"
        log_ok "已安装二进制: $BIN_FILE"
        return 0
      fi
      rm -f "$tarball"
    done
  done
  return 1
}

# ---------------------------------------------------------------------------
# 凭据:首次生成后持久化,卸载重装不换端口/密码
# ---------------------------------------------------------------------------
gen_key() {
  head -c 32 /dev/urandom 2>/dev/null | base64 | tr '+/' '-_' | tr -d '=\n'
}

gen_port() {
  local raw p
  raw=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' \n')
  if [ -z "$raw" ] || ! [ "$raw" -ge 0 ] 2>/dev/null; then
    raw=$(( (${RANDOM:-32768} * 32768) + ${RANDOM:-32768} ))
  fi
  p=$(( raw % 55001 + 10000 ))
  [ "$p" -ge 10000 ] && [ "$p" -le 65000 ] || p=38443
  echo "$p"
}

load_or_create_state() {
  local pwlen
  mkdir -p "$CONF_DIR"
  if [ -f "$STATE_FILE" ]; then
    PORT=""
    PASSWORD=""
    # shellcheck disable=SC1090
    . "$STATE_FILE" 2>/dev/null || true
  fi
  if [ -z "$PORT" ] || ! printf '%s' "$PORT" | grep -Eq '^[0-9]+$' ||
     [ "$PORT" -lt 10000 ] || [ "$PORT" -gt 65000 ]; then
    PORT=$(gen_port)
  fi
  pwlen=$(printf '%s' "$PASSWORD" | wc -c | tr -d ' ')
  if [ -z "$PASSWORD" ] || ! printf '%s' "$PASSWORD" | grep -Eq '^[A-Za-z0-9_-]+$' ||
     [ "$pwlen" -lt 40 ]; then
    # 旧格式或异常时重建密码
    PASSWORD=$(gen_key)
  fi
  [ -n "$PASSWORD" ] || fail "无法生成随机 Key(/dev/urandom 不可用?)"
  umask 077
  printf 'PORT=%s\nPASSWORD=%s\n' "$PORT" "$PASSWORD" > "$STATE_FILE"
  umask 022
  log_info "服务端口: $PORT (已持久化到 $STATE_FILE)"
}

write_config() {
  mkdir -p "$CONF_DIR"
  cat > "$CONF_FILE" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-2022-in",
      "listen": "::",
      "listen_port": $PORT,
      "method": "$SS_METHOD",
      "password": "$PASSWORD",
      "network": "tcp,udp"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
  log_ok "配置已写入: $CONF_FILE"
}

install_service() {
  cat > "$INIT_FILE" <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=95
STOP=10

start_service() {
  procd_open_instance
  procd_set_param command /usr/bin/sing-box
  procd_append_param command run
  procd_append_param command -c
  procd_append_param command /etc/sing-box/config.json
  procd_set_param respawn 3600 5 5
  procd_set_param file /etc/sing-box/config.json
  procd_close_instance
}
EOF
  chmod 0755 "$INIT_FILE"
  "$INIT_FILE" enable 2>/dev/null || true
  "$INIT_FILE" restart 2>/dev/null || "$INIT_FILE" start 2>/dev/null || true
  sleep 1
  if { command -v pgrep >/dev/null 2>&1 && pgrep -f '/usr/bin/sing-box run' >/dev/null 2>&1; } ||
     pidof sing-box >/dev/null 2>&1; then
    log_ok "sing-box 服务已启动(开机自启)"
  else
    log_warn "sing-box 服务启动状态未知,可用 /etc/init.d/sing-box status 查看"
  fi
}

firewall_open() {
  uci -q delete "firewall.$FW_NAME"
  uci set "firewall.$FW_NAME=rule"
  uci set "firewall.$FW_NAME.name=$FIREWALL_RULE_NAME"
  uci set "firewall.$FW_NAME.src=wan"
  uci set "firewall.$FW_NAME.family=any"
  uci set "firewall.$FW_NAME.proto=tcpudp"
  uci set "firewall.$FW_NAME.dest_port=$PORT"
  uci set "firewall.$FW_NAME.target=ACCEPT"
  uci commit firewall
  log_ok "防火墙规则已写入(WAN 入站 tcp/udp $PORT, 名: $FIREWALL_RULE_NAME)"
}

firewall_reload() {
  if [ -x /etc/init.d/firewall ]; then
    /etc/init.d/firewall restart >/dev/null 2>&1
  elif command -v fw4 >/dev/null 2>&1; then
    fw4 reload >/dev/null 2>&1
  elif command -v fw3 >/dev/null 2>&1; then
    fw3 reload >/dev/null 2>&1
  fi
  log_ok "防火墙已重载"
}

detect_host() {
  local ip
  if [ -n "${SINGBOX_DOMAIN:-}" ]; then
    HOST="$SINGBOX_DOMAIN"
    log_info "使用域名生成链接: $HOST"
    return 0
  fi
  for u in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ifconfig.me/ip"; do
    ip=$(http_get "$u" 8)
    if [ -n "$ip" ] && printf '%s' "$ip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
      HOST="$ip"
      break
    fi
  done
  # 本地兜底:默认路由源地址
  if [ -z "$HOST" ] && command -v ip >/dev/null 2>&1; then
    HOST=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1)
  fi
  if [ -z "$HOST" ]; then
    log_warn "公网 IP 探测失败,链接中地址为空。可设置 SINGBOX_DOMAIN 后重跑"
    HOST="<你的公网IP或域名>"
  else
    case "$HOST" in
      10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|192.168.*|100.6[4-9].*|100.7[0-9].*|100.8[0-9].*|100.9[0-9].*|100.1[0-1][0-9].*|100.12[0-7].*)
        log_warn "检测到内网/运营商 NAT 地址 $HOST,若是 CGNAT 则外网无法直连"
        ;;
    esac
    log_info "公网地址: $HOST"
  fi
}

print_link() {
  local link
  link="ss://$SS_METHOD:$PASSWORD@$HOST:$PORT#sing-box-ss2022"
  echo
  echo "================================================================"
  log_ok "客户端连接信息:"
  echo "  协议: $SS_METHOD"
  echo "  服务器: $HOST:$PORT"
  echo "  密码(Key): $PASSWORD"
  echo
  echo "标准 ss:// 链接:"
  echo "  $link"
  echo
  echo "控制台命令:"
  echo "  /etc/init.d/sing-box status|restart|stop"
  echo "卸载: sh $0 uninstall"
  echo "================================================================"
  echo
}

install_main() {
  need_cmd uci uname head base64 tar
  [ "$(id -u 2>/dev/null)" = "0" ] || fail "请以 root 运行(OpenWrt 默认就是 root)"
  setup_downloader
  detect_arch
  detect_region
  resolve_version
  log_info "开始下载 sing-box v$SING_BOX_VERSION ..."
  fetch_and_extract || fail "sing-box 下载/安装失败(可尝试 GH_MIRROR 换镜像,或 SINGBOX_ARCH 强制架构)"
  load_or_create_state
  write_config
  install_service
  firewall_open
  firewall_reload
  detect_host
  print_link
}

uninstall_main() {
  log_info "开始卸载 sing-box ..."
  if [ -x "$INIT_FILE" ]; then
    "$INIT_FILE" stop >/dev/null 2>&1
    "$INIT_FILE" disable >/dev/null 2>&1
    rm -f "$INIT_FILE"
    log_ok "已停止并移除开机服务"
  fi
  rm -f "$BIN_FILE"
  rm -f "$CONF_FILE"
  log_ok "已删除: $BIN_FILE / $CONF_FILE"
  uci -q delete "firewall.$FW_NAME"
  uci commit firewall 2>/dev/null && log_ok "已删除防火墙通信规则"
  firewall_reload
  log_info "凭据文件 $STATE_FILE 已保留(卸载重装后端口/密码不变,链接不失效)"
  log_info "如确认不再使用,可手动执行: rm -f $STATE_FILE && rm -rf $CONF_DIR"
  log_ok "卸载完成"
}

usage() {
  cat <<EOF
singbox.sh - OpenWrt 一键安装/卸载 sing-box Shadowsocks-2022 服务端

用法:
  sh singbox.sh           安装(或更新)sing-box 并输出 ss:// 链接
  sh singbox.sh uninstall 卸载

可选环境变量:
  SINGBOX_DOMAIN=example.com   使用域名而非公网 IP 生成链接
  SINGBOX_ARCH=amd64           手动指定架构后缀(检测失败时用)
  SINGBOX_VERSION=1.13.14      固定安装版本(默认取最新稳定版)
  GH_MIRROR=https://ghfast.top 手动指定 GitHub 镜像前缀
EOF
}

main() {
  case "${1:-}" in
    ""|install)      install_main ;;
    uninstall|remove) uninstall_main ;;
    -h|--help|help)  usage ;;
    *)               log_err "未知参数: $1"; usage; exit 1 ;;
  esac
}

main "$@"

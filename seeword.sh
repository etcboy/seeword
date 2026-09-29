#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT=/etc/seeword
STATE=$ROOT/state.json
XRAY_BIN=/usr/local/bin/xray
XRAY_CONF=/etc/xray/config.json
XRAY_ASSETS=/usr/local/share/xray
OPENLIST_DIR=/opt/openlist
NGINX_CONF=/etc/nginx/conf.d/seeword.conf
ACME_TMP_CONF=/etc/nginx/conf.d/seeword-acme.conf
ACME_WEBROOT=/var/www/seeword
CERT_ROOT=/etc/nginx/zs
ACME=/root/.acme.sh/acme.sh
SELF=/usr/local/bin/seeword
TMP_DIR=
INIT=
PKG=
LOG_FILE=/var/log/seeword.log

step() { printf '\n== [%s/%s] %s ==\n' "$1" "$2" "$3"; }

confirm_go() {
  local ans
  read -r -p "$1 [y/N]：" ans
  [[ ${ans,,} == y ]] || { say '已取消。'; return 1; }
}
# 安装确认：默认 Y，回车即继续
confirm_install() {
  local ans
  read -r -p "$1 [Y/n]：" ans
  [[ ${ans,,} == n ]] && { say '已取消。'; return 1; }
  return 0
}

take_lock() {
  command -v flock >/dev/null 2>&1 || err '缺少 flock 工具。'
  exec 200>/run/seeword.lock 2>/dev/null || err '无法创建锁文件 /run/seeword.lock。'
  flock -n 200 || err '另一个 seeword 正在运行，请稍后再试。'
}

setup_logging() {
  [[ -d /var/log ]] || install -d -m 755 /var/log
  touch "$LOG_FILE" 2>/dev/null || return 0
  chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

open_firewall_port() {
  local proto=$1 port=$2
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "$port/$proto" >/dev/null 2>&1 || true
    return 0
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$port/$proto" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    return 0
  fi
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 || \
      iptables -I INPUT 1 -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
  fi
  # IPv6 同样放行（ufw/firewalld 已自动处理双栈，这里补裸 iptables 的情况）
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 || \
      ip6tables -I INPUT 1 -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
  fi
}

say() { printf '%s\n' "$*"; }
err() { printf '错误：%s\n' "$*" >&2; exit 1; }
# 系统是否有 IPv6 协议栈（注意：/proc 文件 ls 显示大小为 0，不能用 -s 判断，必须读内容）
has_ipv6() { grep -q . /proc/net/if_inet6 2>/dev/null; }
cleanup() {
  if [[ -f $ACME_TMP_CONF ]]; then
    rm -f -- "$ACME_TMP_CONF"
    if [[ -n $INIT ]] && command -v nginx >/dev/null 2>&1; then nginx -t >/dev/null 2>&1 && svc reload nginx >/dev/null 2>&1 || true; fi
  fi
  [[ -z ${TMP_DIR:-} ]] || rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

require_root() { [[ $EUID -eq 0 ]] || err '请以 root 身份运行。'; }
init_tmp() { [[ -n $TMP_DIR ]] || TMP_DIR=$(mktemp -d); }
state_init() {
  install -d -m 700 "$ROOT" /etc/xray "$XRAY_ASSETS"
  [[ -f $STATE ]] || printf '%s\n' '{"version":2,"reality":null,"hy2":null,"ss":null}' > "$STATE"
  chmod 600 "$STATE"
  migrate_state
}

# 将旧版 state（顶层共用 domain、reality/hy2 无独立域名端口、单用户）升级到 v2。
migrate_state() {
  [[ -f $STATE ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local v tmp
  v=$(jq -r '.version // 1' "$STATE" 2>/dev/null || echo 1)
  (( v >= 2 )) && return 0
  tmp=$(mktemp)
  jq '
    .version = 2
    | (if .reality and ((.reality.domain // "") == "") then .reality.domain = (.domain // "") | .reality.port = 443 else . end)
    | (if .reality and ((.reality.users // []) | length) == 0 and ((.reality.uuid // "") != "") then .reality.users = [{uuid: .reality.uuid, remark: "默认"}] else . end)
    | (if .reality and ((.reality.fallback // 0) == 0) then .reality.fallback = 8443 else . end)
    | (if .hy2 and ((.hy2.domain // "") == "") then .hy2.domain = (.domain // "") | .hy2.port = 443 else . end)
    | del(.domain)' "$STATE" > "$tmp" && install -m 600 "$tmp" "$STATE"
  rm -f "$tmp"
  say '状态文件已升级到新版本。' >&2
}
# 任何读取 state 的入口都先确保迁移已执行（幂等）。
_STATE_MIGRATED=
load_state() {
  [[ -n ${_STATE_MIGRATED:-} ]] && return 0
  _STATE_MIGRATED=1
  migrate_state
}
state_get() { load_state; jq -r "$1 // empty" "$STATE"; }
has_reality() { load_state; [[ $(jq -r '.reality != null' "$STATE") == true ]]; }
has_hy2() { load_state; [[ $(jq -r '.hy2 != null' "$STATE") == true ]]; }
has_ss() { load_state; [[ $(jq -r '.ss != null' "$STATE") == true ]]; }

detect_env() {
  [[ $(uname -s) == Linux ]] || err '仅支持 Linux。'
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then INIT=systemd
  elif command -v rc-service >/dev/null 2>&1; then INIT=openrc
  else err '需要 systemd 或 OpenRC。'; fi
  if command -v apt-get >/dev/null 2>&1; then PKG=apt
  elif command -v dnf >/dev/null 2>&1; then PKG=dnf
  elif command -v yum >/dev/null 2>&1; then PKG=yum
  elif command -v apk >/dev/null 2>&1; then PKG=apk
  else err '仅支持 apt、dnf、yum 或 apk 管理的发行版。'; fi
}
pkg_install() {
  case $PKG in
    apt) DEBIAN_FRONTEND=noninteractive apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
    apk) apk add --no-cache "$@" ;;
  esac
}
pkg_remove() {
  case $PKG in
    apt) DEBIAN_FRONTEND=noninteractive apt-get purge -y "$@" ;;
    dnf) dnf remove -y "$@" ;;
    yum) yum remove -y "$@" ;;
    apk) apk del "$@" ;;
  esac
}
ensure_deps() {
  local missing=() cmd
  for cmd in curl jq openssl unzip tar; do command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd"); done
  if ((${#missing[@]})); then pkg_install "${missing[@]}"; fi
  if ! command -v qrencode >/dev/null 2>&1; then
    if [[ $PKG == apk ]]; then pkg_install libqrencode
    elif [[ $PKG == dnf || $PKG == yum ]]; then
      if ! pkg_install qrencode; then pkg_install epel-release; pkg_install qrencode; fi
    else pkg_install qrencode; fi
  fi
  command -v qrencode >/dev/null 2>&1 || err '无法安装 qrencode，无法生成二维码。'
  if ! command -v ss >/dev/null 2>&1; then
    if [[ $PKG == dnf || $PKG == yum ]]; then pkg_install iproute
    else pkg_install iproute2; fi
  fi
  command -v ss >/dev/null 2>&1 || err '缺少 ss（iproute2）端口检查工具。'
}
ensure_web_deps() { command -v nginx >/dev/null 2>&1 || pkg_install nginx; }
# 一键安装本脚本所需的全部依赖（含 acme.sh 需要的 cron、Web 协议需要的 Nginx）
cmd_deps() {
  require_root; detect_env
  ensure_deps
  if ! command -v crontab >/dev/null 2>&1; then
    case $PKG in apt) pkg_install cron ;; dnf|yum) pkg_install cronie ;; apk) pkg_install dcron ;; esac
  fi
  ensure_web_deps
  say '依赖安装完成。'
}
# 极精简系统 apt 源缺失时，写入 Debian/Ubuntu 官方源（先备份原文件）
fix_apt_sources() {
  if grep -rqE --include='*.list' '^[[:space:]]*deb([[:space:]]|$)' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    say '检测到有效的 apt 源。'
  else
    say '未检测到有效的 apt 源。'
    local id codename fw=
    id=$(grep -E '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    codename=$(grep -E '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    [[ -n $codename ]] || err '无法识别系统版本代号，请手动配置 apt 源。'
    confirm_go "将写入 $id $codename 的官方源" || return 1
    [[ -f /etc/apt/sources.list ]] && cp -a /etc/apt/sources.list /etc/apt/sources.list.bak
    case $id in
      debian)
        case $codename in bookworm|trixie|forky|duke) fw=' non-free-firmware' ;; esac
        cat > /etc/apt/sources.list <<EOF
deb https://deb.debian.org/debian $codename main contrib non-free$fw
deb https://deb.debian.org/debian $codename-updates main contrib non-free$fw
deb https://deb.debian.org/debian-security $codename-security main contrib non-free$fw
EOF
        ;;
      ubuntu)
        cat > /etc/apt/sources.list <<EOF
deb https://archive.ubuntu.com/ubuntu $codename main restricted universe multiverse
deb https://archive.ubuntu.com/ubuntu $codename-updates main restricted universe multiverse
deb https://archive.ubuntu.com/ubuntu $codename-security main restricted universe multiverse
EOF
        ;;
      *) err "暂不支持为 $id 自动生成 apt 源，请手动配置。" ;;
    esac
    say '已写入官方源（原文件已备份为 /etc/apt/sources.list.bak）。'
  fi
  DEBIAN_FRONTEND=noninteractive apt-get update || err 'apt update 失败，请检查网络。'
}
# 修复极精简系统的软件源/DNS/网络环境，使依赖能够安装
fixenv() {
  require_root; detect_env
  say '== 检查外网连通性 =='
  if timeout 8 bash -c '</dev/tcp/1.1.1.1/443' 2>/dev/null; then
    say '外网连通正常。'
  else
    err '无法连接外网（1.1.1.1:443），请先检查服务器网络后再试。'
  fi
  say '== 检查 DNS 解析 =='
  if timeout 8 bash -c '</dev/tcp/deb.debian.org/443' 2>/dev/null; then
    say 'DNS 解析正常。'
  elif [[ -L /etc/resolv.conf ]]; then
    err 'DNS 解析失败，且 /etc/resolv.conf 由其他程序管理，请手动检查 DNS 配置。'
  else
    say 'DNS 解析失败，尝试写入公共 DNS（1.1.1.1 / 8.8.8.8）。'
    [[ -f /etc/resolv.conf ]] && cp -a /etc/resolv.conf /etc/resolv.conf.bak
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
    timeout 8 bash -c '</dev/tcp/deb.debian.org/443' 2>/dev/null || err 'DNS 仍不可用，请手动排查。'
    say 'DNS 已修复（原文件已备份为 /etc/resolv.conf.bak）。'
  fi
  say '== 检查软件源 =='
  case $PKG in
    apt) fix_apt_sources ;;
    dnf|yum) "$PKG" makecache -y >/dev/null 2>&1 || err '软件源缓存刷新失败。' ;;
    apk) apk update >/dev/null 2>&1 || err '软件源更新失败。' ;;
  esac
  say '== 安装基础下载工具 =='
  case $PKG in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates ;;
    *) pkg_install curl ca-certificates ;;
  esac
  command -v curl >/dev/null 2>&1 || err 'curl 仍安装失败，请手动排查后重试。'
  say '环境修复完成，接下来可运行 `seeword deps` 安装全部依赖。'
}
svc() {
  local action=$1 name=$2
  if [[ $INIT == systemd ]]; then systemctl "$action" "$name"
  else
    case $action in
      enable) rc-update add "$name" default ;;
      disable) rc-update del "$name" default ;;
      *) rc-service "$name" "$action" ;;
    esac
  fi
}
svc_active() {
  local name=$1
  if [[ $INIT == systemd ]]; then systemctl is-active --quiet "$name"
  else rc-service "$name" status >/dev/null 2>&1; fi
}
restart_or_start() { if svc_active "$1"; then svc restart "$1"; else svc start "$1"; fi; }

arch_names() {
  local arch=${1:-$(uname -m)}
  case "$arch" in
    x86_64|amd64) XRAY_ASSET=Xray-linux-64.zip; OPENLIST_ASSET=openlist-linux-musl-amd64.tar.gz ;;
    i386|i486|i586|i686) XRAY_ASSET=Xray-linux-32.zip; OPENLIST_ASSET=openlist-linux-386.tar.gz ;;
    aarch64|arm64) XRAY_ASSET=Xray-linux-arm64-v8a.zip; OPENLIST_ASSET=openlist-linux-musl-arm64.tar.gz ;;
    armv7*|armhf) XRAY_ASSET=Xray-linux-arm32-v7a.zip; OPENLIST_ASSET=openlist-linux-musleabihf-armv7l.tar.gz ;;
    armv6*) XRAY_ASSET=Xray-linux-arm32-v6.zip; OPENLIST_ASSET=openlist-linux-musleabihf-armv6.tar.gz ;;
    armv5*) XRAY_ASSET=Xray-linux-arm32-v5.zip; OPENLIST_ASSET=openlist-linux-musleabihf-armv5l.tar.gz ;;
    loongarch64|loong64) XRAY_ASSET=Xray-linux-loong64.zip; OPENLIST_ASSET=openlist-linux-musl-loong64.tar.gz ;;
    mips) XRAY_ASSET=Xray-linux-mips32.zip; OPENLIST_ASSET=openlist-linux-musl-mips.tar.gz ;;
    mipsel|mipsle) XRAY_ASSET=Xray-linux-mips32le.zip; OPENLIST_ASSET=openlist-linux-musl-mipsle.tar.gz ;;
    mips64) XRAY_ASSET=Xray-linux-mips64.zip; OPENLIST_ASSET=openlist-linux-musl-mips64.tar.gz ;;
    mips64el|mips64le) XRAY_ASSET=Xray-linux-mips64le.zip; OPENLIST_ASSET=openlist-linux-musl-mips64le.tar.gz ;;
    ppc64le) XRAY_ASSET=Xray-linux-ppc64le.zip; OPENLIST_ASSET=openlist-linux-musl-ppc64le.tar.gz ;;
    ppc64) XRAY_ASSET=Xray-linux-ppc64.zip; OPENLIST_ASSET=openlist-linux-ppc64.tar.gz ;;
    riscv64) XRAY_ASSET=Xray-linux-riscv64.zip; OPENLIST_ASSET=openlist-linux-riscv64.tar.gz ;;
    s390x) XRAY_ASSET=Xray-linux-s390x.zip; OPENLIST_ASSET=openlist-linux-musl-s390x.tar.gz ;;
    *) err "不支持的架构：$arch" ;;
  esac
}
release_asset() {
  local repo=$1 asset=$2 dest=$3 metadata url digest actual
  metadata=$(curl -fsSL --retry 3 "https://api.github.com/repos/$repo/releases/latest") || err "获取 $repo 发布信息失败。"
  url=$(jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .browser_download_url' <<< "$metadata" | head -n 1)
  [[ -n $url ]] || err "$repo 最新正式版未发布 $asset。"
  digest=$(jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .digest // empty' <<< "$metadata" | head -n 1)
  [[ $digest == sha256:* ]] || err "$repo 的 $asset 缺少 SHA-256 校验信息。"
  curl -fL --retry 3 --output "$dest" "$url" || err "下载 $asset 失败。"
  actual=$(sha256sum "$dest" | cut -d' ' -f1)
  [[ $actual == "${digest#sha256:}" ]] || err "$asset SHA-256 校验失败。"
  say "已验证 $asset"
}

# Follow XTLS/Xray-install's release URL and .dgst SHA-256 verification scheme.
# Keep our own service and configuration so Reality, HY2 and SS remain independent.
download_xray_official() {
  local asset=$1 dest=$2 metadata tag url expected actual
  metadata=$(curl -fsSL --retry 3 https://api.github.com/repos/XTLS/Xray-core/releases/latest) || err '获取 Xray 官方发布信息失败。'
  tag=$(jq -r '.tag_name // empty' <<< "$metadata")
  [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.-]+)?$ ]] || err 'Xray 官方版本号无效。'
  jq -e --arg name "$asset" '.assets[] | select(.name == $name)' <<< "$metadata" >/dev/null || err "Xray 官方版本 $tag 未提供 $asset。"
  url="https://github.com/XTLS/Xray-core/releases/download/$tag/$asset"
  curl -fL --retry 3 --output "$dest" "$url" || err "下载 Xray 官方文件 $asset 失败。"
  curl -fL --retry 3 --output "$dest.dgst" "$url.dgst" || err "下载 $asset.dgst 校验文件失败。"
  expected=$(awk -F '= ' '/256=/ {print $2; exit}' "$dest.dgst" | tr -d '\r\n')
  [[ $expected =~ ^[[:xdigit:]]{64}$ ]] || err 'Xray 官方校验文件格式无效。'
  actual=$(sha256sum "$dest" | cut -d' ' -f1)
  [[ ${actual,,} == ${expected,,} ]] || err "$asset SHA-256 校验失败。"
  say "已按 XTLS/Xray-install 官方方式验证 $asset ($tag)"
}

install_xray_core() {
  init_tmp; arch_names
  download_xray_official "$XRAY_ASSET" "$TMP_DIR/xray.zip"
  unzip -q -o "$TMP_DIR/xray.zip" -d "$TMP_DIR/xray-new"
  [[ -f $TMP_DIR/xray-new/xray && -f $TMP_DIR/xray-new/geoip.dat && -f $TMP_DIR/xray-new/geosite.dat ]] || err 'Xray 归档缺少必需文件。'
  chmod 755 "$TMP_DIR/xray-new/xray"
  "$TMP_DIR/xray-new/xray" version >/dev/null || err '下载的 Xray 内核无法运行。'
  if [[ -f $XRAY_CONF ]]; then "$TMP_DIR/xray-new/xray" run -test -config "$XRAY_CONF" || err '新内核与现有配置不兼容。'; fi
  install -d -m 755 "$XRAY_ASSETS" /etc/xray
  [[ ! -x $XRAY_BIN ]] || cp -a "$XRAY_BIN" "$TMP_DIR/xray-old"
  [[ ! -f $XRAY_ASSETS/geoip.dat ]] || cp -a "$XRAY_ASSETS/geoip.dat" "$TMP_DIR/geoip-old"
  [[ ! -f $XRAY_ASSETS/geosite.dat ]] || cp -a "$XRAY_ASSETS/geosite.dat" "$TMP_DIR/geosite-old"
  install -m 755 "$TMP_DIR/xray-new/xray" "$XRAY_BIN"
  install -m 644 "$TMP_DIR/xray-new/geoip.dat" "$XRAY_ASSETS/geoip.dat"
  install -m 644 "$TMP_DIR/xray-new/geosite.dat" "$XRAY_ASSETS/geosite.dat"
  if [[ -f $XRAY_CONF ]]; then
    if ! restart_or_start seeword; then
      [[ ! -f $TMP_DIR/xray-old ]] || install -m 755 "$TMP_DIR/xray-old" "$XRAY_BIN"
      [[ ! -f $TMP_DIR/geoip-old ]] || install -m 644 "$TMP_DIR/geoip-old" "$XRAY_ASSETS/geoip.dat"
      [[ ! -f $TMP_DIR/geosite-old ]] || install -m 644 "$TMP_DIR/geosite-old" "$XRAY_ASSETS/geosite.dat"
      restart_or_start seeword || true
      err 'Xray 更新后启动失败，已恢复旧内核。'
    fi
  fi
  say "Xray 内核与地理数据已更新：$($XRAY_BIN version | sed -n '1p')"
}

install_xray_service() {
  if [[ $INIT == systemd ]]; then
    cat > /etc/systemd/system/seeword.service <<EOF
[Unit]
Description=Seeword service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=XRAY_LOCATION_ASSET=$XRAY_ASSETS
ExecStart=$XRAY_BIN run -c $XRAY_CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    # Use a dedicated unit name to avoid replacing an existing Xray installation.
    systemctl daemon-reload
    systemctl enable seeword >/dev/null
  else
    cat > /etc/init.d/seeword <<EOF
#!/sbin/openrc-run
name="Seeword"
command="$XRAY_BIN"
command_args="run -c $XRAY_CONF"
command_background=true
pidfile="/run/seeword.pid"
export XRAY_LOCATION_ASSET="$XRAY_ASSETS"
depend() { need net; }
EOF
    chmod 755 /etc/init.d/seeword
    rc-update add seeword default >/dev/null
  fi
}

render_config() {
  local input=$1 output=$2
  # 双栈监听：有 IPv6 时用 ::（Linux 默认双栈，同时接受 v4/v6），纯 v4 时用 0.0.0.0
  local listen=0.0.0.0
  has_ipv6 && listen='::'
  jq -n --slurpfile state "$input" --arg listen "$listen" '
    $state[0] as $s |
    {log:{loglevel:"warning"},
     api:{tag:"api",services:["StatsService"]},
     stats:{},
     policy:{levels:{"0":{statsUserUplink:true,statsUserDownlink:true}}},
     routing:{rules:[{type:"field",inboundTag:["api"],outboundTag:"api"}]},
     inbounds:(
      (if $s.reality then [{tag:"reality",listen:$listen,port:$s.reality.port,protocol:"vless",
        settings:{clients:[$s.reality.users[] | {id:.uuid,flow:"xtls-rprx-vision",email:("reality:"+.uuid)}],decryption:"none"},
        streamSettings:{network:"tcp",security:"reality",
          realitySettings:{target:"127.0.0.1:\($s.reality.fallback // 8443)",serverNames:[$s.reality.domain],privateKey:$s.reality.private,shortIds:[$s.reality.sid]}}}] else [] end)
      + (if $s.hy2 then [{tag:"hy2",listen:$listen,port:$s.hy2.port,protocol:"hysteria",
        settings:{version:2,clients:[{auth:$s.hy2.password,email:"hy2"}]},
        streamSettings:{network:"hysteria",security:"tls",
          hysteriaSettings:{version:2,auth:$s.hy2.password,masquerade:{type:"proxy",url:"http://127.0.0.1:5244"}},
          tlsSettings:{alpn:["h3"],certificates:[{certificateFile:$s.hy2.cert,keyFile:$s.hy2.key}]}}}] else [] end)
      + (if $s.ss then [{tag:"ss",listen:$listen,port:$s.ss.port,protocol:"shadowsocks",
        settings:{method:"2022-blake3-aes-128-gcm",password:$s.ss.password,network:"tcp,udp"}}] else [] end)
      + [{tag:"api",listen:"127.0.0.1",port:10085,protocol:"dokodemo-door",settings:{address:"127.0.0.1"}}]
    ),outbounds:[{protocol:"freedom",tag:"direct"}]}
  ' > "$output"
}

rollback_nginx() {
  [[ -f $TMP_DIR/nginx-staged ]] || return 0
  if [[ -f $TMP_DIR/nginx-old ]]; then cp -a "$TMP_DIR/nginx-old" "$NGINX_CONF"
  else rm -f "$NGINX_CONF"; fi
  restart_or_start nginx || true
}

commit_state() {
  local new_state=$1 conf_bak=$TMP_DIR/config-old state_bak=$TMP_DIR/state-old
  render_config "$new_state" "$TMP_DIR/config-new"
  "$XRAY_BIN" run -test -format json -config "$TMP_DIR/config-new" || { rollback_nginx; err 'Xray 配置验证失败。'; }
  cp -a "$STATE" "$state_bak"
  [[ ! -f $XRAY_CONF ]] || cp -a "$XRAY_CONF" "$conf_bak"
  install -m 600 "$new_state" "$STATE"
  install -m 600 "$TMP_DIR/config-new" "$XRAY_CONF"
  install_xray_service
  if ! restart_or_start seeword; then
    install -m 600 "$state_bak" "$STATE"
    if [[ -f $conf_bak ]]; then install -m 600 "$conf_bak" "$XRAY_CONF"; else rm -f "$XRAY_CONF"; fi
    restart_or_start seeword || true
    rollback_nginx
    err 'Xray 启动失败，已恢复原有配置。'
  fi
}

valid_domain() {
  [[ $1 =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] && ((${#1} <= 253))
}
# 解析域名全部 IP（每行一个），尽力而为
resolve_ips() {
  local d=$1
  if command -v getent >/dev/null 2>&1; then
    getent ahosts "$d" 2>/dev/null | awk '{print $1}' | sort -u
  elif command -v dig >/dev/null 2>&1; then
    { dig +short A "$d" 2>/dev/null; dig +short AAAA "$d" 2>/dev/null; } | sort -u
  elif command -v host >/dev/null 2>&1; then
    host "$d" 2>/dev/null | awk '/has (IPv6 )?address/{print $NF}' | sort -u
  elif command -v nslookup >/dev/null 2>&1; then
    nslookup "$d" 2>/dev/null | awk '/^Address: / && $2 !~ /#/{print $2}' | sort -u
  fi
}
# 输入域名/SNI 后检查 DNS：A 记录比公网 v4，AAAA 记录比公网 v6
check_domain_dns() {
  local domain=$1 ip pub4 pub6
  local -a a_list=() aaaa_list=()
  say "正在检查域名 $domain 的 DNS 解析…"
  while IFS= read -r ip; do
    [[ -n $ip ]] || continue
    if [[ $ip == *:* ]]; then aaaa_list+=("$ip"); else a_list+=("$ip"); fi
  done < <(resolve_ips "$domain")
  if (( ${#a_list[@]} == 0 && ${#aaaa_list[@]} == 0 )); then
    if ! command -v getent >/dev/null 2>&1 && ! command -v dig >/dev/null 2>&1 \
      && ! command -v host >/dev/null 2>&1 && ! command -v nslookup >/dev/null 2>&1; then
      say '本机缺少 DNS 查询工具，跳过 DNS 检查（请手动确认域名已解析到本机）。'
      return 0
    fi
    err "域名 $domain 未能解析到任何 IP，请先做好 DNS 解析再安装。"
  fi
  # 本机公网 IP
  pub4=$(curl -4 -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || true)
  pub6=$(curl -6 -fsSL --max-time 5 https://api64.ipify.org 2>/dev/null || true)
  say "DNS 解析结果："
  if (( ${#aaaa_list[@]} > 0 )); then say "  AAAA（IPv6）：${aaaa_list[*]}"; else say '  AAAA（IPv6）：无'; fi
  if (( ${#a_list[@]} > 0 )); then say "  A（IPv4）：${a_list[*]}"; else say '  A（IPv4）：无'; fi
  say "本机公网 IP：IPv4=${pub4:-无} IPv6=${pub6:-无}"
  # 核对：A 记录比公网 v4，AAAA 记录比公网 v6，对上即正确
  local v4_ok=0 v6_ok=0
  if (( ${#a_list[@]} > 0 )) && [[ -n $pub4 ]]; then
    for ip in "${a_list[@]}"; do
      [[ $ip == "$pub4" ]] && { v4_ok=1; break; }
    done
  fi
  if (( ${#aaaa_list[@]} > 0 )) && [[ -n $pub6 ]]; then
    for ip in "${aaaa_list[@]}"; do
      [[ $ip == "$pub6" ]] && { v6_ok=1; break; }
    done
  fi
  if (( v4_ok || v6_ok )); then
    say '结论：域名解析正确，指向本机。'
  else
    say '警告：域名解析到的 IP 与本机公网 IP 不一致，HTTP 证书验证很可能失败。'
    confirm_go '仍要继续安装' || return 1
  fi
}
ask_domain() {
  local proto=$1 other_domain input prompt label
  if [[ $proto == reality ]]; then label='Reality'; else label='HY2'; fi
  if [[ $proto == reality ]]; then other_domain=$(state_get '.hy2.domain')
  else other_domain=$(state_get '.reality.domain'); fi
  if [[ -n $other_domain ]]; then
    prompt="请输入 $label 的域名/SNI（回车沿用 $other_domain）："
  else
    prompt="请输入 $label 的域名/SNI（如 a.example.com）："
  fi
  read -r -p "$prompt" input
  input=${input:-$other_domain}
  input=${input,,}
  valid_domain "$input" || err '域名格式不正确。'
  DOMAIN=$input
  check_domain_dns "$DOMAIN" || return 1
}

ask_port() {
  local _var=$1 proto=$2 default=$3 prompt=$4 input
  read -r -p "$prompt（默认 $default）：" input
  input=${input:-$default}
  [[ $input =~ ^[0-9]+$ ]] || err '端口无效。'
  (( input >= 1 && input <= 65535 )) || err '端口无效。'
  check_port_free "$proto" "$input"
  printf -v "$_var" '%s' "$input"
}

# Reality 端口询问：TCP 443 若被本站点 Nginx 占用，允许接管（Nginx 443 块会自动让位，
# Web 界面改走 Reality 回落，继续可用）。
ask_reality_port() {
  local input
  read -r -p 'Reality TCP 端口（默认 443）：' input
  input=${input:-443}
  [[ $input =~ ^[0-9]+$ ]] || err '端口无效。'
  (( input >= 1 && input <= 65535 )) || err '端口无效。'
  (( input != 80 )) || err '80 为保留端口，请换一个。'
  (( input < 8443 || input > 8462 )) || err '8443-8462 为 Reality 回落保留端口段，请换一个。'
  if (( input == 443 )) && [[ -f $NGINX_CONF ]] && grep -qE 'listen[[:space:]]+443' "$NGINX_CONF"; then
    say '提示：TCP 443 当前由本站点 Nginx 提供 Web 服务，安装后将交由 Reality 接管（Web 界面改走 Reality 回落，继续可用）。'
  else
    check_port_free tcp "$input"
  fi
  RPORT=$input
}

cert_dir() { printf '%s/%s' "$CERT_ROOT" "$1"; }

# 某个域名的证书验证方式：优先读该域名目录下的 method，回退旧版全局文件。
cert_method() {
  local f
  f=$(cert_dir "$1")/method
  if [[ -f $f ]]; then cat "$f"
  elif [[ -f $ROOT/cert-method ]]; then cat "$ROOT/cert-method"
  fi
}
check_port_free() {
  local proto=$1 port=$2
  if [[ $proto == tcp ]]; then
    [[ -z $(ss -H -ltn "sport = :$port" 2>/dev/null) ]] || err "TCP $port 已被占用。"
  else
    [[ -z $(ss -H -lun "sport = :$port" 2>/dev/null) ]] || err "UDP $port 已被占用。"
  fi
}
# Reality 回落内部端口：优先 8443，被占用时依次尝试 8444、8445…
# 回落只是 Xray 转发非 Reality 流量的本地目标，端口号不影响功能
# $1 可选：要排除的端口（用户选的 Reality 公网端口）
find_reality_fallback_port() {
  local p exclude=${1:-0}
  for p in $(seq 8443 8462); do
    (( p != exclude )) || continue
    if [[ -z $(ss -H -ltn "sport = :$p" 2>/dev/null) ]]; then
      printf '%s' "$p"
      return 0
    fi
  done
  err '8443-8462 均被占用，无法为 Reality 分配回落端口。'
}
# TCP 80 是否可用于 HTTP 证书验证：Nginx 在运行（可复用/接管），或 80 端口空闲
http80_usable() {
  svc_active nginx && return 0
  [[ -z $(ss -H -ltn "sport = :80" 2>/dev/null) ]]
}
preflight_web() {
  # 安装首个 Web 协议前的通用检查；Reality 回落端口由 find_reality_fallback_port 动态分配，HY2 不需要
  :
  # OpenList 已改为独立安装，其 5244 端口由独立安装流程检查
}

install_acme() {
  if [[ ! -x $ACME ]]; then
    if ! command -v crontab >/dev/null 2>&1; then
      case $PKG in apt) pkg_install cron ;; dnf|yum) pkg_install cronie ;; apk) pkg_install dcron ;; esac
    fi
    curl -fsSL https://get.acme.sh | sh || err '安装 acme.sh 失败。'
    [[ -x $ACME ]] || err '找不到 acme.sh。'
  fi
  "$ACME" --set-default-ca --server letsencrypt
}
# 确保 $1 域名在 TCP 80 上有可用的 HTTP 验证站点（acme.sh webroot 模式用）。
# 已有配置覆盖该域名时直接复用，否则追加临时站点（随 EXIT trap 自动清理）。
ensure_http_challenge() {
  local domain=$1 ipv6_http= esc
  esc=${domain//./\\.}
  install -d -m 755 "$ACME_WEBROOT/.well-known/acme-challenge"
  if { [[ -f $NGINX_CONF ]] && grep -qE "server_name[^;]*$esc([ ;]|$)" "$NGINX_CONF"; } \
    || { [[ -f $ACME_TMP_CONF ]] && grep -qE "server_name[^;]*$esc([ ;]|$)" "$ACME_TMP_CONF"; }; then
    return 0
  fi
  if ! svc_active nginx; then check_port_free tcp 80; fi
  if has_ipv6; then ipv6_http='listen [::]:80;'; fi
  cat >> "$ACME_TMP_CONF" <<EOF
server {
    listen 80;
    $ipv6_http
    server_name $domain;
    location ^~ /.well-known/acme-challenge/ { root $ACME_WEBROOT; }
    location / { return 404; }
}
EOF
  nginx -t || err 'Nginx HTTP 验证站点配置失败。'
  restart_or_start nginx || err 'Nginx 无法启动 HTTP 验证站点。'
}
issue_cert() {
  local domain=$1 dir owner token zone method_file old_dir
  dir=$(cert_dir "$domain")
  owner=$dir/domain.txt
  method_file=$dir/method
  # 迁移旧版“域名首段”命名的证书目录
  old_dir=$(printf '%s/%s' "$CERT_ROOT" "${domain%%.*}")
  if [[ $old_dir != "$dir" && ! -d $dir && -d $old_dir && -f $old_dir/domain.txt && $(cat "$old_dir/domain.txt") == "$domain" ]]; then
    mv "$old_dir" "$dir"
    say "已迁移旧证书目录 $old_dir → $dir"
  fi
  if [[ -f $owner && $(cat "$owner") != "$domain" ]]; then
    err "证书目录 $dir 已属于 $(cat "$owner")，域名冲突。"
  fi
  if [[ -d $dir && ! -f $owner && -n $(find "$dir" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    err "证书目录 $dir 已有非本脚本管理的文件，停止以避免覆盖。"
  fi
  install -d -m 700 "$dir"
  printf '%s\n' "$domain" > "$owner"
  chmod 600 "$owner"
  # 迁移旧版全局验证方式记录
  if [[ ! -f $method_file && -f $ROOT/cert-method ]]; then
    cp -a "$ROOT/cert-method" "$method_file"
  fi
  if [[ -f $dir/fullchain.pem && -f $dir/privkey.pem ]] && openssl x509 -checkend 604800 -noout -in "$dir/fullchain.pem" >/dev/null 2>&1; then
    say '现有证书仍有效，继续使用。'
    if [[ ! -f $method_file ]]; then printf 'http\n' > "$method_file"; chmod 600 "$method_file"; fi
    return
  fi
  install_acme
  # 优先 TCP 80 验证；80 被占用时自动改用 DNS 验证；HTTP 失败时询问是否切 DNS
  if http80_usable; then
    CERT_METHOD=http
    say 'TCP 80 可用，使用 HTTP 验证申请证书。'
    ensure_http_challenge "$domain"
    if ! "$ACME" --issue --server letsencrypt --webroot "$ACME_WEBROOT" -d "$domain" --keylength ec-256; then
      say 'HTTP 80 证书申请失败：可能域名未解析到本机，或 TCP 80 未放行（含云安全组、IPv6 防火墙）。'
      if confirm_install '是否改用 Cloudflare DNS API 验证'; then
        CERT_METHOD=dns
      else
        err '已取消证书申请。'
      fi
    fi
  else
    CERT_METHOD=dns
    say 'TCP 80 被占用，改用 Cloudflare DNS API 验证申请证书。'
  fi
  if [[ $CERT_METHOD == dns ]]; then
    read -r -s -p 'Cloudflare DNS API Token：' token; printf '\n'
    [[ -n $token ]] || err 'Token 不能为空。'
    read -r -p 'Cloudflare Zone ID（可留空自动查找）：' zone
    if ! CF_Token="$token" CF_Zone_ID="$zone" "$ACME" --issue --server letsencrypt --dns dns_cf -d "$domain" --keylength ec-256; then
      unset token; err 'Cloudflare DNS 证书申请失败。'
    fi
    unset token
  fi
  printf '%s\n' "$CERT_METHOD" > "$method_file"
  chmod 600 "$method_file"
  "$ACME" --install-cert -d "$domain" --ecc \
    --key-file "$dir/privkey.pem" \
    --fullchain-file "$dir/fullchain.pem" \
    --reloadcmd "$SELF reload" || err '证书安装失败。'
  chmod 600 "$dir/privkey.pem" "$owner"
  chmod 644 "$dir/fullchain.pem"
}

install_openlist_service() {
  if [[ $INIT == systemd ]]; then
    cat > /etc/systemd/system/openlist.service <<EOF
[Unit]
Description=Personal OpenList service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$OPENLIST_DIR
ExecStart=$OPENLIST_DIR/openlist server
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable openlist >/dev/null
  else
    cat > /etc/init.d/openlist <<EOF
#!/sbin/openrc-run
name="Personal OpenList"
directory="$OPENLIST_DIR"
command="$OPENLIST_DIR/openlist"
command_args="server"
command_background=true
pidfile="/run/openlist.pid"
depend() { need net; }
EOF
    chmod 755 /etc/init.d/openlist
    rc-update add openlist default >/dev/null
  fi
}
install_openlist() {
  local domain=$1 binary pass config jwt site_url
  site_url=${domain:+https://$domain}
  if [[ -x $OPENLIST_DIR/openlist ]]; then
    [[ -f $ROOT/openlist-owned ]] || err "$OPENLIST_DIR 已存在非本脚本安装的 OpenList。"
    install_openlist_service
    if ! svc_active openlist; then svc start openlist || err 'OpenList 无法重新启动。'; fi
    if [[ ! -f $ROOT/openlist-password ]]; then
      pass=$(openssl rand -hex 18)
      (cd "$OPENLIST_DIR" && ./openlist admin set "$pass") || err '无法恢复 OpenList 管理员密码。'
      printf '%s\n' "$pass" > "$ROOT/openlist-password"
      chmod 600 "$ROOT/openlist-password"
    fi
    say "OpenList 管理员：admin  密码：$(cat "$ROOT/openlist-password")"
    return
  fi
  [[ ! -e $OPENLIST_DIR ]] || err "$OPENLIST_DIR 已存在，避免覆盖。"
  init_tmp; arch_names
  release_asset OpenListTeam/OpenList "$OPENLIST_ASSET" "$TMP_DIR/openlist.tar.gz"
  mkdir -p "$TMP_DIR/openlist-new"
  tar -xzf "$TMP_DIR/openlist.tar.gz" -C "$TMP_DIR/openlist-new"
  binary=$(find "$TMP_DIR/openlist-new" -type f -name openlist -print -quit)
  [[ -n $binary ]] || err 'OpenList 归档中没有 openlist 可执行文件。'
  chmod 755 "$binary"
  "$binary" version >/dev/null || err 'OpenList 二进制无法运行。'
  install -d -m 700 "$OPENLIST_DIR/data"
  install -m 755 "$binary" "$OPENLIST_DIR/openlist"
  touch "$ROOT/openlist-owned"
  config=$OPENLIST_DIR/data/config.json
  jwt=$(openssl rand -hex 32)
  jq -n --arg url "$site_url" --arg jwt "$jwt" \
    '{force:true,site_url:$url,jwt_secret:$jwt,database:{type:"sqlite3",db_file:"data/data.db"},scheme:{address:"127.0.0.1",http_port:5244,https_port:-1},temp_dir:"data/temp",bleve_dir:"data/bleve"}' > "$config"
  chmod 600 "$config"
  install_openlist_service
  restart_or_start openlist || err 'OpenList 启动失败。'
  pass=$(openssl rand -hex 18)
  local attempt password_set=0
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if (cd "$OPENLIST_DIR" && ./openlist admin set "$pass"); then password_set=1; break; fi
    sleep 1
  done
  ((password_set == 1)) || err '设置 OpenList 管理员密码失败。'
  printf '%s\n' "$pass" > "$ROOT/openlist-password"
  chmod 600 "$ROOT/openlist-password"
  touch "$ROOT/openlist-owned"
  say "OpenList 管理员：admin  密码：$pass"
}

# 安装/卸载协议后，把 OpenList 的 site_url 同步为当前 Web 域名（优先 Reality 的）。
sync_openlist_siteurl() {
  local wd cfg cur tmp
  wd=$(web_domain); [[ -n $wd ]] || return 0
  cfg=$OPENLIST_DIR/data/config.json
  [[ -f $cfg ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  cur=$(jq -r '.site_url // empty' "$cfg" 2>/dev/null)
  [[ $cur == "https://$wd" ]] && return 0
  tmp=$(mktemp)
  jq --arg u "https://$wd" '.site_url = $u' "$cfg" > "$tmp" || { rm -f "$tmp"; return 0; }
  install -m 600 "$tmp" "$cfg"
  rm -f "$tmp"
  if svc_active openlist; then svc restart openlist >/dev/null 2>&1 || true; fi
  say "OpenList 访问域名已同步为 https://$wd"
}
# 删除 OpenList 程序、数据与服务（Nginx 站点由调用方按需重写）
purge_openlist() {
  svc stop openlist >/dev/null 2>&1 || true
  svc disable openlist >/dev/null 2>&1 || true
  if [[ $INIT == systemd ]]; then
    rm -f -- /etc/systemd/system/openlist.service
    systemctl daemon-reload
  else
    rm -f -- /etc/init.d/openlist
  fi
  if [[ -f $ROOT/openlist-owned ]]; then rm -rf -- "$OPENLIST_DIR"; fi
  rm -f -- "$ROOT/openlist-password" "$ROOT/openlist-owned"
}
# 单独安装 OpenList（SNI 伪装，可选）
install_openlist_standalone() {
  require_root; detect_env
  ensure_deps
  init_tmp
  local domain= has_web=0
  if [[ -f $STATE ]]; then
    domain=$(web_domain 2>/dev/null || true)
    { has_reality || has_hy2; } && has_web=1
  fi
  if [[ -z $domain ]]; then
    read -r -p 'OpenList 访问域名（可留空，稍后在 OpenList 后台设置）：' domain
  else
    say "OpenList 将绑定到现有 Web 域名：$domain"
  fi
  [[ -x $OPENLIST_DIR/openlist ]] || check_port_free tcp 5244
  install_openlist "$domain"
  if (( has_web )); then
    write_nginx "$STATE" || err 'Nginx 配置更新失败。'
    sync_openlist_siteurl
    say 'Nginx 已切换为反代 OpenList。'
  else
    say '当前未安装 Reality/HY2，安装 Web 协议后 Nginx 会自动反代 OpenList。'
  fi
}
# 单独卸载 OpenList，站点切回 Nginx 默认页面
uninstall_openlist() {
  require_root; detect_env
  [[ -f $STATE ]] || err '没有本脚本管理的安装。'
  [[ -x $OPENLIST_DIR/openlist || -f $ROOT/openlist-owned ]] || { say '未安装 OpenList。'; return; }
  local confirm
  read -r -p '将卸载 OpenList（含其数据），站点切回 Nginx 默认页面。输入 YES 确认：' confirm
  [[ $confirm == YES ]] || { say '已取消。'; return; }
  init_tmp
  purge_openlist
  if [[ -f $STATE ]] && { has_reality || has_hy2; }; then
    write_nginx "$STATE" || err 'Nginx 配置更新失败。'
  fi
  say 'OpenList 已卸载。'
}

# 未安装 OpenList 时 SNI 站点展示的默认页面根目录：优先用系统自带的 nginx 欢迎页
nginx_default_root() {
  local d
  for d in /var/www/html /usr/share/nginx/html; do
    if [[ -f $d/index.nginx-debian.html || -f $d/index.html ]]; then printf '%s' "$d"; return 0; fi
  done
  # 兜底：生成一个极简欢迎页
  install -d -m 755 "$ACME_WEBROOT"
  if [[ ! -f $ACME_WEBROOT/index.html ]]; then
    cat > "$ACME_WEBROOT/index.html" <<'EOF'
<!DOCTYPE html>
<html>
<head><title>Welcome to nginx!</title></head>
<body><h1>Welcome to nginx!</h1></body>
</html>
EOF
  fi
  printf '%s' "$ACME_WEBROOT"
}
# 追加一个 HTTPS server 块（$1=listen 行，可多行；$2=server_name；$3=证书目录）
# 已安装 OpenList 则反代到 OpenList，否则展示 Nginx 默认页面
nginx_server_block() {
  local listens=$1 name=$2 dir=$3 rootdir
  if [[ -x $OPENLIST_DIR/openlist ]]; then
    cat >> "$NGINX_CONF" <<EOF
server {
$listens
    server_name $name;
    ssl_certificate $dir/fullchain.pem;
    ssl_certificate_key $dir/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {
        proxy_pass http://127.0.0.1:5244;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
  else
    rootdir=$(nginx_default_root)
    cat >> "$NGINX_CONF" <<EOF
server {
$listens
    server_name $name;
    ssl_certificate $dir/fullchain.pem;
    ssl_certificate_key $dir/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {
        root $rootdir;
        index index.html index.htm index.nginx-debian.html;
    }
}
EOF
  fi
}

write_nginx() {
  local state_file=$1 r_domain r_port r_fallback h_domain web_domain
  r_domain=$(jq -r '.reality.domain // empty' "$state_file")
  r_port=$(jq -r '.reality.port // 443' "$state_file")
  r_fallback=$(jq -r '.reality.fallback // 8443' "$state_file")
  h_domain=$(jq -r '.hy2.domain // empty' "$state_file")
  web_domain=${r_domain:-$h_domain}
  local backup= ipv6_http= ipv6_https= d dir
  if has_ipv6; then
    ipv6_http='listen [::]:80;'
    ipv6_https='listen [::]:443 ssl;'
  fi
  install -d -m 755 /etc/nginx/conf.d
  if [[ -f $NGINX_CONF ]]; then backup=$TMP_DIR/nginx-old; cp -a "$NGINX_CONF" "$backup"; fi
  touch "$TMP_DIR/nginx-staged"
  rm -f -- "$ACME_TMP_CONF"
  if [[ -z $web_domain ]]; then
    # 已无 Web 协议，清理本站点配置
    rm -f -- "$NGINX_CONF"
    if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1 && svc_active nginx; then
      svc reload nginx >/dev/null 2>&1 || true
    fi
    return 0
  fi
  : > "$NGINX_CONF"
  # 每个 http 验证方式的域名都需要 80 验证块（证书续期用）
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    [[ $(cert_method "$d") == http ]] || continue
    cat >> "$NGINX_CONF" <<EOF
# Managed by seeword. Custom changes will be overwritten.
server {
    listen 80;
    $ipv6_http
    server_name $d;
    location ^~ /.well-known/acme-challenge/ { root $ACME_WEBROOT; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
  done < <(jq -r '[.reality.domain, .hy2.domain] | map(select(. != null)) | unique | .[]' "$state_file")
  # Reality 回落块（xray reality 的 target，127.0.0.1:回落端口；8443 被占用时自动顺延）
  if [[ -n $r_domain ]]; then
    nginx_server_block "    listen 127.0.0.1:$r_fallback ssl;" "$r_domain" "$(cert_dir "$r_domain")"
  fi
  # 公网 443 Web 块：Reality 未占用 443/tcp 时提供
  if [[ -z $r_domain || $r_port != 443 ]]; then
    nginx_server_block "$(printf '    listen 443 ssl;\n    %s' "$ipv6_https")" "$web_domain" "$(cert_dir "$web_domain")"
  fi
  if ! nginx -t || ! restart_or_start nginx; then
    if [[ -n $backup ]]; then cp -a "$backup" "$NGINX_CONF"; else rm -f "$NGINX_CONF"; fi
    restart_or_start nginx || true
    say '错误：Nginx 配置或启动失败，已恢复原有站点。' >&2
    return 1
  fi
}

random_hex() { openssl rand -hex "$1"; }
public_address() {
  local domain ip
  domain=$(web_domain)
  if [[ -n $domain ]]; then printf '%s' "$domain"; return; fi
  ip=$(curl -4 -fsSL --max-time 8 https://api.ipify.org 2>/dev/null || true)
  if [[ -z $ip ]]; then ip=$(curl -6 -fsSL --max-time 8 https://api64.ipify.org 2>/dev/null || true); fi
  [[ -n $ip ]] || err '无法自动查询公网 IP，请先配置 Reality/HY2 域名。'
  [[ $ip != *:* ]] || ip="[$ip]"
  printf '%s' "$ip"
}

install_common() {
  require_root; detect_env
  [[ ! -f $XRAY_CONF || -f $STATE ]] || err '检测到已有非本脚本管理的 Xray 配置，停止以避免覆盖。'
  [[ ! -x $XRAY_BIN || -f $ROOT/core-owned ]] || err '检测到已有非本脚本管理的 Xray 内核，停止以避免覆盖。'
  ensure_deps
  state_init; init_tmp
  if [[ ! -f $SELF ]] || ! cmp -s "${BASH_SOURCE[0]}" "$SELF"; then install -m 755 "${BASH_SOURCE[0]}" "$SELF"; fi
  if [[ ! -f $ROOT/core-owned ]]; then install_xray_core; touch "$ROOT/core-owned"; fi
}

install_reality() {
  install_common
  has_reality && err 'Reality 已安装。'
  ensure_web_deps
  ask_domain reality || return 1
  ask_reality_port
  local fallback_port
  fallback_port=$(find_reality_fallback_port "$RPORT")
  say ''
  say '即将安装：'
  say '  协议：Reality (VLESS + TCP)'
  say "  域名/SNI：$DOMAIN"
  say "  TCP 端口：$RPORT"
  say "  回落端口：127.0.0.1:$fallback_port（8443 被占用时自动顺延）"
  if [[ -x $OPENLIST_DIR/openlist ]]; then say '  伪装站点：OpenList'; else say '  伪装站点：Nginx 默认页面（如需 OpenList 可在主菜单单独安装）'; fi
  confirm_install '确认开始安装' || return 1
  step 1 4 '申请证书'
  issue_cert "$DOMAIN"
  open_firewall_port tcp 80
  open_firewall_port tcp "$RPORT"
  step 2 4 '生成 Reality 密钥与配置'
  local keypair private public sid uuid
  keypair=$($XRAY_BIN x25519)
  private=$(awk -F': ' '/Private ?[Kk]ey/{print $2}' <<< "$keypair" | head -n 1)
  public=$(awk -F': ' '/Public ?[Kk]ey/{print $2}' <<< "$keypair" | head -n 1)
  [[ -n $private && -n $public ]] || err 'Xray 密钥生成失败。'
  uuid=$($XRAY_BIN uuid)
  sid=$(random_hex 8)
  jq --arg d "$DOMAIN" --argjson port "$RPORT" --argjson fallback "$fallback_port" --arg id "$uuid" --arg priv "$private" --arg pub "$public" --arg sid "$sid" \
    '.reality={uuid:$id,private:$priv,public:$pub,sid:$sid,domain:$d,port:$port,fallback:$fallback,users:[{uuid:$id,remark:"默认"}]}' \
    "$STATE" > "$TMP_DIR/state-new"
  step 3 4 '写入 Nginx 与 Xray 配置'
  render_config "$TMP_DIR/state-new" "$TMP_DIR/check-config"
  "$XRAY_BIN" run -test -format json -config "$TMP_DIR/check-config" || err 'Reality 配置验证失败。'
  write_nginx "$TMP_DIR/state-new"
  commit_state "$TMP_DIR/state-new"
  sync_openlist_siteurl
  step 4 4 '完成'
  show_info
}

install_hy2() {
  install_common
  has_hy2 && err 'HY2 已安装。'
  ensure_web_deps
  ask_domain hy2 || return 1
  ask_port HPORT udp 443 'HY2 UDP 端口'
  preflight_web hy2
  say ''
  say '即将安装：'
  say '  协议：Hysteria2 (UDP)'
  say "  域名/SNI：$DOMAIN"
  say "  UDP 端口：$HPORT"
  if [[ -x $OPENLIST_DIR/openlist ]]; then say '  伪装站点：OpenList'; else say '  伪装站点：Nginx 默认页面（如需 OpenList 可在主菜单单独安装）'; fi
  confirm_install '确认开始安装' || return 1
  step 1 4 '申请证书'
  issue_cert "$DOMAIN"
  open_firewall_port tcp 80
  open_firewall_port udp "$HPORT"
  step 2 4 '生成 HY2 配置'
  local pass dir
  pass=$(random_hex 18)
  dir=$(cert_dir "$DOMAIN")
  jq --arg d "$DOMAIN" --argjson port "$HPORT" --arg pass "$pass" --arg cert "$dir/fullchain.pem" --arg key "$dir/privkey.pem" \
    '.hy2={password:$pass,cert:$cert,key:$key,domain:$d,port:$port}' "$STATE" > "$TMP_DIR/state-new"
  step 3 4 '写入 Nginx 与 Xray 配置'
  render_config "$TMP_DIR/state-new" "$TMP_DIR/check-config"
  "$XRAY_BIN" run -test -format json -config "$TMP_DIR/check-config" || err 'HY2 配置验证失败。'
  write_nginx "$TMP_DIR/state-new"
  commit_state "$TMP_DIR/state-new"
  sync_openlist_siteurl
  step 4 4 '完成'
  show_info
}

install_ss() {
  install_common
  has_ss && err 'SS 已安装。'
  local port pass address p
  read -r -p '请输入 SS 端口（1-65535）：' port
  [[ $port =~ ^[0-9]+$ && ${#port} -le 5 ]] || err '端口无效。'
  port=$((10#$port))
  ((port >= 1 && port <= 65535)) || err '端口无效。'
  for p in 80 443 5244; do (( port != p )) || err "端口 $port 为保留端口，请换一个。"; done
  (( port < 8443 || port > 8462 )) || err "端口 $port 在 Reality 回落保留段（8443-8462）内，请换一个。"
  check_port_free tcp "$port"; check_port_free udp "$port"
  address=$(public_address)
  say ''
  say '即将安装：'
  say '  协议：Shadowsocks 2022'
  say "  端口：$port (TCP+UDP)"
  say "  地址：$address"
  confirm_install '确认开始安装' || return 1
  step 1 2 '生成配置'
  pass=$(openssl rand 16 | base64 | tr -d '\n')
  jq --argjson port "$port" --arg pass "$pass" --arg address "$address" \
    '.ss={port:$port,password:$pass,address:$address}' "$STATE" > "$TMP_DIR/state-new"
  step 2 2 '生效配置'
  open_firewall_port tcp "$port"
  open_firewall_port udp "$port"
  commit_state "$TMP_DIR/state-new"
  show_info
}

url_base64() { base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='; }
show_link() {
  local title=$1 link=$2
  say "\n$title 分享链接："
  say "$link"
  qrencode -t ANSIUTF8 "$link"
}

# 分享链接用的连接地址：优先公网 IPv4，没有可用 V4 时才用 IPv6（加方括号），都不行回退域名
link_host() {
  local domain=$1 ip
  # 先找公网 IPv4（排除私网/NAT 地址）
  ip=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | grep -v '^127\.' | grep -v '^10\.' | grep -v '^172\.1[6-9]\.' | grep -v '^172\.2[0-9]\.' | grep -v '^172\.3[0-1]\.' | grep -v '^192\.168\.' | grep -v '^100\.' | head -n1)
  if [[ -z $ip ]]; then
    # 本机无公网 V4（如 NAT），尝试外网查询
    ip=$(curl -fsSL --max-time 8 -4 https://api.ipify.org 2>/dev/null)
  fi
  if [[ -n $ip ]]; then
    printf '%s' "$ip"
    return 0
  fi
  # V4 不可用，用 IPv6
  ip=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6 /{print $2}' | cut -d/ -f1 | grep -v '^fe80' | head -n1)
  if [[ -n $ip ]]; then
    printf '[%s]' "$ip"
  else
    printf '%s' "$domain"
  fi
}

# 生成单个 Reality 用户的分享链接
reality_link() {
  local uuid=$1 remark=$2 r_domain r_port pub sid frag host
  r_domain=$(state_get '.reality.domain'); r_port=$(state_get '.reality.port')
  pub=$(state_get '.reality.public'); sid=$(state_get '.reality.sid')
  host=$(link_host "$r_domain")
  frag="Reality"
  [[ -z ${remark:-} || $remark == 默认 ]] || frag="Reality-$remark"
  printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&flow=xtls-rprx-vision&type=tcp#%s' \
    "$uuid" "$host" "$r_port" "$r_domain" "$pub" "$sid" "$frag"
}

# 输出所有分享链接，每行：标题<TAB>链接
collect_links() {
  local h_domain h_port pass uuid remark port address userpass encoded
  if has_reality; then
    while IFS=$'\t' read -r uuid remark; do
      [[ -n $uuid ]] || continue
      printf '%s\t%s\n' "Reality(${remark:-默认})" "$(reality_link "$uuid" "${remark:-默认}")"
    done < <(jq -r '.reality.users[] | [.uuid, (.remark // "")] | @tsv' "$STATE")
  fi
  if has_hy2; then
    h_domain=$(state_get '.hy2.domain'); h_port=$(state_get '.hy2.port'); pass=$(state_get '.hy2.password')
    printf '%s\t%s\n' 'HY2' "hysteria2://$pass@$(link_host "$h_domain"):$h_port?sni=$h_domain#HY2"
  fi
  if has_ss; then
    pass=$(state_get '.ss.password'); port=$(state_get '.ss.port'); address=$(state_get '.ss.address')
    userpass="2022-blake3-aes-128-gcm:$pass"
    encoded=$(printf '%s' "$userpass" | url_base64)
    printf '%s\t%s\n' 'SS2022' "ss://$encoded@$address:$port#SS2022"
  fi
}

# Web 界面（OpenList）使用的域名：优先 Reality 的
web_domain() {
  local r h
  r=$(state_get '.reality.domain'); h=$(state_get '.hy2.domain')
  printf '%s' "${r:-$h}"
}

show_info() {
  require_root
  [[ -f $STATE ]] || err '尚未安装。'
  local d title link wd
  say "Xray 配置：$XRAY_CONF"
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    say "域名/SNI：$d"
    if [[ -f $(cert_dir "$d")/fullchain.pem ]]; then
      openssl x509 -noout -enddate -in "$(cert_dir "$d")/fullchain.pem"
    fi
  done < <(jq -r '[.reality.domain, .hy2.domain] | map(select(. != null)) | unique | .[]' "$STATE")
  while IFS=$'\t' read -r title link; do
    [[ -n $link ]] || continue
    show_link "$title" "$link"
  done < <(collect_links)
  wd=$(web_domain)
  if [[ -n $wd ]]; then
    say "\nOpenList 地址：https://$wd"
    if [[ -f $ROOT/openlist-password ]]; then say "OpenList 管理员：admin  密码：$(cat "$ROOT/openlist-password")"; fi
  fi
  show_status
}

show_status() {
  require_root
  detect_env
  say '\n服务状态：'
  local name
  for name in seeword openlist nginx; do
    case $name in
      seeword) label='seeword' ;;
      openlist) label='OpenList' ;;
      nginx) label='Nginx' ;;
    esac
    if svc_active "$name"; then say "$label：运行中"; else say "$label：未运行"; fi
  done
  if [[ -x $XRAY_BIN ]]; then "$XRAY_BIN" version | sed -n '1p'; fi
}
reload_services() {
  require_root; detect_env
  if svc_active nginx; then nginx -t && svc reload nginx; fi
  if svc_active seeword; then svc restart seeword; fi
}
update_core() {
  require_root; detect_env; ensure_deps
  [[ -f $ROOT/core-owned && -f $STATE ]] || err '请先通过本脚本安装一种协议。'
  local current latest
  current=$($XRAY_BIN version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
  latest=$(curl -fsSL --retry 2 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | jq -r '.tag_name // empty')
  latest=${latest#v}
  if [[ -n $current && -n $latest && $current == "$latest" ]]; then
    say "Xray 已是最新版本 v$current，无需更新。"
    return 0
  fi
  install_xray_core
}
# 一键体检：检查状态文件、内核、配置、服务、端口、证书、API
doctor() {
  require_root; detect_env
  [[ -f $STATE ]] || err '尚未安装。'
  load_state
  local fail=0 d port exp cur
  t_ok() { say "[OK] $1"; }
  t_fail() { say "[FAIL] $1"; fail=1; }
  if jq empty "$STATE" 2>/dev/null; then t_ok '状态文件 JSON 合法'; else t_fail '状态文件 JSON 损坏'; fi
  if [[ -x $XRAY_BIN ]] && "$XRAY_BIN" version >/dev/null 2>&1; then
    t_ok "Xray 内核可运行（$("$XRAY_BIN" version 2>/dev/null | sed -n '1p')）"
  else t_fail 'Xray 内核缺失或无法运行'; fi
  if [[ -f $XRAY_CONF ]]; then
    if [[ -x $XRAY_BIN ]] && "$XRAY_BIN" run -test -config "$XRAY_CONF" >/dev/null 2>&1; then
      t_ok 'Xray 配置验证通过'
    else t_fail 'Xray 配置验证失败'; fi
  else t_fail 'Xray 配置文件缺失'; fi
  if svc_active seeword; then t_ok 'seeword 服务运行中'; else t_fail 'seeword 服务未运行'; fi
  if [[ -x $OPENLIST_DIR/openlist ]]; then
    if svc_active openlist; then t_ok 'OpenList 服务运行中'; else t_fail 'OpenList 服务未运行'; fi
  fi
  if has_reality || has_hy2; then
    if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
      t_ok 'Nginx 配置验证通过'
    else t_fail 'Nginx 配置验证失败'; fi
    if svc_active nginx; then t_ok 'Nginx 服务运行中'; else t_fail 'Nginx 服务未运行'; fi
  fi
  if has_reality; then
    port=$(state_get '.reality.port')
    if [[ -n $(ss -H -ltn "sport = :$port" 2>/dev/null) ]]; then t_ok "Reality TCP $port 监听正常"; else t_fail "Reality TCP $port 未监听"; fi
  fi
  if has_hy2; then
    port=$(state_get '.hy2.port')
    if [[ -n $(ss -H -lun "sport = :$port" 2>/dev/null) ]]; then t_ok "HY2 UDP $port 监听正常"; else t_fail "HY2 UDP $port 未监听"; fi
  fi
  if has_ss; then
    port=$(state_get '.ss.port')
    if [[ -n $(ss -H -ltn "sport = :$port" 2>/dev/null) ]]; then t_ok "SS TCP $port 监听正常"; else t_fail "SS TCP $port 未监听"; fi
  fi
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    if [[ -f $(cert_dir "$d")/fullchain.pem ]]; then
      if openssl x509 -checkend 2592000 -noout -in "$(cert_dir "$d")/fullchain.pem" >/dev/null 2>&1; then
        exp=$(openssl x509 -noout -enddate -in "$(cert_dir "$d")/fullchain.pem" 2>/dev/null | cut -d= -f2)
        t_ok "证书 $d 有效（到期：$exp）"
      else t_fail "证书 $d 将在 30 天内过期或已过期"; fi
    else t_fail "证书 $d 缺失"; fi
  done < <(jq -r '[.reality.domain, .hy2.domain] | map(select(. != null)) | unique | .[]' "$STATE")
  if [[ -x $XRAY_BIN ]] && "$XRAY_BIN" api statsquery --server=127.0.0.1:10085 -pattern '>>>none' >/dev/null 2>&1; then
    t_ok 'Xray API（流量统计接口）可用'
  else t_fail 'Xray API 不可用（流量统计将无法工作）'; fi
  if (( fail == 0 )); then say '体检通过：一切正常。'; else err '体检发现问题，请按上面 [FAIL] 项排查。'; fi
}

# 备份：状态、配置、Nginx 站点、证书、OpenList 数据
backup() {
  require_root; detect_env
  [[ -f $STATE ]] || err '尚未安装。'
  local dest=${1:-/root/seeword-backup-$(date +%Y%m%d-%H%M%S).tar.gz}
  init_tmp
  local list=$TMP_DIR/filelist f
  : > "$list"
  for f in "$ROOT" "$XRAY_CONF" "$NGINX_CONF" "$CERT_ROOT" \
      /etc/systemd/system/seeword.service /etc/systemd/system/openlist.service \
      /etc/init.d/seeword /etc/init.d/openlist; do
    [[ -e $f ]] || continue
    printf '%s\n' "$f" >> "$list"
  done
  if [[ -f $ROOT/openlist-owned && -d $OPENLIST_DIR ]]; then printf '%s\n' "$OPENLIST_DIR" >> "$list"; fi
  tar -czPf "$dest" -T "$list" || err '备份打包失败。'
  chmod 600 "$dest"
  say "备份已保存到：$dest"
  say '注意：备份不含 Xray 内核二进制，恢复后如缺失可用 update 命令重装。'
}

# 恢复：解包备份并重启服务
restore() {
  require_root; detect_env
  local src=${1:-}
  [[ -n $src ]] || err '用法：seeword restore <备份文件>'
  [[ -f $src ]] || err "备份文件不存在：$src"
  local confirm
  read -r -p '恢复将覆盖现有配置并重启服务，输入 YES 确认：' confirm
  [[ $confirm == YES ]] || { say '已取消。'; return; }
  init_tmp
  tar -tzPf "$src" >/dev/null 2>&1 || err '备份文件损坏或格式不正确。'
  tar -xzPf "$src" -C / || err '恢复解包失败。'
  [[ -f $STATE ]] || err '备份中没有状态文件，恢复中止。'
  install_xray_service
  if [[ -x $OPENLIST_DIR/openlist ]]; then install_openlist_service; fi
  if [[ $INIT == systemd ]]; then systemctl daemon-reload; fi
  if [[ -f $XRAY_CONF ]]; then
    [[ -x $XRAY_BIN ]] || err 'Xray 内核缺失，请先用 update 命令安装后再恢复。'
    "$XRAY_BIN" run -test -config "$XRAY_CONF" >/dev/null 2>&1 || err '恢复的 Xray 配置验证失败。'
  fi
  if command -v nginx >/dev/null 2>&1 && [[ -f $NGINX_CONF ]]; then
    nginx -t >/dev/null 2>&1 || err '恢复的 Nginx 配置验证失败。'
  fi
  restart_or_start seeword || err 'Xray 启动失败。'
  if [[ -f $NGINX_CONF ]]; then restart_or_start nginx || true; fi
  if [[ -x $OPENLIST_DIR/openlist ]]; then restart_or_start openlist || true; fi
  say '恢复完成。'
}

human_bytes() {
  local b=${1:-0}
  (( b < 0 )) && b=0
  if (( b < 1024 )); then printf '%d B' "$b"
  elif (( b < 1048576 )); then awk -v b="$b" 'BEGIN{printf "%.2f KB", b/1024}'
  elif (( b < 1073741824 )); then awk -v b="$b" 'BEGIN{printf "%.2f MB", b/1048576}'
  else awk -v b="$b" 'BEGIN{printf "%.2f GB", b/1073741824}'; fi
}

# 流量统计：通过 Xray API 查询各用户/协议的上行下行（Xray 重启后清零）
traffic() {
  require_root
  [[ -f $STATE ]] || err '尚未安装。'
  [[ -x $XRAY_BIN ]] || err 'Xray 内核缺失。'
  load_state
  local out name value email dir uuid remark up down
  out=$("$XRAY_BIN" api statsquery --server=127.0.0.1:10085 -pattern '>>>' 2>/dev/null) \
    || err 'Xray API 不可用，请确认 seeword 服务运行中。'
  declare -A TUPS TDOWNS
  while IFS=$'\t' read -r name value; do
    [[ $name == user\>\>\>* ]] || [[ $name == inbound\>\>\>* ]] || continue
    dir=${name##*>>>}
    [[ $dir == uplink || $dir == downlink ]] || continue
    email=${name#*>>>}; email=${email%%>>>*}
    if [[ $dir == uplink ]]; then TUPS[$email]=${value:-0}; else TDOWNS[$email]=${value:-0}; fi
  done < <(jq -r '.stat[]? | "\(.name)\t\(.value)"' <<< "$out")
  say '流量统计（自 Xray 启动累计，重启后清零）：'
  if has_reality; then
    say 'Reality 用户：'
    while IFS=$'\t' read -r uuid remark; do
      [[ -n $uuid ]] || continue
      email="reality:$uuid"
      up=${TUPS[$email]:-0}; down=${TDOWNS[$email]:-0}
      say "  ${remark:-默认}：上行 $(human_bytes "$up") / 下行 $(human_bytes "$down")"
    done < <(jq -r '.reality.users[] | [.uuid, (.remark // "")] | @tsv' "$STATE")
  fi
  if has_hy2; then
    up=${TUPS[hy2]:-0}; down=${TDOWNS[hy2]:-0}
    say "HY2：上行 $(human_bytes "$up") / 下行 $(human_bytes "$down")"
  fi
  if has_ss; then
    up=${TUPS[ss]:-0}; down=${TDOWNS[ss]:-0}
    say "SS2022：上行 $(human_bytes "$up") / 下行 $(human_bytes "$down")"
  fi
}

# Reality 添加用户
reality_adduser() {
  require_root; detect_env
  [[ -f $STATE ]] || err '尚未安装。'
  load_state
  has_reality || err 'Reality 尚未安装。'
  local remark=${1:-} uuid link
  if [[ -z $remark ]]; then
    read -r -p '请输入用户名（如 dd）：' remark
  fi
  remark=${remark:-新用户}
  uuid=$($XRAY_BIN uuid)
  init_tmp
  jq --arg id "$uuid" --arg remark "$remark" \
    '.reality.users += [{uuid:$id,remark:$remark}]' "$STATE" > "$TMP_DIR/state-new"
  commit_state "$TMP_DIR/state-new"
  say "已添加 Reality 用户：$remark"
  link=$(reality_link "$uuid" "$remark")
  show_link "Reality($remark)" "$link"
}

# Reality 用户列表（内部：只打印，调用方已做检查）
_list_reality_users() {
  local count i uuid remark
  count=$(jq '.reality.users | length' "$STATE")
  say "Reality 用户（共 $count 个）："
  i=0
  while IFS=$'\t' read -r uuid remark; do
    i=$((i+1)); say "  $i. ${remark:-默认}（${uuid:0:8}…）"
  done < <(jq -r '.reality.users[] | [.uuid, (.remark // "")] | @tsv' "$STATE")
}
# Reality 查看用户
reality_users() {
  require_root
  [[ -f $STATE ]] || err '尚未安装。'
  load_state
  has_reality || err 'Reality 尚未安装。'
  _list_reality_users
}
# 按编号（1-based）或备注解析用户，输出 0-based 索引；编号优先于备注
resolve_user_index() {
  local arg=$1 count i r
  count=$(jq '.reality.users | length' "$STATE")
  if [[ $arg =~ ^[0-9]+$ ]] && (( arg >= 1 && arg <= count )); then
    printf '%s' "$((arg-1))"; return 0
  fi
  i=0
  while IFS= read -r r; do
    if [[ $r == "$arg" ]]; then printf '%s' "$i"; return 0; fi
    i=$((i+1))
  done < <(jq -r '.reality.users[] | (.remark // "")' "$STATE")
  return 1
}
# Reality 删除用户（至少保留一个），$1 可为编号或备注
reality_deluser() {
  require_root; detect_env
  [[ -f $STATE ]] || err '尚未安装。'
  load_state
  has_reality || err 'Reality 尚未安装。'
  local count choice=${1:-} idx remark
  count=$(jq '.reality.users | length' "$STATE")
  (( count > 1 )) || err '只剩一个用户，不能再删。'
  if [[ -z $choice ]]; then
    _list_reality_users
    read -r -p '请输入要删除的用户名（或编号）：' choice
  fi
  idx=$(resolve_user_index "$choice") || err '未找到该用户（编号或备注无效）。'
  remark=$(jq -r --argjson idx "$idx" '.reality.users[$idx].remark // "默认"' "$STATE")
  init_tmp
  jq --argjson idx "$idx" 'del(.reality.users[$idx])' "$STATE" > "$TMP_DIR/state-new"
  commit_state "$TMP_DIR/state-new"
  say "已删除用户：$remark"
}

# 一键开启 BBR
enable_bbr() {
  require_root
  local cur major minor
  cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
  if [[ $cur == bbr ]]; then say 'BBR 已启用。'; return 0; fi
  major=$(uname -r | cut -d. -f1); minor=$(uname -r | cut -d. -f2)
  if (( major < 4 || (major == 4 && minor < 9) )); then
    err "内核版本 $(uname -r) 过低，BBR 需要 4.9+。"
  fi
  modprobe tcp_bbr 2>/dev/null || true
  cat > /etc/sysctl.d/99-seeword-bbr.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
  cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
  if [[ $cur == bbr ]]; then say 'BBR 已启用（重启后保持）。'; else err "BBR 启用失败，当前拥塞算法：${cur:-未知}。"; fi
}
# 删除单个域名的证书（仅当 domain.txt 凭证匹配时才删，避免误删）
remove_cert() {
  local domain=$1 dir owner
  [[ -n $domain ]] || return 0
  dir=$(cert_dir "$domain")
  owner=$dir/domain.txt
  [[ -f $owner && $(cat "$owner") == "$domain" ]] || return 0
  [[ ! -x $ACME ]] || "$ACME" --remove -d "$domain" --ecc >/dev/null 2>&1 || true
  # acme.sh --remove 可能残留域名目录（含旧 key），导致重装时 --issue 拒绝覆盖；彻底删除
  rm -rf -- "${ACME%/*}/${domain}_ecc" "${ACME%/*}/${domain}"
  rm -rf -- "$dir"
}
# 移除整个 Web 栈：Nginx 站点、全部本脚本管理的证书
# OpenList 已是独立组件，不再随 Web 栈移除（由 uninstall_openlist / uninstall_all 处理）
remove_web_stack() {
  local d dom
  if [[ -f $NGINX_CONF ]]; then
    cp -a "$NGINX_CONF" "$TMP_DIR/nginx-remove-old"
    rm -f -- "$NGINX_CONF"
    if ! nginx -t || (svc_active nginx && ! svc reload nginx); then
      cp -a "$TMP_DIR/nginx-remove-old" "$NGINX_CONF"
      svc_active nginx && svc reload nginx || true
      err 'Nginx 站点移除失败，已恢复站点文件。'
    fi
  fi
  if [[ -d $CERT_ROOT ]]; then
    for d in "$CERT_ROOT"/*; do
      [[ -d $d && -f $d/domain.txt ]] || continue
      dom=$(cat "$d/domain.txt")
      remove_cert "$dom"
    done
  fi
  rm -f -- "$ROOT/cert-method" "$ACME_TMP_CONF"
  rm -rf -- "$ACME_WEBROOT"
}
uninstall_protocol() {
  local protocol=$1 label=$2 confirm pdomain
  require_root; detect_env
  [[ -f $STATE ]] || err '没有本脚本管理的安装。'
  command -v jq >/dev/null 2>&1 || err '缺少 jq，无法安全修改配置。'
  load_state
  [[ $(jq -r --arg p "$protocol" '.[$p] != null' "$STATE") == true ]] || err "$label 尚未安装。"
  read -r -p "只卸载 $label；输入 $label 确认：" confirm
  [[ $confirm == "$label" ]] || { say '已取消。'; return; }
  init_tmp
  pdomain=$(jq -r --arg p "$protocol" '.[$p].domain // empty' "$STATE")
  jq --arg p "$protocol" '.[$p] = null' "$STATE" > "$TMP_DIR/state-new"
  if [[ $(jq -r '[.reality,.hy2,.ss] | any(. != null)' "$TMP_DIR/state-new") == true ]]; then
    # 先让 Xray 释放端口，再更新 Nginx（Reality 占 443 时 Nginx 要接回 443）
    commit_state "$TMP_DIR/state-new"
    if [[ $protocol == reality || $protocol == hy2 ]]; then
      if ! write_nginx "$STATE"; then
        install -m 600 "$TMP_DIR/state-old" "$STATE"
        if [[ -f $TMP_DIR/config-old ]]; then install -m 600 "$TMP_DIR/config-old" "$XRAY_CONF"; fi
        restart_or_start seeword || true
        err 'Nginx 配置更新失败，已恢复原有 Xray 配置。'
      fi
      # 该域名若无其他协议使用，删除其证书
      if [[ -n $pdomain ]] && [[ $(jq -r --arg d "$pdomain" \
          '[.reality.domain,.hy2.domain] | map(select(. != null)) | any(. == $d)' "$STATE") != true ]]; then
        remove_cert "$pdomain"
      fi
      sync_openlist_siteurl
    fi
    say "$label 已卸载；其他协议配置保留。"
  else
    svc stop seeword || err 'Xray 停止失败，原配置未修改。'
    svc disable seeword >/dev/null 2>&1 || true
    install -m 600 "$TMP_DIR/state-new" "$STATE"
    rm -f -- "$XRAY_CONF"
    remove_web_stack
    say "$label 已卸载；已无剩余协议，Web 服务已一并清理。"
  fi
}
uninstall_all() {
  require_root; detect_env
  [[ -f $STATE ]] || err '没有本脚本管理的安装。'
  local confirm
  read -r -p '将彻底删除 Xray、Nginx（含软件包与配置）、OpenList、acme.sh、全部证书、配置与账号数据。输入 DELETE 确认：' confirm
  [[ $confirm == DELETE ]] || { say '已取消。'; return; }
  init_tmp
  for service in seeword openlist nginx; do
    svc stop "$service" >/dev/null 2>&1 || true
    svc disable "$service" >/dev/null 2>&1 || true
  done
  if [[ $INIT == systemd ]]; then
    rm -f /etc/systemd/system/seeword.service /etc/systemd/system/openlist.service
    systemctl daemon-reload
  else
    rm -f /etc/init.d/seeword /etc/init.d/openlist
  fi
  remove_web_stack
  # OpenList 是独立组件，全卸载时显式清理
  purge_openlist
  # 卸载 Nginx 软件包（含其配置文件）
  pkg_remove nginx
  # 删除 acme.sh 程序及其管理的全部证书记录
  rm -rf -- /root/.acme.sh
  rm -f -- "$XRAY_CONF" "$XRAY_BIN" "$SELF"
  rm -f -- "$XRAY_ASSETS/geoip.dat" "$XRAY_ASSETS/geosite.dat"
  rm -rf -- "$ROOT"
  rm -f -- "$LOG_FILE"
  say '卸载完成：Xray、Nginx、OpenList、acme.sh 及全部证书、配置、账号数据均已删除。'
}

uninstall_menu() {
  local choice
  while true; do
    cat <<'EOF'

===== 卸载管理 =====
1. 一键全卸载
2. 只卸载 Reality
3. 只卸载 HY2
4. 只卸载 SS2022
5. 只卸载 OpenList
0. 返回上级
EOF
    read -r -p '请选择：' choice
    case "$choice" in
      1) guarded uninstall_all ;;
      2) guarded uninstall_protocol reality Reality ;;
      3) guarded uninstall_protocol hy2 HY2 ;;
      4) guarded uninstall_protocol ss SS2022 ;;
      5) guarded uninstall_openlist ;;
      0) return ;;
      *) say '无效选项。' ;;
    esac
  done
}

# 用户管理子菜单（Reality）
user_menu() {
  local choice
  while true; do
    cat <<'EOF'

===== 用户管理（Reality） =====
1. 查看用户
2. 添加用户
3. 删除用户
0. 返回上级
EOF
    read -r -p '请选择：' choice
    case "$choice" in
      1) reality_users ;;
      2) guarded reality_adduser ;;
      3) guarded reality_deluser ;;
      0) return ;;
      *) say '无效选项。' ;;
    esac
  done
}
tools_menu() {
  local choice src
  while true; do
    cat <<'EOF'

===== 更多工具 =====
1. 更新 Xray 内核和地理数据
2. 一键开启 BBR
3. Reality 用户管理
4. 查看流量统计
5. 一键体检
6. 备份配置
7. 恢复配置
8. 重载服务
9. 安装全部依赖
10. 修复系统环境（软件源/DNS/网络）
0. 返回上级
EOF
    read -r -p '请选择：' choice
    case "$choice" in
      1) guarded update_core ;;
      2) guarded enable_bbr ;;
      3) user_menu ;;
      4) traffic ;;
      5) doctor ;;
      6) guarded backup ;;
      7) read -r -p '请输入备份文件路径：' src
         [[ -n $src ]] || { say '已取消。'; continue; }
         guarded restore "$src" ;;
      8) guarded reload_services ;;
      9) guarded cmd_deps ;;
      10) guarded fixenv ;;
      0) return ;;
      *) say '无效选项。' ;;
    esac
  done
}

# 带并发锁与日志的执行包装：失败时回到菜单，不退出整个脚本
guarded() {
  ( take_lock; setup_logging; "$@" ) || true
}

menu() {
  local choice
  while true; do
    cat <<'EOF'

===== 个人 Xray 管理 =====
1. 一键安装 Reality
2. 一键安装 HY2
3. 一键安装 SS2022
4. 安装 OpenList（SNI 伪装，可选）
5. 查看配置、分享链接和服务状态
6. 更多工具
7. 卸载管理
0. 退出
EOF
    read -r -p '请选择：' choice
    case "$choice" in
      1) guarded install_reality ;;
      2) guarded install_hy2 ;;
      3) guarded install_ss ;;
      4) guarded install_openlist_standalone ;;
      5) show_info ;;
      6) tools_menu ;;
      7) uninstall_menu ;;
      0) return ;;
      *) say '无效选项。' ;;
    esac
  done
}

# 一键安装前自动更新脚本到最新版：静默拉取，下载失败或无变化则直接继续；
# 有更新则替换自身并重新执行相同命令（旧版本备份为 seeword.bak）
ensure_latest_script() {
  local cmd=$1 tmp
  local src=${SEEWORLD_URL:-https://raw.githubusercontent.com/etcboy/seeword/main/seeword.sh}
  # 加时间戳避免 CDN 缓存旧版本
  src="$src?t=$(date +%s)"
  tmp=$(mktemp) || return 0
  trap 'rm -f "$tmp"' RETURN
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 2 --max-time 15 "$src" -o "$tmp" 2>/dev/null || return 0
  elif command -v wget >/dev/null 2>&1; then
    wget -qT 15 -O "$tmp" "$src" 2>/dev/null || return 0
  else
    return 0
  fi
  [[ -s $tmp ]] || return 0
  grep -q 'seeword' "$tmp" 2>/dev/null || return 0
  bash -n "$tmp" 2>/dev/null || return 0
  cmp -s "$tmp" "$SELF" && return 0
  say '检测到脚本有新版本，正在更新…'
  cp -a "$SELF" "$SELF.bak" 2>/dev/null || true
  install -m 755 "$tmp" "$SELF" 2>/dev/null || return 0
  say '脚本已更新，重新执行安装…'
  exec "$SELF" "$cmd"
}

main() {
  local cmd=${1:-menu}
  case $cmd in
    menu|reality|hy2|ss|openlist|update|info|status|uninstall|uninstall-reality|uninstall-hy2|uninstall-ss|uninstall-openlist|reload|\
doctor|backup|restore|traffic|adduser|deluser|users|bbr|deps|fixenv) ;;
    *) say '用法：seeword [menu|reality|hy2|ss|openlist|update|info|status|uninstall|uninstall-reality|uninstall-hy2|uninstall-ss|uninstall-openlist|reload|doctor|backup|restore|traffic|adduser|deluser|users|bbr|deps|fixenv]'; exit 2 ;;
  esac
  require_root; detect_env
  # 一键安装类命令先自动拉取最新脚本（静默，失败不阻塞）
  case $cmd in
    reality|hy2|ss|openlist) ensure_latest_script "$cmd" ;;
  esac
  case $cmd in
    menu|info|status|traffic|doctor|reload) ;;
    *) take_lock; setup_logging ;;
  esac
  case $cmd in
    menu) menu ;;
    reality) install_reality ;;
    hy2) install_hy2 ;;
    ss) install_ss ;;
    openlist) install_openlist_standalone ;;
    update) update_core ;;
    info) show_info ;;
    status) show_status ;;
    uninstall) uninstall_all ;;
    uninstall-reality) uninstall_protocol reality Reality ;;
    uninstall-hy2) uninstall_protocol hy2 HY2 ;;
    uninstall-ss) uninstall_protocol ss SS2022 ;;
    uninstall-openlist) uninstall_openlist ;;
    reload) reload_services ;;
    doctor) doctor ;;
    backup) backup "${2:-}" ;;
    restore) restore "${2:-}" ;;
    traffic) traffic ;;
    adduser) reality_adduser "${2:-}" ;;
    deluser) reality_deluser "${2:-}" ;;
    users) reality_users ;;
    bbr) enable_bbr ;;
    deps) cmd_deps ;;
    fixenv) fixenv ;;
  esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi

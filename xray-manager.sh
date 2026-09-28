#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT=/etc/xray-manager
STATE=$ROOT/state.json
XRAY_BIN=/usr/local/bin/xray
XRAY_CONF=/etc/xray/config.json
XRAY_ASSETS=/usr/local/share/xray
OPENLIST_DIR=/opt/openlist
NGINX_CONF=/etc/nginx/conf.d/xray-manager.conf
ACME_TMP_CONF=/etc/nginx/conf.d/xray-manager-acme.conf
ACME_WEBROOT=/var/www/xray-manager
CERT_ROOT=/etc/nginx/zs
ACME=/root/.acme.sh/acme.sh
SELF=/usr/local/bin/xray-manager
TMP_DIR=
INIT=
PKG=

say() { printf '%s\n' "$*"; }
err() { printf '错误：%s\n' "$*" >&2; exit 1; }
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
  [[ -f $STATE ]] || printf '%s\n' '{"domain":"","reality":null,"hy2":null,"ss":null}' > "$STATE"
  chmod 600 "$STATE"
}
state_get() { jq -r "$1 // empty" "$STATE"; }
has_reality() { [[ $(jq -r '.reality != null' "$STATE") == true ]]; }
has_hy2() { [[ $(jq -r '.hy2 != null' "$STATE") == true ]]; }
has_ss() { [[ $(jq -r '.ss != null' "$STATE") == true ]]; }

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
    if ! restart_or_start xray-manager; then
      [[ ! -f $TMP_DIR/xray-old ]] || install -m 755 "$TMP_DIR/xray-old" "$XRAY_BIN"
      [[ ! -f $TMP_DIR/geoip-old ]] || install -m 644 "$TMP_DIR/geoip-old" "$XRAY_ASSETS/geoip.dat"
      [[ ! -f $TMP_DIR/geosite-old ]] || install -m 644 "$TMP_DIR/geosite-old" "$XRAY_ASSETS/geosite.dat"
      restart_or_start xray-manager || true
      err 'Xray 更新后启动失败，已恢复旧内核。'
    fi
  fi
  say "Xray 内核与地理数据已更新：$($XRAY_BIN version | sed -n '1p')"
}

install_xray_service() {
  if [[ $INIT == systemd ]]; then
    cat > /etc/systemd/system/xray-manager.service <<EOF
[Unit]
Description=Personal Xray manager service
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
    systemctl enable xray-manager >/dev/null
  else
    cat > /etc/init.d/xray-manager <<EOF
#!/sbin/openrc-run
name="Personal Xray"
command="$XRAY_BIN"
command_args="run -c $XRAY_CONF"
command_background=true
pidfile="/run/xray-manager.pid"
export XRAY_LOCATION_ASSET="$XRAY_ASSETS"
depend() { need net; }
EOF
    chmod 755 /etc/init.d/xray-manager
    rc-update add xray-manager default >/dev/null
  fi
}

render_config() {
  local input=$1 output=$2
  jq -n --slurpfile state "$input" '
    $state[0] as $s |
    {log:{loglevel:"warning"},inbounds:(
      (if $s.reality then [{tag:"reality",listen:"0.0.0.0",port:443,protocol:"vless",settings:{users:[{id:$s.reality.uuid,flow:"xtls-rprx-vision"}],decryption:"none"},streamSettings:{method:"raw",security:"reality",realitySettings:{target:"127.0.0.1:8443",serverNames:[$s.domain],privateKey:$s.reality.private,shortIds:[$s.reality.sid]}}}] else [] end)
      + (if $s.hy2 then [{tag:"hy2",listen:"0.0.0.0",port:443,protocol:"hysteria",settings:{version:2,users:[{auth:$s.hy2.password}]},streamSettings:{method:"hysteria",security:"tls",hysteriaSettings:{version:2,auth:$s.hy2.password,masquerade:{type:"proxy",url:"http://127.0.0.1:5244"}},tlsSettings:{alpn:["h3"],certificates:[{certificateFile:$s.hy2.cert,keyFile:$s.hy2.key}]}}}] else [] end)
      + (if $s.ss then [{tag:"ss",listen:"0.0.0.0",port:$s.ss.port,protocol:"shadowsocks",settings:{method:"2022-blake3-aes-128-gcm",password:$s.ss.password,network:"tcp,udp"}}] else [] end)
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
  "$XRAY_BIN" run -test -config "$TMP_DIR/config-new" || { rollback_nginx; err 'Xray 配置验证失败。'; }
  cp -a "$STATE" "$state_bak"
  [[ ! -f $XRAY_CONF ]] || cp -a "$XRAY_CONF" "$conf_bak"
  install -m 600 "$new_state" "$STATE"
  install -m 600 "$TMP_DIR/config-new" "$XRAY_CONF"
  install_xray_service
  if ! restart_or_start xray-manager; then
    install -m 600 "$state_bak" "$STATE"
    if [[ -f $conf_bak ]]; then install -m 600 "$conf_bak" "$XRAY_CONF"; else rm -f "$XRAY_CONF"; fi
    restart_or_start xray-manager || true
    rollback_nginx
    err 'Xray 启动失败，已恢复原有配置。'
  fi
}

valid_domain() {
  [[ $1 =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] && ((${#1} <= 253))
}
ask_domain() {
  local current input
  current=$(state_get '.domain')
  if [[ -n $current ]]; then
    read -r -p "域名/SNI（必须与现有 $current 相同）：" input
    input=${input,,}
    [[ $input == "$current" ]] || err '当前 Reality/HY2 共用一个域名。'
  else
    read -r -p '请输入自己的域名/SNI（如 a.example.com）：' input
    input=${input,,}
    valid_domain "$input" || err '域名格式不正确。'
  fi
  DOMAIN=$input
}
cert_dir() { printf '%s/%s' "$CERT_ROOT" "${1%%.*}"; }
check_port_free() {
  local proto=$1 port=$2
  if [[ $proto == tcp ]]; then
    [[ -z $(ss -H -ltn "sport = :$port" 2>/dev/null) ]] || err "TCP $port 已被占用。"
  else
    [[ -z $(ss -H -lun "sport = :$port" 2>/dev/null) ]] || err "UDP $port 已被占用。"
  fi
}
preflight_domain_ports() {
  if ! has_reality; then
    if ! has_hy2; then check_port_free tcp 443; fi
    if [[ -z $(state_get '.domain') ]]; then check_port_free tcp 8443; fi
  fi
  [[ -x $OPENLIST_DIR/openlist ]] || check_port_free tcp 5244
}
preflight_hy2_port() { has_hy2 || check_port_free udp 443; }

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
issue_cert() {
  local domain=$1 dir owner mode token zone ipv6_http=
  dir=$(cert_dir "$domain")
  owner=$dir/domain.txt
  if [[ -f $owner && $(cat "$owner") != "$domain" ]]; then
    err "证书目录 $dir 已属于 $(cat "$owner")，域名前缀冲突。"
  fi
  if [[ -d $dir && ! -f $owner && -n $(find "$dir" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    err "证书目录 $dir 已有非本脚本管理的文件，停止以避免覆盖。"
  fi
  install -d -m 700 "$dir"
  printf '%s\n' "$domain" > "$owner"
  chmod 600 "$owner"
  if [[ -f $dir/fullchain.pem && -f $dir/privkey.pem ]] && openssl x509 -checkend 604800 -noout -in "$dir/fullchain.pem" >/dev/null 2>&1; then
    say '现有证书仍有效，继续使用。'; return
  fi
  install_acme
  say '证书验证方式：1) TCP 80  2) Cloudflare DNS API'
  read -r -p '请选择 [1/2]：' mode
  case "$mode" in
    1)
      CERT_METHOD=http
      install -d -m 755 "$ACME_WEBROOT/.well-known/acme-challenge"
      if [[ ! -f $NGINX_CONF ]]; then
        if ! svc_active nginx; then check_port_free tcp 80; fi
        if [[ -s /proc/net/if_inet6 ]]; then ipv6_http='listen [::]:80;'; fi
        cat > "$ACME_TMP_CONF" <<EOF
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
      fi
      if ! "$ACME" --issue --server letsencrypt --webroot "$ACME_WEBROOT" -d "$domain" --keylength ec-256; then
        err 'HTTP 80 证书申请失败，请确认 DNS 指向本机且 TCP 80 已放行。'
      fi
      ;;
    2)
      CERT_METHOD=dns
      read -r -s -p 'Cloudflare DNS API Token：' token; printf '\n'
      [[ -n $token ]] || err 'Token 不能为空。'
      read -r -p 'Cloudflare Zone ID（可留空自动查找）：' zone
      if ! CF_Token="$token" CF_Zone_ID="$zone" "$ACME" --issue --server letsencrypt --dns dns_cf -d "$domain" --keylength ec-256; then
        unset token; err 'Cloudflare DNS 证书申请失败。'
      fi
      unset token
      ;;
    *) err '请选择 1 或 2。' ;;
  esac
  printf '%s\n' "$CERT_METHOD" > "$ROOT/cert-method"
  chmod 600 "$ROOT/cert-method"
  "$ACME" --install-cert -d "$domain" --ecc \
    --key-file "$dir/privkey.pem" \
    --fullchain-file "$dir/fullchain.pem" \
    --reloadcmd "$SELF reload" || err '证书安装失败。'
  chmod 600 "$dir/privkey.pem" "$owner"
  chmod 644 "$dir/fullchain.pem"
}

install_openlist_service() {
  if [[ $INIT == systemd ]]; then
    cat > /etc/systemd/system/openlist-manager.service <<EOF
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
    systemctl enable openlist-manager >/dev/null
  else
    cat > /etc/init.d/openlist-manager <<EOF
#!/sbin/openrc-run
name="Personal OpenList"
directory="$OPENLIST_DIR"
command="$OPENLIST_DIR/openlist"
command_args="server"
command_background=true
pidfile="/run/openlist-manager.pid"
depend() { need net; }
EOF
    chmod 755 /etc/init.d/openlist-manager
    rc-update add openlist-manager default >/dev/null
  fi
}
install_openlist() {
  local domain=$1 binary pass config jwt
  if [[ -x $OPENLIST_DIR/openlist ]]; then
    [[ -f $ROOT/openlist-owned ]] || err "$OPENLIST_DIR 已存在非本脚本安装的 OpenList。"
    install_openlist_service
    if ! svc_active openlist-manager; then svc start openlist-manager || err 'OpenList 无法重新启动。'; fi
    if [[ ! -f $ROOT/openlist-password ]]; then
      pass=$(openssl rand -hex 18)
      (cd "$OPENLIST_DIR" && ./openlist admin set "$pass") || err '无法恢复 OpenList 管理员密码。'
      printf '%s\n' "$pass" > "$ROOT/openlist-password"
      chmod 600 "$ROOT/openlist-password"
    fi
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
  jq -n --arg url "https://$domain" --arg jwt "$jwt" \
    '{force:true,site_url:$url,jwt_secret:$jwt,database:{type:"sqlite3",db_file:"data/data.db"},scheme:{address:"127.0.0.1",http_port:5244,https_port:-1},temp_dir:"data/temp",bleve_dir:"data/bleve"}' > "$config"
  chmod 600 "$config"
  install_openlist_service
  restart_or_start openlist-manager || err 'OpenList 启动失败。'
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

write_nginx() {
  local state_file=$1 domain dir reality public_listen= backup= ipv6_http= ipv6_https=
  domain=$(jq -r '.domain' "$state_file")
  [[ -n $domain ]] || return
  dir=$(cert_dir "$domain")
  reality=$(jq -r '.reality != null' "$state_file")
  if [[ -s /proc/net/if_inet6 ]]; then
    ipv6_http='listen [::]:80;'
    ipv6_https='listen [::]:443 ssl;'
  fi
  [[ $reality == true ]] || public_listen=$'listen 443 ssl;\n    '"$ipv6_https"
  install -d -m 755 /etc/nginx/conf.d
  if [[ -f $NGINX_CONF ]]; then backup=$TMP_DIR/nginx-old; cp -a "$NGINX_CONF" "$backup"; fi
  touch "$TMP_DIR/nginx-staged"
  rm -f -- "$ACME_TMP_CONF"
  : > "$NGINX_CONF"
  if [[ -f $ROOT/cert-method && $(cat "$ROOT/cert-method") == http ]]; then
    cat >> "$NGINX_CONF" <<EOF
# Managed by xray-manager. Custom changes will be overwritten.
server {
    listen 80;
    $ipv6_http
    server_name $domain;
    location ^~ /.well-known/acme-challenge/ { root $ACME_WEBROOT; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
  fi
  cat >> "$NGINX_CONF" <<EOF
server {
    listen 127.0.0.1:8443 ssl;
    $public_listen
    server_name $domain;
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
  domain=$(state_get '.domain')
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
  ask_domain; preflight_domain_ports
  issue_cert "$DOMAIN"
  install_openlist "$DOMAIN"
  local keypair private public sid uuid
  keypair=$($XRAY_BIN x25519)
  private=$(awk -F': ' '/Private key:|PrivateKey:/{print $2}' <<< "$keypair" | head -n 1)
  public=$(awk -F': ' '/Public key:|Password:|PublicKey:/{print $2}' <<< "$keypair" | head -n 1)
  [[ -n $private && -n $public ]] || err 'Xray 密钥生成失败。'
  uuid=$($XRAY_BIN uuid)
  sid=$(random_hex 8)
  jq --arg d "$DOMAIN" --arg id "$uuid" --arg priv "$private" --arg pub "$public" --arg sid "$sid" \
    '.domain=$d | .reality={uuid:$id,private:$priv,public:$pub,sid:$sid}' "$STATE" > "$TMP_DIR/state-new"
  render_config "$TMP_DIR/state-new" "$TMP_DIR/check-config"
  "$XRAY_BIN" run -test -config "$TMP_DIR/check-config" || err 'Reality 配置验证失败。'
  write_nginx "$TMP_DIR/state-new"
  commit_state "$TMP_DIR/state-new"
  show_info
}

install_hy2() {
  install_common
  has_hy2 && err 'HY2 已安装。'
  ensure_web_deps
  ask_domain; preflight_hy2_port
  if ! has_reality; then preflight_domain_ports; fi
  issue_cert "$DOMAIN"
  install_openlist "$DOMAIN"
  local pass dir
  pass=$(random_hex 18)
  dir=$(cert_dir "$DOMAIN")
  jq --arg d "$DOMAIN" --arg pass "$pass" --arg cert "$dir/fullchain.pem" --arg key "$dir/privkey.pem" \
    '.domain=$d | .hy2={password:$pass,cert:$cert,key:$key}' "$STATE" > "$TMP_DIR/state-new"
  render_config "$TMP_DIR/state-new" "$TMP_DIR/check-config"
  "$XRAY_BIN" run -test -config "$TMP_DIR/check-config" || err 'HY2 配置验证失败。'
  write_nginx "$TMP_DIR/state-new"
  commit_state "$TMP_DIR/state-new"
  show_info
}

install_ss() {
  install_common
  has_ss && err 'SS 已安装。'
  local port pass address
  read -r -p '请输入 SS 端口（1-65535，不能是 443）：' port
  [[ $port =~ ^[0-9]+$ && ${#port} -le 5 ]] || err '端口无效。'
  port=$((10#$port))
  ((port >= 1 && port <= 65535 && port != 443)) || err '端口无效。'
  check_port_free tcp "$port"; check_port_free udp "$port"
  address=$(public_address)
  pass=$(openssl rand 16 | base64 | tr -d '\n')
  jq --argjson port "$port" --arg pass "$pass" --arg address "$address" \
    '.ss={port:$port,password:$pass,address:$address}' "$STATE" > "$TMP_DIR/state-new"
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
show_info() {
  require_root
  [[ -f $STATE ]] || err '尚未安装。'
  local domain uuid pub sid pass port address userpass encoded
  domain=$(state_get '.domain')
  say "Xray 配置：$XRAY_CONF"
  if [[ -n $domain ]]; then
    say "域名/SNI：$domain"
    if [[ -f $(cert_dir "$domain")/fullchain.pem ]]; then
      openssl x509 -noout -enddate -in "$(cert_dir "$domain")/fullchain.pem"
    fi
  fi
  if has_reality; then
    uuid=$(state_get '.reality.uuid'); pub=$(state_get '.reality.public'); sid=$(state_get '.reality.sid')
    show_link 'Reality' "vless://$uuid@$domain:443?encryption=none&security=reality&sni=$domain&fp=chrome&pbk=$pub&sid=$sid&flow=xtls-rprx-vision&type=tcp#Reality"
  fi
  if has_hy2; then
    pass=$(state_get '.hy2.password')
    show_link 'HY2' "hysteria2://$pass@$domain:443?sni=$domain#HY2"
  fi
  if has_ss; then
    pass=$(state_get '.ss.password'); port=$(state_get '.ss.port'); address=$(state_get '.ss.address')
    userpass="2022-blake3-aes-128-gcm:$pass"
    encoded=$(printf '%s' "$userpass" | url_base64)
    show_link 'SS2022' "ss://$encoded@$address:$port#SS2022"
  fi
  if [[ -n $domain ]]; then
    say "\nOpenList 地址：https://$domain"
    if [[ -f $ROOT/openlist-password ]]; then say "OpenList 管理员：admin  密码：$(cat "$ROOT/openlist-password")"; fi
  fi
  show_status
}
show_status() {
  require_root
  detect_env
  say '\n服务状态：'
  local name
  for name in xray-manager openlist-manager nginx; do
    if svc_active "$name"; then say "$name：运行中"; else say "$name：未运行"; fi
  done
  if [[ -x $XRAY_BIN ]]; then "$XRAY_BIN" version | sed -n '1p'; fi
}
reload_services() {
  require_root; detect_env
  if svc_active nginx; then nginx -t && svc reload nginx; fi
  if svc_active xray-manager; then svc restart xray-manager; fi
}
update_core() {
  require_root; detect_env; ensure_deps
  [[ -f $ROOT/core-owned && -f $STATE ]] || err '请先通过本脚本安装一种协议。'
  install_xray_core
}
remove_web_stack() {
  local domain=$1 dir
  if [[ -f $NGINX_CONF ]]; then
    cp -a "$NGINX_CONF" "$TMP_DIR/nginx-remove-old"
    rm -f -- "$NGINX_CONF"
    if ! nginx -t || (svc_active nginx && ! svc reload nginx); then
      cp -a "$TMP_DIR/nginx-remove-old" "$NGINX_CONF"
      svc_active nginx && svc reload nginx || true
      err 'Nginx 站点移除失败，已恢复站点文件。'
    fi
  fi
  svc stop openlist-manager >/dev/null 2>&1 || true
  svc disable openlist-manager >/dev/null 2>&1 || true
  if [[ $INIT == systemd ]]; then
    rm -f -- /etc/systemd/system/openlist-manager.service
    systemctl daemon-reload
  else
    rm -f -- /etc/init.d/openlist-manager
  fi
  if [[ -n $domain ]]; then
    dir=$(cert_dir "$domain")
    if [[ -f $dir/domain.txt && $(cat "$dir/domain.txt") == "$domain" ]]; then
      [[ ! -x $ACME ]] || "$ACME" --remove -d "$domain" --ecc >/dev/null 2>&1 || true
      rm -rf -- "$dir"
    fi
  fi
  if [[ -f $ROOT/openlist-owned ]]; then rm -rf -- "$OPENLIST_DIR"; fi
  rm -f -- "$ROOT/cert-method" "$ROOT/openlist-password" "$ROOT/openlist-owned" "$ACME_TMP_CONF"
  rm -rf -- "$ACME_WEBROOT"
}
uninstall_protocol() {
  local protocol=$1 label=$2 confirm domain remaining
  require_root; detect_env
  [[ -f $STATE ]] || err '没有本脚本管理的安装。'
  command -v jq >/dev/null 2>&1 || err '缺少 jq，无法安全修改配置。'
  [[ $(jq -r --arg p "$protocol" '.[$p] != null' "$STATE") == true ]] || err "$label 尚未安装。"
  read -r -p "只卸载 $label；输入 $label 确认：" confirm
  [[ $confirm == "$label" ]] || { say '已取消。'; return; }
  init_tmp
  domain=$(state_get '.domain')
  jq --arg p "$protocol" '.[$p] = null | if .reality == null and .hy2 == null then .domain = "" else . end' \
    "$STATE" > "$TMP_DIR/state-new"
  remaining=$(jq -r '[.reality,.hy2,.ss] | any(. != null)' "$TMP_DIR/state-new")
  if [[ $remaining == true ]]; then
    commit_state "$TMP_DIR/state-new"
    if [[ $protocol == reality && $(jq -r '.hy2 != null' "$STATE") == true ]]; then
      if ! write_nginx "$STATE"; then
        cp -a "$TMP_DIR/state-old" "$TMP_DIR/state-rollback"
        commit_state "$TMP_DIR/state-rollback" || true
        err 'Reality 卸载后的 Nginx 切换失败，已尝试恢复原配置。'
      fi
    fi
  else
    svc stop xray-manager || err 'Xray 停止失败，原配置未修改。'
    svc disable xray-manager >/dev/null 2>&1 || true
    install -m 600 "$TMP_DIR/state-new" "$STATE"
    rm -f -- "$XRAY_CONF"
  fi
  if [[ -n $domain && $(jq -r '.domain' "$STATE") == '' ]]; then remove_web_stack "$domain"; fi
  say "$label 已卸载；其他协议配置保留。"
}
uninstall_all() {
  require_root; detect_env
  [[ -f $STATE ]] || err '没有本脚本管理的安装。'
  local confirm domain dir
  read -r -p '将删除 Xray、OpenList、证书、配置和账号数据。输入 DELETE 确认：' confirm
  [[ $confirm == DELETE ]] || { say '已取消。'; return; }
  domain=$(state_get '.domain')
  for service in xray-manager openlist-manager; do
    svc stop "$service" >/dev/null 2>&1 || true
    svc disable "$service" >/dev/null 2>&1 || true
  done
  if [[ $INIT == systemd ]]; then
    rm -f /etc/systemd/system/xray-manager.service /etc/systemd/system/openlist-manager.service
    systemctl daemon-reload
  else
    rm -f /etc/init.d/xray-manager /etc/init.d/openlist-manager
  fi
  if [[ -n $domain ]]; then
    if [[ -x $ACME ]]; then "$ACME" --remove -d "$domain" --ecc >/dev/null 2>&1 || true; fi
    dir=$(cert_dir "$domain")
    if [[ -f $dir/domain.txt && $(cat "$dir/domain.txt") == "$domain" ]]; then rm -rf -- "$dir"; fi
  fi
  rm -f -- "$NGINX_CONF" "$ACME_TMP_CONF" "$XRAY_CONF" "$XRAY_BIN" "$SELF"
  rm -rf -- "$ACME_WEBROOT"
  rm -f -- "$XRAY_ASSETS/geoip.dat" "$XRAY_ASSETS/geosite.dat"
  if [[ -f $ROOT/openlist-owned ]]; then rm -rf -- "$OPENLIST_DIR"; fi
  rm -rf -- "$ROOT"
  if command -v nginx >/dev/null 2>&1 && svc_active nginx; then nginx -t && svc reload nginx || true; fi
  say '卸载完成。系统 Nginx 包与 acme.sh 程序仍保留。'
}

menu() {
  local choice
  while true; do
    cat <<'EOF'

===== 个人 Xray 管理 =====
1. 一键安装 Reality (TCP 443)
2. 一键安装 HY2 (UDP 443)
3. 一键安装 SS2022 (自选端口)
4. 更新 Xray 内核和地理数据
5. 查看当前配置、分享链接和服务状态
6. 一键卸载
7. 只卸载 Reality
8. 只卸载 HY2
9. 只卸载 SS2022
0. 退出
EOF
    read -r -p '请选择：' choice
    case "$choice" in
      1) install_reality ;;
      2) install_hy2 ;;
      3) install_ss ;;
      4) update_core ;;
      5) show_info ;;
      6) uninstall_all ;;
      7) uninstall_protocol reality Reality ;;
      8) uninstall_protocol hy2 HY2 ;;
      9) uninstall_protocol ss SS2022 ;;
      0) return ;;
      *) say '无效选项。' ;;
    esac
  done
}

main() {
  case ${1:-menu} in
    menu) menu ;;
    reality) install_reality ;;
    hy2) install_hy2 ;;
    ss) install_ss ;;
    update) update_core ;;
    info) show_info ;;
    status) show_status ;;
    uninstall) uninstall_all ;;
    uninstall-reality) uninstall_protocol reality Reality ;;
    uninstall-hy2) uninstall_protocol hy2 HY2 ;;
    uninstall-ss) uninstall_protocol ss SS2022 ;;
    reload) reload_services ;;
    *) say '用法：xray-manager [menu|reality|hy2|ss|update|info|status|uninstall|uninstall-reality|uninstall-hy2|uninstall-ss|reload]'; exit 2 ;;
  esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi

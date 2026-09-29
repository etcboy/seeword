#!/usr/bin/env bash
# seeword 一键安装器：下载主脚本到 /usr/local/bin/seeword 并启动。
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/etcboy/seeword/main/install.sh | sudo bash
set -Eeuo pipefail
umask 077

SRC=${SEEWORLD_URL:-https://raw.githubusercontent.com/etcboy/seeword/main/seeword.sh}
TARGET=${SEEWORLD_TARGET:-/usr/local/bin/seeword}

SUDO=
if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || { echo '需要 root 权限，但未找到 sudo。' >&2; exit 1; }
  SUDO=sudo
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
# 加时间戳避免 CDN 缓存旧版本
SRC="$SRC?t=$(date +%s)"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL --retry 3 "$SRC" -o "$tmp"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$tmp" "$SRC"
else
  echo '需要 curl 或 wget，请先安装其中之一。' >&2; exit 1
fi
[[ -s $tmp ]] || { echo '下载失败，中止安装。' >&2; exit 1; }
grep -q 'seeword' "$tmp" || { echo '下载内容异常，中止安装。' >&2; exit 1; }
bash -n "$tmp" || { echo '下载的脚本语法校验失败，中止安装。' >&2; exit 1; }
$SUDO install -m 755 "$tmp" "$TARGET"
# 创建 sw 快捷方式
$SUDO ln -sf "$TARGET" /usr/local/bin/sw
echo "已安装到 $TARGET（快捷命令：sw），正在启动…"
# 管道安装时 stdin 是 curl 的数据流，尝试把菜单接到终端以便交互
if { : </dev/tty; } 2>/dev/null; then
  exec $SUDO "$TARGET" "$@" </dev/tty
else
  exec $SUDO "$TARGET" "$@"
fi

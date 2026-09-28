#!/usr/bin/env bash
# xray-manager 一键安装器：下载主脚本到 /usr/local/bin/xray-manager 并启动。
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/xhtus/seeword/main/install.sh | sudo bash
set -Eeuo pipefail
umask 077

SRC=${XRAY_MANAGER_URL:-https://raw.githubusercontent.com/xhtus/seeword/main/xray-manager.sh}
TARGET=${XRAY_MANAGER_TARGET:-/usr/local/bin/xray-manager}

SUDO=
if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || { echo '需要 root 权限，但未找到 sudo。' >&2; exit 1; }
  SUDO=sudo
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl -fsSL --retry 3 "$SRC" -o "$tmp"
grep -q 'xray-manager' "$tmp" || { echo '下载内容异常，中止安装。' >&2; exit 1; }
bash -n "$tmp" || { echo '下载的脚本语法校验失败，中止安装。' >&2; exit 1; }
$SUDO install -m 755 "$tmp" "$TARGET"
echo "已安装到 $TARGET，正在启动…"
# 管道安装时 stdin 是 curl 的数据流，尝试把菜单接到终端以便交互
if { : </dev/tty; } 2>/dev/null; then
  exec $SUDO "$TARGET" "$@" </dev/tty
else
  exec $SUDO "$TARGET" "$@"
fi

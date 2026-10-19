#!/usr/bin/env bash
# 安装 vram-mode / free-vram 到 /usr/local/bin，并装好桌面与菜单入口。
#
#   ./install.sh            # 需要 sudo 一次
#   PREFIX=$HOME/.local ./install.sh   # 只装到用户目录（不装 desktop 图标）
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"
BIN="$PREFIX/bin"

if [[ $EUID -ne 0 ]]; then
  echo "需要 root 写 $BIN（一次即可）；重新执行：sudo $0"
  exec sudo -- "$0" "$@"
fi

TARGET_UID="${SUDO_UID:-$(id -u)}"
TARGET_USER="$(id -un "$TARGET_UID")"
TARGET_HOME="$(getent passwd "$TARGET_UID" | cut -d: -f6)"

install -Dm755 "$SRC/bin/vram-mode" "$BIN/vram-mode"
install -Dm755 "$SRC/bin/free-vram" "$BIN/free-vram"
echo "✔ $BIN/vram-mode"
echo "✔ $BIN/free-vram"

# 桌面 / 菜单入口。pkexec 指向 root 拥有的副本，别改成用户可写的路径。
if [[ -n $TARGET_HOME && $PREFIX == /usr/local ]]; then
  apps="$TARGET_HOME/.local/share/applications"
  desk="$TARGET_HOME/Desktop"
  [[ -d $desk ]] || desk=$TARGET_HOME
  mkdir -p "$apps"
  install -m755 "$SRC/desktop/free-vram-tty.desktop"   "$apps/"
  install -m755 "$SRC/desktop/vram-mode-desktop.desktop" "$apps/"
  install -m755 "$SRC/desktop/free-vram-tty.desktop"   "$desk/"
  chown -R "$TARGET_UID:$TARGET_UID" "$apps/free-vram-tty.desktop" \
        "$apps/vram-mode-desktop.desktop" "$desk/free-vram-tty.desktop" 2>/dev/null || true
  command -v update-desktop-database >/dev/null && \
    runuser -u "$TARGET_USER" -- update-desktop-database "$apps" 2>/dev/null || true
  echo "✔ 桌面图标: $desk/free-vram-tty.desktop"
  echo "✔ 菜单入口: Free VRAM (pure TTY) / Back to Desktop (leave TTY mode)"
fi

cat <<EOF

下一步：
  从桌面切到纯 tty : 点桌面上的 Free VRAM (pure TTY)，或 sudo vram-mode tty
  回到桌面模式     : sudo vram-mode desktop
  回 Deck UI       : sudo vram-mode game
  看状态           : vram-mode status
  自检             : vram-mode doctor
  只杀 Chrome/Steam: free-vram

--dry-run 可以先看计划：
  vram-mode tty --dry-run
EOF

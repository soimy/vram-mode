#!/usr/bin/env bash
# 安装 vram-mode / free-vram，并装好桌面与菜单入口。
#
#   ./install.sh                       # 装到 /usr/local（需要 sudo 一次）
#   PREFIX=$HOME/.local ./install.sh   # 只装到用户目录（不装桌面图标）
#
# 依赖：systemd + logind（vram-mode 的 tty/desktop 切换用 loginctl 找会话，
# 用 display-manager.service 找登录管理器）。Omarchy/Hyprland、KDE、GNOME、
# sway 都走同一条通用路径。
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"
BIN="$PREFIX/bin"

# 目标目录可写就直接装；不可写才提权（避免 PREFIX=$HOME/.local 也要 sudo）
can_write=0
if mkdir -p "$BIN" 2>/dev/null && [[ -w $BIN ]]; then can_write=1; fi
if [[ $EUID -ne 0 && $can_write -eq 0 ]]; then
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
if [[ $PREFIX == /usr/local && -n $TARGET_HOME ]]; then
  apps="$TARGET_HOME/.local/share/applications"
  desk="$TARGET_HOME/Desktop"
  user_bin="$TARGET_HOME/.local/bin"
  target_group="$(id -gn "$TARGET_UID")"
  mkdir -p "$apps"
  if ((EUID == 0)); then
    install -d -m755 -o "$TARGET_UID" -g "$target_group" "$user_bin"
  else
    mkdir -p "$user_bin"
  fi
  ln -sfnT "$BIN/vram-mode" "$user_bin/vram-mode"
  if ((EUID == 0)); then chown -h "$TARGET_UID:$target_group" "$user_bin/vram-mode"; fi
  install -m644 "$SRC/desktop/free-vram-tty.desktop"     "$apps/"
  install -m644 "$SRC/desktop/vram-mode-desktop.desktop" "$apps/"
  as_target() { if [[ $EUID -eq 0 && $TARGET_UID -ne 0 ]]; then runuser -u "$TARGET_USER" -- "$@"; else "$@"; fi; }
  as_target update-desktop-database "$apps" >/dev/null 2>&1 || true
  chown "$TARGET_UID:$TARGET_UID" "$apps/free-vram-tty.desktop" \
        "$apps/vram-mode-desktop.desktop" 2>/dev/null || true
  echo "✔ 菜单入口: Free VRAM (pure TTY) / Back to Graphical Desktop"

  if [[ -d $desk ]]; then
    install -m755 "$apps/free-vram-tty.desktop" "$desk/free-vram-tty.desktop"
    chown "$TARGET_UID:$TARGET_UID" "$desk/free-vram-tty.desktop" 2>/dev/null || true
    echo "✔ 桌面图标: $desk/free-vram-tty.desktop"
  else
    echo "– 桌面图标: 跳过（没有 $desk）"
  fi
  echo "✔ 用户命令: $user_bin/vram-mode -> $BIN/vram-mode"
elif [[ $PREFIX != /usr/local ]]; then
  echo "– 桌面/菜单入口: 跳过（PREFIX=$PREFIX）"
fi

cat <<EOF

下一步：
  从桌面切到纯 tty : 点菜单里的 Free VRAM (pure TTY)，或 sudo vram-mode tty
  回到图形桌面     : sudo vram-mode desktop
  看状态/自检      : vram-mode status | vram-mode doctor
  只杀 Chrome/Steam: free-vram
  Deck UI（仅掌机）: sudo vram-mode game

先看计划再动手（不实际切换）：
  vram-mode --dry-run tty
EOF

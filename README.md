# vram-mode

一键把图形会话关掉、切到**纯 TTY**，把显存和内存让给 ComfyUI、本地 LLM
这类想独占 GPU 的任务；再用一条命令切回图形桌面。

它不是某个发行版或某个桌面的补丁，而是一套 **systemd + logind 通用方案**：

| 层 | 怎么找 | 覆盖 |
|---|---|---|
| 会话 | `loginctl`（`show-user -p Display`，回退到 `list-sessions` + `Type=wayland/x11`） | 不依赖进程名 |
| 桌面 | `XDG_CURRENT_DESKTOP`（会话环境）→ 进程名 → `uwsm check` | Hyprland / KDE / GNOME / sway |
| 登录管理器 | `display-manager.service` 别名，回退到 sddm/gdm/lightdm/greetd/ly/… | 发行版自行决定 |
| GPU | `nvidia-smi` → amdgpu sysfs | NVIDIA / AMD |

只要满足 **systemd（或 elogind）+ logind + util-linux + 一个
display-manager.service**，Omarchy/Hyprland、KDE Plasma、GNOME、sway 以及
Bazzite/SteamOS 的 Steam Deck UI 都走同一条路径。

```
$ vram-mode status
Mode             desktop (Hyprland)
VRAM             1140 / 24576 MiB (23436 free)  [nvidia]
RAM              6800 MiB used, 41200 MiB available
Session          sym (uid 1000), session 1 on tty1
Desktop          Hyprland — logout via uwsm stop
Display manager  sddm.service (active, enabled)
Autologin        user=sym, session=omarchy.desktop
GPU              NVIDIA GeForce RTX 3090 (nvidia-smi)
Installed        /usr/local/bin/vram-mode
```

## 安装

```bash
git clone git@github.com:soimy/vram-mode.git ~/Repo/vram-mode
cd ~/Repo/vram-mode
./install.sh                          # 首次安装：/usr/local/bin（脚本自己 sudo）
PREFIX=$HOME/.local ./install.sh      # 或只装到 ~/.local/bin，不装桌面图标
```

`./install.sh` 是**唯一的首次安装入口**：它同时装 `vram-mode` 和 `free-vram`，
并在 `~/.local/share/applications` 放两个菜单入口（有 `~/Desktop` 时才放桌面图标）。

装好之后，`sudo vram-mode install` 用于原地更新和补装菜单入口 —— 它不能当
引导用：命令还没装进 PATH 时，`sudo vram-mode install` 只会得到
`sudo: vram-mode: command not found`。

> `~/.local/bin` 不在 sudo 的 `secure_path` 里。装到用户目录后，
> `vram-mode status` 正常，但换模式要写绝对路径
> （`sudo ~/.local/bin/vram-mode tty`，横幅也会这么提示），或者直接用
> 默认的 `/usr/local/bin` 安装。`PREFIX=$HOME/.local` 不会装桌面/菜单入口。


## 用法

| 命令 | 作用 |
|---|---|
| `sudo vram-mode tty` | 图形会话 → 纯 TTY，停掉会话和登录管理器 |
| `sudo vram-mode desktop` | 纯 TTY → 图形会话（拉起 display-manager，等 autologin） |
| `sudo vram-mode game` | 纯 TTY → Steam Deck UI（**仅**存在 `steamosctl` 的掌机） |
| `vram-mode status` | 当前模式 + 显存/内存 + 桌面/登录管理器 |
| `vram-mode doctor` | 自检：依赖、会话栈、autologin、GPU |
| `vram-mode --dry-run tty` | 只打印计划，什么都不动 |
| `free-vram` | 轻量版：只杀 Chrome/Chromium + Steam，保留桌面 |

`tty`/`desktop`/`game` 会先 `sudo` 提权，再把自己作为 **transient system
unit**（`systemd-run --system`）重新执行 —— 因为切换动作最后要拆掉发起命令
所在的那个 cgroup，不隔离出去就会把自己一起杀掉。进度看
`journalctl -t vram-mode -f`。

如果同一台机器上还有**别的用户**开着图形会话，`tty` 会拒绝执行
（停 display-manager 会把对方一起干掉）；确认要停就加 `--force`。

## tty 模式做了什么

1. 用 `loginctl` 找到你的图形会话（session id、所在 VT、桌面类型）
2. **优雅退出**：按桌面类型调用对应适配器，让应用能存盘
   （Hyprland+uwsm → `uwsm stop`；GNOME → `gnome-session-quit --logout`；
   Plasma → `qdbus6 org.kde.Shutdown /Shutdown org.kde.Shutdown.logout`；
   sway → `swaymsg exit`）
3. 等几秒；还在就 `loginctl terminate-session <id>` —— 这是对所有桌面都成立的
   兜底，整个 session scope 连同里面的进程一起结束
4. `systemctl stop display-manager.service`（解析出来的真实 unit，不写死 sddm）
5. `systemctl stop graphical.target`
6. `pkill` 兜底还在的合成器（kwin/plasmashell/gnome-shell/Hyprland/sway/gamescope/Xorg）
7. `systemctl start getty@ttyN`；仅在能检测到控制台宽度至少 2560 像素，且
   `setfont` 和 Terminus 字体均已安装时，才在目标 VT 加载最大字号（优先
   `ter-132n`，16×32）。低于 2560 像素、无法检测分辨率或缺少依赖时保留当前
   字体设置。之后 `chvt N` 并打印横幅；首选会话原来的 VT，getty 起不来就换一个空 VT。

`desktop` 是反过程：`systemctl start display-manager` →
（Bazzite 上额外 `steamosctl switch-to-desktop-mode`）→ 轮询 `loginctl` 等
图形会话出现。如果只有 greeter 在等人登录，会明确告诉你，并打印当前
autologin 配置，而不是假装成功。

> 刻意不用 `systemctl isolate multi-user.target`：`isolate` 会停掉一切不在目标
> 依赖树里的 unit —— 包括正在执行切换的 transient unit，切到一半自己就没了。
> 也刻意不写死 `sddm`：`display-manager.service` 是各发行版约定的别名。

## 桌面适配器

| 桌面 | 识别信号 | 优雅退出 | 兜底 |
|---|---|---|---|
| Hyprland | `XDG_CURRENT_DESKTOP` / `Hyprland` 进程 / `uwsm check is-active hyprland.desktop` | `uwsm stop`（uwsm 会话）或 `hyprctl dispatch exit` | `loginctl terminate-session` |
| KDE Plasma | `KDE` / `plasma` / `plasmashell` / `kwin_wayland` / `kwin_x11` | `qdbus6 org.kde.Shutdown` | 同上 |
| GNOME | `GNOME` / `ubuntu` / `gnome-shell` | `gnome-session-quit --logout --no-prompt` | 同上 |
| sway | `sway` / `swaymsg` | `swaymsg exit`（自动补 `SWAYSOCK`） | 同上 |
| Steam Deck UI | `gamescope` 进程 | — | 同上 |
| 其它 | 任意 wayland/x11 会话 | — | 同上 |

autologin 是**登录管理器**的概念，`status`/`doctor` 会尽力解析：
SDDM `/etc/sddm.conf{,.d/*.conf}` 的 `[Autologin]`、GDM
`/etc/gdm{,3}/custom.conf` 的 `[daemon] AutomaticLogin*`、LightDM
`lightdm.conf` 的 `autologin-user`、greetd `/etc/greetd/config.toml` 的
`[initial_session]`。解析不到也不影响切换，只是 `desktop` 可能停在 greeter。

## 出问题了怎么救

```bash
# 卡在黑屏/旧画面：切到别的 VT
Ctrl+Alt+F2                     # 或 F3..F6

# 回图形会话
sudo systemctl start graphical.target
sudo systemctl start display-manager.service

# 完全不依赖显示管理器（在 tty 里直接起桌面）
uwsm start -g -1 -e -D Hyprland hyprland.desktop   # Hyprland
dbus-run-session startplasma-wayland               # Plasma
dbus-run-session -- gnome-session                  # GNOME

# 看切换过程 / 自检
sudo vram-mode doctor
journalctl -t vram-mode -f
```

## free-vram

`vram-mode tty` 是重锤（整个会话）。只想清出浏览器 + Steam 的显存、保留桌面
时用 `free-vram`：

```bash
free-vram --status     # 谁在占显存
free-vram --dry-run    # 计划
free-vram              # 开杀，打印显存差值
```

它只碰两组目标，**不动**合成器、shell 和会话里的其它东西：

- Chrome / Chromium：原生进程（`chrome`/`chromium`/`google-chrome*`）以及
  flatpak 的 `com.google.Chrome` / `org.chromium.Chromium`（含其 instance
  scope 和 autostart unit）
- Steam：原生客户端 / webhelper / pressure-vessel，以及 Bazzite 的
  `app-steam@autostart.service`（存在就优先停 unit，走 cgroup 语义）

先 `SIGTERM` 让它们自己存盘退出，超时才 `SIGKILL`。

## 踩过的坑（都已修掉，记在这里免得再踩）

**1. 用 `systemctl isolate` 切换会把自己杀掉。** 见上面 tty 模式说明。

**2. `steamosctl switch-to-desktop-mode` 只记录"下次进哪个会话"，不负责启动。**
真正把会话拉起来的是登录管理器的重新 autologin。如果登录管理器没在跑，
这个调用会把当前会话杀掉，然后什么都不启动 —— 屏幕上只剩 tty。
所以 `desktop` 先 `systemctl start display-manager.service`（或 `graphical.target`）。

**3. "某个进程在跑"不等于"会话起来了"。** 在活着的桌面上调用切换命令时，
plasmashell 当然在跑。现在改成用 `loginctl` 看**图形会话是否真的存在**，
等待时轮询的是会话，不是进程名。

**4. 已经在图形会话里就不要再调 `desktop`。** 现在发现会话已存在就直接返回。

**5. `pgrep -f gamescope` 会匹配到自己。** 任何命令行里带 `gamescope` 字样的
shell 都会被算成"游戏模式在跑"。判断用 `pgrep -x`（按进程名精确匹配）。

**6. 驱动坏了时 `nvidia-smi` 会把报错打到 stdout。** 旧版本直接把它当成
"已用显存"参与算术，在 `set -u` 下炸出 `line 333: NVIDIA: unbound variable`。
现在所有 GPU 数值都要先过 `^[0-9]+$`，否则显示 `n/a`。

**7. 停用户 `app.slice` 会连 `dbus.socket` 一起带走**，之后 `podman`/`distrobox`
会退回 system bus 被 polkit 拒绝，报一个毫不相干的 `OCI permission denied`。
通用路径不再去停 app.slice：直接 `loginctl terminate-session` 结束整个会话，
登录到新 tty 会拿到全新的会话总线和 systemd user manager。

**8. `install.sh` 曾经在没有 `~/Desktop` 时把图标装进 `$HOME`。** 现在
`~/Desktop` 不存在就跳过桌面图标，只装菜单入口。

## 测试环境

- Omarchy 4.0.5 / Hyprland 0.56.2 / uwsm 0.27.1 / SDDM 0.21.0 / systemd 262，
  RTX 3090 24GB（NVIDIA 驱动）
- Bazzite `bazzite-deck-nvidia`（kinoite base），RTX 5080 16GB：该机上实测
  tty 模式显存 1653 MiB → 约 50–150 MiB，可用内存多出约 2 GB
- 依赖：`systemctl`、`loginctl`、`systemd-run`、`runuser`、`chvt`（`vram-mode doctor`
  会逐项检查；`pkexec`、`logger` 可选）

## License

MIT

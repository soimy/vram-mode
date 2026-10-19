# vram-mode

在 Bazzite / bazzite-deck 上，一键把桌面会话关掉、切到**纯 TTY**，
把显存和内存让给 ComfyUI、本地 LLM 这类想独占 GPU 的任务；
再用一条命令切回 Plasma 桌面。

Bazzite 自带的是「game mode ↔ desktop mode」切换，这个工具补的是第三条路：
**desktop ↔ tty**。

```
$ vram-mode status
Mode               desktop
VRAM               1653 / 16303 MiB  (14650 free)
Plasma             running
sddm               inactive
```

## 安装

```bash
git clone git@github.com:soimy/vram-mode.git ~/Repo/vram-mode
cd ~/Repo/vram-mode
./install.sh          # 需要 sudo 一次，装到 /usr/local/bin
```

## 用法

| 命令 | 作用 |
|---|---|
| `sudo vram-mode tty` | 桌面/Deck UI → 纯 tty，停掉全部图形会话 |
| `sudo vram-mode desktop` | 纯 tty → Plasma 桌面 |
| `sudo vram-mode game` | 纯 tty → Steam Deck UI |
| `vram-mode status` | 当前模式 + 显存/内存 + 谁在占 GPU |
| `vram-mode doctor` | 自检：依赖、unit 状态、会话栈 |
| `vram-mode <action> --dry-run` | 只打印计划，什么都不动 |
| `free-vram` | 轻量版：只杀 Chrome + Steam，保留桌面 |

切到 tty 后终端上方会打印一个横幅，告诉你显存/内存和回来的命令。

## tty 模式做了什么

1. `systemctl --user stop app.slice` — Chrome、Steam、终端、portal
2. `systemctl --user stop graphical-session.target` — kwin、plasmashell、kded
3. `systemctl --user start dbus.socket` — 把会话总线拉回来（见下面的坑）
4. `systemctl stop graphical.target sddm` — 显示管理器
5. `pkill` 兜底 kwin/plasmashell/gamescope，`chvt` 到你的 tty，打印横幅

整个切换是以 **transient system unit**（`systemd-run --system`）跑的，
因为第 1 步会杀掉发起命令的那个 cgroup —— 不隔离出去，命令会把自己也干掉。

预期收益（RTX 5080 / 16GB，实测）：显存 1653 MiB → 约 50–150 MiB，
可用内存多出约 2 GB。

## 踩过的坑（都已修掉，记在这里免得再踩）

**1. 别用 `systemctl isolate multi-user.target`。**
`isolate` 会停掉一切不在目标依赖树里的 unit —— 包括正在执行切换的那个
transient unit，于是切到一半自己没了。改用显式 `stop graphical.target sddm`。

**2. `steamosctl switch-to-desktop-mode` 只记录"下次进哪个会话"，不负责启动。**
真正把会话拉起来的是 **SDDM 的重新 autologin**。如果 SDDM 没在跑
（比如你之前 isolate 到 multi-user.target 过），这个调用会把当前会话杀掉，
然后什么都不启动 —— 屏幕上只剩 tty，看起来像"桌面回不来了"。
所以 `vram-mode desktop` 会先 `systemctl start sddm`。

**3. "plasmashell 在跑"不等于"会话起来了"。**
在活着的桌面上调用切换命令时，plasmashell 当然在跑 —— 判断会立刻通过，
而真正的拆会话动作才刚开始。现在改成对比 **PID**：必须是切换之后新冒出来的
plasmashell 才算成功。

**4. 已经在桌面模式时不要调 `desktop`。**
会触发 steamos-manager 把当前会话停掉重来。现在 `vram-mode desktop` 发现
plasmashell 已在跑就直接返回，什么都不做。

**5. `pgrep -f gamescope` 会匹配到自己。**
任何命令行里带 `gamescope` 字样的 shell 都会被算成"游戏模式在跑"。
用 `pgrep -x`（按进程名精确匹配）。

**6. 停 `app.slice` 会把 `dbus.socket` 一起带走。**
用户会话总线死了之后，`podman` / `distrobox` 会在建 cgroup 时退回到 system bus，
被 polkit 拒绝，报出来的是这个毫不相干的错误：

```
crun: sd-bus call: Access denied as the requested operation requires
interactive authentication ...: Permission denied: OCI permission denied
```

所以 tty 模式在停完 app.slice 后会立刻 `systemctl --user start dbus.socket`。
如果你有别的脚本会停 app.slice，记得也补这一步。

## 出问题了怎么救

```bash
# 卡在黑屏/旧画面
Ctrl+Alt+F1                     # 或 F2..F6，getty 在 tty1 / tty3

# 回桌面
sudo systemctl start graphical.target
sudo steamosctl switch-to-desktop-mode plasma.desktop
sudo steamosctl switch-to-game-mode            # 回 Deck UI，再用"切换到桌面"

# 完全不依赖显示管理器（在 tty 里直接起 Plasma）
dbus-run-session startplasma-wayland

# 看切换过程
sudo vram-mode doctor
journalctl -t vram-mode -f
```

## free-vram

`vram-mode tty` 是重锤（整个会话）。只想清出 Chrome + Steam 的显存、
保留桌面时用 `free-vram`：

```bash
free-vram --status     # 谁在占显存
free-vram --dry-run    # 计划
free-vram              # 开杀，打印显存差值
```

它只碰 `com.google.Chrome`（flatpak）和 `app-steam@autostart.service`，
不会动 plasmashell / kwin / Xwayland。

## 测试环境

- Bazzite `bazzite-deck-nvidia` F44（kinoite base），RTX 5080 16GB
- 依赖：`systemd-run`、`runuser`、`chvt`、`loginctl`、`steamosctl`、`pkexec`
  （`vram-mode doctor` 会逐项检查）
- 非 deck 的普通 KDE/Fedora 上，`tty` 和 `free-vram` 同样可用；
  `desktop` 的 steamosctl 分支会自动跳过，退化到 `systemctl start graphical.target`

## License

MIT

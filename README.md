# Pressure

macOS 菜单栏小工具：图标显示系统内存压力等级，点开看谁在吃内存。

```
kern.memorystatus_vm_pressure_level ──(启动 + 每 10 s)──┐
DispatchSource 内存压力事件 ──────────(收到时)──────────┴─▶ PressureMonitor ─▶ 菜单栏图标

点开菜单 ─▶ FootprintScanner ─┬─ proc_listpids → proc_pid_rusage(ri_phys_footprint)
                             │    → 按 responsible App 聚合 → Top 3
                             └─ sysctl vm.swapusage
```

## 构建

```bash
./build.sh
```

`swiftc -O` 编译 → 拼装 `build/Pressure.app` → 签名 → 复制到 `~/Applications/Pressure.app` 并重启。
需要 Xcode Command Line Tools，目标 macOS 13+，无第三方依赖。
App 图标由 `icon.swift` 和 `Sources/StatusIcon.swift` 一起编译导出，两者共用同一个仪表盘绘制函数。

## 使用

- 图标是一个压力表：240° 粗弧分三段，从左往右随等级点亮：1 段正常，2 段警告，3 段严重，未点亮段半透明。单色模板图，跟随菜单栏深浅色。
- 快捷键 ⌃⌥⌘P 打开菜单（和点图标一样），全局有效，不需要辅助功能权限。
- 菜单：顶部居中一个大号仪表（和菜单栏图标同一个绘制函数），下面是压力等级（NORMAL / WARNING / CRITICAL）；再下面是 Swap 用量。
  下面是内存占用最高的 3 个 App，每个下面一条分段条（20 段，每段 = 物理内存的 5%），切法和图标一致。数值用等宽字体，文字用系统黑，只有仪表和分段条用浅灰。
  每个进程归给系统记录的 responsible 进程所在的 App（和活动监视器的分组一致）：App 自己的 helper、它用到的 XPC 服务
  （如 Safari 的 WebKit 网页进程）、在终端里敲的命令（Ghostty 里的 claude）都算进对应 App。不属于任何 App 的系统进程不显示。

## 设计取舍

- **尽量事件驱动**：进程扫描只在点开菜单时做一次、不缓存。等级本想完全靠内核推送，但实测不行：
  内核按进程占用从大到小发压力通知、压力一缓解就停，Pressure 这样十来 MB 的进程常常收不到
  （一次实测：正常↔警告跳了 3 次，收到 0 个事件）。所以另加每 10 s 读一次 sysctl，允许系统推迟 5 s 合并唤醒，
  图标最多晚约 15 s。
- **看压力，不看「已用内存」**：macOS 会主动把空闲内存拿去做缓存和压缩，「已用」总是接近满，说明不了问题；
  压力等级才是系统自己判断「内存不够了」的信号。
- **内存数值**用 `ri_phys_footprint`，和活动监视器「内存」列同一口径。

## 已知限制

- App 合计是各进程 footprint 直接相加。共享的脏内存只记在一个进程名下，所以不会重复计入：实测与 `footprint -p …` 多进程去重后的总数相差 0–2 MB。
- `responsibility_get_pid_responsible_for_pid` 是 libSystem 里的私有符号，无公开文档。
- 菜单行是自绘的 view：系统菜单里不可点的行一律画成灰色，没法改色。
- 读不到其他用户（root 等）的进程，`WindowServer`、`kernel_task` 不会出现。

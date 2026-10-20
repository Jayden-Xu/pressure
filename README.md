# Pressure

macOS 菜单栏小工具：图标显示系统内存压力等级，点开看谁在吃内存，可以直接退出它。

```
kern.memorystatus_vm_pressure_level ──(启动读一次)──┐
DispatchSource 内存压力事件 ───────(等级变化时)────┴─▶ PressureMonitor ─▶ 菜单栏图标

点开菜单 ─▶ FootprintScanner ─┬─ proc_listpids → proc_pid_rusage(ri_phys_footprint)
                             │    → 按最外层 .app 聚合 → 排除 excludedBundleIDs → Top N
                             └─ sysctl vm.swapusage
```

## 构建

```bash
./build.sh
```

`swiftc -O` 编译 → 拼装 `build/Pressure.app` → 签名 → 复制到 `~/Applications/Pressure.app` 并重启。
需要 Xcode Command Line Tools，目标 macOS 13+，无第三方依赖。
App 图标由 `icon.swift` 和 `Sources/StatusIcon.swift` 一起编译导出，两者共用同一个胶囊绘制函数。

## 使用

- 图标是一个竖向胶囊，填充高度表示等级：1/3 正常，2/3 警告，满格严重。单色模板图，跟随菜单栏深浅色。
- 菜单：压力等级、Swap 用量、内存占用 Top N。App 行右侧有两个按钮：
  「退出」等同 ⌘Q，App 可以保存状态、询问未保存的文档；「强制退出」直接结束进程（SIGKILL），卡死的 App 也能关，未保存的内容会丢。
  不在 `.app` 里的进程（`python`、`node` 等）只显示、没有按钮。
- 配置（重新打开菜单即生效）：

```bash
defaults write com.jayden.pressure topN -int 3
defaults write com.jayden.pressure excludedBundleIDs -array com.apple.Terminal com.mitchellh.ghostty
```

## 设计取舍

- **事件驱动**：没有定时器。等级变化由内核推送；进程扫描只在点开菜单时做一次、不缓存。空闲时 CPU 和唤醒都是 0。
- **看压力，不看「已用内存」**：macOS 会主动把空闲内存拿去做缓存和压缩，「已用」总是接近满，说明不了问题；
  压力等级才是系统自己判断「内存不够了」的信号。
- **内存数值**用 `ri_phys_footprint`，和活动监视器「内存」列同一口径。

## 已知限制

- Safari 等 WebKit 网页进程在 `/System/Library/...` 下的 `.xpc` 里，不在 Safari.app 内，会按进程名单独列出。
- 菜单行是自绘的 view：系统菜单里不可点的行一律画成灰色，没法改色。
- 读不到其他用户（root 等）的进程，`WindowServer`、`kernel_task` 不会出现。

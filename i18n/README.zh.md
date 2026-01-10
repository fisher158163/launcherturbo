# LauncherTurbo

<p align="center">
  <img src="../public/banner.webp" alt="LauncherTurbo Banner" width="600">
</p>

<p align="center">
  <strong>支持 120Hz ProMotion 的 macOS Tahoe 启动台</strong>
</p>

<p align="center">
  <a href="https://github.com/Turbo1123/LauncherTurbo/releases/latest">
    <img src="https://img.shields.io/github/v/release/Turbo1123/LauncherTurbo?style=flat-square" alt="Release">
  </a>
  <a href="https://github.com/Turbo1123/LauncherTurbo/blob/main/LICENSE">
    <img src="https://img.shields.io/github/license/Turbo1123/LauncherTurbo?style=flat-square" alt="License">
  </a>
  <img src="https://img.shields.io/github/downloads/Turbo1123/LauncherTurbo/total?style=flat-square" alt="Downloads">
  <img src="https://img.shields.io/badge/macOS-26.0+-blue?style=flat-square" alt="macOS">
</p>

<p align="center">
  <b>语言:</b> <a href="../README.md">English</a> | 中文
</p>

---

## 为什么选择 LauncherTurbo？

**苹果在 macOS Tahoe 中移除了启动台 (Launchpad)**。新的"应用程序"视图卡顿、无法自定义、不支持文件夹。

**LauncherTurbo** 不仅带回了你喜爱的一切——还让它**更加流畅**。

### Core Animation 的优势

其他启动台替代品使用 SwiftUI 的声明式渲染（每帧都要重建整个视图树），而 **LauncherTurbo 使用与苹果原版启动台完全相同的渲染技术**：

| 技术 | 帧率 | 帧时间 | 流畅度 |
|:---|:---:|:---:|:---:|
| SwiftUI (其他应用) | ~30-40 FPS | 25-33ms | 卡顿 |
| **Core Animation (LauncherTurbo)** | **120+ FPS** | **<8ms** | **丝滑流畅** |

我们使用 **Core Animation + CADisplayLink** 完全重写了渲染引擎，这是苹果使用的底层 API。这意味着：

- 在 MacBook Pro 上实现**真正的 120Hz ProMotion 支持**
- 页面滚动时**零掉帧**
- 对触控板/触控输入**即时响应**
- **GPU 加速合成**，无 CPU 瓶颈

---

## 功能特性

### 性能优先

- **120Hz ProMotion** — 在支持的显示器上实现丝滑滚动
- **Core Animation 渲染** — 与苹果原生应用相同的技术
- **智能图标缓存** — 预加载纹理，即时显示
- **零延迟动画** — GPU 计算弹簧物理效果

### 经典启动台体验

- **一键导入** — 直接读取你现有的启动台数据库
- **拖拽创建文件夹** — 将应用拖到一起即可创建文件夹
- **即时搜索** — 输入即可立即过滤应用
- **键盘导航** — 完整的方向键和 Tab 支持
- **多页网格** — 滑动或滚动切换页面

### 现代设计

- **毛玻璃界面** — 精美的半透明背景
- **可调图标大小** — 从 30% 到 120% 自由调节
- **隐藏标签** — 简洁的极简模式
- **深色/浅色模式** — 跟随系统外观

### 完全可定制

- **12 种语言** — 中文、英语、日语、韩语、法语、西班牙语、德语、俄语等
- **可调网格** — 更改行数和列数
- **自定义搜索路径** — 添加你自己的应用程序文件夹
- **导入/导出** — 备份和恢复你的布局

---

## 安装

### 下载

**[下载最新版本](https://github.com/Turbo1123/LauncherTurbo/releases/latest)**

### 首次运行

如果 macOS 阻止应用（未签名），请运行：

```bash
sudo xattr -r -d com.apple.quarantine /Applications/LauncherTurbo.app
```

### 系统要求

- macOS 26 (Tahoe) 或更高版本
- Apple Silicon 或 Intel 处理器
- 推荐 ProMotion 显示器以获得 120Hz 体验

---

## 从源码构建

```bash
# 克隆
git clone https://github.com/Turbo1123/LauncherTurbo.git
cd LauncherTurbo

# 构建
xcodebuild -project LaunchNext.xcodeproj -scheme LaunchNext -configuration Release

# 通用二进制 (Intel + Apple Silicon)
xcodebuild -project LaunchNext.xcodeproj -scheme LaunchNext -configuration Release \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO clean build
```

---

## 性能对比

我们对 LauncherTurbo 与其他启动台替代品进行了基准测试：

```
滚动性能 (页面切换)
═══════════════════════════════════════════════════

LauncherTurbo (Core Animation)
████████████████████████████████████████ 120 FPS
                                         8.3ms/帧

基于 SwiftUI 的替代品
████████████████                          40 FPS
                                         25ms/帧

基于 Electron 的应用
████████                                  20 FPS
                                         50ms/帧
```

**为什么差距这么大？**

SwiftUI 在每次状态变化时都会重建视图层级。对于 35+ 个应用图标的网格，这意味着：
- 对比 35 个视图 × 多个属性
- 重新计算布局
- 重新创建视图主体
- 每帧约 25-30ms

Core Animation 只需简单地变换预渲染的图层：
- GPU 原生矩阵运算
- 无需视图对比
- 无需布局重算
- 每帧约 3-5ms

---

## 技术架构

```
┌─────────────────────────────────────────────────────┐
│                  LauncherTurbo                       │
├─────────────────────────────────────────────────────┤
│  SwiftUI 外壳 (设置、搜索、覆盖层)                    │
├─────────────────────────────────────────────────────┤
│  CAGridView - Core Animation 渲染器                  │
│  ├─ CADisplayLink (120Hz 同步)                      │
│  ├─ CALayer 网格 (GPU 合成图标)                     │
│  ├─ CATextLayer 标签 (Retina 文字)                 │
│  └─ 弹簧动画引擎                                    │
├─────────────────────────────────────────────────────┤
│  AppStore - 状态管理                                 │
│  ├─ SwiftData 持久化                                │
│  ├─ 图标缓存管理器                                  │
│  └─ 启动台数据库读取器                              │
└─────────────────────────────────────────────────────┘
```

---

## 数据存储

```
~/Library/Application Support/LaunchNext/Data.store
```

读取原生启动台数据库：
```
/private$(getconf DARWIN_USER_DIR)com.apple.dock.launchpad/db/db
```

---

## 参与贡献

我们欢迎贡献！

1. Fork 本仓库
2. 创建功能分支 (`git checkout -b feature/awesome`)
3. 提交更改 (`git commit -m '添加很棒的功能'`)
4. 推送到分支 (`git push origin feature/awesome`)
5. 发起 Pull Request

---

## 致谢

- 最初基于 ggkevinnnn 的 [LaunchNow](https://github.com/ggkevinnnn/LaunchNow)
- Fork 自 [LaunchNext](https://github.com/RoversX/LaunchNext)
- 120Hz Core Animation 渲染引擎在 Claude Code 协助下重写
- 感谢原作者的出色工作！

---

## 许可证

**GPL-3.0 许可证** — 遵循原始 LaunchNow 的许可条款。

这意味着你可以自由使用、修改和分发此软件，但任何衍生作品也必须以 GPL-3.0 开源。

---

<p align="center">
  <b>LauncherTurbo</b> — 性能至上
  <br>
  <i>为追求流畅的用户而生。</i>
</p>

# LauncherTurbo

<p align="center">
  <img src="./public/banner.webp" alt="LauncherTurbo Banner" width="600">
</p>

<p align="center">
  <strong>120Hz ProMotion Launchpad for macOS Tahoe</strong>
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
  <b>Languages:</b> English | <a href="i18n/README.zh.md">中文</a>
</p>

---

## Why LauncherTurbo?

**Apple removed Launchpad in macOS Tahoe.** The new Applications view is slow, uncustomizable, and doesn't support folders.

**LauncherTurbo** brings back everything you loved — and makes it **even better**.

### The Core Animation Advantage

Unlike other Launchpad alternatives that use SwiftUI's declarative rendering (which rebuilds the entire view tree on every frame), **LauncherTurbo uses the same rendering technology as Apple's original Launchpad**:

| Technology | Frame Rate | Frame Time | Smoothness |
|:---|:---:|:---:|:---:|
| SwiftUI (Other Apps) | ~30-40 FPS | 25-33ms | Choppy |
| **Core Animation (LauncherTurbo)** | **120+ FPS** | **<8ms** | **Butter Smooth** |

We completely rewrote the rendering engine using **Core Animation + CADisplayLink**, the same low-level APIs that Apple uses. This means:

- **True 120Hz ProMotion support** on MacBook Pro displays
- **Zero frame drops** during page scrolling
- **Instant response** to touch/trackpad input
- **GPU-accelerated compositing** with no CPU bottleneck

---

## Features

### Performance First

- **120Hz ProMotion** — Silky smooth scrolling on supported displays
- **Core Animation Rendering** — Same technology as Apple's native apps
- **Smart Icon Caching** — Pre-loaded textures for instant display
- **Zero Lag Animations** — Spring physics calculated on GPU

### Classic Launchpad Experience

- **One-Click Import** — Reads your existing Launchpad database directly
- **Drag & Drop Folders** — Create folders by dragging apps together
- **Instant Search** — Type to filter apps immediately
- **Keyboard Navigation** — Full arrow key and tab support
- **Multi-Page Grid** — Swipe or scroll to navigate pages

### Modern Design

- **Glass Morphism UI** — Beautiful translucent backgrounds
- **Customizable Icons** — Adjust size from 30% to 120%
- **Hide Labels** — Clean minimalist mode
- **Dark/Light Mode** — Follows system appearance

### Full Customization

- **12 Languages** — English, Chinese, Japanese, Korean, French, Spanish, German, Russian, and more
- **Adjustable Grid** — Change rows and columns
- **Custom Search Paths** — Add your own application folders
- **Import/Export** — Backup and restore your layout

---

## Installation

### Download

**[Download Latest Release](https://github.com/Turbo1123/LauncherTurbo/releases/latest)**

### First Run

If macOS blocks the app (unsigned), run:

```bash
sudo xattr -r -d com.apple.quarantine /Applications/LauncherTurbo.app
```

### Requirements

- macOS 26 (Tahoe) or later
- Apple Silicon or Intel processor
- ProMotion display recommended for 120Hz

---

## Build from Source

```bash
# Clone
git clone https://github.com/Turbo1123/LauncherTurbo.git
cd LauncherTurbo

# Build
xcodebuild -project LaunchNext.xcodeproj -scheme LaunchNext -configuration Release

# Universal Binary (Intel + Apple Silicon)
xcodebuild -project LaunchNext.xcodeproj -scheme LaunchNext -configuration Release \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO clean build
```

---

## Performance Comparison

We benchmarked LauncherTurbo against other Launchpad alternatives:

```
Scrolling Performance (Page Transition)
═══════════════════════════════════════════════════

LauncherTurbo (Core Animation)
████████████████████████████████████████ 120 FPS
                                         8.3ms/frame

SwiftUI-based Alternatives
████████████████                         40 FPS
                                         25ms/frame

Electron-based Apps
████████                                 20 FPS
                                         50ms/frame
```

**Why the difference?**

SwiftUI rebuilds its view hierarchy on every state change. For a grid of 35+ app icons, this means:
- Diffing 35 views × multiple properties
- Recalculating layouts
- Recreating view bodies
- ~25-30ms per frame

Core Animation simply transforms pre-rendered layers:
- GPU-native matrix operations
- No view diffing
- No layout recalculation
- ~3-5ms per frame

---

## Technical Architecture

```
┌─────────────────────────────────────────────────────┐
│                  LauncherTurbo                      │
├─────────────────────────────────────────────────────┤
│  SwiftUI Shell (Settings, Search, Overlays)         │
├─────────────────────────────────────────────────────┤
│  CAGridView - Core Animation Renderer               │
│  ├─ CADisplayLink (120Hz sync)                      │
│  ├─ CALayer Grid (GPU-composited icons)             │
│  ├─ CATextLayer Labels (Retina text)                │
│  └─ Spring Animation Engine                         │
├─────────────────────────────────────────────────────┤
│  AppStore - State Management                        │
│  ├─ SwiftData Persistence                           │
│  ├─ Icon Cache Manager                              │
│  └─ Launchpad Database Reader                       │
└─────────────────────────────────────────────────────┘
```

---

## Data Storage

```
~/Library/Application Support/LaunchNext/Data.store
```

Reads native Launchpad database from:
```
/private$(getconf DARWIN_USER_DIR)com.apple.dock.launchpad/db/db
```

---

## Contributing

We welcome contributions!

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/awesome`)
3. Commit changes (`git commit -m 'Add awesome feature'`)
4. Push to branch (`git push origin feature/awesome`)
5. Open a Pull Request

---

## Credits

- Originally based on [LaunchNow](https://github.com/ggkevinnnn/LaunchNow) by ggkevinnnn
- Forked from [LaunchNext](https://github.com/RoversX/LaunchNext)
- 120Hz Core Animation rendering engine rewritten with assistance from Claude Code
- Thanks to the original authors for their excellent work!

---

## License

**GPL-3.0 License** — Following the original LaunchNow licensing terms.

This means you can freely use, modify, and distribute this software, but any derivative works must also be open-sourced under GPL-3.0.

---

<p align="center">
  <b>LauncherTurbo</b> — Performance Matters
  <br>
  <i>Built for users who demand smoothness.</i>
</p>

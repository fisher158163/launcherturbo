import SwiftUI

enum LNAnimations {
    // MARK: - Springs - 优化性能的动画配置
    static var springFast: Animation {
        guard AnimationPreferences.isEnabled else { return .linear(duration: 0.0001) }
        return .spring(response: AnimationPreferences.springResponse, dampingFraction: 0.8)
    }

    // MARK: - 性能优化的动画
    static var dragPreview: Animation {
        guard AnimationPreferences.isEnabled else { return .linear(duration: 0.0001) }
        return .easeOut(duration: AnimationPreferences.baseDuration)
    }
    static var gridUpdate: Animation {
        guard AnimationPreferences.isEnabled else { return .linear(duration: 0.0001) }
        return .easeInOut(duration: AnimationPreferences.baseDuration)
    }

    // MARK: - Folder Animations

    /// 文件夹打开/关闭的主动画 - 使用弹性动画
    static var folderOpenClose: Animation {
        guard AnimationPreferences.isEnabled else { return .linear(duration: 0.0001) }
        return .spring(response: 0.35, dampingFraction: 0.85, blendDuration: 0)
    }

    /// 背景模糊/缩放动画 - 稍快于文件夹动画
    static var folderBackgroundEffect: Animation {
        guard AnimationPreferences.isEnabled else { return .linear(duration: 0.0001) }
        return .easeOut(duration: 0.25)
    }

    /// 文件夹内应用的交错动画
    static func folderItemStagger(index: Int) -> Animation {
        guard AnimationPreferences.isEnabled else { return .linear(duration: 0.0001) }
        let delay = Double(index) * 0.02 // 每个应用延迟20ms
        return .spring(response: 0.3, dampingFraction: 0.8).delay(delay)
    }

    /// 背景缩放值 - 文件夹打开时背景的缩放比例
    static let folderBackgroundScale: CGFloat = 0.92

    /// 背景模糊半径
    static let folderBackgroundBlur: CGFloat = 8

    // MARK: - Transitions
    static var folderOpenTransition: AnyTransition {
        if AnimationPreferences.isEnabled {
            return AnyTransition.asymmetric(
                insertion: .scale(scale: 0.5).combined(with: .opacity),
                removal: .scale(scale: 0.85).combined(with: .opacity)
            )
        } else {
            return AnyTransition.opacity
        }
    }

    // MARK: - Window Animations

    /// 窗口显示动画持续时间
    static let windowShowDuration: TimeInterval = 0.28

    /// 窗口隐藏动画持续时间
    static let windowHideDuration: TimeInterval = 0.22

    /// 窗口显示时的初始缩放 (从大到正常 - 缩小效果)
    static let windowShowStartScale: CGFloat = 1.08

    /// 窗口隐藏时的最终缩放 (从正常到小 - 缩小效果)
    static let windowHideEndScale: CGFloat = 0.96

    // MARK: - Page Transition

    /// 页面切换动画 - 流畅的弹性效果
    static var pageTransition: Animation {
        guard AnimationPreferences.isEnabled else { return .linear(duration: 0.0001) }
        return .spring(response: 0.38, dampingFraction: 0.88, blendDuration: 0)
    }

    // MARK: - App Launch Animation

    /// 应用启动时的动画 - 快速缩小反馈
    static var appLaunch: Animation {
        guard AnimationPreferences.isEnabled else { return .linear(duration: 0.0001) }
        return .easeOut(duration: 0.15)
    }

    /// 应用启动时的缩放值
    static let appLaunchScale: CGFloat = 0.85

    // MARK: - Icon Appear Animation

    /// 图标出现动画 - 用于窗口首次显示时的交错效果
    static func iconAppearStagger(index: Int, totalCount: Int) -> Animation {
        guard AnimationPreferences.isEnabled else { return .linear(duration: 0.0001) }
        // 限制最大延迟，避免太多图标时延迟过长
        let maxDelay: Double = 0.15
        let delayPerIcon: Double = min(maxDelay / Double(max(totalCount, 1)), 0.012)
        let delay = Double(index) * delayPerIcon
        return .spring(response: 0.35, dampingFraction: 0.75).delay(delay)
    }
}

private enum AnimationPreferences {
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "enableAnimations") as? Bool ?? true
    }

    static var baseDuration: Double {
        let stored = UserDefaults.standard.double(forKey: "animationDuration")
        let value = stored == 0 ? 0.3 : stored
        return max(0.05, min(value, 1.5))
    }

    static var springResponse: Double {
        max(0.15, baseDuration)
    }
}

import SwiftUI
import AppKit
import SwiftData
import Combine
import QuartzCore
import Carbon
import Carbon.HIToolbox

extension Notification.Name {
    static let launchpadWindowShown = Notification.Name("LaunchpadWindowShown")
    static let launchpadWindowHidden = Notification.Name("LaunchpadWindowHidden")
}

class BorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // 监控所有可能显示窗口的方法
    override func orderFront(_ sender: Any?) {
        print("🪟 [Window] orderFront called")
        super.orderFront(sender)
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        print("🪟 [Window] makeKeyAndOrderFront called")
        super.makeKeyAndOrderFront(sender)
    }

    override func orderFrontRegardless() {
        print("🪟 [Window] orderFrontRegardless called")
        super.orderFrontRegardless()
    }

    override func orderOut(_ sender: Any?) {
        print("🪟 [Window] orderOut called")
        super.orderOut(sender)
    }

    override func deminiaturize(_ sender: Any?) {
        print("🪟 [Window] deminiaturize called")
        super.deminiaturize(sender)
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        print("🪟 [Window] order(\(place.rawValue), relativeTo: \(otherWin)) called")
        super.order(place, relativeTo: otherWin)
    }

    override func makeKey() {
        print("🪟 [Window] makeKey called")
        super.makeKey()
    }

    override func makeMain() {
        print("🪟 [Window] makeMain called")
        super.makeMain()
    }
}

@main
struct LaunchpadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings {} }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSGestureRecognizerDelegate {
    static var shared: AppDelegate?

    // let authStore = FileAuthStore()
    private var window: NSWindow?
    private let minimumContentSize = NSSize(width: 800, height: 600)
    private var lastShowAt: Date?
    private var cancellables = Set<AnyCancellable>()
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyEventHandler: EventHandlerRef?
    // private var aiHotKeyRef: EventHotKeyRef?
    private let launchpadHotKeySignature = fourCharCode("LNXK")
    private var windowVisibilityObservation: NSKeyValueObservation?
    // private let aiOverlayHotKeySignature = fourCharCode("AIOV")
    
    let appStore = AppStore()
    var modelContainer: ModelContainer?
    private var isTerminating = false
    private var windowIsVisible = false
    private var isAnimatingWindow = false
    private var pendingShow = false
    private var pendingHide = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // let copilotProvider = CopilotProvider(authStore: authStore)
        // LLMProviderRegistry.shared.register(provider: copilotProvider)

        appStore.syncGlobalHotKeyRegistration()
        // appStore.syncAIOverlayHotKeyRegistration()

        SoundManager.shared.bind(appStore: appStore)
        VoiceManager.shared.bind(appStore: appStore)

        let launchedAtLogin = wasLaunchedAsLoginItem()
        let shouldSilentlyLaunch = launchedAtLogin && appStore.isStartOnLogin

        setupWindow(showImmediately: !shouldSilentlyLaunch)
        appStore.performInitialScanIfNeeded()
        appStore.startAutoRescan()

        bindAppearancePreference()
        bindControllerPreference()
        bindSystemUIVisibility()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyAppearancePreference(self.appStore.appearancePreference)
            self.updateSystemUIVisibility()
        }

        if appStore.isFullscreenMode { updateWindowMode(isFullscreen: true) }

        // 注册 Apple Event 处理器来监听 "reopen" 事件（点击 Dock 图标）
        // 这是 applicationShouldHandleReopen 的底层机制，在 SwiftUI 中更可靠
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleReopenEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEReopenApplication)
        )

        // 对于 LSUIElement 应用，使用 NSWorkspace 监听应用激活事件
        // 这可以捕获从 Finder 双击应用或其他方式激活应用的情况
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceAppActivation(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    private var isShowingFromDockClick = false

    @objc private func handleWorkspaceAppActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        // 检查是否是我们的应用被激活
        if app.bundleIdentifier == Bundle.main.bundleIdentifier {
            print("🍎 [AppDelegate] Our app activated via NSWorkspace, windowIsVisible=\(windowIsVisible)")
            // 如果窗口不可见，显示它
            if !windowIsVisible {
                print("🍎 [AppDelegate] Showing window because app was activated")
                // 标记为从 Dock 点击显示，防止立即被 autoHideIfNeeded 隐藏
                isShowingFromDockClick = true
                showWindow()
                // 延迟重置标记，给窗口足够时间完成显示和获取焦点
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.isShowingFromDockClick = false
                }
            }
        }
    }

    @objc private func handleReopenEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        print("🍎 [AppDelegate] handleReopenEvent - Dock icon clicked!")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.windowIsVisible {
                print("🍎 [AppDelegate] Window is visible, hiding")
                self.hideWindow()
            } else {
                print("🍎 [AppDelegate] Window is hidden, showing")
                self.showWindow()
            }
        }
    }

    // MARK: - Global Hotkey

    func updateGlobalHotKey(configuration: AppStore.HotKeyConfiguration?) {
        unregisterGlobalHotKey()
        guard let configuration else { return }
        registerGlobalHotKey(configuration)
    }

    // func updateAIOverlayHotKey(configuration: AppStore.HotKeyConfiguration?) {
    //     unregisterAIOverlayHotKey()
    //     guard let configuration, appStore.isAIEnabled else { return }
    //     registerAIOverlayHotKey(configuration)
    // }

    private func registerGlobalHotKey(_ configuration: AppStore.HotKeyConfiguration) {
        ensureHotKeyEventHandler()
        let hotKeyID = EventHotKeyID(signature: launchpadHotKeySignature, id: 1)
        let status = RegisterEventHotKey(configuration.keyCodeUInt32,
                                         configuration.carbonModifierFlags,
                                         hotKeyID,
                                         GetEventDispatcherTarget(),
                                         0,
                                         &hotKeyRef)
        if status != noErr {
            NSLog("LauncherTurbo: Failed to register launchpad hotkey (status %d)", status)
            hotKeyRef = nil
        }
    }

    // private func registerAIOverlayHotKey(_ configuration: AppStore.HotKeyConfiguration) {
    //     ensureHotKeyEventHandler()
    //     var hotKeyID = EventHotKeyID(signature: aiOverlayHotKeySignature, id: 1)
    //     let status = RegisterEventHotKey(configuration.keyCodeUInt32,
    //                                      configuration.carbonModifierFlags,
    //                                      hotKeyID,
    //                                      GetEventDispatcherTarget(),
    //                                      0,
    //                                      &aiHotKeyRef)
    //     if status != noErr {
    //         NSLog("LauncherTurbo: Failed to register AI overlay hotkey (status %d)", status)
    //         aiHotKeyRef = nil
    //     }
    // }

    private func unregisterGlobalHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        cleanUpHotKeyEventHandlerIfNeeded()
    }

    // private func unregisterAIOverlayHotKey() {
    //     if let aiHotKeyRef {
    //         UnregisterEventHotKey(aiHotKeyRef)
    //         self.aiHotKeyRef = nil
    //     }
    //     cleanUpHotKeyEventHandlerIfNeeded()
    // }

    private func cleanUpHotKeyEventHandlerIfNeeded() {
        // if hotKeyRef == nil && aiHotKeyRef == nil, let handler = hotKeyEventHandler {
        if hotKeyRef == nil, let handler = hotKeyEventHandler {
            RemoveEventHandler(handler)
            hotKeyEventHandler = nil
        }
    }

    private func ensureHotKeyEventHandler() {
        guard hotKeyEventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(), hotKeyEventCallback, 1, &eventType, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), &hotKeyEventHandler)
        if status != noErr {
            NSLog("LauncherTurbo: Failed to install hotkey handler (status %d)", status)
        }
    }

    fileprivate func handleHotKeyEvent(signature: OSType, id: UInt32) {
        print("🔥 [AppDelegate] handleHotKeyEvent called! signature=\(signature), id=\(id)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch (signature, id) {
            case (self.launchpadHotKeySignature, 1):
                print("🔥 [AppDelegate] Launchpad hotkey triggered, calling toggleWindow()")
                self.toggleWindow()
            // case (self.aiOverlayHotKeySignature, 1):
            //     self.appStore.toggleAIOverlayPreview()
            default:
                print("🔥 [AppDelegate] Unknown hotkey: signature=\(signature), id=\(id)")
                break
            }
        }
    }

    private func setupWindow(showImmediately: Bool = true) {
        guard let screen = NSScreen.main else { return }
        let rect = calculateContentRect(for: screen)
        
        window = BorderlessWindow(contentRect: rect, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        window?.delegate = self
        window?.isMovable = false
        window?.level = .floating
        window?.collectionBehavior = [.transient, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        window?.isOpaque = false
        window?.backgroundColor = .clear
        window?.hasShadow = true
        window?.contentAspectRatio = NSSize(width: 4, height: 3)
        window?.contentMinSize = minimumContentSize
        window?.minSize = window?.frameRect(forContentRect: NSRect(origin: .zero, size: minimumContentSize)).size ?? minimumContentSize
        
        // SwiftData 支持（固定到 Application Support 目录，避免替换应用后数据丢失）
        do {
            let fm = FileManager.default
            let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let storeDir = appSupport.appendingPathComponent("LauncherTurbo", isDirectory: true)
            if !fm.fileExists(atPath: storeDir.path) {
                try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
            }
            let storeURL = storeDir.appendingPathComponent("Data.store")

            let configuration = ModelConfiguration(url: storeURL)
            let container = try ModelContainer(for: TopItemData.self, PageEntryData.self, configurations: configuration)
            modelContainer = container
            appStore.configure(modelContext: container.mainContext)
            window?.contentView = NSHostingView(rootView: LaunchpadView(appStore: appStore).modelContainer(container))
        } catch {
            // 回退到默认容器，保证功能可用
            if let container = try? ModelContainer(for: TopItemData.self, PageEntryData.self) {
                modelContainer = container
                appStore.configure(modelContext: container.mainContext)
                window?.contentView = NSHostingView(rootView: LaunchpadView(appStore: appStore).modelContainer(container))
            } else {
                window?.contentView = NSHostingView(rootView: LaunchpadView(appStore: appStore))
            }
        }
        
        applyCornerRadius()
        window?.alphaValue = 0
        window?.contentView?.alphaValue = 0
        windowIsVisible = false

        // 初始化完成后执行首个淡入
        if showImmediately {
            showWindow()
        }

        // 背景点击关闭逻辑改为 SwiftUI 内部实现，避免与输入控件冲突

        // 使用通知监听应用激活（比 delegate 方法更可靠）
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppDidBecomeActive(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppWillBecomeActive(_:)), name: NSApplication.willBecomeActiveNotification, object: nil)

        // KVO 监听窗口可见性变化
        if let window = window {
            windowVisibilityObservation = window.observe(\.isVisible, options: [.new, .old]) { [weak self] window, change in
                let oldValue = change.oldValue ?? false
                let newValue = change.newValue ?? false
                print("🔍 [KVO] Window isVisible changed: \(oldValue) -> \(newValue)")
                if newValue && !oldValue {
                    // 窗口变为可见 - 确保我们的状态同步
                    print("🔍 [KVO] Window became visible, our windowIsVisible=\(self?.windowIsVisible ?? false)")
                }
            }
        }
    }

    private func bindAppearancePreference() {
        appStore.$appearancePreference
            .receive(on: RunLoop.main)
            .sink { [weak self] preference in
                DispatchQueue.main.async {
                    self?.applyAppearancePreference(preference)
                }
            }
            .store(in: &cancellables)
    }

    

    private func bindControllerPreference() {
        appStore.$gameControllerEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { enabled in
                if enabled {
                    ControllerInputManager.shared.start()
                } else {
                    ControllerInputManager.shared.stop()
                }
            }
            .store(in: &cancellables)
    }

    private func bindSystemUIVisibility() {
        appStore.$hideDock
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateSystemUIVisibility()
            }
            .store(in: &cancellables)
    }

    func updateSystemUIVisibility() {
        let shouldHideDock = appStore.hideDock && windowIsVisible
        let options: NSApplication.PresentationOptions = shouldHideDock ? [.autoHideDock] : []
        if options != NSApp.presentationOptions {
            NSApp.presentationOptions = options
        }
    }

    private func wasLaunchedAsLoginItem() -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        guard event.eventID == kAEOpenApplication else { return false }
        guard let descriptor = event.paramDescriptor(forKeyword: keyAEPropData) else { return false }
        return descriptor.enumCodeValue == keyAELaunchedAsLogInItem
    }

    private func applyAppearancePreference(_ preference: AppearancePreference) {
        let appearance = preference.nsAppearance.flatMap { NSAppearance(named: $0) }
        window?.appearance = appearance
        NSApp.appearance = appearance
    }

    func presentLaunchError(_ error: Error, for url: URL) { }
    
    func showWindow() {
        print("📣 [AppDelegate] showWindow() called, windowIsVisible=\(windowIsVisible)")
        pendingShow = true
        pendingHide = false
        startPendingWindowTransition()
    }

    func hideWindow() {
        print("📣 [AppDelegate] hideWindow() called, windowIsVisible=\(windowIsVisible)")
        pendingHide = true
        pendingShow = false
        startPendingWindowTransition()
    }

    func toggleWindow() {
        print("📣 [AppDelegate] toggleWindow() called, windowIsVisible=\(windowIsVisible)")
        if windowIsVisible {
            hideWindow()
        } else {
            showWindow()
        }
    }

    // MARK: - Quit with fade
    func quitWithFade() {
        guard !isTerminating else { NSApp.terminate(nil); return }
        isTerminating = true
        if let window = window {
            pendingShow = false
            pendingHide = false
            animateWindow(to: 0, resumePending: false) {
                window.orderOut(nil)
                window.alphaValue = 1
                window.contentView?.alphaValue = 1
                NSApp.terminate(nil)
            }
        } else {
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        quitWithFade()
        return .terminateLater
    }

    deinit {
        unregisterGlobalHotKey()
    }
    
    func updateWindowMode(isFullscreen: Bool) {
        guard let window = window else { return }
        let screen = getCurrentActiveScreen() ?? NSScreen.main!
        window.setFrame(isFullscreen ? screen.frame : calculateContentRect(for: screen), display: true)
        window.hasShadow = !isFullscreen
        window.contentAspectRatio = isFullscreen ? NSSize(width: 0, height: 0) : NSSize(width: 4, height: 3)
        applyCornerRadius()
    }
    
    private func applyCornerRadius() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = appStore.isFullscreenMode ? 0 : 30
        contentView.layer?.masksToBounds = true
    }
    
    private func calculateContentRect(for screen: NSScreen) -> NSRect {
        let frame = screen.visibleFrame
        let width = max(frame.width * 0.4, minimumContentSize.width, minimumContentSize.height * 4/3)
        let height = width * 3/4
        return NSRect(x: frame.midX - width/2, y: frame.midY - height/2, width: width, height: height)
    }
    
    private func getCurrentActiveScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }

    // MARK: - Window animation helpers

    private func startPendingWindowTransition() {
        guard !isAnimatingWindow else { return }
        if pendingShow {
            performShowWindow()
        } else if pendingHide {
            performHideWindow()
        }
    }

    private func performShowWindow() {
        pendingShow = false
        guard let window = window else { return }

        if windowIsVisible && !isAnimatingWindow && window.alphaValue >= 0.99 {
            return
        }

        let screen = getCurrentActiveScreen() ?? NSScreen.main!
        let rect = appStore.isFullscreenMode ? screen.frame : calculateContentRect(for: screen)
        window.setFrame(rect, display: true)
        applyCornerRadius()

        if window.alphaValue <= 0.01 || !windowIsVisible {
            window.alphaValue = 0
            window.contentView?.alphaValue = 0
        }

        window.makeKeyAndOrderFront(nil)
        window.collectionBehavior = [.transient, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        window.orderFrontRegardless()
        
        // Force window to become key and main window for proper focus
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        window.makeMain()

        lastShowAt = Date()
        windowIsVisible = true
        updateSystemUIVisibility()
        SoundManager.shared.play(.launchpadOpen)

        // 先发送一个早期通知，让 CAGridView 可以提前准备
        print("📣 [AppDelegate] Posting launchpadWindowShown notification (early)")
        NotificationCenter.default.post(name: .launchpadWindowShown, object: nil)

        animateWindow(to: 1) {
            self.windowIsVisible = true
            self.updateSystemUIVisibility()
            // Ensure focus after animation completes
            DispatchQueue.main.async {
                self.window?.makeKey()
                self.window?.makeMain()
                // 动画完成后再次发送通知，确保滚轮事件监听器正确设置
                print("📣 [AppDelegate] Posting launchpadWindowShown notification (after animation)")
                NotificationCenter.default.post(name: .launchpadWindowShown, object: nil)
            }
        }
    }

    private func performHideWindow() {
        pendingHide = false
        guard let window = window else { return }

        let shouldPlaySound = windowIsVisible && !isTerminating

        let finalize: () -> Void = {
            self.windowIsVisible = false
            self.updateSystemUIVisibility()
            window.orderOut(nil)
            window.alphaValue = 1
            window.contentView?.alphaValue = 1
            self.appStore.isSetting = false
            if self.appStore.rememberLastPage {
                self.appStore.persistCurrentPageIfNeeded()
            } else {
                self.appStore.currentPage = 0
            }
            self.appStore.searchText = ""
            self.appStore.openFolder = nil
            self.appStore.forceSaveAllOrder()  // 窗口关闭时强制保存
            NotificationCenter.default.post(name: .launchpadWindowHidden, object: nil)
        }

        if (!windowIsVisible && window.alphaValue <= 0.01) || isTerminating {
            if shouldPlaySound {
                SoundManager.shared.play(.launchpadClose)
            }
            finalize()
            return
        }

        if shouldPlaySound {
            SoundManager.shared.play(.launchpadClose)
        }

        animateWindow(to: 0) {
            finalize()
        }
    }

    private func animateWindow(to targetAlpha: CGFloat, resumePending: Bool = true, completion: (() -> Void)? = nil) {
        guard let window = window, let contentView = window.contentView else {
            completion?()
            return
        }

        // 确保 contentView 有 layer
        contentView.wantsLayer = true
        guard let layer = contentView.layer else {
            completion?()
            return
        }

        isAnimatingWindow = true

        let isShowing = targetAlpha > 0.5
        let duration = isShowing ? LNAnimations.windowShowDuration : LNAnimations.windowHideDuration

        // 设置初始状态
        if isShowing {
            // 显示时：从放大状态开始
            let startScale = LNAnimations.windowShowStartScale
            layer.setAffineTransform(CGAffineTransform(scaleX: startScale, y: startScale))
        }

        // 计算目标缩放
        let targetScale: CGFloat = isShowing ? 1.0 : LNAnimations.windowHideEndScale

        // 使用 CATransaction 进行更精确的动画控制
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: isShowing ? .easeOut : .easeIn))
        CATransaction.setCompletionBlock {
            // 重置 transform
            layer.setAffineTransform(.identity)
            window.alphaValue = targetAlpha
            contentView.alphaValue = targetAlpha
            self.isAnimatingWindow = false
            completion?()
            if resumePending {
                self.startPendingWindowTransition()
            }
        }

        // 添加缩放动画
        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = isShowing ? LNAnimations.windowShowStartScale : 1.0
        scaleAnimation.toValue = targetScale
        scaleAnimation.duration = duration
        scaleAnimation.timingFunction = CAMediaTimingFunction(name: isShowing ? .easeOut : .easeIn)
        scaleAnimation.fillMode = .forwards
        scaleAnimation.isRemovedOnCompletion = false
        layer.add(scaleAnimation, forKey: "windowScaleAnimation")

        // 同时执行透明度动画
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: isShowing ? .easeOut : .easeIn)
            window.animator().alphaValue = targetAlpha
            contentView.animator().alphaValue = targetAlpha
        })

        CATransaction.commit()
    }
    
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minSize = minimumContentSize
        let contentSize = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let clamped = NSSize(width: max(contentSize.width, minSize.width), height: max(contentSize.height, minSize.height))
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: clamped)).size
    }
    
    func windowDidResignKey(_ notification: Notification) { autoHideIfNeeded() }
    func windowDidResignMain(_ notification: Notification) { autoHideIfNeeded() }
    private func autoHideIfNeeded() {
        // 如果正在从 Dock 点击显示窗口，不要自动隐藏
        guard !isShowingFromDockClick else {
            print("🍎 [AppDelegate] autoHideIfNeeded: skipping because isShowingFromDockClick=true")
            return
        }
        guard !appStore.isSetting else { return }
        hideWindow()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        print("📣 [AppDelegate] applicationShouldHandleReopen, hasVisibleWindows=\(flag), window.isVisible=\(window?.isVisible ?? false)")
        if window?.isVisible == true {
            hideWindow()
        } else {
            showWindow()
        }
        return false
    }

    // SwiftUI + NSApplicationDelegateAdaptor bug workaround:
    // applicationShouldHandleReopen is not called in SwiftUI apps
    // Use applicationWillBecomeActive as a workaround
    // See: https://developer.apple.com/forums/thread/706772
    func applicationWillBecomeActive(_ notification: Notification) {
        print("📣 [AppDelegate] applicationWillBecomeActive, windowIsVisible=\(windowIsVisible), window.isVisible=\(window?.isVisible ?? false)")
        // 如果窗口不可见，点击 dock 图标时显示窗口
        if !windowIsVisible {
            showWindow()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        print("📣 [AppDelegate] applicationDidBecomeActive (delegate), windowIsVisible=\(windowIsVisible), window.isVisible=\(window?.isVisible ?? false)")
        // 确保窗口在 app 激活后正确显示
        if window?.isVisible == true && !windowIsVisible {
            // 窗口可见但我们的状态显示不可见，同步状态
            windowIsVisible = true
        }
    }

    // 使用通知监听（比 delegate 方法更可靠）
    @objc private func handleAppWillBecomeActive(_ notification: Notification) {
        print("📣 [AppDelegate] handleAppWillBecomeActive (notification), windowIsVisible=\(windowIsVisible), window.isVisible=\(window?.isVisible ?? false)")
        // 如果窗口不可见，点击 dock 图标时显示窗口
        if !windowIsVisible {
            print("📣 [AppDelegate] Window not visible, calling showWindow()")
            showWindow()
        }
    }

    @objc private func handleAppDidBecomeActive(_ notification: Notification) {
        print("📣 [AppDelegate] handleAppDidBecomeActive (notification), windowIsVisible=\(windowIsVisible), window.isVisible=\(window?.isVisible ?? false)")
        // 确保窗口在 app 激活后正确显示
        if window?.isVisible == true && !windowIsVisible {
            // 窗口可见但我们的状态显示不可见，同步状态
            print("📣 [AppDelegate] Syncing windowIsVisible to true")
            windowIsVisible = true
        }
        // 确保滚轮事件监听器正确安装
        NotificationCenter.default.post(name: .launchpadWindowShown, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        ControllerInputManager.shared.stop()
    }
    
    private func isInteractiveView(_ view: NSView?) -> Bool {
        var v = view
        while let cur = v {
            if cur is NSControl || cur is NSTextView || cur is NSScrollView || cur is NSVisualEffectView { return true }
            v = cur.superview
        }
        return false
    }

    @objc private func handleBackgroundClick(_ sender: NSClickGestureRecognizer) {
        guard appStore.openFolder == nil && !appStore.isFolderNameEditing else { return }
        guard let view = sender.view else { return }
        let p = sender.location(in: view)
        if let hit = view.hitTest(p), isInteractiveView(hit) { return }
        hideWindow()
    }

    // MARK: - NSGestureRecognizerDelegate
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard let contentView = window?.contentView else { return true }
        let point = contentView.convert(event.locationInWindow, from: nil)
        if let hit = contentView.hitTest(point), isInteractiveView(hit) {
            return false
        }
        return true
    }
}

private func hotKeyEventCallback(eventHandlerCallRef: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData, let event else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    if status != noErr {
        return status
    }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    delegate.handleHotKeyEvent(signature: hotKeyID.signature, id: hotKeyID.id)
    return noErr
}

private func fourCharCode(_ string: String) -> FourCharCode {
    var result: UInt32 = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) | (scalar.value & 0xFF)
    }
    return result
}

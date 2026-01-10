import AppKit
import QuartzCore
import Combine

// MARK: - Safe Array Subscript
private extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Core Animation Grid View
/// 使用 Core Animation 实现的高性能网格视图，支持 120Hz ProMotion
final class CAGridView: NSView, CALayerDelegate {

    // MARK: - Properties

    private var displayLink: CADisplayLink?
    private var containerLayer: CALayer!
    private var pageContainerLayer: CALayer!
    private var iconLayers: [[CALayer]] = []  // [page][item]

    // 网格配置
    var columns: Int = 7 { didSet { rebuildLayers() } }
    var rows: Int = 5 { didSet { rebuildLayers() } }
    var iconSize: CGFloat = 72 { didSet { updateLayout() } }
    var itemSpacing: CGFloat = 24 { didSet { updateLayout() } }
    var rowSpacing: CGFloat = 36 { didSet { updateLayout() } }
    var labelFontSize: CGFloat = 12 { didSet { rebuildLayers() } }  // 默认 12pt，比原来大一点

    // 数据源
    var items: [LaunchpadItem] = [] {
        didSet {
            rebuildLayers()
            preloadIcons()
        }
    }

    // 分页
    private(set) var currentPage: Int = 0
    var itemsPerPage: Int { columns * rows }
    var pageCount: Int { max(1, (items.count + itemsPerPage - 1) / itemsPerPage) }

    // 滚动状态
    private var scrollOffset: CGFloat = 0
    private var targetScrollOffset: CGFloat = 0
    private var scrollVelocity: CGFloat = 0
    private var isScrollAnimating = false
    private var isDragging = false
    private var dragStartOffset: CGFloat = 0
    private var accumulatedDelta: CGFloat = 0

    // 性能监控
    private var lastFrameTime: CFAbsoluteTime = 0
    private var frameCount: Int = 0
    private var currentFPS: Double = 120
    private var frameTimes: [Double] = []

    // 图标缓存
    private var iconCache: [String: CGImage] = [:]
    private let iconCacheLock = NSLock()

    // 回调
    var onItemClicked: ((LaunchpadItem, Int) -> Void)?
    var onItemDoubleClicked: ((LaunchpadItem, Int) -> Void)?
    var onPageChanged: ((Int) -> Void)?
    var onFPSUpdate: ((Double) -> Void)?
    var onEmptyAreaClicked: (() -> Void)?
    var onCreateFolder: ((AppInfo, AppInfo, Int) -> Void)?  // (拖拽的app, 目标app, 位置)
    var onMoveToFolder: ((AppInfo, FolderInfo) -> Void)?    // 移动到已有文件夹
    var onReorderItems: ((Int, Int) -> Void)?               // 重新排序 (fromIndex, toIndex)
    var onRequestNewPage: (() -> Void)?                     // 请求创建新页面

    // 拖拽状态
    private var isDraggingItem = false
    private var draggingIndex: Int?
    private var draggingItem: LaunchpadItem?
    private var draggingLayer: CALayer?
    private var dragStartPoint: CGPoint = .zero
    private var dragCurrentPoint: CGPoint = .zero
    private var dropTargetIndex: Int?
    private var longPressTimer: Timer?
    private let longPressDuration: TimeInterval = 0.3

    // 跨页拖拽
    private var edgeDragTimer: Timer?
    private let edgeDragThreshold: CGFloat = 60  // 边缘检测区域宽度
    private let edgeDragDelay: TimeInterval = 0.4  // 触发翻页延迟

    // 插入位置指示器
    private var insertIndicatorLayer: CALayer?
    private var currentInsertIndex: Int?

    // 鼠标拖拽翻页
    private var isPageDragging = false
    private var pageDragStartX: CGFloat = 0
    private var pageDragStartOffset: CGFloat = 0

    // 事件监听器
    private var scrollEventMonitor: Any?
    private var wasWindowVisible = false  // 跟踪窗口可见状态

    // 实例追踪
    private static var instanceCounter = 0
    private let instanceId: Int

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        CAGridView.instanceCounter += 1
        self.instanceId = CAGridView.instanceCounter
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        CAGridView.instanceCounter += 1
        self.instanceId = CAGridView.instanceCounter
        super.init(coder: coder)
        setup()
    }

    deinit {
        print("💀 [CAGrid #\(instanceId)] deinit - instance being destroyed!")
        displayLink?.invalidate()
        removeScrollEventMonitor()
        NotificationCenter.default.removeObserver(self)
    }

    private func setup() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        // 创建容器层
        containerLayer = CALayer()
        containerLayer.frame = bounds
        containerLayer.masksToBounds = true
        layer?.addSublayer(containerLayer)

        // 页面容器层（用于整体偏移）
        pageContainerLayer = CALayer()
        pageContainerLayer.frame = bounds
        containerLayer.addSublayer(pageContainerLayer)

        // 禁用隐式动画
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.commit()

        // 在初始化时就注册 launchpad 窗口通知（确保始终能接收）
        NotificationCenter.default.addObserver(self, selector: #selector(launchpadWindowDidShow(_:)), name: .launchpadWindowShown, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(launchpadWindowDidHide(_:)), name: .launchpadWindowHidden, object: nil)
        // 监听应用激活事件（作为备用方案）
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)

        print("✅ [CAGrid #\(instanceId)] Core Animation grid initialized")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            setupDisplayLink()
            // 始终安装滚轮事件监听器（更可靠）
            setupScrollEventMonitor()
            // 确保视图成为第一响应者
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                window.makeFirstResponder(self)
            }
            print("✅ [CAGrid #\(instanceId)] View moved to window, scroll monitor installed")

            // 监听窗口显示/隐藏事件
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeMainNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)

            NotificationCenter.default.addObserver(self, selector: #selector(windowDidActivate(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidActivate(_:)), name: NSWindow.didBecomeMainNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowOcclusionChanged(_:)), name: NSWindow.didChangeOcclusionStateNotification, object: window)
            // launchpad 窗口通知在 setup() 中注册，这里不需要重复注册
        } else {
            // 视图从窗口移除时清理窗口相关的事件监听器
            // 注意：launchpad 窗口通知不在这里移除，因为它们在 setup() 中注册
            removeScrollEventMonitor()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeMainNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        }
    }

    @objc private func windowDidActivate(_ notification: Notification) {
        print("🪟 [CAGrid] Window activated, making first responder")
        window?.makeFirstResponder(self)
    }

    @objc private func windowOcclusionChanged(_ notification: Notification) {
        guard let window = window else { return }
        if window.occlusionState.contains(.visible) {
            print("🪟 [CAGrid] Window became visible, making first responder")
            window.makeFirstResponder(self)
        }
    }

    @objc private func launchpadWindowDidShow(_ notification: Notification) {
        // 只有有窗口的实例才响应
        guard let window = window else {
            print("⚠️ [CAGrid #\(instanceId)] Launchpad window shown - but no window, ignoring")
            return
        }
        print("🚀 [CAGrid #\(instanceId)] Launchpad window shown, hasMonitor=\(scrollEventMonitor != nil)")

        // 立即安装滚轮事件监听器（如果没有）
        if scrollEventMonitor == nil {
            print("🔄 [CAGrid #\(instanceId)] Reinstalling scroll monitor on window show")
            setupScrollEventMonitor()
        }

        // 确保成为第一响应者
        window.makeFirstResponder(self)

        // 延迟再次确认（防止其他组件抢占）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, let win = self.window else { return }
            print("🔄 [CAGrid #\(self.instanceId)] Delayed check, isFirstResponder=\(win.firstResponder === self), hasMonitor=\(self.scrollEventMonitor != nil)")
            if win.firstResponder !== self {
                win.makeFirstResponder(self)
            }
            // 确保滚轮监听器存在
            if self.scrollEventMonitor == nil {
                self.setupScrollEventMonitor()
            }
        }
    }

    @objc private func launchpadWindowDidHide(_ notification: Notification) {
        // 只有有窗口的实例才响应
        guard window != nil else {
            print("⚠️ [CAGrid #\(instanceId)] Window hidden - but no window, ignoring")
            return
        }
        print("🚀 [CAGrid #\(instanceId)] Window hidden, hasMonitor=\(scrollEventMonitor != nil)")
        // 不再移除监听器 - 让它保持活跃，这样窗口重新显示时就能立即使用
        // removeScrollEventMonitor()
        wasWindowVisible = false
    }

    @objc private func appDidBecomeActive(_ notification: Notification) {
        // 应用激活时检查是否需要安装滚轮监听器
        print("🔔 [CAGrid #\(instanceId)] App became active notification received, window=\(window != nil), isVisible=\(window?.isVisible ?? false)")
        guard let window = window else {
            print("🔔 [CAGrid #\(instanceId)] App became active - no window")
            return
        }

        // 立即尝试重新安装滚轮监听器（不管窗口是否可见）
        // 因为窗口可能正在动画中，isVisible 可能还是 false
        print("🔔 [CAGrid #\(instanceId)] Reinstalling scroll monitor immediately on app activate")
        setupScrollEventMonitor()
        window.makeFirstResponder(self)

        // 延迟再次检查，确保滚轮监听器存在
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self, let win = self.window else { return }
            print("🔔 [CAGrid #\(self.instanceId)] Delayed check: isVisible=\(win.isVisible), scrollMonitor=\(self.scrollEventMonitor != nil)")
            if self.scrollEventMonitor == nil {
                print("🔄 [CAGrid #\(self.instanceId)] App became active (delayed), reinstalling scroll monitor")
                self.setupScrollEventMonitor()
            }
            win.makeFirstResponder(self)
        }
    }

    private func setupScrollEventMonitor() {
        // 移除旧的监听器
        removeScrollEventMonitor()

        // 确保有窗口才设置监听器（可见性在事件处理时动态检查）
        guard window != nil else {
            print("⚠️ [CAGrid #\(instanceId)] setupScrollEventMonitor: no window, skipping")
            return
        }

        // 记录安装时的实例ID用于调试
        let myInstanceId = self.instanceId

        // 添加本地事件监听器 - 模仿原 LaunchpadView 的 ScrollEventCatcherView
        // 关键：不进行严格的窗口检查，让事件能够传递
        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self else {
                return event
            }

            // 简单检查：只要有窗口就处理
            guard self.window != nil else {
                return event
            }

            // 不消费事件，让 scrollWheel(with:) 方法也能收到
            // 但我们在这里也处理一下，作为备份
            let isPrecise = event.hasPreciseScrollingDeltas
            print("🎡 [Monitor #\(myInstanceId)] scroll event, precise=\(isPrecise), deltaY=\(event.scrollingDeltaY)")

            // 处理滚轮事件
            self.handleScrollWheel(with: event)

            // 返回 event 而不是 nil - 让事件继续传递
            // 这样 scrollWheel(with:) 也能收到事件
            return event
        }
        print("✅ [CAGrid #\(instanceId)] Scroll event monitor installed")
    }

    private func removeScrollEventMonitor() {
        if let monitor = scrollEventMonitor {
            print("🗑️ [CAGrid #\(instanceId)] Removing scroll event monitor")
            NSEvent.removeMonitor(monitor)
            scrollEventMonitor = nil
        }
    }

    // MARK: - Display Link (120Hz)

    private func setupDisplayLink() {
        displayLink?.invalidate()

        guard let window = window else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.setupDisplayLink()
            }
            return
        }

        displayLink = window.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        displayLink?.add(to: .main, forMode: .common)

        print("✅ [CAGrid] DisplayLink configured for 120Hz")
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        // 只在动画时才更新
        guard isScrollAnimating || isDraggingItem else {
            // 空闲时重置帧计数
            if frameCount > 0 {
                frameCount = 0
                lastFrameTime = 0
            }
            return
        }

        // 计算实时帧率（仅在动画时）
        let now = CFAbsoluteTimeGetCurrent()
        if lastFrameTime > 0 {
            let delta = now - lastFrameTime
            let instantFPS = 1.0 / delta
            // 使用滑动窗口平均，减少数组操作
            if frameTimes.count >= 30 {
                frameTimes.removeFirst()
            }
            frameTimes.append(instantFPS)
            currentFPS = frameTimes.reduce(0, +) / Double(frameTimes.count)
        }
        lastFrameTime = now

        frameCount += 1
        // 每 60 帧输出一次（约 0.5 秒）
        if frameCount % 60 == 0 {
            onFPSUpdate?(currentFPS)
            print("🎮 [CAGrid] Avg FPS: \(String(format: "%.1f", currentFPS))")
        }

        // 更新滚动动画
        if isScrollAnimating {
            updateScrollAnimation()
        }
    }

    // MARK: - Scroll Animation

    private func updateScrollAnimation() {
        let snapThreshold: CGFloat = 0.3
        let diff = targetScrollOffset - scrollOffset

        // 使用更平滑的 ease-out 动画曲线
        if abs(diff) > snapThreshold {
            // 根据距离动态调整速度，距离远时快，距离近时慢
            let t: CGFloat = 0.18  // 基础插值系数
            scrollOffset += diff * t
        } else {
            // 接近目标时直接对齐
            scrollOffset = targetScrollOffset
            scrollVelocity = 0
            isScrollAnimating = false
        }

        // 更新页面容器位置 - 使用最小开销的方式
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setAnimationDuration(0)
        pageContainerLayer.transform = CATransform3DMakeTranslation(scrollOffset, 0, 0)
        CATransaction.commit()
    }

    func navigateToPage(_ page: Int, animated: Bool = true) {
        let newPage = max(0, min(pageCount - 1, page))

        // 允许重新定位到同一页（用于初始化）
        let pageChanged = newPage != currentPage
        currentPage = newPage
        targetScrollOffset = -CGFloat(currentPage) * bounds.width

        if animated && pageChanged {
            isScrollAnimating = true
        } else {
            // 立即跳转
            scrollOffset = targetScrollOffset
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pageContainerLayer.transform = CATransform3DMakeTranslation(scrollOffset, 0, 0)
            CATransaction.commit()
        }

        if pageChanged {
            onPageChanged?(currentPage)
        }
    }

    // MARK: - Layer Management

    private func rebuildLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // 清除旧层
        for pageLayers in iconLayers {
            for layer in pageLayers {
                layer.removeFromSuperlayer()
            }
        }
        iconLayers.removeAll()

        guard !items.isEmpty else {
            CATransaction.commit()
            print("⚠️ [CAGrid] rebuildLayers: no items")
            return
        }

        // 为每页创建图层
        let totalPages = pageCount
        print("🔧 [CAGrid] rebuildLayers: \(items.count) items, \(totalPages) pages, \(itemsPerPage) per page")

        for pageIndex in 0..<totalPages {
            var pageLayers: [CALayer] = []
            let startIndex = pageIndex * itemsPerPage
            let endIndex = min(startIndex + itemsPerPage, items.count)

            for i in startIndex..<endIndex {
                let localIndex = i - startIndex
                let layer = createIconLayer(for: items[i], localIndex: localIndex, pageIndex: pageIndex)
                pageContainerLayer.addSublayer(layer)
                pageLayers.append(layer)
            }

            iconLayers.append(pageLayers)
        }

        CATransaction.commit()

        // 确保布局更新
        updateLayout()

        // 重置到当前页
        navigateToPage(currentPage, animated: false)
    }

    private func createIconLayer(for item: LaunchpadItem, localIndex: Int, pageIndex: Int) -> CALayer {
        // 创建容器层（包含图标和文字）
        let containerLayer = CALayer()
        containerLayer.masksToBounds = false

        // 性能优化：异步绘制
        containerLayer.drawsAsynchronously = true

        // 图标层
        let iconLayer = CALayer()
        iconLayer.name = "icon"
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        iconLayer.masksToBounds = false

        // 性能优化：启用栅格化缓存
        iconLayer.shouldRasterize = true
        iconLayer.rasterizationScale = NSScreen.main?.backingScaleFactor ?? 2.0
        iconLayer.drawsAsynchronously = true

        // 添加阴影 - 使用 shadowPath 优化性能
        iconLayer.shadowColor = NSColor.black.cgColor
        iconLayer.shadowOffset = CGSize(width: 0, height: -2)
        iconLayer.shadowRadius = 6  // 减小阴影半径
        iconLayer.shadowOpacity = 0.25

        containerLayer.addSublayer(iconLayer)

        // 文字标签层 - 匹配原 SwiftUI 样式
        let textLayer = CATextLayer()
        textLayer.name = "label"
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        textLayer.fontSize = labelFontSize
        textLayer.font = NSFont.systemFont(ofSize: labelFontSize, weight: .medium)
        textLayer.alignmentMode = .center
        textLayer.truncationMode = .end
        textLayer.isWrapped = false

        // 性能优化：栅格化文字层
        textLayer.shouldRasterize = true
        textLayer.rasterizationScale = NSScreen.main?.backingScaleFactor ?? 2.0

        // 使用白色文字 + 黑色描边/阴影确保可读性
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.shadowColor = NSColor.black.cgColor
        textLayer.shadowOffset = CGSize(width: 0, height: -0.5)
        textLayer.shadowRadius = 2  // 减小阴影半径
        textLayer.shadowOpacity = 0.8

        // 设置文字内容
        switch item {
        case .app(let app):
            textLayer.string = app.name
        case .folder(let folder):
            textLayer.string = folder.name
        case .missingApp(let placeholder):
            textLayer.string = placeholder.displayName
        case .empty:
            textLayer.string = ""
        }

        containerLayer.addSublayer(textLayer)

        // 设置图标
        setIcon(for: iconLayer, item: item)

        return containerLayer
    }

    private func setIcon(for layer: CALayer, item: LaunchpadItem) {
        switch item {
        case .app(let app):
            if let cgImage = getCachedIcon(for: app.url.path) {
                layer.contents = cgImage
            } else {
                // 异步加载 - 直接从系统获取图标
                let path = app.url.path
                DispatchQueue.global(qos: .userInitiated).async { [weak self, weak layer] in
                    guard let self = self, let layer = layer else { return }
                    // 直接从 NSWorkspace 获取图标，确保能加载
                    let icon = NSWorkspace.shared.icon(forFile: path)
                    if let cgImage = self.loadIcon(for: path, icon: icon) {
                        DispatchQueue.main.async {
                            CATransaction.begin()
                            CATransaction.setDisableActions(true)
                            layer.contents = cgImage
                            CATransaction.commit()
                        }
                    }
                }
            }
        case .folder(let folder):
            // 异步加载文件夹图标
            let folderIconSize = iconSize
            DispatchQueue.global(qos: .userInitiated).async { [weak layer] in
                let icon = folder.icon(of: folderIconSize)
                if let cgImage = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    DispatchQueue.main.async {
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        layer?.contents = cgImage
                        CATransaction.commit()
                    }
                }
            }
        case .missingApp(let placeholder):
            if let cgImage = placeholder.icon.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                layer.contents = cgImage
            }
        case .empty:
            layer.contents = nil
        }
    }

    private func getCachedIcon(for path: String) -> CGImage? {
        iconCacheLock.lock()
        defer { iconCacheLock.unlock() }
        return iconCache[path]
    }

    private func loadIcon(for path: String, icon: NSImage) -> CGImage? {
        iconCacheLock.lock()
        if let cached = iconCache[path] {
            iconCacheLock.unlock()
            return cached
        }
        iconCacheLock.unlock()

        // 渲染为 CGImage
        let size = NSSize(width: iconSize * 2, height: iconSize * 2) // Retina
        let image = NSImage(size: size)
        image.lockFocus()
        icon.draw(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        iconCacheLock.lock()
        iconCache[path] = cgImage
        iconCacheLock.unlock()

        return cgImage
    }

    func preloadIcons() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            for item in self.items {
                if case .app(let app) = item {
                    _ = self.loadIcon(for: app.url.path, icon: app.icon)
                }
            }
            print("✅ [CAGrid] Icons preloaded")
        }
    }

    // MARK: - Layout

    private func updateLayout() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let pageWidth = bounds.width
        let pageHeight = bounds.height

        // 苹果 Launchpad 风格布局：均匀分布整个可用区域
        let horizontalMargin: CGFloat = pageWidth * 0.06  // 6% 左右边距
        let topMargin: CGFloat = pageHeight * 0.02        // 2% 顶部边距
        let bottomMargin: CGFloat = pageHeight * 0.10     // 10% 底部边距

        let availableWidth = pageWidth - horizontalMargin * 2
        let availableHeight = pageHeight - topMargin - bottomMargin

        // 计算单元格大小（均匀分布）
        let cellWidth = availableWidth / CGFloat(columns)
        let cellHeight = availableHeight / CGFloat(rows)

        // 实际图标大小 - 更大一些
        let actualIconSize = iconSize * 1.3  // 增大 30%
        let labelHeight: CGFloat = labelFontSize + 8  // 字体大小 + padding
        let labelTopSpacing: CGFloat = 6

        for (pageIndex, pageLayers) in iconLayers.enumerated() {
            for (localIndex, containerLayer) in pageLayers.enumerated() {
                let col = localIndex % columns
                let row = localIndex / columns

                // 计算单元格中心位置
                let cellCenterX = horizontalMargin + cellWidth * (CGFloat(col) + 0.5)
                let cellCenterY = topMargin + cellHeight * (CGFloat(row) + 0.5)

                // 容器位置（包含图标+文字的整体）
                let totalHeight = actualIconSize + labelTopSpacing + labelHeight
                let containerX = CGFloat(pageIndex) * pageWidth + cellCenterX - cellWidth / 2
                let containerY = pageHeight - cellCenterY - totalHeight / 2

                containerLayer.frame = CGRect(x: containerX, y: containerY, width: cellWidth, height: totalHeight)

                // 更新子层位置
                if let iconLayer = containerLayer.sublayers?.first(where: { $0.name == "icon" }) {
                    let iconX = (cellWidth - actualIconSize) / 2
                    let iconY = labelHeight + labelTopSpacing  // 图标在上
                    let iconFrame = CGRect(x: iconX, y: iconY, width: actualIconSize, height: actualIconSize)
                    iconLayer.frame = iconFrame

                    // 性能优化：设置 shadowPath 避免实时计算阴影
                    let shadowRect = CGRect(x: 0, y: 0, width: actualIconSize, height: actualIconSize)
                    iconLayer.shadowPath = CGPath(roundedRect: shadowRect, cornerWidth: actualIconSize * 0.2, cornerHeight: actualIconSize * 0.2, transform: nil)
                }

                if let textLayer = containerLayer.sublayers?.first(where: { $0.name == "label" }) as? CATextLayer {
                    let labelWidth = cellWidth - 8  // 留一点边距
                    textLayer.frame = CGRect(x: 4, y: 0, width: labelWidth, height: labelHeight)
                }
            }
        }

        // 更新页面容器大小
        let totalWidth = pageWidth * CGFloat(max(1, pageCount))
        pageContainerLayer.frame = CGRect(x: 0, y: 0, width: totalWidth, height: bounds.height)

        CATransaction.commit()

        print("📐 [CAGrid] Layout: \(columns)x\(rows), iconSize=\(actualIconSize), cell=\(cellWidth)x\(cellHeight)")
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        // 确保视图是第一响应者和滚轮监听器已安装
        if let win = window {
            if win.firstResponder !== self {
                win.makeFirstResponder(self)
            }
            // 确保滚轮监听器存在
            if scrollEventMonitor == nil {
                setupScrollEventMonitor()
            }
        }
    }

    override func layout() {
        super.layout()

        guard bounds.width > 0, bounds.height > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.frame = bounds
        CATransaction.commit()

        updateLayout()

        // 重新定位到当前页（不使用动画）
        scrollOffset = -CGFloat(currentPage) * bounds.width
        targetScrollOffset = scrollOffset
        isScrollAnimating = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageContainerLayer.transform = CATransform3DMakeTranslation(scrollOffset, 0, 0)
        CATransaction.commit()
    }

    // MARK: - Input Handling

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        print("🎯 [CAGrid] becomeFirstResponder")
        return true
    }

    override func resignFirstResponder() -> Bool {
        print("🎯 [CAGrid] resignFirstResponder")
        return true
    }

    // 确保视图接受第一次鼠标点击就能响应
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    // 确保视图可以接收鼠标事件
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = frame.contains(point) ? self : nil
        return result
    }

    override func scrollWheel(with event: NSEvent) {
        // 直接处理滚轮事件 - 这是最可靠的方式
        print("🎯 [CAGrid] scrollWheel method called directly")
        handleScrollWheel(with: event)
    }

    private func handleScrollWheel(with event: NSEvent) {
        // 优先使用水平滑动，如果没有则用垂直滑动（反向）
        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY
        let delta = abs(deltaX) > abs(deltaY) ? deltaX : -deltaY
        let isPrecise = event.hasPreciseScrollingDeltas

        if !isPrecise {
            // 鼠标滚轮 - 直接翻页
            print("🖱️ [CAGrid #\(instanceId)] Mouse wheel event, delta=\(delta), currentPage=\(currentPage)")
            // 降低阈值，让鼠标滚轮更容易触发翻页
            if abs(delta) > 0.5 {
                if delta > 0 {
                    print("🖱️ [CAGrid #\(instanceId)] Mouse wheel -> previous page")
                    navigateToPage(currentPage - 1)
                } else {
                    print("🖱️ [CAGrid #\(instanceId)] Mouse wheel -> next page")
                    navigateToPage(currentPage + 1)
                }
            }
            return
        }

        // 触控板滑动
        switch event.phase {
        case .began:
            isDragging = true
            isScrollAnimating = false
            dragStartOffset = scrollOffset
            accumulatedDelta = 0
            scrollVelocity = 0

        case .changed:
            accumulatedDelta += delta

            // 计算新的偏移量
            var newOffset = dragStartOffset + accumulatedDelta

            // 橡皮筋效果：在边界处添加阻力
            let minOffset = -CGFloat(pageCount - 1) * bounds.width
            let maxOffset: CGFloat = 0

            if newOffset > maxOffset {
                // 超出左边界
                let overscroll = newOffset - maxOffset
                newOffset = maxOffset + rubberBand(overscroll, limit: bounds.width * 0.2)
            } else if newOffset < minOffset {
                // 超出右边界
                let overscroll = newOffset - minOffset
                newOffset = minOffset + rubberBand(overscroll, limit: bounds.width * 0.2)
            }

            scrollOffset = newOffset

            // 性能优化：使用 CATransaction 批量更新，并强制刷新
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setAnimationDuration(0)
            pageContainerLayer.transform = CATransform3DMakeTranslation(scrollOffset, 0, 0)
            CATransaction.commit()
            CATransaction.flush()  // 强制立即渲染

        case .ended, .cancelled:
            isDragging = false

            // 根据滑动距离和速度确定目标页面
            let velocity = abs(deltaX) > abs(deltaY) ? deltaX : -deltaY
            let threshold = bounds.width * 0.15  // 15% 即可触发翻页
            let velocityThreshold: CGFloat = 30
            var targetPage = currentPage

            // 根据累计滑动方向决定翻页
            if accumulatedDelta < -threshold || velocity < -velocityThreshold {
                targetPage = currentPage + 1
            } else if accumulatedDelta > threshold || velocity > velocityThreshold {
                targetPage = currentPage - 1
            }

            navigateToPage(targetPage)

        default:
            // 处理 mayBegin 等其他阶段
            break
        }
    }

    private func rubberBand(_ offset: CGFloat, limit: CGFloat) -> CGFloat {
        let factor: CGFloat = 0.5
        let absOffset = abs(offset)
        let scaled = (factor * absOffset * limit) / (absOffset + limit)
        return offset >= 0 ? scaled : -scaled
    }

    override func mouseDown(with event: NSEvent) {
        // 确保成为第一响应者，这样后续的滚轮事件才能被接收
        window?.makeFirstResponder(self)

        let location = convert(event.locationInWindow, from: nil)
        print("🖱️ [CAGrid] mouseDown at \(location)")

        if let (item, index) = itemAt(location) {
            print("🖱️ [CAGrid] Hit item: \(item.name) at index \(index)")
            if event.clickCount == 1 {
                // 添加点击效果动画
                animatePress(at: index, pressed: true)
                pressedIndex = index
                dragStartPoint = location

                // 启动长按计时器（用于开始拖拽）
                // 注意：必须添加到 .common 模式，否则在鼠标追踪期间不会触发
                longPressTimer?.invalidate()
                let timer = Timer(timeInterval: longPressDuration, repeats: false) { [weak self] _ in
                    self?.startDragging(item: item, index: index, at: location)
                }
                RunLoop.main.add(timer, forMode: .common)
                longPressTimer = timer
            }
        } else {
            // 点击空白区域 - 开始页面拖拽模式
            print("🖱️ [CAGrid] Hit empty area, starting page drag")
            isPageDragging = true
            pageDragStartX = location.x
            pageDragStartOffset = scrollOffset
            dragStartPoint = location
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        // 页面拖拽模式
        if isPageDragging {
            let deltaX = location.x - pageDragStartX
            var newOffset = pageDragStartOffset + deltaX

            // 橡皮筋效果 - 在边界处添加阻力
            let minOffset = -CGFloat(pageCount - 1) * bounds.width
            let maxOffset: CGFloat = 0

            if newOffset > maxOffset {
                let overscroll = newOffset - maxOffset
                newOffset = maxOffset + rubberBand(overscroll, limit: bounds.width * 0.3)
            } else if newOffset < minOffset {
                let overscroll = newOffset - minOffset
                newOffset = minOffset + rubberBand(overscroll, limit: bounds.width * 0.3)
            }

            scrollOffset = newOffset

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pageContainerLayer.transform = CATransform3DMakeTranslation(scrollOffset, 0, 0)
            CATransaction.commit()
            return
        }

        // 检查是否移动足够距离来开始拖拽（5像素即可）
        if !isDraggingItem, let idx = pressedIndex {
            let distance = hypot(location.x - dragStartPoint.x, location.y - dragStartPoint.y)
            if distance > 5 {
                // 取消长按计时器，立即开始拖拽
                longPressTimer?.invalidate()
                longPressTimer = nil
                if let item = items[safe: idx] {
                    startDragging(item: item, index: idx, at: location)
                }
            }
        }

        // 更新拖拽位置
        if isDraggingItem {
            updateDragging(at: location)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        // 取消长按计时器
        longPressTimer?.invalidate()
        longPressTimer = nil

        // 结束页面拖拽
        if isPageDragging {
            isPageDragging = false

            let totalDrag = location.x - pageDragStartX
            let threshold = bounds.width * 0.15  // 15% 即可触发翻页

            var targetPage = currentPage
            if totalDrag < -threshold {
                // 向左拖 -> 下一页
                targetPage = min(currentPage + 1, pageCount - 1)
            } else if totalDrag > threshold {
                // 向右拖 -> 上一页
                targetPage = max(currentPage - 1, 0)
            }

            // 如果没有实际拖动（只是点击），则关闭窗口
            if abs(totalDrag) < 5 {
                onEmptyAreaClicked?()
                return
            }

            navigateToPage(targetPage, animated: true)
            return
        }

        if isDraggingItem {
            // 结束拖拽
            endDragging(at: location)
        } else if let idx = pressedIndex {
            // 恢复点击效果
            animatePress(at: idx, pressed: false)
            pressedIndex = nil

            // 检查是否在同一个 item 上释放
            if let (item, index) = itemAt(location), index == idx {
                // 延迟一点点再触发，让动画效果更明显
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.onItemClicked?(item, index)
                }
            }
        }
    }

    private var pressedIndex: Int?

    private func animatePress(at index: Int, pressed: Bool) {
        let pageIndex = index / itemsPerPage
        let localIndex = index % itemsPerPage

        guard pageIndex < iconLayers.count, localIndex < iconLayers[pageIndex].count else { return }

        let layer = iconLayers[pageIndex][localIndex]

        CATransaction.begin()
        CATransaction.setAnimationDuration(pressed ? 0.1 : 0.15)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: pressed ? .easeIn : .easeOut))

        let scale: CGFloat = pressed ? 0.92 : 1.0
        layer.transform = CATransform3DMakeScale(scale, scale, 1.0)

        CATransaction.commit()
    }

    // MARK: - Drag and Drop

    private func startDragging(item: LaunchpadItem, index: Int, at point: CGPoint) {
        // 只允许拖拽应用
        guard case .app = item else { return }

        isDraggingItem = true
        draggingIndex = index
        draggingItem = item
        dragCurrentPoint = point

        // 恢复按压效果
        if let idx = pressedIndex {
            animatePress(at: idx, pressed: false)
            pressedIndex = nil
        }

        // 隐藏原图标
        let pageIndex = index / itemsPerPage
        let localIndex = index % itemsPerPage
        if pageIndex < iconLayers.count, localIndex < iconLayers[pageIndex].count {
            iconLayers[pageIndex][localIndex].opacity = 0.3
        }

        // 创建拖拽图层
        createDraggingLayer(for: item, at: point)

        print("🎯 [CAGrid] Started dragging: \(item.name) at index \(index)")
    }

    private func createDraggingLayer(for item: LaunchpadItem, at point: CGPoint) {
        let actualIconSize = iconSize * 1.3
        let layer = CALayer()
        layer.frame = CGRect(x: point.x - actualIconSize / 2, y: point.y - actualIconSize / 2,
                            width: actualIconSize, height: actualIconSize)
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer.contentsGravity = .resizeAspect
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: -4)
        layer.shadowRadius = 12
        layer.shadowOpacity = 0.5
        layer.transform = CATransform3DMakeScale(1.1, 1.1, 1.0)
        layer.zPosition = 1000

        // 设置图标内容
        if case .app(let app) = item {
            let icon = NSWorkspace.shared.icon(forFile: app.url.path)
            if let cgImage = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                layer.contents = cgImage
            }
        }

        containerLayer.addSublayer(layer)
        draggingLayer = layer
    }

    private func updateDragging(at point: CGPoint) {
        dragCurrentPoint = point

        // 更新拖拽图层位置
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let actualIconSize = iconSize * 1.3
        draggingLayer?.frame = CGRect(x: point.x - actualIconSize / 2, y: point.y - actualIconSize / 2,
                                      width: actualIconSize, height: actualIconSize)
        CATransaction.commit()

        // 检测边缘翻页
        checkEdgeDrag(at: point)

        // 检测目标位置（优先检测是否在某个item上）
        if let (targetItem, targetIndex) = itemAt(point), targetIndex != draggingIndex {
            // 在另一个item上 - 高亮显示（用于创建文件夹或移入文件夹）
            highlightDropTarget(at: targetIndex)
            clearInsertIndicator()
        } else {
            // 不在item上 - 计算插入位置
            clearDropTargetHighlight()
            if let insertIndex = gridPositionAt(point), insertIndex != draggingIndex {
                showInsertIndicator(at: insertIndex)
            } else {
                clearInsertIndicator()
            }
        }
    }

    // MARK: - 边缘翻页检测
    private func checkEdgeDrag(at point: CGPoint) {
        let leftEdge = point.x < edgeDragThreshold
        let rightEdge = point.x > bounds.width - edgeDragThreshold

        if leftEdge && currentPage > 0 {
            // 左边缘 - 翻到上一页
            startEdgeDragTimer(direction: -1)
        } else if rightEdge {
            // 右边缘 - 翻到下一页（可能创建新页）
            startEdgeDragTimer(direction: 1)
        } else {
            // 离开边缘区域 - 取消计时器
            cancelEdgeDragTimer()
        }
    }

    private func startEdgeDragTimer(direction: Int) {
        // 如果已有相同方向的计时器，不重复创建
        if edgeDragTimer != nil { return }

        let timer = Timer(timeInterval: edgeDragDelay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            let targetPage = self.currentPage + direction

            // 检查是否需要创建新页面
            if direction > 0 && targetPage >= self.pageCount {
                // 通知创建新页面
                self.onRequestNewPage?()
            }

            self.navigateToPage(targetPage, animated: true)
            self.edgeDragTimer = nil

            // 翻页后继续检测
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self, self.isDraggingItem else { return }
                self.checkEdgeDrag(at: self.dragCurrentPoint)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        edgeDragTimer = timer
    }

    private func cancelEdgeDragTimer() {
        edgeDragTimer?.invalidate()
        edgeDragTimer = nil
    }

    // MARK: - 插入位置指示器
    private func showInsertIndicator(at index: Int) {
        if currentInsertIndex == index { return }
        currentInsertIndex = index

        // 计算指示器位置
        let pageIndex = index / itemsPerPage
        let localIndex = index % itemsPerPage

        let pageWidth = bounds.width
        let pageHeight = bounds.height
        let horizontalMargin: CGFloat = pageWidth * 0.06
        let topMargin: CGFloat = pageHeight * 0.02
        let bottomMargin: CGFloat = pageHeight * 0.10
        let availableWidth = pageWidth - horizontalMargin * 2
        let availableHeight = pageHeight - topMargin - bottomMargin
        let cellWidth = availableWidth / CGFloat(columns)
        let cellHeight = availableHeight / CGFloat(rows)

        let col = localIndex % columns
        let row = localIndex / columns
        let cellCenterX = horizontalMargin + cellWidth * (CGFloat(col) + 0.5)
        let cellCenterY = topMargin + cellHeight * (CGFloat(row) + 0.5)

        let indicatorX = CGFloat(pageIndex) * pageWidth + cellCenterX - 2 + scrollOffset
        let indicatorY = pageHeight - cellCenterY - cellHeight * 0.4

        // 创建或更新指示器
        if insertIndicatorLayer == nil {
            let layer = CALayer()
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.8).cgColor
            layer.cornerRadius = 2
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOffset = CGSize(width: 0, height: 1)
            layer.shadowRadius = 4
            layer.shadowOpacity = 0.3
            layer.zPosition = 500
            containerLayer.addSublayer(layer)
            insertIndicatorLayer = layer
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        insertIndicatorLayer?.frame = CGRect(x: indicatorX, y: indicatorY, width: 4, height: cellHeight * 0.8)
        insertIndicatorLayer?.opacity = 1.0
        CATransaction.commit()
    }

    private func clearInsertIndicator() {
        guard currentInsertIndex != nil else { return }
        currentInsertIndex = nil

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)
        insertIndicatorLayer?.opacity = 0
        CATransaction.commit()
    }

    /// 计算点击位置对应的网格位置（即使是空白区域）
    private func gridPositionAt(_ point: CGPoint) -> Int? {
        let pageWidth = bounds.width
        let pageHeight = bounds.height
        let adjustedX = point.x - scrollOffset

        // 计算点击的页面
        let pageIndex = Int(floor(adjustedX / pageWidth))
        guard pageIndex >= 0 else { return nil }
        // 允许拖拽到最后一页之后（会创建新页）
        let effectivePageIndex = min(pageIndex, max(0, pageCount - 1))

        // 使用和 updateLayout 相同的布局计算
        let horizontalMargin: CGFloat = pageWidth * 0.06
        let topMargin: CGFloat = pageHeight * 0.02
        let bottomMargin: CGFloat = pageHeight * 0.10

        let availableWidth = pageWidth - horizontalMargin * 2
        let availableHeight = pageHeight - topMargin - bottomMargin

        let cellWidth = availableWidth / CGFloat(columns)
        let cellHeight = availableHeight / CGFloat(rows)

        // 计算点击位置相对于当前页的坐标
        let localX = adjustedX - CGFloat(effectivePageIndex) * pageWidth - horizontalMargin
        let localY = pageHeight - point.y - topMargin

        // 钳制到有效范围
        let clampedX = max(0, min(localX, availableWidth - 1))
        let clampedY = max(0, min(localY, availableHeight - 1))

        let col = Int(clampedX / cellWidth)
        let row = Int(clampedY / cellHeight)

        let clampedCol = max(0, min(col, columns - 1))
        let clampedRow = max(0, min(row, rows - 1))

        let localIndex = clampedRow * columns + clampedCol
        let globalIndex = effectivePageIndex * itemsPerPage + localIndex

        return globalIndex
    }

    private func highlightDropTarget(at index: Int) {
        // 清除之前的高亮
        if let oldTarget = dropTargetIndex, oldTarget != index {
            setHighlight(at: oldTarget, highlighted: false)
        }

        dropTargetIndex = index
        setHighlight(at: index, highlighted: true)
    }

    private func clearDropTargetHighlight() {
        if let target = dropTargetIndex {
            setHighlight(at: target, highlighted: false)
            dropTargetIndex = nil
        }
    }

    private func setHighlight(at index: Int, highlighted: Bool) {
        let pageIndex = index / itemsPerPage
        let localIndex = index % itemsPerPage
        guard pageIndex < iconLayers.count, localIndex < iconLayers[pageIndex].count else { return }

        let layer = iconLayers[pageIndex][localIndex]

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        layer.transform = highlighted ? CATransform3DMakeScale(1.1, 1.1, 1.0) : CATransform3DIdentity
        CATransaction.commit()
    }

    private func endDragging(at point: CGPoint) {
        guard let dragIndex = draggingIndex, let dragItem = draggingItem else {
            cancelDragging()
            return
        }

        // 保存当前插入位置（在清除之前）
        let savedInsertIndex = currentInsertIndex

        // 清除高亮和指示器
        clearDropTargetHighlight()
        clearInsertIndicator()
        cancelEdgeDragTimer()

        print("🎯 [CAGrid] endDragging at point: \(point), dragIndex: \(dragIndex), savedInsertIndex: \(String(describing: savedInsertIndex))")

        // 计算目标位置
        let targetPosition = gridPositionAt(point)
        print("🎯 [CAGrid] targetPosition: \(String(describing: targetPosition)), currentInsertIndex: \(String(describing: currentInsertIndex))")

        // 检查是否拖到另一个item上
        if let (targetItem, targetIndex) = itemAt(point), targetIndex != dragIndex {
            print("🎯 [CAGrid] Dropped on item: \(targetItem.name) at index \(targetIndex)")
            // 拖拽到另一个 item 上
            if case .app(let dragApp) = dragItem {
                switch targetItem {
                case .app(let targetApp):
                    // 两个应用 -> 创建文件夹
                    print("📁 [CAGrid] Creating folder: \(dragApp.name) + \(targetApp.name)")
                    onCreateFolder?(dragApp, targetApp, targetIndex)
                    cancelDragging()
                    return
                case .folder(let folder):
                    // 拖到文件夹 -> 移入文件夹
                    print("📂 [CAGrid] Moving to folder: \(dragApp.name) -> \(folder.name)")
                    onMoveToFolder?(dragApp, folder)
                    cancelDragging()
                    return
                case .empty, .missingApp:
                    // 空白格子或丢失的应用 -> 当作重排序处理
                    print("🔄 [CAGrid] Dropped on empty/missing, reordering: \(dragIndex) -> \(targetIndex)")
                    onReorderItems?(dragIndex, targetIndex)
                    cancelDragging()
                    return
                }
            }
        }

        // 拖拽到空白区域（不在任何item的图标区域内）-> 重新排序
        // 优先使用保存的插入位置，其次使用计算的目标位置
        if let insertIndex = savedInsertIndex ?? targetPosition, insertIndex != dragIndex {
            print("🔄 [CAGrid] Reordering to empty area: \(dragIndex) -> \(insertIndex)")
            onReorderItems?(dragIndex, insertIndex)
        } else {
            print("⚠️ [CAGrid] No valid drop target, canceling")
        }

        cancelDragging()
    }

    private func cancelDragging() {
        // 恢复原图标
        if let index = draggingIndex {
            let pageIndex = index / itemsPerPage
            let localIndex = index % itemsPerPage
            if pageIndex < iconLayers.count, localIndex < iconLayers[pageIndex].count {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.2)
                iconLayers[pageIndex][localIndex].opacity = 1.0
                CATransaction.commit()
            }
        }

        // 移除拖拽图层
        draggingLayer?.removeFromSuperlayer()
        draggingLayer = nil

        isDraggingItem = false
        draggingIndex = nil
        draggingItem = nil
        dropTargetIndex = nil
    }

    private func itemAt(_ point: CGPoint) -> (LaunchpadItem, Int)? {
        let pageWidth = bounds.width
        let pageHeight = bounds.height
        let adjustedX = point.x - scrollOffset

        // 计算点击的页面
        let pageIndex = Int(floor(adjustedX / pageWidth))
        guard pageIndex >= 0 && pageIndex < pageCount else { return nil }

        // 使用和 updateLayout 相同的布局计算
        let horizontalMargin: CGFloat = pageWidth * 0.06
        let topMargin: CGFloat = pageHeight * 0.02
        let bottomMargin: CGFloat = pageHeight * 0.10

        let availableWidth = pageWidth - horizontalMargin * 2
        let availableHeight = pageHeight - topMargin - bottomMargin

        let cellWidth = availableWidth / CGFloat(columns)
        let cellHeight = availableHeight / CGFloat(rows)

        // 计算点击位置相对于当前页的坐标
        let localX = adjustedX - CGFloat(pageIndex) * pageWidth - horizontalMargin
        let localY = pageHeight - point.y - topMargin  // 翻转 Y

        guard localX >= 0, localY >= 0 else { return nil }
        guard localX < availableWidth, localY < availableHeight else { return nil }

        let col = Int(localX / cellWidth)
        let row = Int(localY / cellHeight)

        guard col >= 0, col < columns, row >= 0, row < rows else { return nil }

        let localIndex = row * columns + col
        let globalIndex = pageIndex * itemsPerPage + localIndex

        guard globalIndex < items.count else { return nil }

        // 检查是否点击在图标+标签区域内（不是单元格的空白部分）
        let actualIconSize = iconSize * 1.3
        let labelHeight: CGFloat = labelFontSize + 8
        let labelTopSpacing: CGFloat = 6
        let totalItemHeight = actualIconSize + labelTopSpacing + labelHeight

        // 计算点击位置在单元格内的相对坐标
        let cellLocalX = localX - CGFloat(col) * cellWidth
        let cellLocalY = localY - CGFloat(row) * cellHeight

        // 图标+标签区域居中于单元格
        let itemStartX = (cellWidth - actualIconSize) / 2
        let itemEndX = itemStartX + actualIconSize
        let itemStartY = (cellHeight - totalItemHeight) / 2
        let itemEndY = itemStartY + totalItemHeight

        // 检查是否在图标+标签区域内
        guard cellLocalX >= itemStartX && cellLocalX <= itemEndX else { return nil }
        guard cellLocalY >= itemStartY && cellLocalY <= itemEndY else { return nil }

        return (items[globalIndex], globalIndex)
    }

    // MARK: - Public Methods

    func clearIconCache() {
        iconCacheLock.lock()
        iconCache.removeAll()
        iconCacheLock.unlock()
    }

    func refreshLayout() {
        rebuildLayers()
    }

    /// 确保滚轮事件监听器已安装（供外部调用）
    func ensureScrollMonitorInstalled() {
        guard let window = window else {
            print("⚠️ [CAGrid #\(instanceId)] ensureScrollMonitorInstalled: no window")
            return
        }

        // 只要有窗口且没有监听器就安装（可见性在事件处理时检查）
        if scrollEventMonitor == nil {
            print("🔄 [CAGrid #\(instanceId)] ensureScrollMonitorInstalled: monitor missing, installing")
            setupScrollEventMonitor()
            window.makeFirstResponder(self)
        }
    }

    /// 获取实例ID（用于调试）
    var debugInstanceId: Int { instanceId }
}

// MARK: - SwiftUI Wrapper

import SwiftUI

struct CAGridViewRepresentable: NSViewRepresentable {
    @ObservedObject var appStore: AppStore
    var items: [LaunchpadItem]  // 支持传入过滤后的 items
    var onOpenApp: ((AppInfo) -> Void)?
    var onOpenFolder: ((FolderInfo) -> Void)?

    // 监听这些触发器来强制刷新
    var gridRefreshTrigger: UUID { appStore.gridRefreshTrigger }
    var folderUpdateTrigger: UUID { appStore.folderUpdateTrigger }

    func makeNSView(context: Context) -> CAGridView {
        let view = CAGridView(frame: .zero)

        // 初始化配置
        view.columns = appStore.gridColumnsPerPage
        view.rows = appStore.gridRowsPerPage
        view.iconSize = CGFloat(72 * appStore.iconScale)
        view.labelFontSize = CGFloat(appStore.iconLabelFontSize)
        view.items = items

        view.onItemClicked = { item, index in
            // 单击打开应用或文件夹
            switch item {
            case .app(let app):
                onOpenApp?(app)
                NSWorkspace.shared.open(app.url)
                AppDelegate.shared?.hideWindow()
            case .folder(let folder):
                onOpenFolder?(folder)
            case .missingApp:
                // 丢失的应用，不处理
                break
            case .empty:
                // 空白位置，不做任何操作（和真实Launchpad一致）
                // 只有点击网格外的空白区域才关闭窗口
                break
            }
        }

        view.onItemDoubleClicked = { item, index in
            // 双击也处理（兼容）
        }

        view.onPageChanged = { page in
            DispatchQueue.main.async {
                if appStore.currentPage != page {
                    appStore.currentPage = page
                }
            }
        }

        view.onFPSUpdate = { fps in
            // 可以在这里更新 FPS 显示
        }

        view.onEmptyAreaClicked = {
            // 点击空白区域关闭窗口
            AppDelegate.shared?.hideWindow()
        }

        // 拖拽创建文件夹
        view.onCreateFolder = { dragApp, targetApp, insertAt in
            DispatchQueue.main.async {
                _ = appStore.createFolder(with: [dragApp, targetApp], insertAt: insertAt)
            }
        }

        // 拖拽移入文件夹
        view.onMoveToFolder = { app, folder in
            DispatchQueue.main.async {
                appStore.addAppToFolder(app, folder: folder)
            }
        }

        // 拖拽重新排序
        view.onReorderItems = { fromIndex, toIndex in
            DispatchQueue.main.async {
                guard fromIndex < appStore.items.count else { return }
                let item = appStore.items[fromIndex]
                appStore.moveItemAcrossPagesWithCascade(item: item, to: toIndex)
            }
        }

        // 请求创建新页面（拖拽到右边缘时）
        view.onRequestNewPage = {
            DispatchQueue.main.async {
                let itemsPerPage = appStore.gridColumnsPerPage * appStore.gridRowsPerPage
                let currentPageCount = (appStore.items.count + itemsPerPage - 1) / itemsPerPage
                let neededItems = (currentPageCount + 1) * itemsPerPage - appStore.items.count
                for _ in 0..<neededItems {
                    appStore.items.append(.empty(UUID().uuidString))
                }
            }
        }

        return view
    }

    func updateNSView(_ nsView: CAGridView, context: Context) {
        print("🔄 [CAGrid #\(nsView.debugInstanceId)] updateNSView, window=\(nsView.window != nil), isVisible=\(nsView.window?.isVisible ?? false)")
        // 确保滚轮事件监听器已安装（窗口重新显示时需要）
        nsView.ensureScrollMonitorInstalled()

        // 更新配置
        let configChanged = nsView.columns != appStore.gridColumnsPerPage ||
                            nsView.rows != appStore.gridRowsPerPage ||
                            nsView.iconSize != CGFloat(72 * appStore.iconScale) ||
                            nsView.labelFontSize != CGFloat(appStore.iconLabelFontSize)

        if configChanged {
            nsView.columns = appStore.gridColumnsPerPage
            nsView.rows = appStore.gridRowsPerPage
            nsView.iconSize = CGFloat(72 * appStore.iconScale)
            nsView.labelFontSize = CGFloat(appStore.iconLabelFontSize)
        }

        // 检查刷新触发器是否变化（文件夹创建/修改会触发）
        let triggerChanged = context.coordinator.lastGridRefreshTrigger != gridRefreshTrigger ||
                             context.coordinator.lastFolderUpdateTrigger != folderUpdateTrigger

        if triggerChanged {
            context.coordinator.lastGridRefreshTrigger = gridRefreshTrigger
            context.coordinator.lastFolderUpdateTrigger = folderUpdateTrigger
            print("🔄 [CAGrid] Trigger changed, forcing refresh")
            nsView.items = items
        } else if itemsChanged(nsView.items, items) {
            // 更新 items - 始终检查完整变化（包括文件夹名称等）
            print("🔄 [CAGrid] Updating items: \(nsView.items.count) -> \(items.count)")
            nsView.items = items
        }

        // 同步页面
        if nsView.currentPage != appStore.currentPage {
            print("📄 [CAGrid] Page sync: \(nsView.currentPage) -> \(appStore.currentPage)")
            nsView.navigateToPage(appStore.currentPage, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var lastGridRefreshTrigger: UUID = UUID()
        var lastFolderUpdateTrigger: UUID = UUID()
    }

    // 检查 items 是否变化（完整比较所有 item 的 id 和名称）
    private func itemsChanged(_ old: [LaunchpadItem], _ new: [LaunchpadItem]) -> Bool {
        guard old.count == new.count else { return true }
        guard !old.isEmpty else { return !new.isEmpty }

        // 完整比较每个 item
        for i in 0..<old.count {
            let oldItem = old[i]
            let newItem = new[i]

            // 比较 id
            if oldItem.id != newItem.id { return true }

            // 比较名称（文件夹改名后需要刷新）
            if oldItem.name != newItem.name { return true }

            // 对于文件夹，还要比较内部应用数量
            if case .folder(let oldFolder) = oldItem, case .folder(let newFolder) = newItem {
                if oldFolder.apps.count != newFolder.apps.count { return true }
            }
        }

        return false
    }
}

// MARK: - Preview

#if DEBUG
struct CAGridViewRepresentable_Previews: PreviewProvider {
    static var previews: some View {
        CAGridViewRepresentable(appStore: AppStore(), items: [])
            .frame(width: 1200, height: 800)
    }
}
#endif

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
    var onReorderItems: ((Int, Int) -> Void)?               // 重新排序

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

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        displayLink?.invalidate()
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

        print("✅ [CAGrid] Core Animation grid initialized")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            setupDisplayLink()
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
        // 计算实时帧率
        let now = CFAbsoluteTimeGetCurrent()
        if lastFrameTime > 0 {
            let delta = now - lastFrameTime
            let instantFPS = 1.0 / delta
            frameTimes.append(instantFPS)
            if frameTimes.count > 60 {
                frameTimes.removeFirst()
            }
            currentFPS = frameTimes.reduce(0, +) / Double(frameTimes.count)
        }
        lastFrameTime = now

        frameCount += 1
        if frameCount % 120 == 0 {
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
        // 苹果风格的平滑减速动画（类似 UIScrollView 的 decelerationRate）
        let decelerationRate: CGFloat = 0.92  // 接近苹果的 .normal (0.998) 但更快收敛
        let snapThreshold: CGFloat = 0.5

        let diff = targetScrollOffset - scrollOffset

        // 使用指数衰减而不是弹簧，避免抖动
        if abs(diff) > snapThreshold {
            // 平滑插值到目标位置
            let interpolation: CGFloat = 0.15  // 每帧移动 15% 的距离
            scrollOffset += diff * interpolation
        } else {
            // 接近目标时直接对齐
            scrollOffset = targetScrollOffset
            scrollVelocity = 0
            isScrollAnimating = false
        }

        // 更新页面容器位置
        CATransaction.begin()
        CATransaction.setDisableActions(true)
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

        // 图标层
        let iconLayer = CALayer()
        iconLayer.name = "icon"
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        iconLayer.masksToBounds = false

        // 添加阴影
        iconLayer.shadowColor = NSColor.black.cgColor
        iconLayer.shadowOffset = CGSize(width: 0, height: -2)
        iconLayer.shadowRadius = 8
        iconLayer.shadowOpacity = 0.3

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
        // 使用白色文字 + 黑色描边/阴影确保可读性
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.shadowColor = NSColor.black.cgColor
        textLayer.shadowOffset = CGSize(width: 0, height: -0.5)
        textLayer.shadowRadius = 3
        textLayer.shadowOpacity = 1.0

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
                    iconLayer.frame = CGRect(x: iconX, y: iconY, width: actualIconSize, height: actualIconSize)
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

    override func scrollWheel(with event: NSEvent) {
        // 优先使用水平滑动，如果没有则用垂直滑动（反向）
        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY
        let delta = abs(deltaX) > abs(deltaY) ? deltaX : -deltaY
        let isPrecise = event.hasPreciseScrollingDeltas

        if !isPrecise {
            // 鼠标滚轮 - 直接翻页
            if abs(delta) > 2 {
                if delta > 0 {
                    navigateToPage(currentPage - 1)
                } else {
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

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pageContainerLayer.transform = CATransform3DMakeTranslation(scrollOffset, 0, 0)
            CATransaction.commit()

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
        let location = convert(event.locationInWindow, from: nil)

        if let (item, index) = itemAt(location) {
            if event.clickCount == 1 {
                // 添加点击效果动画
                animatePress(at: index, pressed: true)
                pressedIndex = index
                dragStartPoint = location

                // 启动长按计时器（用于开始拖拽）
                longPressTimer?.invalidate()
                longPressTimer = Timer.scheduledTimer(withTimeInterval: longPressDuration, repeats: false) { [weak self] _ in
                    self?.startDragging(item: item, index: index, at: location)
                }
            }
        } else {
            // 点击空白区域，关闭窗口
            onEmptyAreaClicked?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        // 检查是否移动足够距离来开始拖拽
        if !isDraggingItem, let idx = pressedIndex {
            let distance = hypot(location.x - dragStartPoint.x, location.y - dragStartPoint.y)
            if distance > 10 {
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

        // 检测目标位置
        if let (targetItem, targetIndex) = itemAt(point), targetIndex != draggingIndex {
            highlightDropTarget(at: targetIndex)
        } else {
            clearDropTargetHighlight()
        }
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

        // 清除高亮
        clearDropTargetHighlight()

        // 检查目标
        if let (targetItem, targetIndex) = itemAt(point), targetIndex != dragIndex {
            // 拖拽到另一个 item 上
            if case .app(let dragApp) = dragItem {
                switch targetItem {
                case .app(let targetApp):
                    // 两个应用 -> 创建文件夹
                    print("📁 [CAGrid] Creating folder: \(dragApp.name) + \(targetApp.name)")
                    onCreateFolder?(dragApp, targetApp, targetIndex)
                case .folder(let folder):
                    // 拖到文件夹 -> 移入文件夹
                    print("📂 [CAGrid] Moving to folder: \(dragApp.name) -> \(folder.name)")
                    onMoveToFolder?(dragApp, folder)
                default:
                    break
                }
            }
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
}

// MARK: - SwiftUI Wrapper

import SwiftUI

struct CAGridViewRepresentable: NSViewRepresentable {
    @ObservedObject var appStore: AppStore
    var items: [LaunchpadItem]  // 支持传入过滤后的 items
    var onOpenApp: ((AppInfo) -> Void)?
    var onOpenFolder: ((FolderInfo) -> Void)?

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
                // 空白位置，关闭窗口
                AppDelegate.shared?.hideWindow()
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

        return view
    }

    func updateNSView(_ nsView: CAGridView, context: Context) {
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

        // 更新 items - 总是检查并更新（使用传入的 items，支持搜索过滤）
        if nsView.items.count != items.count || nsView.items.isEmpty || itemsChanged(nsView.items, items) {
            print("🔄 [CAGrid] Updating items: \(nsView.items.count) -> \(items.count)")
            nsView.items = items
        }

        // 同步页面
        if nsView.currentPage != appStore.currentPage {
            print("📄 [CAGrid] Page sync: \(nsView.currentPage) -> \(appStore.currentPage)")
            nsView.navigateToPage(appStore.currentPage, animated: true)
        }
    }

    // 检查 items 是否变化（简单比较第一个和最后一个）
    private func itemsChanged(_ old: [LaunchpadItem], _ new: [LaunchpadItem]) -> Bool {
        guard old.count == new.count else { return true }
        guard !old.isEmpty else { return false }
        return old.first?.id != new.first?.id || old.last?.id != new.last?.id
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

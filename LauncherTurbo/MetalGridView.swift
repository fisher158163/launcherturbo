import AppKit
import Metal
import MetalKit
import QuartzCore
import Combine

// MARK: - Metal Grid View
/// 高性能 Metal 渲染的应用网格视图，支持 120Hz ProMotion
final class MetalGridView: NSView {

    // MARK: - Properties

    private var displayLink: CADisplayLink?
    private var metalLayer: CAMetalLayer!
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var pipelineState: MTLRenderPipelineState!

    // 纹理缓存
    private var iconTextureCache: [String: MTLTexture] = [:]
    private let textureCacheLock = NSLock()

    // 网格配置
    var columns: Int = 7
    var rows: Int = 5
    var iconSize: CGFloat = 72
    var itemSpacing: CGFloat = 20
    var rowSpacing: CGFloat = 30

    // 数据源
    var items: [LaunchpadItem] = [] {
        didSet { needsDisplay = true }
    }

    // 分页
    var currentPage: Int = 0 {
        didSet {
            if currentPage != oldValue {
                animateToPage(currentPage, from: oldValue)
            }
        }
    }
    var itemsPerPage: Int { columns * rows }
    var pageCount: Int { max(1, (items.count + itemsPerPage - 1) / itemsPerPage) }

    // 滚动状态
    private var scrollOffset: CGFloat = 0
    private var targetScrollOffset: CGFloat = 0
    private var scrollVelocity: CGFloat = 0
    private var isAnimating = false

    // 性能监控
    private var lastFrameTime: CFAbsoluteTime = 0
    private var frameCount: Int = 0
    private var fps: Double = 0

    // 回调
    var onItemClicked: ((LaunchpadItem, Int) -> Void)?
    var onPageChanged: ((Int) -> Void)?
    var onFPSUpdate: ((Double) -> Void)?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupMetal()
        setupDisplayLink()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupMetal()
        setupDisplayLink()
    }

    deinit {
        displayLink?.invalidate()
    }

    // MARK: - Metal Setup

    private func setupMetal() {
        // 获取 Metal 设备
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("❌ [MetalGrid] Metal is not supported on this device")
            return
        }
        self.device = device

        // 创建命令队列
        guard let commandQueue = device.makeCommandQueue() else {
            print("❌ [MetalGrid] Failed to create command queue")
            return
        }
        self.commandQueue = commandQueue

        // 配置 Metal layer
        metalLayer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0

        // 启用 ProMotion (120Hz)
        if #available(macOS 14.0, *) {
            metalLayer.developerHUDProperties = [:]
        }

        wantsLayer = true
        layer = metalLayer

        // 创建渲染管线
        setupRenderPipeline()

        print("✅ [MetalGrid] Metal initialized successfully")
    }

    private func setupRenderPipeline() {
        // 创建简单的纹理渲染着色器
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn {
            float2 position [[attribute(0)]];
            float2 texCoord [[attribute(1)]];
        };

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        vertex VertexOut vertexShader(VertexIn in [[stage_in]],
                                       constant float4x4 &mvp [[buffer(1)]]) {
            VertexOut out;
            out.position = mvp * float4(in.position, 0.0, 1.0);
            out.texCoord = in.texCoord;
            return out;
        }

        fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                        texture2d<float> texture [[texture(0)]],
                                        sampler textureSampler [[sampler(0)]]) {
            return texture.sample(textureSampler, in.texCoord);
        }
        """

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let vertexFunction = library.makeFunction(name: "vertexShader")
            let fragmentFunction = library.makeFunction(name: "fragmentShader")

            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha

            // 顶点描述符
            let vertexDescriptor = MTLVertexDescriptor()
            vertexDescriptor.attributes[0].format = .float2
            vertexDescriptor.attributes[0].offset = 0
            vertexDescriptor.attributes[0].bufferIndex = 0
            vertexDescriptor.attributes[1].format = .float2
            vertexDescriptor.attributes[1].offset = MemoryLayout<Float>.size * 2
            vertexDescriptor.attributes[1].bufferIndex = 0
            vertexDescriptor.layouts[0].stride = MemoryLayout<Float>.size * 4
            pipelineDescriptor.vertexDescriptor = vertexDescriptor

            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("❌ [MetalGrid] Failed to create pipeline state: \(error)")
        }
    }

    // MARK: - Display Link (120Hz)

    private func setupDisplayLink() {
        guard let window = window ?? NSApp.windows.first else {
            // 延迟设置
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.setupDisplayLink()
            }
            return
        }

        displayLink = window.displayLink(target: self, selector: #selector(displayLinkCallback(_:)))

        // 请求 120Hz
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        displayLink?.add(to: .main, forMode: .common)

        print("✅ [MetalGrid] DisplayLink configured for 120Hz")
    }

    @objc private func displayLinkCallback(_ displayLink: CADisplayLink) {
        // 计算 FPS
        let now = CFAbsoluteTimeGetCurrent()
        if lastFrameTime > 0 {
            let delta = now - lastFrameTime
            fps = fps * 0.9 + (1.0 / delta) * 0.1
            frameCount += 1
            if frameCount % 60 == 0 {
                onFPSUpdate?(fps)
            }
        }
        lastFrameTime = now

        // 更新动画
        updateAnimation()

        // 渲染
        render()
    }

    // MARK: - Animation

    private func updateAnimation() {
        guard isAnimating else { return }

        // 弹簧动画
        let spring: CGFloat = 0.15
        let damping: CGFloat = 0.85

        let diff = targetScrollOffset - scrollOffset
        scrollVelocity = scrollVelocity * damping + diff * spring
        scrollOffset += scrollVelocity

        // 检查是否完成
        if abs(diff) < 0.5 && abs(scrollVelocity) < 0.5 {
            scrollOffset = targetScrollOffset
            scrollVelocity = 0
            isAnimating = false
        }
    }

    private func animateToPage(_ page: Int, from oldPage: Int) {
        targetScrollOffset = -CGFloat(page) * bounds.width
        isAnimating = true
        onPageChanged?(page)
    }

    // MARK: - Rendering

    private func render() {
        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        // 渲染每个可见页面的图标
        renderVisiblePages(encoder: renderEncoder)

        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func renderVisiblePages(encoder: MTLRenderCommandEncoder) {
        let pageWidth = bounds.width
        let currentOffset = scrollOffset

        // 计算可见页面范围
        let visiblePageStart = max(0, Int(floor(-currentOffset / pageWidth)) - 1)
        let visiblePageEnd = min(pageCount - 1, Int(ceil((-currentOffset + pageWidth) / pageWidth)))

        for pageIndex in visiblePageStart...visiblePageEnd {
            renderPage(pageIndex, offset: currentOffset + CGFloat(pageIndex) * pageWidth, encoder: encoder)
        }
    }

    private func renderPage(_ pageIndex: Int, offset: CGFloat, encoder: MTLRenderCommandEncoder) {
        let startIndex = pageIndex * itemsPerPage
        let endIndex = min(startIndex + itemsPerPage, items.count)

        guard startIndex < items.count else { return }

        for i in startIndex..<endIndex {
            let localIndex = i - startIndex
            let col = localIndex % columns
            let row = localIndex / columns

            let x = offset + CGFloat(col) * (iconSize + itemSpacing) + (bounds.width - CGFloat(columns) * (iconSize + itemSpacing)) / 2
            let y = bounds.height - CGFloat(row + 1) * (iconSize + rowSpacing) - 100 // 顶部留空

            renderItem(items[i], at: CGPoint(x: x, y: y), encoder: encoder)
        }
    }

    private func renderItem(_ item: LaunchpadItem, at position: CGPoint, encoder: MTLRenderCommandEncoder) {
        // 获取或创建纹理
        guard let texture = getTexture(for: item) else { return }

        // TODO: 实现纹理渲染
        // 这里需要设置顶点缓冲区和渲染纹理
        // 为了快速实现，先用 Core Graphics 作为过渡方案
    }

    private func getTexture(for item: LaunchpadItem) -> MTLTexture? {
        let key: String
        switch item {
        case .app(let app):
            key = app.url.path
        case .folder(let folder):
            key = "folder_\(folder.id)"
        case .missingApp(let placeholder):
            key = "missing_\(placeholder.bundlePath)"
        case .empty:
            return nil
        }

        textureCacheLock.lock()
        defer { textureCacheLock.unlock() }

        if let cached = iconTextureCache[key] {
            return cached
        }

        // 异步创建纹理
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.createTexture(for: item, key: key)
        }

        return nil
    }

    private func createTexture(for item: LaunchpadItem, key: String) {
        let icon: NSImage
        switch item {
        case .app(let app):
            icon = app.icon
        case .folder(let folder):
            icon = folder.icon(of: iconSize)
        case .missingApp(let placeholder):
            icon = placeholder.icon
        case .empty:
            return
        }

        // 将 NSImage 转换为 MTLTexture
        guard let cgImage = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: Int(iconSize * 2), // Retina
            height: Int(iconSize * 2),
            mipmapped: false
        )

        guard let texture = device.makeTexture(descriptor: textureDescriptor) else { return }

        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                               size: MTLSize(width: Int(iconSize * 2), height: Int(iconSize * 2), depth: 1))

        // 绘制图标到纹理
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(data: nil,
                                       width: Int(iconSize * 2),
                                       height: Int(iconSize * 2),
                                       bitsPerComponent: 8,
                                       bytesPerRow: Int(iconSize * 2) * 4,
                                       space: colorSpace,
                                       bitmapInfo: bitmapInfo.rawValue) else { return }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: iconSize * 2, height: iconSize * 2))

        guard let data = context.data else { return }
        texture.replace(region: region, mipmapLevel: 0, withBytes: data, bytesPerRow: Int(iconSize * 2) * 4)

        textureCacheLock.lock()
        iconTextureCache[key] = texture
        textureCacheLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.needsDisplay = true
        }
    }

    // MARK: - Input Handling

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : -event.scrollingDeltaY

        switch event.phase {
        case .began:
            isAnimating = false
        case .changed:
            scrollOffset += delta
            // 边界限制
            let minOffset = -CGFloat(pageCount - 1) * bounds.width
            scrollOffset = max(minOffset, min(0, scrollOffset))
        case .ended, .cancelled:
            // 确定目标页面
            let proposedPage = Int(round(-scrollOffset / bounds.width))
            currentPage = max(0, min(pageCount - 1, proposedPage))
            targetScrollOffset = -CGFloat(currentPage) * bounds.width
            isAnimating = true
        default:
            break
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if let (item, index) = itemAt(location) {
            onItemClicked?(item, index)
        }
    }

    private func itemAt(_ point: CGPoint) -> (LaunchpadItem, Int)? {
        let pageWidth = bounds.width
        let currentPageOffset = scrollOffset + CGFloat(currentPage) * pageWidth

        for i in 0..<itemsPerPage {
            let globalIndex = currentPage * itemsPerPage + i
            guard globalIndex < items.count else { break }

            let col = i % columns
            let row = i / columns

            let x = currentPageOffset + CGFloat(col) * (iconSize + itemSpacing) + (bounds.width - CGFloat(columns) * (iconSize + itemSpacing)) / 2
            let y = bounds.height - CGFloat(row + 1) * (iconSize + rowSpacing) - 100

            let rect = CGRect(x: x, y: y, width: iconSize, height: iconSize)
            if rect.contains(point) {
                return (items[globalIndex], globalIndex)
            }
        }

        return nil
    }

    // MARK: - Public Methods

    func preloadTextures() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            for item in self.items {
                _ = self.getTexture(for: item)
            }
        }
    }

    func clearTextureCache() {
        textureCacheLock.lock()
        iconTextureCache.removeAll()
        textureCacheLock.unlock()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            setupDisplayLink()
        }
    }

    override func layout() {
        super.layout()
        metalLayer?.frame = bounds
        metalLayer?.drawableSize = CGSize(
            width: bounds.width * (NSScreen.main?.backingScaleFactor ?? 2),
            height: bounds.height * (NSScreen.main?.backingScaleFactor ?? 2)
        )
    }
}

// MARK: - SwiftUI Wrapper
import SwiftUI

struct MetalGridViewRepresentable: NSViewRepresentable {
    @ObservedObject var appStore: AppStore

    func makeNSView(context: Context) -> MetalGridView {
        let view = MetalGridView(frame: .zero)
        view.columns = appStore.gridColumnsPerPage
        view.rows = appStore.gridRowsPerPage
        view.items = appStore.items
        view.currentPage = appStore.currentPage

        view.onItemClicked = { item, index in
            switch item {
            case .app(let app):
                NSWorkspace.shared.open(app.url)
            case .folder(let folder):
                appStore.openFolder = folder
            default:
                break
            }
        }

        view.onPageChanged = { page in
            appStore.currentPage = page
        }

        view.onFPSUpdate = { fps in
            print("🎮 [MetalGrid] FPS: \(String(format: "%.1f", fps))")
        }

        view.preloadTextures()
        return view
    }

    func updateNSView(_ nsView: MetalGridView, context: Context) {
        nsView.columns = appStore.gridColumnsPerPage
        nsView.rows = appStore.gridRowsPerPage

        if nsView.items.count != appStore.items.count {
            nsView.items = appStore.items
            nsView.preloadTextures()
        }

        if nsView.currentPage != appStore.currentPage {
            nsView.currentPage = appStore.currentPage
        }
    }
}

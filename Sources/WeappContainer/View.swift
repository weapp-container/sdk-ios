import UIKit
@preconcurrency import Metal
@preconcurrency import QuartzCore
import SwiftUI
import WeappContainerNative

@MainActor final class MetalSurface {
    weak var session: WeappContainerSession?
    let layer: CAMetalLayer
    let device: MTLDevice
    let queue: MTLCommandQueue
    var attached = false
    var inFlight = false
    private var epoch: UInt64 = 1
    private var lastRevision: UInt64?
    private var lastEpoch: UInt64?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var onPresented: ((UInt64) -> Void)?
    var cancelInput: (() -> Void)?
    var observeVisibility: (() -> Void)?

    init(layer: CAMetalLayer, session: WeappContainerSession) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw WeappContainerError(code: "ERR_UNSUPPORTED", message: "Metal is unavailable")
        }
        self.device = device; self.queue = queue; self.layer = layer; self.session = session
        layer.device = device; layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false; layer.isOpaque = true; layer.presentsWithTransaction = false
    }
    func invalidate() { epoch &+= 1 }
    func attach() throws {
        // Logical hostSurface ownership exists before App/Page execution, but
        // the physical SDK renderer requires an accepted pack (ERR_NOT_LOADED
        // otherwise). Preflight observations must not attach a Metal renderer.
        guard !attached, let session, session.isLoaded else { return }
        try session.metal { h, result in weapp_container_sdk_metal_attach(h, Unmanaged.passUnretained(device as AnyObject).toOpaque(), Unmanaged.passUnretained(queue as AnyObject).toOpaque(), &result) }
        attached = true; invalidate()
    }
    func detach() throws {
        guard attached else { return }
        precondition(!inFlight, "Drain the host queue before detaching Skia")
        try session?.metal { h, result in weapp_container_sdk_metal_detach(h, &result) }
        attached = false
    }
    func drain() async {
        if inFlight { await withCheckedContinuation { waiters.append($0) } }
    }
    func present() throws {
        guard attached, !inFlight, let session, session.canPresent,
              lastRevision != session.frameRevision || lastEpoch != epoch,
              layer.drawableSize.width > 0, layer.drawableSize.height > 0,
              let drawable = layer.nextDrawable() else { return }
        guard let fence = queue.makeCommandBuffer() else {
            throw WeappContainerError(code: "ERR_METAL", message: "Failed to allocate presentation command buffer")
        }
        let identity = try session.presentationIdentity(), submittedEpoch = epoch
        let revision = identity.revision
        // Rust Skia submits into this same command queue. The following host
        // buffer fences that work and retains the drawable until completion.
        try session.metal { h, result in weapp_container_sdk_metal_present(h, Unmanaged.passUnretained(drawable.texture as AnyObject).toOpaque(), UInt32(drawable.texture.width), UInt32(drawable.texture.height), &result) }
        inFlight = true
        fence.present(drawable)
        fence.addCompletedHandler { [self, drawable] buffer in
            let success = buffer.status == .completed
            let message = buffer.error?.localizedDescription ?? "Metal command buffer status \(buffer.status.rawValue)"
            DispatchQueue.main.async { [self, drawable] in
                _ = drawable
                inFlight = false
                if success, attached, epoch == submittedEpoch, session.canPresent {
                    do {
                        // Completion of this drawable acknowledges only its
                        // captured frame; onReady may accept a newer frame.
                        try session.acknowledgePresentation(generation: identity.generation, revision: revision, layout: identity.layout)
                        lastRevision = revision; lastEpoch = submittedEpoch; onPresented?(revision)
                    } catch let error as WeappContainerError where error.code == "ERR_CANCELLED" {
                        // Reload/resize superseded this drawable. Retry the
                        // current frame without acknowledging it retroactively.
                    } catch { session.report(error) }
                } else if !success { session.report(WeappContainerError(code: "ERR_METAL", message: message)) }
                let completed = waiters; waiters.removeAll()
                for c in completed { c.resume() }
            }
        }
        fence.commit()
    }
}

@MainActor private final class DisplayTarget: NSObject {
    weak var view: WeappContainerView?
    @objc func tick() { view?.display() }
}

/// A touch that starts inside the mini-program belongs to its input runtime.
/// Claim only ancestor scroll pans; leave host navigation and other recognizers
/// free to cancel the touch through the normal UIKit cancellation path.
@MainActor private final class ContainerTouchOwnership: UIGestureRecognizer {
    private let acceptsInput: () -> Bool
    private var contacts: Set<UITouch> = []
    init(acceptsInput: @escaping () -> Bool) {
        self.acceptsInput = acceptsInput
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false; delaysTouchesEnded = false
    }
    private func isAncestorScrollPan(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let scroll = recognizer.view as? UIScrollView, recognizer === scroll.panGestureRecognizer,
              let view else { return false }
        return view.isDescendant(of: scroll)
    }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        isAncestorScrollPan(preventedGestureRecognizer)
    }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        !isAncestorScrollPan(preventingGestureRecognizer) && super.canBePrevented(by: preventingGestureRecognizer)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard acceptsInput() else { state = state == .possible ? .failed : .cancelled; return }
        contacts.formUnion(touches)
        state = state == .possible ? .began : .changed
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { state = .changed }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        contacts.subtract(touches); state = contacts.isEmpty ? .ended : .changed
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
    override func reset() { super.reset(); contacts.removeAll() }
}

/// Native Skia Metal surface. Removing this view hides the app; it does not
/// close its session. Await detach() before attaching a replacement view.
@MainActor public final class WeappContainerView: UIView {
    public override class var layerClass: AnyClass { CAMetalLayer.self }
    public let session: WeappContainerSession
    /// Delivered only after the Metal queue has completed the frame.
    public var onPresented: ((UInt64) -> Void)?
    public private(set) var presentedFrameCount: UInt64 = 0
    public private(set) var lastPresentedRevision: UInt64?
    private var surface: MetalSurface!
    private let target = DisplayTarget()
    private var link: CADisplayLink?
    private var notifications: [NSObjectProtocol] = []
    private var detached = false
    private var detaching = false
    private var appActive = false
    private var sceneActive = true
    private var observedScene: ObjectIdentifier?
    private var touch: UITouch?
    private var start = CGPoint.zero
    private var last = CGPoint.zero
    private var started: TimeInterval = 0
    private var moved = false
    private var ignoringTouches = false
    private var pendingInput = PresentationInputQueue()
    private var gestureContext: WeappJSON?

    public init(session: WeappContainerSession) throws {
        self.session = session
        super.init(frame: .zero)
        surface = try MetalSurface(layer: layer as! CAMetalLayer, session: session)
        try session.claim(surface)
        isOpaque = true; backgroundColor = .white; isMultipleTouchEnabled = true
        addGestureRecognizer(ContainerTouchOwnership { [weak self] in self?.acceptsInput ?? false })
        // Session lifecycle operations retire their native touch state. They
        // must not replay a cancellation against another page or surface.
        surface.cancelInput = { [weak self] in self?.retireInput() }
        surface.observeVisibility = { [weak self] in self?.synchronizeActivity() }
        target.view = self
        surface.onPresented = { [weak self] revision in
            guard let self else { return }
            presentedFrameCount &+= 1; lastPresentedRevision = revision; onPresented?(revision)
            flushPendingInput()
        }
        let displayLink = CADisplayLink(target: target, selector: #selector(DisplayTarget.tick))
        displayLink.preferredFramesPerSecond = 60; displayLink.isPaused = true
        displayLink.add(to: .main, forMode: .common); link = displayLink
        appActive = UIApplication.shared.applicationState == .active
        notifications = [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
                         UIApplication.didEnterBackgroundNotification, UIScene.didActivateNotification,
                         UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
                         UIScene.didDisconnectNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated { self?.activity(n) }
            }
        }
    }
    @available(*, unavailable, message: "Use init(session:)")
    public required init?(coder: NSCoder) { fatalError() }
    deinit {
        link?.invalidate()
        for token in notifications { NotificationCenter.default.removeObserver(token) }
        if let p = surface {
            let s = session
            Task { @MainActor in
                do { try await s.release(p) } catch { s.report(error) }
            }
        }
    }
    /// Allows a new view to claim this session. Does not close or flush it.
    public func detach() async throws {
        guard !detached else { return }
        retireInput(); detaching = true; synchronizeActivity()
        do { try await session.release(surface) }
        catch { detaching = false; synchronizeActivity(); throw error }
        detached = true; detaching = false; link?.invalidate(); link = nil
        for token in notifications { NotificationCenter.default.removeObserver(token) }; notifications.removeAll()
        surface.layer.device = nil
    }
    public func close() async throws { try await session.close(); try await detach() }
    public override var isHidden: Bool { didSet { if surface != nil { synchronizeActivity() } } }
    public override var alpha: CGFloat { didSet { if surface != nil { synchronizeActivity() } } }
    public override func didMoveToSuperview() { super.didMoveToSuperview(); if surface != nil { synchronizeActivity() } }
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        retireInput()
        let scene = window?.windowScene.map(ObjectIdentifier.init)
        if scene != observedScene { observedScene = scene; sceneActive = true }
        surface.invalidate(); setNeedsLayout(); synchronizeActivity()
    }
    public override func layoutSubviews() {
        super.layoutSubviews()
        guard !detached, !session.isClosed, let window,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            retireInput(); link?.isPaused = true; session.setSurfaceForeground(false); return
        }
        let width = max(1, bounds.width.rounded()), height = max(1, bounds.height.rounded())
        let scale = window.screen.scale
        let pixels = CGSize(width: width * scale, height: height * scale)
        if surface.layer.drawableSize != pixels || surface.layer.contentsScale != scale {
            retireInput(); surface.layer.contentsScale = scale; surface.layer.drawableSize = pixels; surface.invalidate()
        }
        let intersection = bounds.inset(by: safeAreaInsets).intersection(bounds)
        let safe = intersection.isNull ? CGRect.zero : intersection
        let sx = width / bounds.width, sy = height / bounds.height
        let inScreen = convert(bounds, to: window.screen.coordinateSpace)
        let screen = window.screen.bounds
        let metrics: WeappJSON = .object([
            "windowWidth": .number(Double(width)), "windowHeight": .number(Double(height)), "pixelRatio": .number(Double(scale)),
            "screenWidth": .number(Double(screen.width)), "screenHeight": .number(Double(screen.height)),
            "statusBarHeight": .number(Double(window.windowScene?.statusBarManager?.statusBarFrame.height ?? 0)),
            "screenTop": .number(Double(inScreen.minY)),
            "safeArea": .object(["left": .number(Double(safe.minX * sx)), "right": .number(Double(safe.maxX * sx)), "top": .number(Double(safe.minY * sy)), "bottom": .number(Double(safe.maxY * sy)), "width": .number(Double(safe.width * sx)), "height": .number(Double(safe.height * sy))]),
            "deviceOrientation": .string(screen.width > screen.height ? "landscape" : "portrait")
        ])
        session.updateMetrics(metrics); synchronizeActivity(); display()
    }
    fileprivate func display() {
        guard !detached else { return }
        synchronizeActivity()
        flushPendingInput()
        do { try surface.present() } catch { session.report(error) }
    }
    private func activity(_ n: Notification) {
        if n.name == UIApplication.didBecomeActiveNotification { appActive = true }
        else if n.name == UIApplication.willResignActiveNotification || n.name == UIApplication.didEnterBackgroundNotification { appActive = false }
        else {
            guard let scene = n.object as? UIScene, scene === window?.windowScene else { return }
            sceneActive = n.name == UIScene.didActivateNotification
        }
        synchronizeActivity()
    }
    private func synchronizeActivity() {
        let sceneReady = window?.windowScene.map { $0.activationState == .foregroundActive } ?? appActive
        var visible = true
        var ancestor: UIView? = self
        while let view = ancestor {
            if view.isHidden || view.alpha <= 0.01 { visible = false; break }
            ancestor = view.superview
        }
        // UIKit has no general ancestor-visibility notification. The session's
        // independent completion pump also observes this while CADisplayLink is
        // paused, so showing any ancestor resumes presentation.
        let active = visible && !detached && !detaching && window != nil && bounds.width > 0 && bounds.height > 0 && appActive && sceneActive && sceneReady
        if !active { retireInput() }
        session.setSurfaceForeground(active); link?.isPaused = !session.isForeground
    }
    private var acceptsInput: Bool { !detached && session.canPresent && bounds.width > 0 && bounds.height > 0 }
    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard acceptsInput, !ignoringTouches else { return }
        if touch != nil || touches.count != 1 || activeCount(event) > 1 { cancelTouch(); ignoringTouches = true; return }
        guard let t = touches.first else { return }
        touch = t; start = t.location(in: self); last = start; started = t.timestamp; moved = false
        dispatch([pointer("touchstart", active: true, time: t.timestamp)])
    }
    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard acceptsInput else { retireInput(); return }
        guard activeCount(event) <= 1 else { cancelTouch(); ignoringTouches = true; return }
        guard let t = touch, touches.contains(t), !ignoringTouches else { return }
        last = t.location(in: self); moved = moved || hypot(last.x - start.x, last.y - start.y) > 10
        dispatch([pointer("touchmove", active: true, time: t.timestamp)])
    }
    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer { if activeCount(event) == 0 { ignoringTouches = false } }
        guard let t = touch, touches.contains(t) else { return }
        guard acceptsInput else { retireInput(); return }
        guard !ignoringTouches else { cancelTouch(); return }
        last = t.location(in: self); moved = moved || hypot(last.x - start.x, last.y - start.y) > 10
        var values = [pointer("touchend", active: false, time: t.timestamp)]
        if !moved, t.timestamp - started <= 0.5, bounds.contains(last) { values.append(pointer("tap", active: false, time: t.timestamp)) }
        touch = nil; dispatch(values)
    }
    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = touch, touches.contains(t) { cancelTouch() }
        if activeCount(event) == 0 { ignoringTouches = false }
    }
    private func cancelTouch() {
        guard let t = touch else { return }
        let value = pointer("touchcancel", active: false, time: t.timestamp); touch = nil
        guard session.canPresent else { retireInput(); return }
        // UIKit cancellation is a terminal event in this gesture, and must
        // wait for the same presentation gate as its preceding touch phases.
        dispatch([value])
    }
    private func activeCount(_ event: UIEvent?) -> Int { event?.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }.count ?? 0 }
    private func dispatch(_ values: [WeappJSON]) {
        do {
            let state = try session.state(), context = inputContext(state)
            if values.first?["type"].string == "touchstart" { gestureContext = context }
            guard gestureContext == context else { retireInput(); return }
            try pendingInput.enqueue(values, context: context, now: CACurrentMediaTime())
            flushPendingInput()
        } catch { retireInput(); session.report(error) }
    }
    private func flushPendingInput() {
        guard !pendingInput.batches.isEmpty, session.canPresent else { return }
        do {
            let state = try session.state()
            guard inputContext(state) == pendingInput.context else { retireInput(); return }
            guard let batch = try pendingInput.next(context: inputContext(state), inputEnabled: state["inputEnabled"].bool == true, now: CACurrentMediaTime()) else { return }
            try session.input(batch.events)
            pendingInput.didDispatch(batch)
        } catch let error as WeappContainerError where error.code == "ERR_CANCELLED" {
            // A runtime completion accepted another frame before input. Keep
            // this batch until its actual presentation acknowledgement.
        } catch {
            retireInput(); session.report(error)
        }
    }
    private func inputContext(_ state: WeappJSON) -> WeappJSON {
        .object(["generation": state["generation"], "page": state["page"]])
    }
    private func retireInput() {
        pendingInput.clear(); gestureContext = nil
        touch = nil; ignoringTouches = false
    }
    private func pointer(_ type: String, active: Bool, time: TimeInterval) -> WeappJSON {
        let x = Double(last.x * max(1, bounds.width.rounded()) / max(1, bounds.width))
        let y = Double(last.y * max(1, bounds.height.rounded()) / max(1, bounds.height))
        let contact: WeappJSON = .object(["identifier": .number(0), "clientX": .number(x), "clientY": .number(y), "pageX": .number(x), "pageY": .number(y)])
        return .object(["type": .string(type), "x": .number(x), "y": .number(y), "timeStamp": .number(time * 1000), "bubbles": .bool(true), "detail": .object(type == "tap" ? ["x": .number(x), "y": .number(y)] : [:]), "touches": .array(active ? [contact] : []), "changedTouches": .array([contact])])
    }
}

@MainActor public final class WeappContainerViewController: UIViewController {
    public let containerView: WeappContainerView
    public var session: WeappContainerSession { containerView.session }
    public init(session: WeappContainerSession) throws { containerView = try WeappContainerView(session: session); super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable, message: "Use init(session:)")
    public required init?(coder: NSCoder) { fatalError() }
    public override func loadView() { view = containerView }
}

/// Create the native view once with try WeappContainerView(session:), then
/// give it to SwiftUI. Removing it hides the session; await close() when done.
@MainActor public struct WeappContainerRepresentable: UIViewRepresentable {
    public let containerView: WeappContainerView
    public init(view: WeappContainerView) { containerView = view }
    public func makeUIView(context: Context) -> WeappContainerView { containerView }
    public func updateUIView(_ uiView: WeappContainerView, context: Context) {}
}

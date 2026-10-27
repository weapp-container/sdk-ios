import UIKit
import WeappContainer

@main final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "SDK Consumer", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = ConsumerSceneDelegate.self
        return configuration
    }
}

final class ConsumerSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = ConsumerController(); window.makeKeyAndVisible(); self.window = window
    }
}

@MainActor final class ConsumerController: UIViewController, UIScrollViewDelegate {
    private var session: WeappContainerSession!
    private var container: WeappContainerView!
    private let surfaceHost = UIView()
    private let secondHost = UIView()
    private var secondSession: WeappContainerSession!
    private var secondContainer: WeappContainerView!
    private let observation = UILabel()
    private let buttons = UIStackView()
    private let hostScroll = UIScrollView()
    private let parentDragArea = UIView()
    private var nested = false
    private var facts: [String: WeappJSON] = [:]
    private var events: [WeappJSON] = []
    private var featurePaused = false
    private var orientationMask: UIInterfaceOrientationMask = .allButUpsideDown
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { orientationMask }
    private var pack: URL { Bundle.main.resourceURL!.appendingPathComponent("portable-pack") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .white
        observation.accessibilityIdentifier = "sdk-observation"; observation.isAccessibilityElement = true
        observation.text = "Native SDK consumer"; observation.font = .systemFont(ofSize: 12)
        buttons.axis = .horizontal; buttons.distribution = .fillEqually
        for (title, action) in [("Reload", #selector(reload)), ("Hidden call", #selector(hiddenCall)), ("Pause", #selector(pauseFeature)), ("Reopen", #selector(reopen)), ("Next", #selector(nextPage)), ("Back", #selector(previousPage)), ("Embed", #selector(embed)), ("Reset", #selector(resetParent)), ("Rotate", #selector(rotateScene)), ("Close", #selector(closePair))] {
            let b = UIButton(type: .system); b.setTitle(title, for: .normal); b.accessibilityIdentifier = title
            b.addTarget(self, action: action, for: .touchUpInside); buttons.addArrangedSubview(b)
        }
        view.addSubview(surfaceHost); view.addSubview(secondHost); view.addSubview(observation); view.addSubview(buttons)
        hostScroll.delegate = self; hostScroll.accessibilityIdentifier = "host-scroll"
        parentDragArea.backgroundColor = .systemYellow; parentDragArea.accessibilityIdentifier = "parent-drag-area"
        parentDragArea.isAccessibilityElement = true
        do { try install(); try installSecond() } catch { fail(error) }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets
        observation.frame = CGRect(x: 8, y: safe.top, width: view.bounds.width - 16, height: 24)
        buttons.frame = CGRect(x: 0, y: view.bounds.height - safe.bottom - 44, width: view.bounds.width, height: 44)
        let area = CGRect(x: 0, y: safe.top + 24, width: view.bounds.width, height: max(1, view.bounds.height - safe.top - safe.bottom - 68))
        if nested {
            hostScroll.frame = area; hostScroll.contentSize = CGSize(width: area.width, height: 1400)
            parentDragArea.frame = CGRect(x: 0, y: 0, width: area.width, height: 120)
            surfaceHost.frame = CGRect(x: 0, y: 120, width: area.width, height: 380)
        } else {
            let half = max(1, (view.bounds.width - 12) / 2)
            surfaceHost.frame = CGRect(x: 0, y: area.minY, width: half, height: area.height)
            secondHost.frame = CGRect(x: half + 12, y: area.minY, width: half, height: area.height)
        }
        container?.frame = surfaceHost.bounds
        secondContainer?.frame = secondHost.bounds
        publish()
    }
    @objc private func rotateScene() {
        guard let scene = view.window?.windowScene else { return }
        orientationMask = scene.interfaceOrientation.isLandscape ? .portrait : .landscapeRight
        facts["requestedOrientationMask"] = .number(Double(orientationMask.rawValue))
        setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientationMask)) { [weak self] error in
            self?.fail(error)
        }
    }
    @objc private func embed() {
        nested = true; secondHost.isHidden = true; view.insertSubview(hostScroll, belowSubview: observation)
        facts.removeValue(forKey: "scroll"); facts.removeValue(forKey: "geometry")
        hostScroll.addSubview(parentDragArea); hostScroll.addSubview(surfaceHost)
        view.setNeedsLayout(); view.layoutIfNeeded()
        facts["nested"] = .bool(true); publish()
    }
    @objc private func resetParent() { hostScroll.setContentOffset(.zero, animated: false); publish() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { publish() }
    private func install() throws {
        facts["loaded"] = .bool(false); facts["completedFrames"] = .number(0); facts.removeValue(forKey: "initial"); facts.removeValue(forKey: "geometry")
        let s = WeappContainerSession(configuration: .init(storageKey: "sdk-ios-consumer/account"))
        try s.registerHostMethod("native.echo") { value in .object(["echo": value, "native": .bool(true)]) }
        try s.registerHostMethod("native.delayed") { value in
            try await Task.sleep(nanoseconds: 250_000_000)
            return .object(["finished": .bool(true), "value": value])
        }
        let v = try WeappContainerView(session: s)
        v.accessibilityIdentifier = "sdk-surface"; v.isAccessibilityElement = true
        v.onPresented = { [weak self, weak v] revision in
            guard let self, let v else { return }
            facts["presentedRevision"] = .number(Double(revision))
            facts["completedFrames"] = .number(Double(v.presentedFrameCount))
            facts["stateAfterPresentation"] = try? s.state()
            facts["capabilitiesAfterPresentation"] = try? s.capabilities()
            // Geometry is valid only after this revision has actually been
            // presented. Loading and resizing may still be awaiting Metal.
            if facts["geometry"] == nil, facts["stateAfterPresentation"]?["inputEnabled"].bool == true {
                do { try s.sendMessage(.object(["op": .string("inspect")])) } catch { fail(error) }
            }
            publish()
        }
        s.onEvent = { [weak self, weak v, weak s] event in
            guard let self, let v, let s else { return }
            switch event {
            case .message(let message):
                events.append(message)
                if let type = message["kind"].string { facts[type] = message }
                if message["kind"].string == "hiddenDone" {
                    if featurePaused {
                        facts["hostPausePreserved"] = .bool(v.window != nil && !surfaceHost.isHidden && !s.isForeground)
                        facts["hostPausePresentationStopped"] = .bool(Double(v.presentedFrameCount) == facts["hostPauseStableFrames"]?.number)
                        featurePaused = false
                        do { try s.setForeground(true) } catch { fail(error) }
                    } else {
                        facts["hiddenCompletionWhileAttached"] = .bool(v.window != nil && surfaceHost.isHidden && !s.isForeground)
                        facts["hiddenPresentationStopped"] = .bool(Double(v.presentedFrameCount) == facts["hiddenStableFrames"]?.number)
                        surfaceHost.isHidden = false; view.setNeedsLayout()
                    }
                }
            case .error(let error): fail(error)
            case .closed(let error): facts["closed"] = .bool(true); if let error { fail(error) }
            case .ready(let state): facts["ready"] = state
            case .navigation: facts["currentRoute"] = try? s.state()["page"]["route"]
            }
            publish()
        }
        session = s; container = v; surfaceHost.addSubview(v); view.setNeedsLayout()
        do {
            _ = try WeappContainerView(session: s)
            throw NSError(domain: "consumer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Second view unexpectedly accepted"])
        } catch let error as WeappContainerError {
            guard error.code == "ERR_SURFACE_ATTACHED" else { throw error }
            facts["singleViewRejected"] = .bool(true)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await s.load(packURL: pack)
                facts["capabilities"] = try s.capabilities()
                facts["loaded"] = .bool(true)
                try s.sendMessage(.object(["kind": .string("echo"), "value": .string("host-to-js")]))
                publish()
            } catch { fail(error) }
        }
    }
    private func installSecond() throws {
        let s = WeappContainerSession(configuration: .init(storageKey: "sdk-ios-consumer/second"))
        let v = try WeappContainerView(session: s)
        v.accessibilityIdentifier = "sdk-second-surface"; v.isAccessibilityElement = true
        v.onPresented = { [weak self, weak v, weak s] _ in
            guard let self, let v, let s else { return }
            facts["secondCompletedFrames"] = .number(Double(v.presentedFrameCount))
            facts["secondStateAfterPresentation"] = try? s.state(); publish()
        }
        s.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .message(let value):
                if value["kind"].string == "initial" { facts["secondInitial"] = value }
                if value["kind"].string == "tap" { facts["secondTap"] = value }
            case .error(let error): fail(error)
            default: break
            }
            publish()
        }
        secondSession = s; secondContainer = v; secondHost.addSubview(v)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await s.load(packURL: pack); facts["secondLoaded"] = .bool(true); publish() }
            catch { fail(error) }
        }
    }
    @objc private func nextPage() {
        do { try session.navigate(route: "pages/detail/index", query: ["source": .string("native-host")]); publish() }
        catch { fail(error) }
    }
    @objc private func previousPage() {
        do { try session.back(); publish() }
        catch { fail(error) }
    }
    @objc private func closePair() {
        Task { @MainActor in
            do {
                try await container.close(); try await secondContainer.close()
                facts["pairClosed"] = .bool(true); publish()
            } catch { fail(error) }
        }
    }
    @objc private func reload() {
        Task { @MainActor in
            do {
                let before = try session.state()
                do { try await session.load(packURL: pack.appendingPathComponent("missing")); throw NSError(domain: "consumer", code: 2) }
                catch let error as WeappContainerError {
                    facts["failedLoadCode"] = .string(error.code)
                    facts["failedLoadPreservedGeneration"] = .bool(try session.state()["generation"] == before["generation"])
                }
                try session.sendMessage(.object(["kind": .string("recovered")]))
                for _ in 0..<16 { try await session.flushStorage() }
                facts["flushed"] = .bool(true)
                try await session.load(packURL: pack)
                facts["reloaded"] = .bool(true); publish()
            } catch { fail(error) }
        }
    }
    @objc private func hiddenCall() {
        do {
            try session.sendMessage(.object(["kind": .string("hidden")]))
            surfaceHost.isHidden = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 60_000_000)
                facts["hiddenStableFrames"] = .number(Double(container.presentedFrameCount)); publish()
            }
            publish()
        } catch { fail(error) }
    }
    @objc private func pauseFeature() {
        do {
            featurePaused = true
            try session.sendMessage(.object(["kind": .string("hidden")]))
            try session.setForeground(false)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 60_000_000)
                facts["hostPauseStableFrames"] = .number(Double(container.presentedFrameCount)); publish()
            }
        } catch { fail(error) }
    }
    @objc private func reopen() {
        Task { @MainActor in
            do {
                try await container.close(); container.removeFromSuperview()
                facts["durableClose"] = .bool(true)
                try install(); facts["reopened"] = .bool(true); publish()
            } catch { fail(error) }
        }
    }
    private func fail(_ error: Error) { facts["failure"] = .string(error.localizedDescription); publish() }
    private func publish() {
        facts["surfaceWidth"] = .number(Double(container?.bounds.width.rounded() ?? 0))
        facts["surfaceHeight"] = .number(Double(container?.bounds.height.rounded() ?? 0))
        facts["interfaceOrientation"] = .number(Double(view.window?.windowScene?.interfaceOrientation.rawValue ?? 0))
        facts["deviceOrientation"] = .number(Double(UIDevice.current.orientation.rawValue))
        facts["foreground"] = .bool(session?.isForeground ?? false)
        facts["parentOffset"] = .number(Double(hostScroll.contentOffset.y))
        facts["events"] = .array(events)
        if let data = try? JSONEncoder().encode(WeappJSON.object(facts)), let json = String(data: data, encoding: .utf8) {
            observation.accessibilityValue = json
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? data.write(to: documents.appendingPathComponent("result.json"), options: .atomic)
        }
    }
}

import AppKit
import Metal
import QuartzCore
import os

/// Shows a scene across every screen as one picture, until any input or until its time is up,
/// and keeps the displays awake meanwhile. It can lock the Mac when it ends.
@MainActor
final class Screensaver: NSObject {
    private var running = false
    private var locks = false
    /// Counts starts, so a renderer that finishes compiling after its run ended is dropped.
    private var session = 0
    private var renderer: SaverRenderer?
    private var building: Task<Void, Never>?
    private var start: CFTimeInterval = 0
    private var views: [SaverView] = []
    private var windows: [NSWindow] = []
    private var displayLink: CADisplayLink?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var caffeinate: Process?
    private var timer: Timer?
    private var shownAt = Date.distantPast
    private var mouseTravel = 0.0
    /// Frames presented but not yet on screen, per screen. Each holds a drawable, and asking for
    /// one while all are held blocks the main thread for up to a second.
    private var unshown: [Int] = []
    private let log = Logger(subsystem: "local.tether", category: "screensaver")

    /// Nil `duration` runs until stopped. The screens stay black while the scene is built and
    /// compiled; if that fails, the error is logged and the screensaver stops.
    func start(_ scene: SaverScene, for duration: TimeInterval?, locks: Bool) throws {
        stop()
        guard let device = MTLCreateSystemDefaultDevice() else { throw CocoaError(.featureUnsupported) }
        running = true
        self.locks = locks
        session += 1
        start = CACurrentMediaTime()

        // Displays would otherwise sleep on their idle timer. -w ends it if Tether quits first.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-d", "-w", "\(ProcessInfo.processInfo.processIdentifier)"] + (duration.map { ["-t", "\(Int($0))"] } ?? [])
        try? process.run()
        caffeinate = process
        if let duration {
            timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.end() }
            }
        }

        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return nil
        }
        let center = NotificationCenter.default
        observers = [
            // Switching to another app (⌘⇥, a notification) ends it too.
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.end() }
            },
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.showWindows(device: device) }
            },
        ]
        showWindows(device: device)
        NSCursor.hide()
        let screens = views.map(\.screen), session = session
        building = Task {
            do {
                let renderer = try await SaverRenderer.make(scene, device: device, screens: screens)
                guard running, session == self.session else { return }
                try renderer.setScreens(views.map(\.screen))
                self.renderer = renderer
            } catch {
                guard running, session == self.session else { return }
                log.error("\(scene.name, privacy: .public) can't start: \(String(describing: error), privacy: .public)")
                end()
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        building?.cancel()
        building = nil
        renderer = nil
        closeWindows()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        timer?.invalidate()
        timer = nil
        caffeinate?.terminate()
        caffeinate = nil
        NSCursor.unhide()
    }

    /// One window per screen, each showing its own part of the picture.
    private func showWindows(device: MTLDevice) {
        closeWindows()
        let layout = SaverLayout(screens: NSScreen.screens.map(\.frame))
        views = NSScreen.screens.map { screen in
            SaverView(frame: CGRect(origin: .zero, size: screen.frame.size),
                      screen: SaverScreen(rect: layout.rect(of: screen.frame), size: screen.frame.size, scale: screen.backingScaleFactor), device: device)
        }
        if let renderer, (try? renderer.setScreens(views.map(\.screen))) == nil { return end() }
        windows = zip(NSScreen.screens, views).map { screen, view in
            let window = SaverWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.backgroundColor = .black
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.acceptsMouseMovedEvents = true
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFrontRegardless()
            return window
        }
        NSApp.activate()
        windows.first?.makeKey()
        // Every screen is drawn on one beat, so they always show the same moment.
        displayLink = views.first?.displayLink(target: self, selector: #selector(drawFrame))
        // Film's cadence; it divides both 60 and 120 Hz evenly.
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        displayLink?.add(to: .main, forMode: .common)
        shownAt = .now
        mouseTravel = 0
        unshown = views.map { _ in 0 }
    }

    private func closeWindows() {
        displayLink?.invalidate()
        displayLink = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        views = []
    }

    @objc private func drawFrame() {
        guard let renderer, renderer.canRender, unshown.allSatisfy({ $0 < 2 }) else { return }
        let drawables = views.compactMap { $0.metalLayer.nextDrawable() }
        guard drawables.count == views.count,
              let buffer = renderer.render(time: CACurrentMediaTime() - start, into: drawables.map(\.texture),
                                           behind: unshown.contains { $0 > 0 }) else { return }
        for (i, drawable) in drawables.enumerated() {
            unshown[i] += 1
            drawable.addPresentedHandler { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let self, i < self.unshown.count { self.unshown[i] = max(0, self.unshown[i] - 1) }
                    }
                }
            }
        }
        drawables.forEach(buffer.present)
        buffer.commit()
    }

    private func handle(_ event: NSEvent) {
        // Ignore what's still arriving from the click that started it.
        guard Date.now.timeIntervalSince(shownAt) > 0.5 else { return }
        if event.type == .mouseMoved {
            // A nudged desk shouldn't end it.
            mouseTravel += hypot(event.deltaX, event.deltaY)
            guard mouseTravel > 12 else { return }
        }
        end()
    }

    /// Stops however it ends, except for a new start, locking the Mac first if asked. The lock
    /// screen takes a moment to cover the screens, so the windows stay up, showing the last frame,
    /// until it has.
    private func end() {
        guard running else { return }
        guard locks else { return stop() }
        ScreenLock.lock()
        let covered = windows
        windows = []
        stop()
        Task {
            try? await Task.sleep(for: .seconds(1))
            covered.forEach { $0.orderOut(nil) }
        }
    }

    private final class SaverWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private final class SaverView: NSView {
        let metalLayer = CAMetalLayer()
        /// The part of the picture this screen shows.
        let screen: SaverScreen

        init(frame: CGRect, screen: SaverScreen, device: MTLDevice) {
            self.screen = screen
            super.init(frame: frame)
            metalLayer.device = device
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { nil }

        override func makeBackingLayer() -> CALayer { metalLayer }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            let scale = window?.backingScaleFactor ?? 1
            metalLayer.contentsScale = scale
            metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        }
    }
}

/// Locks the Mac with the call behind the system's Lock Screen command. It's private, so it's
/// looked up at run time.
@MainActor
private enum ScreenLock {
    private static let lockNow: (@convention(c) () -> Int32)? = {
        guard let login = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(login, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
    }()

    static func lock() {
        if let lockNow {
            _ = lockNow()
            return
        }
        // Without the call, sleeping the displays locks a Mac that asks for its password on wake.
        let sleep = Process()
        sleep.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        sleep.arguments = ["displaysleepnow"]
        try? sleep.run()
    }
}

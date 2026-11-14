import Foundation
import GameController

enum MouseTrackingMode: String, CaseIterable {
    case relative
    case absolute
}

/// Session-scoped physical mouse input.
///
/// visionOS may expose several GCMouse profiles for a single physical device
/// (an automation profile, the built-in keyboard/trackpad, a USB receiver...).
/// Handlers are installed on every profile; the first one that produces an
/// event becomes the source, so the app never forwards the same movement twice.
final class StreamMouseInput {
    private enum MouseButton: Int32 {
        case left = 0x01
        case middle = 0x02
        case right = 0x03
        case back = 0x04
        case forward = 0x05
    }

    private enum Action: Int8 {
        case press = 0x07
        case release = 0x08
    }

    private static let deltaDivisor: Float = 1.25
    private static let scrollStep: Int32 = 20

    private var mode: MouseTrackingMode = .relative
    private var streamWidth: Int32 = 1920
    private var streamHeight: Int32 = 1080

    private var profiles: [GCMouse] = []
    private var activeProfile: GCMouse?
    private var observers: [NSObjectProtocol] = []
    private var running = false
    private var attachRetry: DispatchWorkItem?
    private var attachRetries = 0

    private var moveRemainderX: Float = 0
    private var moveRemainderY: Float = 0
    private var cursorX: Float = 0.5
    private var cursorY: Float = 0.5
    private var scrollRemainderX: Float = 0
    private var scrollRemainderY: Float = 0
    private var heldButtons = Set<Int32>()

    func start(mode: MouseTrackingMode, streamWidth: Int32, streamHeight: Int32) {
        stop()
        self.mode = mode
        self.streamWidth = max(streamWidth, 1)
        self.streamHeight = max(streamHeight, 1)
        resetState()
        running = true

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] _ in
                self?.refreshProfiles()
            },
            center.addObserver(forName: .GCMouseDidBecomeCurrent, object: nil, queue: .main) { [weak self] _ in
                self?.refreshProfiles()
            },
            center.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] note in
                guard let self, let mouse = note.object as? GCMouse else { return }
                self.detach(mouse)
                self.refreshProfiles()
            }
        ]

        refreshProfiles()
    }

    func stop() {
        running = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        attachRetry?.cancel()
        attachRetry = nil
        attachRetries = 0
        releaseHeldButtons()
        profiles.forEach(detach)
        profiles.removeAll()
        activeProfile = nil
    }

    func updateStreamSize(width: Int32, height: Int32) {
        streamWidth = max(width, 1)
        streamHeight = max(height, 1)
    }

    func setTrackingMode(_ mode: MouseTrackingMode) {
        self.mode = mode
        resetState()
    }

    // MARK: - Profiles

    private func refreshProfiles() {
        guard running else { return }

        for mouse in GCMouse.mice() where mouse.mouseInput != nil {
            guard !profiles.contains(where: { $0 === mouse }) else { continue }
            attach(mouse)
        }

        if profiles.isEmpty {
            scheduleAttachRetry()
        } else {
            attachRetry?.cancel()
            attachRetry = nil
            attachRetries = 0
        }
    }

    private func scheduleAttachRetry() {
        guard attachRetries < 20 else { return }
        attachRetries += 1
        attachRetry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running, self.profiles.isEmpty else { return }
            self.refreshProfiles()
        }
        attachRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        profiles.append(mouse)

        input.mouseMovedHandler = { [weak self, weak mouse] _, dx, dy in
            guard let self, let mouse else { return }
            self.handleMove(from: mouse, dx: dx, dy: dy)
        }
        input.leftButton.pressedChangedHandler = { [weak self, weak mouse] _, _, pressed in
            guard let self, let mouse else { return }
            self.handleButton(from: mouse, button: .left, pressed: pressed)
        }
        input.rightButton?.pressedChangedHandler = { [weak self, weak mouse] _, _, pressed in
            guard let self, let mouse else { return }
            self.handleButton(from: mouse, button: .right, pressed: pressed)
        }
        input.middleButton?.pressedChangedHandler = { [weak self, weak mouse] _, _, pressed in
            guard let self, let mouse else { return }
            self.handleButton(from: mouse, button: .middle, pressed: pressed)
        }
        if let auxiliary = input.auxiliaryButtons {
            if auxiliary.count >= 1 {
                auxiliary[0].pressedChangedHandler = { [weak self, weak mouse] _, _, pressed in
                    guard let self, let mouse else { return }
                    self.handleButton(from: mouse, button: .back, pressed: pressed)
                }
            }
            if auxiliary.count >= 2 {
                auxiliary[1].pressedChangedHandler = { [weak self, weak mouse] _, _, pressed in
                    guard let self, let mouse else { return }
                    self.handleButton(from: mouse, button: .forward, pressed: pressed)
                }
            }
        }
        input.scroll.yAxis.valueChangedHandler = { [weak self, weak mouse] _, value in
            guard let self, let mouse else { return }
            self.handleScroll(from: mouse, vertical: value)
        }
        input.scroll.xAxis.valueChangedHandler = { [weak self, weak mouse] _, value in
            guard let self, let mouse else { return }
            self.handleScroll(from: mouse, horizontal: value)
        }
    }

    private func detach(_ mouse: GCMouse) {
        if activeProfile === mouse {
            releaseHeldButtons()
            activeProfile = nil
        }
        if let input = mouse.mouseInput {
            input.mouseMovedHandler = nil
            input.leftButton.pressedChangedHandler = nil
            input.rightButton?.pressedChangedHandler = nil
            input.middleButton?.pressedChangedHandler = nil
            input.auxiliaryButtons?.forEach { $0.pressedChangedHandler = nil }
            input.scroll.xAxis.valueChangedHandler = nil
            input.scroll.yAxis.valueChangedHandler = nil
        }
        profiles.removeAll { $0 === mouse }
    }

    private func isSource(_ mouse: GCMouse) -> Bool {
        if activeProfile == nil {
            activeProfile = mouse
        }
        return activeProfile === mouse
    }

    private func resetState() {
        moveRemainderX = 0
        moveRemainderY = 0
        cursorX = 0.5
        cursorY = 0.5
        scrollRemainderX = 0
        scrollRemainderY = 0
    }

    // MARK: - Events

    private func handleMove(from mouse: GCMouse, dx: Float, dy: Float) {
        guard running, isSource(mouse) else { return }

        // GCMouse reports +Y up; the protocol expects +Y down.
        moveRemainderX += dx / Self.deltaDivisor
        moveRemainderY -= dy / Self.deltaDivisor

        let wholeX = moveRemainderX.rounded(.towardZero)
        let wholeY = moveRemainderY.rounded(.towardZero)
        guard wholeX != 0 || wholeY != 0 else { return }
        moveRemainderX -= wholeX
        moveRemainderY -= wholeY

        switch mode {
        case .relative:
            LiSendMouseMoveEvent(
                Int16(clamping: Int32(wholeX)),
                Int16(clamping: Int32(wholeY))
            )
        case .absolute:
            cursorX = min(max(cursorX + wholeX / Float(streamWidth), 0), 1)
            cursorY = min(max(cursorY + wholeY / Float(streamHeight), 0), 1)
            LiSendMousePositionEvent(
                Int16(cursorX * Float(streamWidth)),
                Int16(cursorY * Float(streamHeight)),
                Int16(clamping: streamWidth),
                Int16(clamping: streamHeight)
            )
        }
    }

    private func handleButton(from mouse: GCMouse, button: MouseButton, pressed: Bool) {
        guard running, isSource(mouse) else { return }
        if pressed {
            heldButtons.insert(button.rawValue)
        } else {
            heldButtons.remove(button.rawValue)
        }
        LiSendMouseButtonEvent(pressed ? Action.press.rawValue : Action.release.rawValue, button.rawValue)
    }

    private func handleScroll(from mouse: GCMouse, vertical value: Float) {
        guard running, isSource(mouse) else { return }
        scrollRemainderY += value
        let notches = scrollRemainderY.rounded(.towardZero)
        guard notches != 0 else { return }
        scrollRemainderY -= notches
        LiSendHighResScrollEvent(Int16(clamping: Int32(notches) * Self.scrollStep))
    }

    private func handleScroll(from mouse: GCMouse, horizontal value: Float) {
        guard running, isSource(mouse) else { return }
        scrollRemainderX -= value
        let notches = scrollRemainderX.rounded(.towardZero)
        guard notches != 0 else { return }
        scrollRemainderX -= notches
        LiSendHighResHScrollEvent(Int16(clamping: Int32(notches) * Self.scrollStep))
    }

    private func releaseHeldButtons() {
        for button in heldButtons {
            LiSendMouseButtonEvent(Action.release.rawValue, button)
        }
        heldButtons.removeAll()
    }
}

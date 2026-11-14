import Foundation
import GameController

enum MouseTrackingMode: String, CaseIterable {
    case relative
    case absolute
}

/// Session-scoped owner of the physical mouse. Adapted from the visionOS fork's
/// GCMouse stack: handlers are installed on every GCMouse profile, the first
/// profile that emits becomes active, and remainders are carried across events.
final class MouseInputController {
    private static let speedDivisor: Float = 1.25
    /// One GCMouse scroll axis unit is one physical notch; the protocol's wheel
    /// delta is 120, matching the rest of the app.
    private static let highResScrollScale: Int32 = 120

    private let buttonLeft: Int32 = 0x01
    private let buttonMiddle: Int32 = 0x02
    private let buttonRight: Int32 = 0x03
    private let buttonX1: Int32 = 0x04
    private let buttonX2: Int32 = 0x05
    private let actionPress: Int8 = 0x07
    private let actionRelease: Int8 = 0x08

    private var trackingMode: MouseTrackingMode = .relative
    private var streamWidth: Int32 = 1920
    private var streamHeight: Int32 = 1080

    private var attachedMice: [GCMouse] = []
    private var activeMouse: GCMouse?
    private var observers: [NSObjectProtocol] = []
    private var pendingX: Float = 0
    private var pendingY: Float = 0
    private var absoluteX: Float = 0.5
    private var absoluteY: Float = 0.5
    private var pendingScrollX: Float = 0
    private var pendingScrollY: Float = 0
    private var pressedButtons: Set<Int32> = []
    private var isRunning = false
    private var attachRetryWorkItem: DispatchWorkItem?
    private var attachRetryCount = 0

    var isAttached: Bool { !attachedMice.isEmpty }
    private(set) var eventCount = 0

    var onPresenceChanged: ((Bool) -> Void)?

    func start(mode: MouseTrackingMode, streamWidth: Int32, streamHeight: Int32) {
        stop()
        trackingMode = mode
        self.streamWidth = max(streamWidth, 1)
        self.streamHeight = max(streamHeight, 1)
        resetAccumulators()
        isRunning = true

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.attachAllMice(reportPresence: true)
        })
        observers.append(center.addObserver(forName: .GCMouseDidBecomeCurrent, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.attachAllMice(reportPresence: true)
        })
        observers.append(center.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let self, self.isRunning else { return }
            guard let departing = note.object as? GCMouse else { return }
            guard self.attachedMice.contains(where: { $0 === departing }) else { return }
            self.removeMouse(departing)
            self.attachAllMice(reportPresence: true)
            if self.attachedMice.isEmpty { self.onPresenceChanged?(false) }
        })

        attachAllMice(reportPresence: true)
        let inventory = GCMouse.mice().map { "\($0.vendorName ?? "?")/\($0.mouseInput != nil ? "in" : "no")" }
        print("[MouseInput] start mice=\(GCMouse.mice().count) inputs=\(GCMouse.mice().filter { $0.mouseInput != nil }.count) attached=\(isAttached) inventory=\(inventory)")
    }

    func updateStreamSize(width: Int32, height: Int32) {
        streamWidth = max(width, 1)
        streamHeight = max(height, 1)
    }

    func setTrackingMode(_ mode: MouseTrackingMode) {
        trackingMode = mode
        resetAccumulators()
    }

    func stop() {
        isRunning = false
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        attachRetryWorkItem?.cancel()
        attachRetryWorkItem = nil
        attachRetryCount = 0
        let wasAttached = !attachedMice.isEmpty
        releaseHeldButtons()
        for mouse in attachedMice {
            removeMouse(mouse)
        }
        attachedMice.removeAll()
        activeMouse = nil
        if wasAttached { onPresenceChanged?(false) }
    }

    // MARK: - GCMouse attach/detach

    private func attachAllMice(reportPresence: Bool) {
        guard isRunning else { return }
        let mice = GCMouse.mice().filter { $0.mouseInput != nil }
        var added = false
        for mouse in mice where !attachedMice.contains(where: { $0 === mouse }) {
            attach(mouse)
            added = true
        }
        if added {
            let names = attachedMice.map { $0.vendorName ?? "?" }
            print("[MouseInput] attached \(names)")
        }
        if attachedMice.isEmpty {
            scheduleAttachRetry()
        } else {
            attachRetryWorkItem?.cancel()
            attachRetryWorkItem = nil
            attachRetryCount = 0
            if reportPresence && added { onPresenceChanged?(true) }
        }
    }

    private func scheduleAttachRetry() {
        guard attachRetryCount < 20 else { return }
        attachRetryCount += 1
        attachRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning, self.attachedMice.isEmpty else { return }
            self.attachAllMice(reportPresence: true)
        }
        attachRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        attachedMice.append(mouse)

        input.mouseMovedHandler = { [weak self, weak mouse] _, dx, dy in
            guard let self, let mouse else { return }
            self.handleMove(from: mouse, dx: dx, dy: dy)
        }
        input.leftButton.pressedChangedHandler = { [weak self, weak mouse] _, _, pressed in
            guard let self, let mouse else { return }
            self.handleButton(from: mouse, button: self.buttonLeft, pressed: pressed)
        }
        input.rightButton?.pressedChangedHandler = { [weak self, weak mouse] _, _, pressed in
            guard let self, let mouse else { return }
            self.handleButton(from: mouse, button: self.buttonRight, pressed: pressed)
        }
        input.middleButton?.pressedChangedHandler = { [weak self, weak mouse] _, _, pressed in
            guard let self, let mouse else { return }
            self.handleButton(from: mouse, button: self.buttonMiddle, pressed: pressed)
        }
        if let auxiliary = input.auxiliaryButtons {
            if auxiliary.count >= 1 {
                auxiliary[0].pressedChangedHandler = { [weak self, weak mouse] _, _, pressed in
                    guard let self, let mouse else { return }
                    self.handleButton(from: mouse, button: self.buttonX1, pressed: pressed)
                }
            }
            if auxiliary.count >= 2 {
                auxiliary[1].pressedChangedHandler = { [weak self, weak mouse] _, _, pressed in
                    guard let self, let mouse else { return }
                    self.handleButton(from: mouse, button: self.buttonX2, pressed: pressed)
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

    private func removeMouse(_ mouse: GCMouse) {
        if activeMouse === mouse {
            releaseHeldButtons()
            activeMouse = nil
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
        attachedMice.removeAll { $0 === mouse }
    }

    private func activateIfNeeded(_ mouse: GCMouse) -> Bool {
        if activeMouse == nil {
            activeMouse = mouse
            print("[MouseInput] active \(mouse.vendorName ?? "?")")
        }
        return activeMouse === mouse
    }

    private func resetAccumulators() {
        pendingX = 0
        pendingY = 0
        absoluteX = 0.5
        absoluteY = 0.5
        pendingScrollX = 0
        pendingScrollY = 0
    }

    // MARK: - Event handling

    private func handleMove(from mouse: GCMouse, dx: Float, dy: Float) {
        guard isRunning, activateIfNeeded(mouse) else { return }
        eventCount += 1
        if eventCount == 1 || eventCount % 120 == 0 {
            print("[MouseInput] move #\(eventCount) dx=\(dx) dy=\(dy) mode=\(trackingMode.rawValue) source=\(mouse.vendorName ?? "?")")
        }

        // GCMouse reports +Y up; the protocol's screen coordinates are +Y down.
        pendingX += dx / Self.speedDivisor
        pendingY += -dy / Self.speedDivisor
        let wholeX = pendingX.rounded(.towardZero)
        let wholeY = pendingY.rounded(.towardZero)
        guard wholeX != 0 || wholeY != 0 else { return }
        pendingX -= wholeX
        pendingY -= wholeY

        switch trackingMode {
        case .relative:
            LiSendMouseMoveEvent(
                Int16(clamping: Int32(wholeX)),
                Int16(clamping: Int32(wholeY))
            )
        case .absolute:
            absoluteX = min(max(absoluteX + wholeX / Float(streamWidth), 0), 1)
            absoluteY = min(max(absoluteY + wholeY / Float(streamHeight), 0), 1)
            LiSendMousePositionEvent(
                Int16(absoluteX * Float(streamWidth)),
                Int16(absoluteY * Float(streamHeight)),
                Int16(clamping: streamWidth),
                Int16(clamping: streamHeight)
            )
        }
    }

    private func handleButton(from mouse: GCMouse, button: Int32, pressed: Bool) {
        guard isRunning, activateIfNeeded(mouse) else { return }
        eventCount += 1
        if pressed {
            pressedButtons.insert(button)
        } else {
            pressedButtons.remove(button)
        }
        LiSendMouseButtonEvent(pressed ? actionPress : actionRelease, button)
    }

    private func handleScroll(from mouse: GCMouse, vertical value: Float) {
        guard isRunning, activateIfNeeded(mouse) else { return }
        eventCount += 1
        pendingScrollY += value
        let whole = pendingScrollY.rounded(.towardZero)
        guard whole != 0 else { return }
        pendingScrollY -= whole
        LiSendHighResScrollEvent(
            Int16(clamping: Int32(whole) * Self.highResScrollScale)
        )
    }

    private func handleScroll(from mouse: GCMouse, horizontal value: Float) {
        guard isRunning, activateIfNeeded(mouse) else { return }
        eventCount += 1
        pendingScrollX += -value
        let whole = pendingScrollX.rounded(.towardZero)
        guard whole != 0 else { return }
        pendingScrollX -= whole
        LiSendHighResHScrollEvent(
            Int16(clamping: Int32(whole) * Self.highResScrollScale)
        )
    }

    private func releaseHeldButtons() {
        for button in pressedButtons {
            LiSendMouseButtonEvent(actionRelease, button)
        }
        pressedButtons.removeAll()
    }
}

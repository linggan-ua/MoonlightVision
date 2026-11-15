//
//  VirtualKeyboardView.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import SwiftUI

/// On-screen PC keyboard for the stream. Shift/Ctrl/Alt/Win are sticky: tap once
/// to hold for the next key, twice to lock, a third time to release.
struct VirtualKeyboardView: View {
    let input: StreamKeyboardInput
    let isActive: Bool
    let showsGlassBackground: Bool
    let keyUnit: CGFloat

    init(
        input: StreamKeyboardInput,
        isActive: Bool = true,
        showsGlassBackground: Bool = true,
        keyUnit: CGFloat = 46
    ) {
        self.input = input
        self.isActive = isActive
        self.showsGlassBackground = showsGlassBackground
        self.keyUnit = keyUnit
    }

    @State private var latched: Set<UInt16> = []
    @State private var locked: Set<UInt16> = []
    @State private var textEntry = ""
    @State private var fnActive = false
    @State private var winLongPressHandled = false
    @State private var winLongPressResetTask: Task<Void, Never>?
    @FocusState private var textFocused: Bool

    private static let shiftLeft: UInt16 = 0xE1
    private static let fnUsage: UInt16 = 0xFFFE
    private static let spacing: CGFloat = 5

    private var unit: CGFloat { keyUnit }

    private struct Key: Identifiable {
        let usage: UInt16
        let label: String
        var shiftedLabel: String? = nil
        var width: CGFloat = 1
        var symbol: String? = nil
        /// Windows virtual-key code for media keys that don't have a HID usage.
        var virtualKey: Int16? = nil
        var id: UInt16 { usage }
    }

    private struct Shortcut: Identifiable {
        let label: String
        let modifiers: [UInt16]
        let key: UInt16?
        var id: String { label }
    }

    private let shortcuts: [Shortcut] = [
        Shortcut(label: "Alt+Tab", modifiers: [0xE2], key: 0x2B),
        Shortcut(label: "Alt+F4", modifiers: [0xE2], key: 0x3D),
        Shortcut(label: "Win", modifiers: [0xE3], key: nil),
        Shortcut(label: "Win+D", modifiers: [0xE3], key: 0x07),
        Shortcut(label: "Win+E", modifiers: [0xE3], key: 0x08),
        Shortcut(label: "Win+L", modifiers: [0xE3], key: 0x0F),
        Shortcut(label: "Ctrl+Shift+Esc", modifiers: [0xE0, 0xE1], key: 0x29),
        Shortcut(label: "Ctrl+C", modifiers: [0xE0], key: 0x06),
        Shortcut(label: "Ctrl+V", modifiers: [0xE0], key: 0x19)
    ]

    private let physicalFunctionRow: [Key] = [Key(usage: 0x29, label: "Esc", width: 1.4)]
        + (1...12).map { Key(usage: 0x3A + UInt16($0 - 1), label: "F\($0)") }
        + [Key(usage: 0x4C, label: "Del", width: 1.4)]

    /// Fn switches the function row to the Windows media keys. Fn itself is a
    /// hardware key with no HID usage, so it only changes this on-screen row.
    private let mediaRow: [Key] = [
        Key(usage: 0x2001, label: "Mute", symbol: "speaker.slash.fill", virtualKey: 0xAD),
        Key(usage: 0x2002, label: "Volume Down", symbol: "speaker.wave.1.fill", virtualKey: 0xAE),
        Key(usage: 0x2003, label: "Volume Up", symbol: "speaker.wave.3.fill", virtualKey: 0xAF),
        Key(usage: 0x2004, label: "Previous Track", symbol: "backward.fill", virtualKey: 0xB1),
        Key(usage: 0x2005, label: "Play/Pause", symbol: "playpause.fill", virtualKey: 0xB3),
        Key(usage: 0x2006, label: "Next Track", symbol: "forward.fill", virtualKey: 0xB0),
        Key(usage: 0x2007, label: "Stop", symbol: "stop.fill", virtualKey: 0xB2),
        Key(usage: 0x2C, label: "Space", width: 6.6),
        Key(usage: Self.fnUsage, label: "Fn", width: 1.2, symbol: "globe"),
    ]

    private var functionRow: [Key] {
        fnActive ? mediaRow : physicalFunctionRow
    }

    private let numberRow: [Key] = [
        Key(usage: 0x35, label: "`", shiftedLabel: "~"),
        Key(usage: 0x1E, label: "1", shiftedLabel: "!"),
        Key(usage: 0x1F, label: "2", shiftedLabel: "@"),
        Key(usage: 0x20, label: "3", shiftedLabel: "#"),
        Key(usage: 0x21, label: "4", shiftedLabel: "$"),
        Key(usage: 0x22, label: "5", shiftedLabel: "%"),
        Key(usage: 0x23, label: "6", shiftedLabel: "^"),
        Key(usage: 0x24, label: "7", shiftedLabel: "&"),
        Key(usage: 0x25, label: "8", shiftedLabel: "*"),
        Key(usage: 0x26, label: "9", shiftedLabel: "("),
        Key(usage: 0x27, label: "0", shiftedLabel: ")"),
        Key(usage: 0x2D, label: "-", shiftedLabel: "_"),
        Key(usage: 0x2E, label: "=", shiftedLabel: "+"),
        Key(usage: 0x2A, label: "Backspace", width: 1.8, symbol: "delete.left"),
    ]

    private var topRow: [Key] {
        [Key(usage: 0x2B, label: "Tab", width: 1.6)]
            + letters("qwertyuiop")
            + [
                Key(usage: 0x2F, label: "[", shiftedLabel: "{"),
                Key(usage: 0x30, label: "]", shiftedLabel: "}"),
                Key(usage: 0x31, label: "\\", shiftedLabel: "|", width: 1.2),
            ]
    }

    private var homeRow: [Key] {
        [Key(usage: 0x39, label: "Caps", width: 1.8)]
            + letters("asdfghjkl")
            + [
                Key(usage: 0x33, label: ";", shiftedLabel: ":"),
                Key(usage: 0x34, label: "'", shiftedLabel: "\""),
                Key(usage: 0x28, label: "Enter", width: 2.0, symbol: "return"),
            ]
    }

    private var bottomRow: [Key] {
        [Key(usage: Self.shiftLeft, label: "Shift", width: 1.8, symbol: "shift")]
            + letters("zxcvbnm")
            + [
                Key(usage: 0x36, label: ",", shiftedLabel: "<"),
                Key(usage: 0x37, label: ".", shiftedLabel: ">"),
                Key(usage: 0x38, label: "/", shiftedLabel: "?"),
            ]
    }

    private let spaceRow: [Key] = [
        Key(usage: 0xE0, label: "Ctrl", width: 1.5),
        Key(usage: 0xE3, label: "Win", width: 1.2, symbol: "square.grid.2x2"),
        Key(usage: 0xE2, label: "Alt", width: 1.2),
        Key(usage: 0x2C, label: "Space", width: 6.7),
        Key(usage: Self.fnUsage, label: "Fn", width: 1.2, symbol: "globe"),
    ]

    var body: some View {
        VStack(spacing: Self.spacing) {
            HStack(spacing: 8) {
                TextField("Type text…", text: $textEntry)
                    .textFieldStyle(.roundedBorder)
                    .focused($textFocused)
                    .frame(maxWidth: 460)
                    .onSubmit(sendText)
                Button("Send", action: sendText)
                    .disabled(textEntry.isEmpty)
                Menu {
                    ForEach(shortcuts) { shortcut in
                        Button(shortcut.label) {
                            input.sendShortcut(
                                modifiers: shortcut.modifiers,
                                key: shortcut.key
                            )
                        }
                    }
                } label: {
                    Label("Shortcuts", systemImage: "command")
                }
            }

            row(functionRow, height: 0.8)
            row(numberRow)
            row(topRow)
            row(homeRow)
            HStack(alignment: .top, spacing: Self.spacing) {
                VStack(spacing: Self.spacing) {
                    row(bottomRow)
                    row(spaceRow)
                }
                arrowCluster
            }
        }
        .padding(12)
        .glassBackgroundEffect(displayMode: showsGlassBackground ? .always : .never)
        .onChange(of: isActive) { _, active in
            if !active {
                textFocused = false
                fnActive = false
                releaseAll()
            }
        }
        .onDisappear(perform: releaseAll)
    }

    private var shifted: Bool {
        let active = latched.union(locked)
        return active.contains(Self.shiftLeft)
    }

    private func letters(_ string: String) -> [Key] {
        string.map { character in
            Key(
                usage: 0x04 + UInt16(character.asciiValue! - Character("a").asciiValue!),
                label: String(character),
                shiftedLabel: character.uppercased()
            )
        }
    }

    private var arrowCluster: some View {
        VStack(spacing: Self.spacing) {
            HStack(spacing: Self.spacing) {
                Color.clear.frame(width: unit, height: unit)
                keyButton(Key(usage: 0x52, label: "Up", symbol: "arrowtriangle.up.fill"), height: 1)
                Color.clear.frame(width: unit, height: unit)
            }
            HStack(spacing: Self.spacing) {
                keyButton(Key(usage: 0x50, label: "Left", symbol: "arrowtriangle.left.fill"), height: 1)
                keyButton(Key(usage: 0x51, label: "Down", symbol: "arrowtriangle.down.fill"), height: 1)
                keyButton(Key(usage: 0x4F, label: "Right", symbol: "arrowtriangle.right.fill"), height: 1)
            }
        }
    }

    private func row(_ keys: [Key], height: CGFloat = 1) -> some View {
        HStack(spacing: Self.spacing) {
            ForEach(keys) { key in
                keyButton(key, height: height)
            }
        }
    }

    @ViewBuilder
    private func keyButton(_ key: Key, height: CGFloat) -> some View {
        let modifier = modifierFlag(for: key.usage) != 0
        let isLatched = latched.contains(key.usage)
        let isLocked = locked.contains(key.usage)
        let isFn = key.usage == Self.fnUsage && fnActive
        let active = isLatched || isLocked || isFn

        if key.usage == 0xE3 {
            // Keep it a Button so visionOS still provides gaze/press feedback;
            // a simultaneous long press handles the sticky states and
            // suppresses the button's tap on release.
            Button {
                if winLongPressHandled {
                    winLongPressHandled = false
                    winLongPressResetTask?.cancel()
                    return
                }
                tapWin()
            } label: {
                keyContent(key, height: height)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.55)
                    .onEnded { _ in
                        winLongPressHandled = true
                        toggleWinSticky()
                        winLongPressResetTask?.cancel()
                        winLongPressResetTask = Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1))
                            guard !Task.isCancelled else { return }
                            winLongPressHandled = false
                        }
                    }
            )
            .accessibilityLabel(key.label)
            .accessibilityHint(
                "Tap for a normal Win press. Long-press once for the next key, twice to lock, again to release."
            )
            .accessibilityAddTraits(active ? .isSelected : [])
        } else {
            Button {
                tap(key)
            } label: {
                keyContent(key, height: height)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(key.label)
            .accessibilityHint(
                modifier
                    ? "Tap once for the next key, twice to lock, again to release."
                    : ""
            )
            .accessibilityAddTraits(modifier && active ? .isSelected : [])
        }
    }

    private func keyContent(_ key: Key, height: CGFloat) -> some View {
        let isLatched = latched.contains(key.usage)
        let isLocked = locked.contains(key.usage)
        let isFn = key.usage == Self.fnUsage && fnActive
        let background: Color = isLocked || isFn
            ? .accentColor
            : (isLatched ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.12))
        return Group {
            if let symbol = key.symbol {
                Image(systemName: isLocked && symbol == "shift" ? "capslock.fill" : symbol)
            } else {
                Text(shifted ? (key.shiftedLabel ?? key.label) : key.label)
            }
        }
        .font(key.label.count > 1 && key.symbol == nil ? .footnote : .body)
        .frame(
            width: unit * key.width + Self.spacing * (key.width - 1),
            height: unit * height
        )
        .background(background, in: .rect(cornerRadius: 9))
        .overlay(alignment: .topTrailing) {
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8, weight: .bold))
                    .padding(4)
            } else if isLatched {
                Circle()
                    .fill(.white)
                    .frame(width: 5, height: 5)
                    .padding(4)
            }
        }
        .contentShape(.rect(cornerRadius: 9))
    }

    private func tap(_ key: Key) {
        if key.usage == Self.fnUsage {
            fnActive.toggle()
            return
        }
        if key.usage == 0xE3 {
            tapWin()
            return
        }
        if modifierFlag(for: key.usage) != 0 {
            toggleModifier(key.usage)
            return
        }

        let flags = activeModifiers
        if let virtualKey = key.virtualKey {
            input.send(virtualKey: virtualKey, pressed: true, modifiers: flags)
            input.send(virtualKey: virtualKey, pressed: false, modifiers: flags)
        } else {
            input.send(hidUsage: key.usage, pressed: true, modifiers: flags)
            input.send(hidUsage: key.usage, pressed: false, modifiers: flags)
        }

        // One-shot modifiers apply to a single key.
        for modifier in latched {
            input.send(hidUsage: modifier, pressed: false, modifiers: activeModifiers)
        }
        latched.removeAll()
    }

    /// A short Win tap is a complete Win press, unless Win is already latched
    /// or locked: then the tap simply releases that sticky state.
    private func tapWin() {
        if locked.contains(0xE3) {
            locked.remove(0xE3)
            input.send(hidUsage: 0xE3, pressed: false, modifiers: activeModifiers)
            return
        }
        if latched.contains(0xE3) {
            latched.remove(0xE3)
            input.send(hidUsage: 0xE3, pressed: false, modifiers: activeModifiers)
            return
        }

        let flags = activeModifiers
        input.send(hidUsage: 0xE3, pressed: true, modifiers: flags)
        input.send(hidUsage: 0xE3, pressed: false, modifiers: flags)
        for modifier in latched {
            input.send(hidUsage: modifier, pressed: false, modifiers: activeModifiers)
        }
        latched.removeAll()
    }

    /// Long-press cycles Win through one-shot, locked, and released. Win
    /// shortcuts (Win+D, Win+E, Win+L) then use the normal key row.
    private func toggleWinSticky() {
        if locked.contains(0xE3) {
            locked.remove(0xE3)
            input.send(hidUsage: 0xE3, pressed: false, modifiers: activeModifiers)
        } else if latched.contains(0xE3) {
            latched.remove(0xE3)
            locked.insert(0xE3)
        } else {
            latched.insert(0xE3)
            input.send(hidUsage: 0xE3, pressed: true, modifiers: activeModifiers)
        }
    }

    private func toggleModifier(_ usage: UInt16) {
        if locked.contains(usage) {
            let flags = activeModifiers
            locked.remove(usage)
            input.send(hidUsage: usage, pressed: false, modifiers: flags)
        } else if latched.contains(usage) {
            latched.remove(usage)
            locked.insert(usage)
        } else {
            latched.insert(usage)
            input.send(hidUsage: usage, pressed: true, modifiers: activeModifiers)
        }
    }

    private func releaseAll() {
        let flags = activeModifiers
        for usage in latched.union(locked) {
            input.send(hidUsage: usage, pressed: false, modifiers: flags)
        }
        latched.removeAll()
        locked.removeAll()
    }

    private var activeModifiers: Int8 {
        latched.union(locked).reduce(into: Int8(0)) { flags, usage in
            flags |= modifierFlag(for: usage)
        }
    }

    private func modifierFlag(for usage: UInt16) -> Int8 {
        StreamKeyboardInput.modifierFlag(for: usage)
    }

    private func sendText() {
        guard !textEntry.isEmpty else { return }
        input.send(text: textEntry)
        textEntry = ""
        textFocused = false
    }
}

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
    let onClose: () -> Void

    init(input: StreamKeyboardInput, isActive: Bool = true, onClose: @escaping () -> Void) {
        self.input = input
        self.isActive = isActive
        self.onClose = onClose
    }

    @State private var latched: Set<UInt16> = []
    @State private var locked: Set<UInt16> = []

    private static let shiftLeft: UInt16 = 0xE1
    private static let shiftRight: UInt16 = 0xE5
    private static let unit: CGFloat = 46
    private static let spacing: CGFloat = 5

    private struct Key: Identifiable {
        let usage: UInt16
        let label: String
        var shiftedLabel: String? = nil
        var width: CGFloat = 1
        var symbol: String? = nil
        var id: UInt16 { usage }
    }

    private let functionRow: [Key] = [Key(usage: 0x29, label: "Esc", width: 1.2)]
        + (1...12).map { Key(usage: 0x3A + UInt16($0 - 1), label: "F\($0)") }
        + [Key(usage: 0x4C, label: "Del", width: 1.2)]

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
        [Key(usage: 0x2B, label: "Tab", width: 1.5)]
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
        [Key(usage: Self.shiftLeft, label: "Shift", width: 2.2, symbol: "shift")]
            + letters("zxcvbnm")
            + [
                Key(usage: 0x36, label: ",", shiftedLabel: "<"),
                Key(usage: 0x37, label: ".", shiftedLabel: ">"),
                Key(usage: 0x38, label: "/", shiftedLabel: "?"),
                Key(usage: Self.shiftRight, label: "Shift", width: 1.5, symbol: "shift"),
                Key(usage: 0x52, label: "Up", symbol: "arrowtriangle.up.fill"),
            ]
    }

    private let spaceRow: [Key] = [
        Key(usage: 0xE0, label: "Ctrl", width: 1.5),
        Key(usage: 0xE3, label: "Win", width: 1.2, symbol: "square.grid.2x2"),
        Key(usage: 0xE2, label: "Alt", width: 1.2),
        Key(usage: 0x2C, label: "Space", width: 6.0),
        Key(usage: 0x4F, label: "Left", symbol: "arrowtriangle.left.fill"),
        Key(usage: 0x50, label: "Down", symbol: "arrowtriangle.down.fill"),
        Key(usage: 0x51, label: "Right", symbol: "arrowtriangle.right.fill"),
    ]

    var body: some View {
        VStack(spacing: Self.spacing) {
            HStack {
                Text("Keyboard")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }

            row(functionRow, height: 0.8)
            row(numberRow)
            row(topRow)
            row(homeRow)
            row(bottomRow)
            row(spaceRow)
        }
        .padding(12)
        .glassBackgroundEffect()
        .onChange(of: isActive) { _, active in
            if !active {
                releaseAll()
            }
        }
        .onDisappear(perform: releaseAll)
    }

    private var shifted: Bool {
        let active = latched.union(locked)
        return active.contains(Self.shiftLeft) || active.contains(Self.shiftRight)
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

    private func row(_ keys: [Key], height: CGFloat = 1) -> some View {
        HStack(spacing: Self.spacing) {
            ForEach(keys) { key in
                keyButton(key, height: height)
            }
        }
    }

    private func keyButton(_ key: Key, height: CGFloat) -> some View {
        let modifier = modifierFlag(for: key.usage) != 0
        let active = latched.contains(key.usage) || locked.contains(key.usage)
        return Button {
            tap(key.usage)
        } label: {
            Group {
                if let symbol = key.symbol {
                    Image(systemName: locked.contains(key.usage) && symbol == "shift" ? "capslock.fill" : symbol)
                } else {
                    Text(shifted ? (key.shiftedLabel ?? key.label) : key.label)
                }
            }
            .font(key.label.count > 1 && key.symbol == nil ? .footnote : .body)
            .frame(
                width: Self.unit * key.width + Self.spacing * (key.width - 1),
                height: Self.unit * height
            )
            .background(
                active ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white.opacity(0.12)),
                in: .rect(cornerRadius: 9)
            )
            .contentShape(.hoverEffect, .rect(cornerRadius: 9))
            .hoverEffect()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(key.label)
        .accessibilityAddTraits(modifier && active ? .isSelected : [])
    }

    private func tap(_ usage: UInt16) {
        if modifierFlag(for: usage) != 0 {
            toggleModifier(usage)
            return
        }

        let flags = activeModifiers
        input.send(hidUsage: usage, pressed: true, modifiers: flags)
        input.send(hidUsage: usage, pressed: false, modifiers: flags)

        // One-shot modifiers apply to a single key.
        for modifier in latched {
            input.send(hidUsage: modifier, pressed: false, modifiers: activeModifiers)
        }
        latched.removeAll()
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
        switch usage {
        case 0xE1, 0xE5: return Int8(MODIFIER_SHIFT)
        case 0xE0, 0xE4: return Int8(MODIFIER_CTRL)
        case 0xE2, 0xE6: return Int8(MODIFIER_ALT)
        case 0xE3, 0xE7: return Int8(MODIFIER_META)
        default: return 0
        }
    }
}

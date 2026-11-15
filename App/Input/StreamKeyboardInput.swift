//
//  StreamKeyboardInput.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import Foundation

/// Sends virtual-keyboard HID usages to the host as Windows virtual-key events.
/// Hardware keyboards keep using KeyboardSupport's UIPress mapping; this type is
/// only for the on-screen keyboard.
final class StreamKeyboardInput {
    private static let keyCodes: [UInt16: Int16] = {
        var map: [UInt16: Int16] = [
            0x29: 0x1B, // Esc
            0x2A: 0x08, // Backspace
            0x2B: 0x09, // Tab
            0x2C: 0x20, // Space
            0x2D: 0xBD, // -
            0x2E: 0xBB, // =
            0x2F: 0xDB, // [
            0x30: 0xDD, // ]
            0x31: 0xDC, // backslash
            0x33: 0xBA, // ;
            0x34: 0xDE, // '
            0x35: 0xC0, // `
            0x36: 0xBC, // ,
            0x37: 0xBE, // .
            0x38: 0xBF, // /
            0x39: 0x14, // Caps Lock
            0x28: 0x0D, // Enter
            0x4C: 0x2E, // Forward Delete
            0x65: 0x5D, // Application / Menu
            0x4F: 0x27, // Right
            0x50: 0x25, // Left
            0x51: 0x28, // Down
            0x52: 0x26, // Up
            0xE0: 0xA2, // Left Ctrl
            0xE1: 0xA0, // Left Shift
            0xE2: 0xA4, // Left Alt
            0xE3: 0x5B, // Left Win
            0xE4: 0xA3, // Right Ctrl
            0xE5: 0xA1, // Right Shift
            0xE6: 0xA5, // Right Alt
            0xE7: 0x5C, // Right Win
        ]

        // A-Z: HID 0x04...0x1D -> VK 0x41...0x5A
        for index in 0..<26 {
            map[0x04 + UInt16(index)] = Int16(0x41 + index)
        }
        // 1-9 then 0
        for index in 0..<9 {
            map[0x1E + UInt16(index)] = Int16(0x31 + index)
        }
        map[0x27] = 0x30
        // F1-F12
        for index in 0..<12 {
            map[0x3A + UInt16(index)] = Int16(0x70 + index)
        }

        return map
    }()

    func send(hidUsage: UInt16, pressed: Bool, modifiers: Int8 = 0) {
        guard let keyCode = Self.keyCodes[hidUsage] else { return }
        send(virtualKey: keyCode, pressed: pressed, modifiers: modifiers)
    }

    /// Sends a Windows virtual-key code directly. Used by the Fn media row.
    func send(virtualKey: Int16, pressed: Bool, modifiers: Int8 = 0) {
        let action = pressed ? Int8(KEY_ACTION_DOWN) : Int8(KEY_ACTION_UP)
        LiSendKeyboardEvent(virtualKey, action, modifiers)
    }

    /// Sends a complete chord: modifiers down, key down/up (if any), modifiers
    /// up. Used by the on-screen shortcut menu.
    func sendShortcut(modifiers: [UInt16], key: UInt16?) {
        var flags: Int8 = 0
        for usage in modifiers {
            flags |= Self.modifierFlag(for: usage)
            send(hidUsage: usage, pressed: true, modifiers: flags)
        }
        if let key {
            send(hidUsage: key, pressed: true, modifiers: flags)
            send(hidUsage: key, pressed: false, modifiers: flags)
        }
        for usage in modifiers.reversed() {
            send(hidUsage: usage, pressed: false, modifiers: flags)
            flags &= ~Self.modifierFlag(for: usage)
        }
    }

    /// Sends arbitrary UTF-8 text through Sunshine's text-input extension. The
    /// host receives the text as committed input, not as key events.
    func send(text: String) {
        guard !text.isEmpty else { return }
        text.withCString { pointer in
            _ = LiSendUtf8TextEvent(pointer, UInt32(text.utf8.count))
        }
    }

    static func modifierFlag(for usage: UInt16) -> Int8 {
        switch usage {
        case 0xE1, 0xE5: return Int8(MODIFIER_SHIFT)
        case 0xE0, 0xE4: return Int8(MODIFIER_CTRL)
        case 0xE2, 0xE6: return Int8(MODIFIER_ALT)
        case 0xE3, 0xE7: return Int8(MODIFIER_META)
        default: return 0
        }
    }
}

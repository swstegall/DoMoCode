// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoTermIO
import Testing

@Suite("Terminal-native protocol")
struct TerminalNativeTests {
    private func text(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    @Test("The keyboard query asks for Kitty flags and the DA fallback")
    func keyboardQuery() {
        #expect(text(TerminalNativeSequence.keyboardProtocolQuery()) == "\u{1b}[>7u\u{1b}[?u\u{1b}[c")
        #expect(text(TerminalNativeSequence.keyboardProtocolQuery(flags: 0)) == "\u{1b}[>0u\u{1b}[?u\u{1b}[c")
    }

    @Test("Kitty and device-attributes responses parse without consuming ordinary CSI")
    func keyboardResponses() {
        #expect(
            TerminalNativeSequence.parseKeyboardProtocolResponse(Array("\u{1b}[?7u".utf8))
                == .kitty(flags: 7)
        )
        #expect(
            TerminalNativeSequence.parseKeyboardProtocolResponse(Array("\u{1b}[?0u".utf8))
                == .kitty(flags: 0)
        )
        #expect(
            TerminalNativeSequence.parseKeyboardProtocolResponse(Array("\u{1b}[?1;2c".utf8))
                == .deviceAttributes
        )
        #expect(TerminalNativeSequence.parseKeyboardProtocolResponse(Array("\u{1b}[1;2c".utf8)) == nil)
        #expect(TerminalNativeSequence.parseKeyboardProtocolResponse(Array("\u{1b}[?x".utf8)) == nil)
    }

    @Test("Focus reports and ambiguous Shift+Enter forms are identified")
    func focusAndShiftEnter() {
        #expect(TerminalNativeSequence.focusState(from: Array("\u{1b}[I".utf8)) == true)
        #expect(TerminalNativeSequence.focusState(from: Array("\u{1b}[O".utf8)) == false)
        #expect(TerminalNativeSequence.focusState(from: Array("\u{1b}[A".utf8)) == nil)
        #expect(TerminalNativeSequence.isAmbiguousShiftEnter(Array("\u{1b}\r".utf8)))
        #expect(TerminalNativeSequence.isAmbiguousShiftEnter([0x0a]))
        #expect(!TerminalNativeSequence.isAmbiguousShiftEnter(Array("\r".utf8)))
        #expect(text(TerminalNativeSequence.shiftEnterSequence()) == "\u{1b}[13;2u")
    }

    @Test("Presentation sequences clamp progress and strip OSC field controls")
    func presentationSequences() {
        #expect(text(TerminalNativeSequence.modifyOtherKeysSequence(enabled: true)) == "\u{1b}[>4;2m")
        #expect(text(TerminalNativeSequence.modifyOtherKeysSequence(enabled: false)) == "\u{1b}[>4;0m")
        #expect(text(TerminalNativeSequence.focusReportingSequence(enabled: true)) == "\u{1b}[?1004h")
        #expect(text(TerminalNativeSequence.progressSequence(.clear)) == "\u{1b}]9;4;0;\u{07}")
        #expect(text(TerminalNativeSequence.progressSequence(.indeterminate)) == "\u{1b}]9;4;3\u{07}")
        #expect(text(TerminalNativeSequence.progressSequence(.percent(140))) == "\u{1b}]9;4;1;100\u{07}")
        #expect(text(TerminalNativeSequence.titleSequence("a;b\n\rb")) == "\u{1b}]0;a b  b\u{07}")
        #expect(text(TerminalNativeSequence.clearTitleSequence()) == "\u{1b}]0;\u{07}")
    }

    @Test("Both notification formats terminate safely")
    func notifications() {
        #expect(
            text(TerminalNativeSequence.notificationSequence(title: "Domo", message: "Done"))
                == "\u{1b}]777;notify;Domo;Done\u{07}"
        )
        #expect(
            text(TerminalNativeSequence.notificationSequence(
                title: "Domo",
                message: "Done",
                protocol: .kittyOSC99
            )) == "\u{1b}]99;i=1:d=0;Domo\u{1b}\\\u{1b}]99;i=1:p=Done;Done\u{1b}\\"
        )
    }

    @Test("OSC 133 prompt marks have stable, data-free payloads")
    func promptMarks() {
        #expect(
            text(TerminalNativeSequence.promptMark(.promptStart))
                == "\u{1b}]133;A\u{07}"
        )
        #expect(
            text(TerminalNativeSequence.promptMark(.promptEnd))
                == "\u{1b}]133;B\u{07}"
        )
        #expect(
            text(TerminalNativeSequence.promptMark(.commandStart))
                == "\u{1b}]133;C\u{07}"
        )
        #expect(
            text(TerminalNativeSequence.promptMark(.commandEnd(exitCode: 7)))
                == "\u{1b}]133;D;7\u{07}"
        )
        #expect(
            text(TerminalNativeSequence.promptMark(.commandEnd(exitCode: nil)))
                == "\u{1b}]133;D\u{07}"
        )
    }
}

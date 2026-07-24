// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported from pi's word-navigation.test.ts. The ASCII/punctuation/path cases are
// ported verbatim (indices coincide with Character indices for these BMP inputs).
// The CJK case is adapted to this port's maximal-CJK-run boundaries (pi's ICU
// dictionary splits undelimited CJK words; see WordNavigation.swift).

import Testing
@testable import DoMoTUI

private func chars(_ s: String) -> [Character] { Array(s) }

@Suite("WordNavigation")
struct WordNavigationTests {
    // MARK: findWordBackward

    @Test("backward: hello world")
    func backHelloWorld() {
        let t = chars("hello world")
        #expect(findWordBackward(t, 11) == 6)
        #expect(findWordBackward(t, 6) == 0)
    }

    @Test("backward: foo.bar")
    func backDotted() {
        let t = chars("foo.bar")
        #expect(findWordBackward(t, 7) == 4)
        #expect(findWordBackward(t, 4) == 3)
        #expect(findWordBackward(t, 3) == 0)
    }

    @Test("backward: foo:bar")
    func backColon() {
        let t = chars("foo:bar")
        #expect(findWordBackward(t, 7) == 4)
        #expect(findWordBackward(t, 4) == 3)
        #expect(findWordBackward(t, 3) == 0)
    }

    @Test("backward: path/to/file")
    func backPath() {
        let t = chars("path/to/file")
        #expect(findWordBackward(t, 12) == 8)
        #expect(findWordBackward(t, 8) == 7)
        #expect(findWordBackward(t, 7) == 5)
        #expect(findWordBackward(t, 5) == 4)
        #expect(findWordBackward(t, 4) == 0)
    }

    @Test("backward: whitespace at boundaries")
    func backWhitespace() {
        let t = chars("  hello  ")
        #expect(findWordBackward(t, 9) == 2)
        #expect(findWordBackward(t, 2) == 0)
    }

    @Test("backward: punctuation run foo...bar")
    func backPunctRun() {
        let t = chars("foo...bar")
        #expect(findWordBackward(t, 9) == 6)
        #expect(findWordBackward(t, 6) == 3)
        #expect(findWordBackward(t, 3) == 0)
    }

    @Test("backward: cursor at 0 returns 0")
    func backZero() {
        #expect(findWordBackward(chars("hello"), 0) == 0)
    }

    // MARK: findWordForward

    @Test("forward: hello world")
    func fwdHelloWorld() {
        let t = chars("hello world")
        #expect(findWordForward(t, 0) == 5)
        #expect(findWordForward(t, 5) == 11)
    }

    @Test("forward: foo.bar")
    func fwdDotted() {
        let t = chars("foo.bar")
        #expect(findWordForward(t, 0) == 3)
        #expect(findWordForward(t, 3) == 4)
        #expect(findWordForward(t, 4) == 7)
    }

    @Test("forward: path/to/file")
    func fwdPath() {
        let t = chars("path/to/file")
        #expect(findWordForward(t, 0) == 4)
        #expect(findWordForward(t, 4) == 5)
        #expect(findWordForward(t, 5) == 7)
        #expect(findWordForward(t, 7) == 8)
        #expect(findWordForward(t, 8) == 12)
    }

    @Test("forward: whitespace at boundaries")
    func fwdWhitespace() {
        let t = chars("  hello  ")
        #expect(findWordForward(t, 0) == 7)
        #expect(findWordForward(t, 7) == 9)
    }

    @Test("forward: punctuation run foo...bar")
    func fwdPunctRun() {
        let t = chars("foo...bar")
        #expect(findWordForward(t, 0) == 3)
        #expect(findWordForward(t, 3) == 6)
        #expect(findWordForward(t, 6) == 9)
    }

    @Test("forward: cursor at end returns end")
    func fwdEnd() {
        #expect(findWordForward(chars("hello"), 5) == 5)
    }

    // MARK: CJK (adapted — maximal-CJK-run boundaries)

    @Test("CJK runs delimited by punctuation move as units")
    func cjkDelimited() {
        // 你好(0-2) ，(2-3) 世界(3-5): maximal-CJK-run groups each pair.
        let t = chars("你好，世界")
        #expect(findWordBackward(t, 5) == 3)
        #expect(findWordBackward(t, 3) == 2)
        #expect(findWordBackward(t, 2) == 0)
        #expect(findWordForward(t, 0) == 2)
        #expect(findWordForward(t, 2) == 3)
        #expect(findWordForward(t, 3) == 5)
    }

    @Test("CJK↔latin transition is a boundary")
    func cjkLatin() {
        // hello(0-5) 你好(5-7) ，(7-8) world(8-13) 世界(13-15)
        let t = chars("hello你好，world世界")
        #expect(findWordBackward(t, 15) == 13)
        #expect(findWordBackward(t, 13) == 8)
        #expect(findWordBackward(t, 8) == 7)
        #expect(findWordBackward(t, 7) == 5)
        #expect(findWordBackward(t, 5) == 0)
    }

    // MARK: Atomic markers

    @Test("atomic marker skipped as one unit")
    func atomicMarker() {
        // "hello [paste #1 +5 lines] world"; marker spans 6..<25.
        let t = chars("hello [paste #1 +5 lines] world")
        let markers = [6..<25]
        #expect(findWordBackward(t, t.count, markers: markers) == 26)
        #expect(findWordBackward(t, 26, markers: markers) == 6)
        #expect(findWordForward(t, 6, markers: markers) == 25)
    }
}

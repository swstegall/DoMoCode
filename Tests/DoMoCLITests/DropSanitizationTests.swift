// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// `InteractiveCoordinator.sanitizedForInsertion` — the ONLY scrubber on the one
// paste path that bypasses `Editor.handlePaste`.
//
// A drop is intercepted by `Editor.onPaste`, and returning `true` there swallows
// the paste whole, short-circuiting the C0/C1/DEL filter the editor would
// otherwise have applied. A refused drop puts that raw payload back into the
// document, so this function has to re-apply the filter itself. The payload is a
// filename chosen by whoever produced the file, so an unfiltered `ESC]0;…BEL`
// reaching the document would let a dragged file retitle the window — which is
// exactly why the function exists and why it is pinned here directly rather than
// only through the end-to-end drop test.
//
// The line-ending and tab folding is asserted alongside the control filter
// because it happens FIRST and is what keeps a CR-separated multi-file drop from
// collapsing into one run-on line: fold before filtering, or the CRs are simply
// deleted as C0 bytes.

@testable import DoMoCLI
import Testing

@MainActor
@Suite
struct DropSanitizationTests {

    /// ESC on its own and a full CSI sequence are stripped down to their printable
    /// tail — nothing a terminal would ACT on survives.
    @Test
    func stripsEscapeAndCSISequences() {
        #expect(InteractiveCoordinator.sanitizedForInsertion("a\u{1b}b") == "ab")
        #expect(InteractiveCoordinator.sanitizedForInsertion("a\u{1b}[31mred\u{1b}[0m") == "a[31mred[0m")
        // The OSC window-title attack a dragged filename is the vehicle for: the
        // ESC and the BEL go, so nothing remains that a terminal will execute.
        #expect(
            InteractiveCoordinator.sanitizedForInsertion("\u{1b}]0;PWNED\u{07}shot.png")
                == "]0;PWNEDshot.png"
        )
    }

    /// NUL and DEL are dropped rather than truncating or back-spacing the rest.
    @Test
    func stripsNULAndDEL() {
        #expect(InteractiveCoordinator.sanitizedForInsertion("a\u{00}b") == "ab")
        #expect(InteractiveCoordinator.sanitizedForInsertion("a\u{7f}b") == "ab")
    }

    /// The whole C1 range, 0x80–0x9F — the eight-bit spellings of the same
    /// controls, including 0x9B (CSI) and 0x9D (OSC).
    @Test
    func stripsTheC1Range() {
        for value in 0x80...0x9f {
            let scalar = Unicode.Scalar(UInt32(value))!
            let input = "a" + String(scalar) + "b"
            #expect(
                InteractiveCoordinator.sanitizedForInsertion(input) == "ab",
                "C1 U+\(String(value, radix: 16, uppercase: true)) survived"
            )
        }
        // …and the first scalar ABOVE the range is ordinary text that must not be
        // eaten with it: U+00A0 NO-BREAK SPACE is a legal character in a filename.
        #expect(InteractiveCoordinator.sanitizedForInsertion("a\u{a0}b") == "a\u{a0}b")
    }

    /// CR and CRLF both fold to a single LF, so a multi-file drop separated by
    /// either keeps exactly one line break per file rather than losing them to the
    /// control filter or doubling them.
    @Test
    func foldsCRAndCRLFToNewlines() {
        #expect(InteractiveCoordinator.sanitizedForInsertion("one\rtwo") == "one\ntwo")
        #expect(InteractiveCoordinator.sanitizedForInsertion("one\r\ntwo") == "one\ntwo")
        #expect(InteractiveCoordinator.sanitizedForInsertion("one\ntwo") == "one\ntwo")
        #expect(InteractiveCoordinator.sanitizedForInsertion("a\r\n\r\nb") == "a\n\nb")
    }

    /// Tabs become four spaces — the document is a plain text buffer whose renderer
    /// has no tab stops, so a literal tab would render as a single cell and lose the
    /// alignment it was meant to carry.
    @Test
    func expandsTabsToSpaces() {
        #expect(InteractiveCoordinator.sanitizedForInsertion("a\tb") == "a    b")
        #expect(InteractiveCoordinator.sanitizedForInsertion("\t") == "    ")
    }

    /// Ordinary text — including a real dropped path with spaces and non-ASCII — is
    /// returned byte-for-byte. A scrubber that ate legitimate characters would be a
    /// worse bug than the one it prevents.
    @Test
    func leavesOrdinaryTextAlone() {
        #expect(
            InteractiveCoordinator.sanitizedForInsertion("/Users/me/Desktop/my shot.png")
                == "/Users/me/Desktop/my shot.png"
        )
        #expect(InteractiveCoordinator.sanitizedForInsertion("café ☕️.png") == "café ☕️.png")
        #expect(InteractiveCoordinator.sanitizedForInsertion("") == "")
    }
}

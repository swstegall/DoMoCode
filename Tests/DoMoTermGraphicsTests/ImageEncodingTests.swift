// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

// The Kitty and iTerm2 encoders, asserted byte-exactly against pi's output, plus
// image-line detection and header parsing.

import DoMoTermGraphics
import Foundation
import Testing

@Suite("Image encoding")
struct ImageEncodingTests {
    private let esc = "\u{1b}"

    @Test("A single-chunk Kitty escape has the exact param order and ST terminator")
    func kittySingleChunk() {
        let sequence = encodeKitty("QUJD", columns: 10, rows: 5, imageId: 42, moveCursor: false)
        #expect(sequence == "\(esc)_Ga=T,f=100,q=2,C=1,c=10,r=5,i=42;QUJD\(esc)\\")
    }

    @Test("Kitty omits C=1 when the cursor should move, and c/r/i when unset")
    func kittyOptionalParams() {
        #expect(encodeKitty("QUJD", moveCursor: true) == "\(esc)_Ga=T,f=100,q=2;QUJD\(esc)\\")
        #expect(encodeKitty("QUJD", columns: 3) == "\(esc)_Ga=T,f=100,q=2,c=3;QUJD\(esc)\\")
    }

    @Test("A large Kitty payload splits into m=1 chunks ending in m=0")
    func kittyChunked() {
        let payload = String(repeating: "A", count: 5000)   // > 4096 -> 2 chunks
        let sequence = encodeKitty(payload, columns: 8, rows: 4, imageId: 7, moveCursor: false)
        // Two envelopes.
        let envelopes = sequence.components(separatedBy: "\(esc)_G")
        #expect(envelopes.count == 3)   // leading "" + 2 chunks
        // First chunk carries full params + m=1.
        #expect(sequence.hasPrefix("\(esc)_Ga=T,f=100,q=2,C=1,c=8,r=4,i=7,m=1;"))
        // Final chunk is m=0.
        #expect(sequence.contains("\(esc)_Gm=0;"))
        #expect(sequence.hasSuffix("\(esc)\\"))
        // The full payload survives chunking: the uppercase 'A' payload appears
        // nowhere in the headers (params use lowercase a=T), so counting them
        // recovers the original 5000 chars.
        #expect(sequence.filter { $0 == "A" }.count == 5000)
    }

    @Test("Non-positive c/r/i are omitted (pi parity; c=0 is invalid Kitty)")
    func kittyOmitsZero() {
        #expect(encodeKitty("QUJD", columns: 0, rows: 0, imageId: 0, moveCursor: false)
            == "\(esc)_Ga=T,f=100,q=2,C=1;QUJD\(esc)\\")
    }

    @Test("An empty iTerm2 name is omitted")
    func iterm2OmitsEmptyName() {
        #expect(!encodeITerm2("QUJD", name: "").contains("name="))
    }

    @Test("Kitty delete sequences use uppercase I/A to free data")
    func kittyDelete() {
        #expect(deleteKittyImage(42) == "\(esc)_Ga=d,d=I,i=42,q=2\(esc)\\")
        #expect(deleteAllKittyImages() == "\(esc)_Ga=d,d=A,q=2\(esc)\\")
    }

    @Test("allocateImageId returns a positive 32-bit id")
    func allocateId() {
        for _ in 0..<100 {
            let id = allocateImageId()
            #expect(id >= 1 && id <= UInt32.max)
        }
    }

    @Test("An iTerm2 escape uses inline=1, semicolon params, and a BEL terminator")
    func iterm2Basic() {
        let sequence = encodeITerm2("QUJD", width: "10", height: "auto", preserveAspectRatio: true)
        #expect(sequence == "\(esc)]1337;File=inline=1;width=10;height=auto:QUJD\u{07}")
    }

    @Test("iTerm2 emits preserveAspectRatio=0 only when false, and base64s the name")
    func iterm2Options() {
        #expect(encodeITerm2("QUJD", preserveAspectRatio: false).contains(";preserveAspectRatio=0:"))
        #expect(encodeITerm2("QUJD", name: "a").contains(";name=YQ==:"))     // base64("a") == "YQ=="
        #expect(encodeITerm2("QUJD", name: "ab").contains(";name=YWI=:"))    // base64("ab") == "YWI="
    }

    @Test("isImageLine detects Kitty and iTerm2 escapes at the start or embedded")
    func imageLineDetection() {
        #expect(isImageLine("\(esc)_Ga=T;QUJD\(esc)\\"))
        #expect(isImageLine("\(esc)]1337;File=inline=1:QUJD\u{07}"))
        #expect(isImageLine("\(esc)[1A\(esc)_Ga=T;QUJD\(esc)\\"))   // cursor-motion prefix
        #expect(!isImageLine("just some text"))
        #expect(!isImageLine("\(esc)[0m styled text \(esc)[0m"))
    }

    @Test("parseKittyImageHeader extracts the id and row count")
    func headerParsing() {
        let header = parseKittyImageHeader("\(esc)_Ga=T,f=100,q=2,c=10,r=5,i=42;QUJD\(esc)\\")
        #expect(header?.imageId == 42)
        #expect(header?.rows == 5)
        // No Kitty header -> nil.
        #expect(parseKittyImageHeader("plain") == nil)
        #expect(parseKittyImageHeader("\(esc)]1337;File=inline=1:x\u{07}") == nil)
        // A header without i/r still parses to a (nil, nil) tuple.
        let bare = parseKittyImageHeader("\(esc)_Ga=T,f=100;QUJD\(esc)\\")
        #expect(bare?.imageId == nil && bare?.rows == nil)
    }
}

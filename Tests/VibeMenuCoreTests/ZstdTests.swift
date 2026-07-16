import Foundation
import Testing
@testable import VibeMenuCore

// Tests for the vendored Zstandard decompressor wrapper (Sources/CZstd + Zstd.swift,
// docs/decisions/0016-claude-usage-limits.md). All fixtures are synthetic zstd frames generated
// offline (Node's built-in `zlib.zstdCompressSync`) and pasted as base64 — the tests decode committed
// bytes with the vendored decoder, so they need no zstd tooling at test time. This is exactly the code
// path that decodes Claude Desktop's real cache body; proving it here means the decoder works before
// any cache plumbing is involved.

private func b64(_ string: String) -> Data { Data(base64Encoded: string)! }

@Suite("Zstd decompressor")
struct ZstdTests {
    // zstd of `{"hello":"world","n":42}`
    private let simpleFrame = "KLUv/SAYwQAAeyJoZWxsbyI6IndvcmxkIiwibiI6NDJ9"

    @Test func decompressesAValidFrame() {
        let out = Zstd.decompressFrame(b64(simpleFrame))
        #expect(out != nil)
        #expect(String(decoding: out!, as: UTF8.self) == #"{"hello":"world","n":42}"#)
    }

    @Test func rejectsGarbageAndEmpty() {
        #expect(Zstd.decompressFrame(Data()) == nil)
        #expect(Zstd.decompressFrame(Data("not a zstd frame at all".utf8)) == nil)
        // Valid magic but truncated/garbage body → nil, never a crash.
        #expect(Zstd.decompressFrame(Data([0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x01, 0x02])) == nil)
    }

    @Test func ignoresTrailingBytesAfterFrame() {
        // Chromium appends its own metadata + EOF records after the frame; the streaming decoder must
        // stop at the frame boundary and ignore the rest.
        var withTrailer = b64(simpleFrame)
        withTrailer.append(Data("HTTP/1.1 200 OK\r\ncontent-encoding:zstd\r\n\u{0}\u{0}JUNK".utf8))
        let out = Zstd.decompressFrame(withTrailer)
        #expect(out != nil)
        #expect(String(decoding: out!, as: UTF8.self) == #"{"hello":"world","n":42}"#)
    }

    @Test func capsDecompressedOutputAgainstBombs() {
        // 200 KB of 0x41 that compresses to ~30 bytes: decodes fine with a generous cap...
        let bomb = b64("KLUv/aBADQMAVAAAEEFBAQD7/znAAgNqCEE=")
        #expect(Zstd.decompressFrame(bomb, maxOutputBytes: 1_000_000)?.count == 200_000)
        // ...but a small cap refuses it rather than allocating 200 KB.
        #expect(Zstd.decompressFrame(bomb, maxOutputBytes: 4_096) == nil)
    }

    @Test func scanningFindsFramePrecededByJunk() {
        // A cache entry never starts with the frame; the scanner must skip the header/key bytes.
        var entry = Data("\u{FC}...simple-cache-header + /api/organizations/x/usage key...".utf8)
        let frameOffset = entry.count
        entry.append(b64(simpleFrame))
        entry.append(Data("trailing".utf8))
        let out = Zstd.decompressFirstFrame(scanning: entry)
        #expect(out != nil)
        #expect(String(decoding: out!, as: UTF8.self) == #"{"hello":"world","n":42}"#)
        // Sanity: the magic really was not at offset 0.
        #expect(frameOffset > 0)
    }

    @Test func scanningReturnsNilWhenNoFrame() {
        #expect(Zstd.decompressFirstFrame(scanning: Data("no frames here, just text".utf8)) == nil)
    }

    @Test func scanningIsSafeOnSliceWithNonZeroStartIndex() {
        // A Data slice carries a non-zero startIndex; the scanner must index via the raw buffer, not
        // the Data's own index space, or it would trap. (Regression for the review's slice finding.)
        var full = Data("garbage-prefix-".utf8)
        full.append(b64(simpleFrame))
        let slice = full[6...]   // startIndex = 6
        let out = Zstd.decompressFirstFrame(scanning: slice)
        #expect(out != nil)
        #expect(String(decoding: out!, as: UTF8.self) == #"{"hello":"world","n":42}"#)
    }
}

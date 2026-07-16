import Foundation
import CZstd

// Thin, safe Swift wrapper over the vendored decompression-only Zstandard
// (docs/decisions/0016-claude-usage-limits.md, Sources/CZstd). Its single job is to decode the
// zstd-compressed body of the Claude Desktop usage-cache entry; nothing else in VibeMenu uses it.
//
// Safety posture (this is the only C we call):
//   * Decode only — the vendored amalgamation contains no compressor.
//   * Streaming API (`ZSTD_decompressStream`) so a single frame decodes cleanly even when the cache
//     file has trailing bytes after the frame (Chromium appends its own metadata + EOF records);
//     the decoder stops at the frame boundary and we ignore the rest.
//   * Hard output cap (`maxOutputBytes`) so a corrupt or hostile frame can never balloon memory
//     (a "zip bomb"). The real usage JSON is a few KB; the default cap is generous but bounded.
//   * Every failure path returns `nil` — never a crash, never a partial-but-claimed-complete result.
public enum Zstd {
    /// The zstd frame magic (`0xFD2FB528`, little-endian on disk). Public so the cache reader can
    /// locate candidate frames inside a Chromium cache entry.
    public static let frameMagic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    /// Generous but bounded cap on decompressed output (8 MiB). The usage payload is a few KB; this
    /// only exists to stop a malformed/hostile frame from exhausting memory.
    public static let defaultMaxOutputBytes = 8 * 1024 * 1024

    /// Decompress the **first** complete zstd frame at the start of `src`, ignoring any bytes after
    /// the frame. Returns `nil` if `src` does not begin with a valid frame, the frame is truncated,
    /// a decode error occurs, or the output would exceed `maxOutputBytes`.
    public static func decompressFrame(
        _ src: Data,
        maxOutputBytes: Int = defaultMaxOutputBytes
    ) -> Data? {
        guard !src.isEmpty else { return nil }
        guard let dctx = ZSTD_createDCtx() else { return nil }
        defer { ZSTD_freeDCtx(dctx) }

        let chunkSize = 128 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var result = Data()

        return src.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Data? in
            guard let srcBase = srcRaw.baseAddress, srcRaw.count > 0 else { return nil }
            var input = ZSTD_inBuffer(src: srcBase, size: srcRaw.count, pos: 0)

            while true {
                let ret: size_t = chunk.withUnsafeMutableBytes { dstRaw -> size_t in
                    var output = ZSTD_outBuffer(dst: dstRaw.baseAddress, size: dstRaw.count, pos: 0)
                    let r = ZSTD_decompressStream(dctx, &output, &input)
                    // Copy freshly produced bytes out of the scratch chunk immediately. Copying from
                    // the raw pointer (not re-indexing `chunk`) avoids an overlapping-access violation.
                    if ZSTD_isError(r) == 0, output.pos > 0, let base = dstRaw.baseAddress {
                        result.append(base.assumingMemoryBound(to: UInt8.self), count: output.pos)
                    }
                    return r
                }

                if ZSTD_isError(ret) != 0 { return nil }
                if result.count > maxOutputBytes { return nil }   // bomb guard
                if ret == 0 { return result }                     // frame fully decoded
                if input.pos >= input.size { return nil }         // needs more input but none left
            }
        }
    }

    /// Scan `data` for zstd frame magic and return the first frame that decodes successfully. Used by
    /// the Desktop cache reader because a Chromium cache entry wraps the compressed body in its own
    /// header/key/metadata, so the frame does not start at byte 0. False-positive magic matches inside
    /// the metadata simply fail to decode and are skipped. Scans at most `maxFrames` candidates.
    public static func decompressFirstFrame(
        scanning data: Data,
        from startOffset: Int = 0,
        maxOutputBytes: Int = defaultMaxOutputBytes,
        maxFrames: Int = 8
    ) -> Data? {
        let magic = frameMagic
        let count = data.count
        guard count >= 4, startOffset >= 0, startOffset < count else { return nil }

        var searchFrom = startOffset
        var framesTried = 0
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            while searchFrom <= count - 4, framesTried < maxFrames {
                // Find the next magic occurrence.
                var idx = -1
                var i = searchFrom
                while i <= count - 4 {
                    if base[i] == magic[0], base[i + 1] == magic[1],
                       base[i + 2] == magic[2], base[i + 3] == magic[3] {
                        idx = i
                        break
                    }
                    i += 1
                }
                guard idx >= 0 else { return nil }
                searchFrom = idx + 4
                framesTried += 1
                // Build the frame from the 0-based raw pointer (NOT `data.subdata(in:)`, whose range is
                // in the Data's own index space and would trap for a slice with a non-zero startIndex).
                let frame = Data(bytes: base + idx, count: count - idx)
                if let decoded = decompressFrame(frame, maxOutputBytes: maxOutputBytes) {
                    return decoded
                }
            }
            return nil
        }
    }
}

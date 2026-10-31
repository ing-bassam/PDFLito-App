import Foundation
import Compression

/// zlib streams (RFC 1950) for the PDF FlateDecode filter.
enum Zlib {
    /// Apple's encoder writes raw DEFLATE, so the zlib header and Adler-32 trailer are added here.
    static func compress(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        let capacity = input.count + input.count / 8 + 1024
        var deflated = Data(count: capacity)
        let written = deflated.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let targetBase = target.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(targetBase, capacity, sourceBase, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        deflated.count = written

        var output = Data([0x78, 0x9C])
        output.append(deflated)
        let checksum = adler32(input)
        output.append(contentsOf: [UInt8(truncatingIfNeeded: checksum >> 24),
                                   UInt8(truncatingIfNeeded: checksum >> 16),
                                   UInt8(truncatingIfNeeded: checksum >> 8),
                                   UInt8(truncatingIfNeeded: checksum)])
        return output
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var index = 0
            let count = bytes.count
            while index < count {
                let end = min(index + 5552, count)
                while index < end {
                    a &+= UInt32(bytes[index])
                    b &+= a
                    index += 1
                }
                a %= 65521
                b %= 65521
            }
        }
        return (b << 16) | a
    }
}

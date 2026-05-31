import Foundation
import LabanCore
import XCTest

final class OSC52ClipboardTests: XCTestCase {
  func testDecodeWriteDecodesStandardBase64() {
    // base64("hello") == "aGVsbG8="
    let data = OSC52Clipboard.decodeWrite(base64: Array("aGVsbG8=".utf8))
    XCTAssertEqual(data, Data("hello".utf8))
  }

  func testDecodeWriteRoundTripsArbitraryBytes() {
    let original = Data((0..<256).map { UInt8($0) })
    let base64 = Array(original.base64EncodedString().utf8)
    XCTAssertEqual(OSC52Clipboard.decodeWrite(base64: base64), original)
  }

  func testDecodeWriteRejectsEmptyInput() {
    XCTAssertNil(OSC52Clipboard.decodeWrite(base64: []))
  }

  func testDecodeWriteRejectsInvalidBase64() {
    // '!' is not a base64 character and there is no padding to recover.
    XCTAssertNil(OSC52Clipboard.decodeWrite(base64: Array("not base64 !!".utf8)))
  }

  func testDecodeWriteToleratesWrappedWhitespace() {
    // Some emitters fold long base64; the decoder ignores stray whitespace.
    let wrapped = "aGVs\nbG8=\n"
    XCTAssertEqual(
      OSC52Clipboard.decodeWrite(base64: Array(wrapped.utf8)), Data("hello".utf8))
  }

  func testDecodeWriteRejectsOversizedPayload() {
    // A decoded payload past maxDecodedBytes is rejected so a remote write
    // cannot push an unbounded blob onto the host clipboard.
    let big = Data(repeating: 0x41, count: OSC52Clipboard.maxDecodedBytes + 1)
    let base64 = Array(big.base64EncodedString().utf8)
    XCTAssertNil(OSC52Clipboard.decodeWrite(base64: base64))
  }

  func testDecodeWriteAcceptsPayloadAtTheCap() {
    let atCap = Data(repeating: 0x42, count: OSC52Clipboard.maxDecodedBytes)
    let base64 = Array(atCap.base64EncodedString().utf8)
    XCTAssertEqual(OSC52Clipboard.decodeWrite(base64: base64), atCap)
  }

  func testEncodeReadProducesStandardBase64() {
    XCTAssertEqual(OSC52Clipboard.encodeRead(Data("world".utf8)), "d29ybGQ=")
  }

  func testEncodeReadOfEmptyClipboardIsEmptyString() {
    XCTAssertEqual(OSC52Clipboard.encodeRead(Data()), "")
  }
}

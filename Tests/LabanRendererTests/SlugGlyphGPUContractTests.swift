import XCTest
@testable import LabanRenderer

final class SlugGlyphGPUContractTests: XCTestCase {
  func testOrdinaryInstanceStrideIs64() {
    XCTAssertEqual(MemoryLayout<SlugGlyphGPUInstance>.stride, 64)
    XCTAssertEqual(MemoryLayout<SlugGlyphGPUInstance>.size, 64)
    XCTAssertEqual(MemoryLayout<SlugGlyphGPUInstance>.alignment, 16)
  }

  func testMotionInstanceStrideIs96() {
    XCTAssertEqual(MemoryLayout<SlugGlyphMotionGPUInstance>.stride, 96)
    XCTAssertEqual(MemoryLayout<SlugGlyphMotionGPUInstance>.size, 96)
    XCTAssertEqual(MemoryLayout<SlugGlyphMotionGPUInstance>.alignment, 16)
  }

  func testOrdinaryInstanceOffsetsMatchMetalMirror() {
    XCTAssertEqual(MemoryLayout<SlugGlyphGPUInstance>.offset(of: \.originPx), 0)
    XCTAssertEqual(MemoryLayout<SlugGlyphGPUInstance>.offset(of: \.sizePx), 8)
    XCTAssertEqual(MemoryLayout<SlugGlyphGPUInstance>.offset(of: \.localMin), 16)
    XCTAssertEqual(MemoryLayout<SlugGlyphGPUInstance>.offset(of: \.localMax), 24)
    XCTAssertEqual(MemoryLayout<SlugGlyphGPUInstance>.offset(of: \.color), 32)
    XCTAssertEqual(MemoryLayout<SlugGlyphGPUInstance>.offset(of: \.glyphIndex), 48)
    XCTAssertEqual(MemoryLayout<SlugGlyphGPUInstance>.offset(of: \.dilation), 52)
    XCTAssertEqual(MemoryLayout<SlugGlyphGPUInstance>.offset(of: \.effectKind), 56)
    XCTAssertEqual(MemoryLayout<SlugGlyphGPUInstance>.offset(of: \.effectStart), 60)
  }

  func testMotionInstanceOffsetsMatchMetalMirror() {
    XCTAssertEqual(MemoryLayout<SlugGlyphMotionGPUInstance>.offset(of: \.originPx), 0)
    XCTAssertEqual(MemoryLayout<SlugGlyphMotionGPUInstance>.offset(of: \.sizePx), 8)
    XCTAssertEqual(MemoryLayout<SlugGlyphMotionGPUInstance>.offset(of: \.localMin), 16)
    XCTAssertEqual(MemoryLayout<SlugGlyphMotionGPUInstance>.offset(of: \.localMax), 24)
    XCTAssertEqual(MemoryLayout<SlugGlyphMotionGPUInstance>.offset(of: \.color), 32)
    XCTAssertEqual(MemoryLayout<SlugGlyphMotionGPUInstance>.offset(of: \.glyphIndex), 48)
    XCTAssertEqual(MemoryLayout<SlugGlyphMotionGPUInstance>.offset(of: \.dilation), 52)
    XCTAssertEqual(MemoryLayout<SlugGlyphMotionGPUInstance>.offset(of: \.effectKind), 56)
    XCTAssertEqual(MemoryLayout<SlugGlyphMotionGPUInstance>.offset(of: \.effectStart), 60)
    XCTAssertEqual(MemoryLayout<SlugGlyphMotionGPUInstance>.offset(of: \.duration), 64)
    XCTAssertEqual(MemoryLayout<SlugGlyphMotionGPUInstance>.offset(of: \.startColor), 80)
  }

  func testEffectKindConstantsArePinned() {
    XCTAssertEqual(SlugGlyphRenderer.glyphEffectKindNone, 0)
    XCTAssertEqual(SlugGlyphRenderer.glyphEffectKindInkBloom, 1)
    XCTAssertEqual(SlugGlyphRenderer.glyphEffectKindBellShake, 2)
    XCTAssertEqual(SlugGlyphRenderer.glyphEffectKindSpinnerForegroundMotion, 3)
  }
}

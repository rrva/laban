import Foundation
import XCTest

@testable import LabanRenderer

final class CJKFontSettingsTests: XCTestCase {
  private var defaults: UserDefaults!
  private let suiteName = "laban-cjk-font-settings-tests-\(getpid())"

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  func testDefaultPreferenceIsPingFangSC() {
    XCTAssertEqual(CJKFontSettings.current(defaults: defaults), .pingFangSC)
  }

  func testGarbageValueFallsBackToPingFangSC() {
    defaults.set("Hanzi Sans", forKey: CJKFontSettings.defaultsKey)
    XCTAssertEqual(CJKFontSettings.current(defaults: defaults), .pingFangSC)
  }

  func testSetPersistsRawValue() {
    CJKFontSettings.set(.sarasaTermSC, defaults: defaults)
    XCTAssertEqual(
      defaults.string(forKey: CJKFontSettings.defaultsKey),
      CJKFontPreference.sarasaTermSC.rawValue)
    XCTAssertEqual(CJKFontSettings.current(defaults: defaults), .sarasaTermSC)
  }

  func testSetFiresChangeNotification() {
    let exp = expectation(
      forNotification: CJKFontSettings.didChangeNotification,
      object: nil,
      handler: nil)
    CJKFontSettings.set(.notoSansMonoCJKSC, defaults: defaults)
    wait(for: [exp], timeout: 1.0)
  }

  func testSetCustomPersistsPostScriptName() {
    CJKFontSettings.setCustom(postScriptName: "SourceHanSansSC-Regular", defaults: defaults)
    XCTAssertEqual(CJKFontSettings.current(defaults: defaults), .custom)
    XCTAssertEqual(
      defaults.string(forKey: CJKFontSettings.customPostScriptNameKey),
      "SourceHanSansSC-Regular")
  }

  func testSetPresetClearsCustomPostScriptName() {
    CJKFontSettings.setCustom(postScriptName: "SourceHanSansSC-Regular", defaults: defaults)
    CJKFontSettings.set(.pingFangSC, defaults: defaults)
    XCTAssertNil(defaults.string(forKey: CJKFontSettings.customPostScriptNameKey))
  }
}

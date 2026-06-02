import XCTest

@testable import LabanApp

final class TerminalGitLookupTests: XCTestCase {
  func testCommitHashCandidateShapes() {
    XCTAssertTrue(TerminalGitLookup.isCommitHashCandidate("a1b2c3d"))  // 7 (abbrev)
    XCTAssertTrue(TerminalGitLookup.isCommitHashCandidate(String(repeating: "0", count: 40)))
    XCTAssertFalse(TerminalGitLookup.isCommitHashCandidate("a1b2c3"))  // 6, too short
    XCTAssertFalse(TerminalGitLookup.isCommitHashCandidate("feature/login"))  // not hex
    XCTAssertFalse(TerminalGitLookup.isCommitHashCandidate("ZZZZZZZ"))  // not hex
    XCTAssertFalse(TerminalGitLookup.isCommitHashCandidate("A1B2C3D"))  // uppercase
  }

  /// A confirmed commit renders `git show` to a temp file.
  func testResolvesConfirmedCommitToPreviewFile() throws {
    var seenArgs: [[String]] = []
    let url = TerminalGitLookup.commitPreviewURL(
      for: "deadbee", workingDirectory: "/repo",
      runGit: { args, cwd in
        seenArgs.append(args)
        XCTAssertEqual(cwd, "/repo")
        switch args.first {
        case "cat-file": return (0, "commit\n")
        case "show": return (0, "commit deadbee\n diff --git a b\n+added\n")
        default: return (1, "")
        }
      },
      writeTempFile: { name, contents in
        XCTAssertEqual(name, "commit-deadbee.diff")
        XCTAssertTrue(contents.contains("+added"))
        return URL(filePath: "/tmp/\(name)")
      })
    XCTAssertEqual(url?.lastPathComponent, "commit-deadbee.diff")
    // Validated as a commit before showing it.
    XCTAssertEqual(seenArgs.first?.first, "cat-file")
  }

  /// Hex that git says is not a commit (a tree/blob, or unknown) falls through.
  func testNonCommitObjectIsNil() {
    let url = TerminalGitLookup.commitPreviewURL(
      for: "abc1234", workingDirectory: "/repo",
      runGit: { args, _ in
        args.first == "cat-file" ? (0, "tree\n") : (0, "should not be reached")
      },
      writeTempFile: { _, _ in XCTFail("should not write when not a commit"); return nil })
    XCTAssertNil(url)
  }

  func testUnknownObjectIsNil() {
    let url = TerminalGitLookup.commitPreviewURL(
      for: "abc1234", workingDirectory: "/repo",
      runGit: { _, _ in (128, "") },  // git error: not a valid object
      writeTempFile: { _, _ in XCTFail("should not write on git failure"); return nil })
    XCTAssertNil(url)
  }

  func testNonCandidateSkipsGitEntirely() {
    let url = TerminalGitLookup.commitPreviewURL(
      for: "feature/login", workingDirectory: "/repo",
      runGit: { _, _ in XCTFail("git must not run for a non-candidate"); return nil },
      writeTempFile: { _, _ in nil })
    XCTAssertNil(url)
  }

  func testMissingWorkingDirectoryIsNil() {
    let url = TerminalGitLookup.commitPreviewURL(
      for: "deadbee", workingDirectory: nil,
      runGit: { _, _ in XCTFail("git needs a cwd"); return nil },
      writeTempFile: { _, _ in nil })
    XCTAssertNil(url)
  }
}

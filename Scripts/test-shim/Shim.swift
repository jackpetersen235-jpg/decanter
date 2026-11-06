import Foundation
// A minimal XCTest stand-in, so the pure-logic tests run on a Mac with only the Command Line Tools
// (or with Xcode's license not yet accepted), where `swift test` can't load XCTest at all.
// Used by run-tests.sh in this folder. Covers the XCTest API Decanter's tests actually use.
var shimFailures = 0
var shimCurrent = ""
func shimFail(_ msg: String, _ file: StaticString, _ line: UInt) {
    shimFailures += 1; print("  FAIL \(shimCurrent) \(file):\(line): \(msg)")
}
struct XCTSkip: Error { init(_ m: String = "") {} }
class XCTestCase {
    required init() {}
    private var teardowns: [() throws -> Void] = []
    func setUp() {}
    func tearDown() {}
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
    func addTeardownBlock(_ b: @escaping () throws -> Void) { teardowns.append(b) }
    func shimRun(_ name: String, _ body: () throws -> Void) {
        shimCurrent = "\(type(of: self)).\(name)"; let before = shimFailures
        do { try setUpWithError(); setUp(); try body() } catch is XCTSkip { print("  skip \(shimCurrent)") }
        catch { shimFail("threw \(error)", #file, #line) }
        for t in teardowns.reversed() { try? t() }; teardowns = []
        tearDown(); try? tearDownWithError()
        if shimFailures == before { print("  ok   \(shimCurrent)") }
    }
}
func XCTFail(_ m: String = "", file: StaticString = #file, line: UInt = #line) { shimFail(m, file, line) }
func XCTAssert(_ e: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    if (try? e()) != true { shimFail("XCTAssert \(m())", file, line) } }
func XCTAssertTrue(_ e: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    if (try? e()) != true { shimFail("XCTAssertTrue \(m())", file, line) } }
func XCTAssertFalse(_ e: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    if (try? e()) != false { shimFail("XCTAssertFalse \(m())", file, line) } }
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    do { let x = try a(), y = try b(); if x != y { shimFail("(\(x)) != (\(y)) \(m())", file, line) } } catch { shimFail("threw \(error)", file, line) } }
func XCTAssertEqual<T: FloatingPoint>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, accuracy: T, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    do { let x = try a(), y = try b(); if abs(x - y) > accuracy { shimFail("(\(x)) !≈ (\(y)) ±\(accuracy) \(m())", file, line) } } catch { shimFail("threw \(error)", file, line) } }
func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    do { let x = try a(), y = try b(); if x == y { shimFail("(\(x)) == (\(y)) \(m())", file, line) } } catch { shimFail("threw \(error)", file, line) } }
func XCTAssertNil(_ e: @autoclosure () throws -> Any?, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    if let v = try? e() { shimFail("not nil: \(v) \(m())", file, line) } }
func XCTAssertNotNil(_ e: @autoclosure () throws -> Any?, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    if (try? e()) == nil { shimFail("nil \(m())", file, line) } }
func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    if let x = try? a(), let y = try? b(), !(x > y) { shimFail("\(x) <= \(y) \(m())", file, line) } }
func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    if let x = try? a(), let y = try? b(), !(x < y) { shimFail("\(x) >= \(y) \(m())", file, line) } }
func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    if let x = try? a(), let y = try? b(), !(x >= y) { shimFail("\(x) < \(y) \(m())", file, line) } }
func XCTAssertLessThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    if let x = try? a(), let y = try? b(), !(x <= y) { shimFail("\(x) > \(y) \(m())", file, line) } }
func XCTUnwrap<T>(_ e: @autoclosure () throws -> T?, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) throws -> T {
    guard let v = try e() else { shimFail("XCTUnwrap nil \(m())", file, line); throw XCTSkip() }; return v }
func XCTAssertThrowsError<T>(_ e: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line, _ h: (Error) -> Void = { _ in }) {
    do { _ = try e(); shimFail("did not throw \(m())", file, line) } catch { h(error) } }
func XCTAssertNoThrow<T>(_ e: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) {
    do { _ = try e() } catch { shimFail("threw \(error) \(m())", file, line) } }

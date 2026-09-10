import Foundation
import MaiCore
import XCTest

final class JSONIntegerTests: XCTestCase {
  func testIntegerAccessRejectsOutOfRangeAndNonintegralDoubles() throws {
    for number in [Double.infinity, -.infinity, .nan, 1e100, -1e100, Double(Int.max), 1.5] {
      XCTAssertNil(JSONValue.number(number).intValue)
    }
    XCTAssertEqual(JSONValue.number(Double(Int.min)).intValue, Int.min)
    XCTAssertEqual(JSONValue.integer(Int.max).intValue, Int.max)
    XCTAssertEqual(JSONValue.number(42).intValue, 42)
    XCTAssertEqual(JSONValue.number(-42).intValue, -42)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: Data("1e100".utf8))
    XCTAssertNil(decoded.intValue)
  }
}

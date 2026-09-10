import Foundation
import Testing
@testable import MaiCore

@Test("JSON integer access rejects out-of-range and nonintegral doubles without trapping")
func jsonIntegerRange() throws {
  for number in [Double.infinity, -.infinity, .nan, 1e100, -1e100, Double(Int.max), 1.5] {
    #expect(JSONValue.number(number).intValue == nil)
  }
  #expect(JSONValue.number(Double(Int.min)).intValue == Int.min)
  #expect(JSONValue.integer(Int.max).intValue == Int.max)
  #expect(JSONValue.number(42).intValue == 42)
  #expect(JSONValue.number(-42).intValue == -42)
  let decoded = try JSONDecoder().decode(JSONValue.self, from: Data("1e100".utf8))
  #expect(decoded.intValue == nil)
}

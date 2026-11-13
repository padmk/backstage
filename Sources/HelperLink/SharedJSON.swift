// JSON values handed from one thread to another, as the socket and stdio servers do with each message.

import Foundation

// A JSON value as Foundation holds it: strings, numbers, booleans, null, and arrays and dictionaries of them.
// Swift arrays and dictionaries are values, and the objects JSONSerialization makes without `.mutableContainers`
// (NSString, NSNumber, NSNull and the immutable NSArray and NSDictionary) never change after they are made, so any
// thread may read a copy. That is what makes the unchecked conformance hold, so the initializer checks, in debug
// builds and so in the tests, that nothing else, such as a class instance or a closure, is inside.
public struct SharedJSON<Value>: @unchecked Sendable {
  public let value: Value

  public init(_ value: Value) {
    assert(isPlainJSON(value), "SharedJSON holds only strings, numbers, booleans, null, arrays and dictionaries")
    self.value = value
  }
}

private func isPlainJSON(_ value: Any) -> Bool {
  switch value {
  case is String, is NSString, is NSNumber, is NSNull, is Int, is Double, is Bool: return true
  case let array as [Any]: return array.allSatisfy(isPlainJSON)
  case let object as [String: Any]: return object.values.allSatisfy(isPlainJSON)
  default: return false
  }
}

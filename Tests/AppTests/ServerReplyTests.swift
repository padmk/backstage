// Replies as the socket sends them.

@testable import App
import Foundation
import Testing

@Suite struct ServerReplyTests {
  // A number that is not finite, as an app can report for a frame, makes JSONSerialization raise, which would end the app.
  @Test func aReplyThatIsNotJSONBecomesAnErrorForItsRequest() throws {
    let data = encodedReply(["id": 7, "result": ["x": Double.nan]])
    #expect(data.last == 0x0a)
    let reply = try #require(try JSONSerialization.jsonObject(with: data) as? JSON)
    #expect(reply["id"] as? Int == 7)
    #expect((reply["error"] as? JSON)?["code"] as? String == "outcome_unknown")
  }
}

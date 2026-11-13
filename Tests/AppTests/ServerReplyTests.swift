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

@Suite struct ConnectionSessionTests {
  // A hello that runs while its connection closes can adopt its session after close gave up the one it held; kept,
  // the adopted session would count a connection forever, listed as connected and never forgotten.
  @Test func aSessionAdoptedAfterCloseIsGivenUpAtOnce() {
    let connection = Connection(descriptor: -1)
    connection.close()
    connection.adopt(sessionId: "adopted-after-close-\(UUID().uuidString)")
    #expect(connection.session.attachedConnections == 0)
  }
}

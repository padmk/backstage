// How long record_audio records: what was asked, within its limits and within the time the client still waits.

@testable import App
import Testing

@Suite struct StateRecordingTests {
  @Test func withoutADeadlineTheAskedTimeHoldsWithinTheLimits() {
    #expect(recordingLimit(requested: nil, timeLeft: nil) == 60)
    #expect(recordingLimit(requested: 30, timeLeft: nil) == 30)
    #expect(recordingLimit(requested: 0.1, timeLeft: nil) == 1)
    #expect(recordingLimit(requested: 1000, timeLeft: nil) == maxRecordingSeconds)
  }

  @Test func aRecordingEndsBeforeTheClientGivesUp() {
    #expect(recordingLimit(requested: 180, timeLeft: 199) == 180)
    // After a wait for the app's lock, the time left decides, with room for the press to settle and the file to close.
    #expect(recordingLimit(requested: 180, timeLeft: 120) == 110)
    #expect(recordingLimit(requested: 60, timeLeft: 30) == 20)
  }

  @Test func tooLittleTimeLeftRecordsNothing() {
    #expect(recordingLimit(requested: 60, timeLeft: 10.5) == nil)
    #expect(recordingLimit(requested: 60, timeLeft: -5) == nil)
    #expect(recordingLimit(requested: 60, timeLeft: 11) == 1)
  }
}

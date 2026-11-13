// Recording what an app plays, such as a voice message, into a file the agent can transcribe. A Core Audio process
// tap takes the sound of the app and of the helper processes it plays through (a Chromium app plays from a helper
// with a bundle id of its own), and mutes it while it records, so the user does not hear what the agent plays. The
// recording can press an element once it runs, so nothing at the start is missed, and it ends after a pause in the
// sound or at a time limit. It needs System Audio Recording (Sources/App/SystemPermissions.swift).

import AVFoundation
import AppKit
import CoreAudio

// A request has to answer before the command gives up on it (200 seconds), with the press and its settling.
let maxRecordingSeconds = 180.0
// What a recording leaves of the request's time for the press to settle and the file to close.
private let recordingReserveSeconds = 10.0
private let minRecordingSeconds = 1.0
private let defaultRecordingSeconds = 60.0
private let defaultSilenceSeconds = 3.0
// Quieter than this counts as silence: about -60 dB.
private let soundThreshold: Float = 0.001
// How often the recording looks for processes the app started meanwhile, such as an audio helper that starts on
// the first sound.
private let processRefreshSeconds = 0.25

// MARK: Processes

private func property<Value>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ fallback: Value) -> Value {
  var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  var value = fallback
  var size = UInt32(MemoryLayout<Value>.size)
  let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
  return status == noErr ? value : fallback
}

// A string property comes back retained, so it is taken over rather than read in place.
private func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
  var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  var value: Unmanaged<CFString>?
  var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
  guard status == noErr, let value else { return "" }
  return value.takeRetainedValue() as String
}

private func audioProcessObjects() -> [AudioObjectID] {
  let system = AudioObjectID(kAudioObjectSystemObject)
  var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  var size: UInt32 = 0
  guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
  var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
  guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
  return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
}

private func parent(of pid: pid_t) -> pid_t? {
  var info = proc_bsdinfo()
  let size = Int32(MemoryLayout<proc_bsdinfo>.size)
  guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
  return pid_t(info.pbi_ppid)
}

private func descends(_ pid: pid_t, from ancestor: pid_t) -> Bool {
  var current = pid
  for _ in 0..<8 {
    if current == ancestor { return true }
    guard let next = parent(of: current), next > 1, next != current else { return false }
    current = next
  }
  return false
}

// Whether the process runs from inside the app's bundle, as its helpers do. A bundle id is no proof: another app's
// id can start with this one's, as a browser's other release channels do.
private func runsInsideBundle(_ pid: pid_t, of app: AppIdentity) -> Bool {
  guard let bundle = app.path, !bundle.isEmpty else { return false }
  var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
  let length = Int(proc_pidpath(pid, &buffer, UInt32(buffer.count)))
  guard length > 0 else { return false }
  let path = String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  return executable.hasPrefix(URL(fileURLWithPath: bundle).resolvingSymlinksInPath().path + "/")
}

// The app's own audio clients: the app, the processes it started, and those that run from inside its bundle.
private func audioProcesses(of app: AppIdentity) -> (objects: [AudioObjectID], bundleIds: [String]) {
  var objects: [AudioObjectID] = []
  var bundleIds: Set<String> = [app.bundleId]
  for object in audioProcessObjects() {
    let pid: pid_t = property(object, kAudioProcessPropertyPID, 0)
    let bundleId = stringProperty(object, kAudioProcessPropertyBundleID)
    guard pid > 0, descends(pid, from: app.pid) || runsInsideBundle(pid, of: app) else { continue }
    objects.append(object)
    if !bundleId.isEmpty { bundleIds.insert(bundleId) }
  }
  return (objects.sorted(), bundleIds.sorted())
}

// MARK: Tap

private func failure(_ what: String, _ status: OSStatus) -> HelperError {
  HelperError(code: "action_failed", message: "\(what) failed (Core Audio error \(status)).")
}

private func defaultOutputDeviceUID() throws -> String {
  let device: AudioObjectID = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, AudioObjectID(kAudioObjectUnknown))
  guard device != kAudioObjectUnknown else { throw HelperError(code: "action_failed", message: "The Mac has no sound output device to record from.") }
  return stringProperty(device, kAudioDevicePropertyDeviceUID)
}

// A private device that reads the tap, clocked by the sound output.
private func aggregateDevice(tapping description: CATapDescription) throws -> AudioObjectID {
  let output = try defaultOutputDeviceUID()
  let aggregate: [String: Any] = [
    kAudioAggregateDeviceNameKey: description.name,
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceMainSubDeviceKey: output,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
  ]
  var device = AudioObjectID(kAudioObjectUnknown)
  let status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
  guard status == noErr else { throw failure("Creating the recording device", status) }
  return device
}

// macOS shows its System Audio Recording prompt when an app first reads a tap, so the user's Allow starts one that
// taps no process, for a moment, and keeps nothing. Blocks, so it runs off the main thread.
func showAudioCapturePrompt() {
  let description = CATapDescription(monoMixdownOfProcesses: [])
  description.name = "\(Configuration.appName) permission check"
  description.isPrivate = true
  var tap = AudioObjectID(kAudioObjectUnknown)
  guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { return }
  defer { AudioHardwareDestroyProcessTap(tap) }
  // Only the prompt is wanted; without a device macOS shows none, and the Setup tab still says what to allow.
  guard let device = try? aggregateDevice(tapping: description) else { return }
  defer { AudioHardwareDestroyAggregateDevice(device) }
  var procedure: AudioDeviceIOProcID?
  guard AudioDeviceCreateIOProcIDWithBlock(&procedure, device, nil, { _, _, _, _, _ in }) == noErr, let procedure else { return }
  defer { AudioDeviceDestroyIOProcID(device, procedure) }
  guard AudioDeviceStart(device, procedure) == noErr else { return }
  Thread.sleep(forTimeInterval: 0.5)
  AudioDeviceStop(device, procedure)
}

// What the recording heard, written on the audio queue and read by the request.
private struct Heard {
  var frames: Int64 = 0
  var firstSound: Date?
  var lastSound: Date?
  var writeError: String?
}

private final class AppAudioRecorder {
  private let app: AppIdentity
  private let description: CATapDescription
  private var tap = AudioObjectID(kAudioObjectUnknown)
  private var device = AudioObjectID(kAudioObjectUnknown)
  private var procedure: AudioDeviceIOProcID?
  private var file: AVAudioFile?
  private var tapped: [AudioObjectID] = []
  private let queue = DispatchQueue(label: "audio-recording")
  // Looks for new processes of the app from the start of the recording, also while the press settles.
  private let processQueue = DispatchQueue(label: "audio-recording-processes")
  private var processTimer: DispatchSourceTimer?
  private let lock = NSLock()
  private var heard = Heard()
  private(set) var sampleRate = 0.0

  init(app: AppIdentity) {
    self.app = app
    let processes = audioProcesses(of: app)
    tapped = processes.objects
    description = CATapDescription(monoMixdownOfProcesses: processes.objects)
    description.bundleIDs = processes.bundleIds
    description.name = "\(Configuration.appName) recording of \(app.name)"
    description.isPrivate = true
    description.muteBehavior = .muted
  }

  func start(writingTo url: URL) throws {
    var status = AudioHardwareCreateProcessTap(description, &tap)
    guard status == noErr else { throw failure("Creating the audio tap", status) }
    var format: AudioStreamBasicDescription = property(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
    guard format.mSampleRate > 0, let tapFormat = AVAudioFormat(streamDescription: &format) else {
      throw HelperError(code: "action_failed", message: "The audio tap reported no format.")
    }
    sampleRate = tapFormat.sampleRate
    device = try aggregateDevice(tapping: description)
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: tapFormat.sampleRate,
      AVNumberOfChannelsKey: tapFormat.channelCount, AVEncoderBitRateKey: 96_000,
    ]
    do {
      file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: tapFormat.commonFormat, interleaved: tapFormat.isInterleaved)
    } catch {
      throw HelperError(code: "action_failed", message: "The recording file could not be made: \(error.localizedDescription)")
    }
    status = AudioDeviceCreateIOProcIDWithBlock(&procedure, device, queue) { [weak self] _, input, _, _, _ in
      self?.receive(input, format: tapFormat)
    }
    guard status == noErr else { throw failure("Starting the recording", status) }
    status = AudioDeviceStart(device, procedure)
    guard status == noErr else { throw failure("Starting the recording", status) }
    let timer = DispatchSource.makeTimerSource(queue: processQueue)
    timer.schedule(deadline: .now() + processRefreshSeconds, repeating: processRefreshSeconds)
    timer.setEventHandler { [weak self] in self?.followNewProcesses() }
    timer.resume()
    processTimer = timer
  }

  private func receive(_ input: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
    guard let file, let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
    var peak: Float = 0
    if let channels = buffer.floatChannelData {
      let count = Int(buffer.frameLength) * (format.isInterleaved ? Int(format.channelCount) : 1)
      for channel in 0..<(format.isInterleaved ? 1 : Int(format.channelCount)) {
        for index in 0..<count { peak = max(peak, abs(channels[channel][index])) }
      }
    }
    var problem: String?
    do { try file.write(from: buffer) } catch { problem = error.localizedDescription }
    let now = Date()
    lock.withLock {
      heard.frames += Int64(buffer.frameLength)
      if peak >= soundThreshold {
        if heard.firstSound == nil { heard.firstSound = now }
        heard.lastSound = now
      }
      if let problem, heard.writeError == nil { heard.writeError = problem }
    }
  }

  var state: Heard { lock.withLock { heard } }

  // Adds processes the app started since the tap was made; a tap whose description cannot change keeps the ones it has.
  // Runs on processQueue.
  private func followNewProcesses() {
    let current = audioProcesses(of: app)
    guard current.objects != tapped, tap != kAudioObjectUnknown else { return }
    description.processes = current.objects
    description.bundleIDs = current.bundleIds
    var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = description
    let status = withUnsafeMutablePointer(to: &value) {
      AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
    }
    if status == noErr { tapped = current.objects }
  }

  // Stops the sound reaching the file, then lets the app be heard again. The file is complete once this returns.
  func stop() {
    processTimer?.cancel()
    processTimer = nil
    // A look that is running ends before the tap goes.
    processQueue.sync {}
    if let procedure, device != kAudioObjectUnknown {
      AudioDeviceStop(device, procedure)
      AudioDeviceDestroyIOProcID(device, procedure)
    }
    procedure = nil
    queue.sync { file = nil }
    if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device) }
    device = AudioObjectID(kAudioObjectUnknown)
    if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
    tap = AudioObjectID(kAudioObjectUnknown)
  }

  deinit { stop() }
}

// MARK: Request

// How long to record: what was asked, within the limits, and within the time the client still waits for the answer,
// which waiting for the app's lock may have used up. Nil when too little is left to record at all.
func recordingLimit(requested: Double?, timeLeft: TimeInterval?) -> Double? {
  let asked = min(max(requested ?? defaultRecordingSeconds, minRecordingSeconds), maxRecordingSeconds)
  guard let timeLeft else { return asked }
  let available = timeLeft - recordingReserveSeconds
  return available < minRecordingSeconds ? nil : min(asked, available)
}

// Runs under the app's lock for the whole recording, so no other request starts or stops playback in the app
// meanwhile, and after the check that the user is not working there, since the tap mutes the app.
func recordAudio(app: AppIdentity, params: JSON, session: ApprovalSession, connection: Connection) throws -> JSON {
  try requirePermission(.audioRecording, for: "Recording an app's sound")
  guard let limit = recordingLimit(requested: (params["seconds"] as? NSNumber)?.doubleValue,
                                   timeLeft: connection.deadline?.timeIntervalSinceNow) else { throw expiredError }
  let silence = max((params["until_silent"] as? NSNumber)?.doubleValue ?? defaultSilenceSeconds, 0.5)
  let pressed = params["press"] as? Int

  let folder = try newCopyFolder(.audioRecordings)
  let url = folder.appendingPathComponent("\(app.name) \(timestampForFileName()).m4a")
  let recorder = AppAudioRecorder(app: app)
  do {
    try recorder.start(writingTo: url)
  } catch {
    recorder.stop()
    // A folder left behind on failure holds no result and only takes space.
    try? FileManager.default.removeItem(at: folder)
    throw error
  }
  let started = Date()
  var result: JSON = ["path": url.path, "muted_for_user": true]
  var ended = "time_limit"
  do {
    if let pressed {
      try requireAccessibility()
      result["press"] = try acting(app: app, session: session) {
        try performAction("press", app: app, params: ["app": app.bundleId, "element": pressed], session: session)
      }
    }
    while Date().timeIntervalSince(started) < limit {
      try connection.throwIfCancelled()
      if let last = recorder.state.lastSound, Date().timeIntervalSince(last) >= silence {
        ended = "silence"
        break
      }
      sleep(seconds: 0.05)
    }
  } catch {
    recorder.stop()
    // A folder left behind on failure holds no result and only takes space.
    try? FileManager.default.removeItem(at: folder)
    throw error
  }
  recorder.stop()
  let heard = recorder.state
  if let problem = heard.writeError {
    // A folder left behind on failure holds no result and only takes space.
    try? FileManager.default.removeItem(at: folder)
    throw HelperError(code: "action_failed", message: "The recording could not be written: \(problem)")
  }
  result["ended"] = ended
  result["seconds"] = recorder.sampleRate > 0 ? (Double(heard.frames) / recorder.sampleRate * 10).rounded() / 10 : 0
  result["heard_sound"] = heard.firstSound != nil
  if let first = heard.firstSound { result["sound_starts_at"] = (first.timeIntervalSince(started) * 10).rounded() / 10 }
  if heard.firstSound == nil {
    result["note"] = "Nothing was heard: the app played nothing, or its own volume is off. Check that playback started."
  }
  return result
}

private func timestampForFileName() -> String {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
  return formatter.string(from: Date())
}

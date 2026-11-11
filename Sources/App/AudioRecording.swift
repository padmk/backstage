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
private let defaultRecordingSeconds = 60.0
private let defaultSilenceSeconds = 3.0
// Quieter than this counts as silence: about -60 dB.
private let soundThreshold: Float = 0.001
// How often the tap looks for processes the app started meanwhile, such as an audio helper that starts on the first
// sound.
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

// The app's own audio clients: the app, the processes it started, and those inside its bundle.
private func audioProcesses(of app: AppIdentity) -> (objects: [AudioObjectID], bundleIds: [String]) {
  var objects: [AudioObjectID] = []
  var bundleIds: Set<String> = [app.bundleId]
  for object in audioProcessObjects() {
    let pid: pid_t = property(object, kAudioProcessPropertyPID, 0)
    let bundleId = stringProperty(object, kAudioProcessPropertyBundleID)
    guard pid > 0, descends(pid, from: app.pid) || bundleId.hasPrefix(app.bundleId + ".") else { continue }
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
  func followNewProcesses() {
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

func recordAudio(app: AppIdentity, params: JSON, session: ApprovalSession, connection: Connection) throws -> JSON {
  try requirePermission(.audioRecording, for: "Recording an app's sound")
  let limit = min(max((params["seconds"] as? NSNumber)?.doubleValue ?? defaultRecordingSeconds, 1), maxRecordingSeconds)
  let silence = max((params["until_silent"] as? NSNumber)?.doubleValue ?? defaultSilenceSeconds, 0.5)
  let pressed = params["press"] as? Int

  let folder = try newCopyFolder(.audioRecordings)
  let url = folder.appendingPathComponent("\(app.name) \(timestampForFileName()).m4a")
  let recorder = AppAudioRecorder(app: app)
  try recorder.start(writingTo: url)
  let started = Date()
  var result: JSON = ["path": url.path, "muted_for_user": true]
  var ended = "time_limit"
  do {
    if let pressed {
      result["press"] = try AppLocks.with(app.bundleId, connection: connection) { () throws -> JSON in
        try ApprovalGate.require(app, session: session)
        try requireSameProcess(app)
        try requireScreenUnlocked("press", params: ["element": pressed], app: app, session: session)
        try requireUserNotWorking(in: app)
        try requireAccessibility()
        return try acting(app: app, session: session) {
          try performAction("press", app: app, params: ["app": app.bundleId, "element": pressed], session: session)
        }
      }
    }
    var nextRefresh = Date()
    while Date().timeIntervalSince(started) < limit {
      try connection.throwIfCancelled()
      if Date() >= nextRefresh {
        recorder.followNewProcesses()
        nextRefresh = Date().addingTimeInterval(processRefreshSeconds)
      }
      if let last = recorder.state.lastSound, Date().timeIntervalSince(last) >= silence {
        ended = "silence"
        break
      }
      sleep(seconds: 0.05)
    }
  } catch {
    recorder.stop()
    try? FileManager.default.removeItem(at: folder)
    throw error
  }
  recorder.stop()
  let heard = recorder.state
  if let problem = heard.writeError {
    try? FileManager.default.removeItem(at: folder)
    throw HelperError(code: "action_failed", message: "The recording could not be written: \(problem)")
  }
  result["ended"] = ended
  result["seconds"] = recorder.sampleRate > 0 ? (Double(heard.frames) / recorder.sampleRate * 10).rounded() / 10 : 0
  result["heard_sound"] = heard.firstSound != nil
  if let first = heard.firstSound { result["sound_starts_at"] = (first.timeIntervalSince(started) * 10).rounded() / 10 }
  if heard.firstSound == nil {
    result["note"] = permissionState(.audioRecording) == .unknown
      ? "Nothing was heard. Either the app played nothing, or System Audio Recording is off: ask the user to allow it in the Backstage window, on the Setup tab."
      : "Nothing was heard: the app played nothing, or its own volume is off. Check that playback started."
  }
  return result
}

private func timestampForFileName() -> String {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
  return formatter.string(from: Date())
}

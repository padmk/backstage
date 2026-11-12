// The optional macOS permissions of Backstage itself: Screen Recording, for screenshots, and System Audio Recording,
// for record_audio. A request that needs one the user has not given leaves a request in the Backstage window, as an
// app asked for over the socket does: macOS's prompt shows only when the user chooses Allow there, never because an
// agent asked. macOS keeps the answer it gave a process for that process's lifetime, so the window reads the current
// answer in a short-lived copy of the app, and the app restarts itself once a grant made in System Settings is
// waiting for it.

import AppKit
import HelperLink

enum PermissionState: String {
  case granted, denied, notAsked = "not_asked", unknown
}

enum SystemPermission: String, CaseIterable, Identifiable {
  case screenRecording = "screen_recording", audioRecording = "audio_recording"
  var id: String { rawValue }

  // The name macOS uses in System Settings.
  var name: String {
    switch self {
    case .screenRecording: "Screen Recording"
    case .audioRecording: "System Audio Recording"
    }
  }

  // What agents can do with it, for the window.
  var purpose: String {
    switch self {
    case .screenRecording: "Screenshots, for web pages and apps that show no elements"
    case .audioRecording: "Record what an app plays, such as a voice message, without you hearing it"
    }
  }

  // Both live in Privacy & Security > Screen & System Audio Recording.
  var pane: String { "Privacy_ScreenCapture" }

  fileprivate var service: CFString {
    switch self {
    case .screenRecording: "kTCCServiceScreenCapture" as CFString
    case .audioRecording: "kTCCServiceAudioCapture" as CFString
    }
  }
}

// MARK: State

private let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
private let preflight = lookUp("TCCAccessPreflight", as: Preflight.self, in: tcc)

// What macOS answers this process. Without the private call, Screen Recording falls back to the public check, and
// System Audio Recording is unknown: recording is then refused, since a tap started to find out would make macOS
// show its prompt for a request from the socket.
func permissionState(_ permission: SystemPermission) -> PermissionState {
  if let preflight {
    switch preflight(permission.service, nil) {
    case 0: return .granted
    case 1: return .denied
    default: return .notAsked
    }
  }
  switch permission {
  case .screenRecording: return CGPreflightScreenCaptureAccess() ? .granted : .denied
  case .audioRecording: return .unknown
  }
}

// The argument that makes the app print the current answers and exit, for permissionStatesNow().
let permissionStatesArgument = "--permission-states"

func printPermissionStates() {
  let states = Dictionary(uniqueKeysWithValues: SystemPermission.allCases.map { ($0.rawValue, permissionState($0).rawValue) })
  if let data = try? JSONSerialization.data(withJSONObject: states) { FileHandle.standardOutput.write(data) }
}

// The answers macOS gives now, read in a new process of this app, since this one keeps the answers it was given.
// Runs a process, so it is called off the main thread.
func permissionStatesNow() -> [SystemPermission: PermissionState]? {
  guard Bundle.main.bundleIdentifier != nil, let executable = Bundle.main.executablePath else { return nil }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = [permissionStatesArgument]
  let output = Pipe()
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  guard (try? process.run()) != nil else { return nil }
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard let states = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
  return Dictionary(uniqueKeysWithValues: states.compactMap { key, value in
    SystemPermission(rawValue: key).flatMap { permission in PermissionState(rawValue: value).map { (permission, $0) } }
  })
}

// MARK: Asking

// The user chose Allow: macOS's prompt when it has not asked yet, otherwise its pane in System Settings, where only the
// user can turn it on. `answered` gets whether the permission is on afterwards, read in a new process, since this one
// keeps its first answer; a grant that only a new process has makes the app restart. Runs on the main thread.
func askForPermission(_ permission: SystemPermission, answered: @escaping (Bool) -> Void) {
  guard permissionState(permission) == .notAsked else {
    openPrivacyPane(permission.pane)
    return answered(false)
  }
  DispatchQueue.global().async {
    switch permission {
    case .screenRecording: _ = CGRequestScreenCaptureAccess()
    case .audioRecording: showAudioCapturePrompt()
    }
    let granted = permissionStatesNow()?[permission] == .granted
    DispatchQueue.main.async {
      if granted, permissionState(permission) != .granted { restartWhenIdleForNewGrant() }
      answered(granted)
    }
  }
}

// MARK: Requests from agents

struct PermissionRequest: Identifiable, Equatable {
  let permission: SystemPermission
  let client: String?
  var id: String { permission.rawValue }
}

enum PermissionRequests {
  private static let lock = NSLock()
  private static var waiting: [PermissionRequest] = []

  static var all: [PermissionRequest] { lock.withLock { waiting } }

  // Returns whether the request is new, so the window comes forward only once for it.
  static func add(_ permission: SystemPermission, client: String?) -> Bool {
    lock.withLock {
      if waiting.contains(where: { $0.permission == permission }) { return false }
      waiting.append(PermissionRequest(permission: permission, client: client))
      return true
    }
  }

  static func remove(_ permission: SystemPermission) {
    lock.withLock { waiting.removeAll { $0.permission == permission } }
  }
}

// Stops a request that needs a permission the user has not given, and leaves the user an Allow button for it in the
// Backstage window. `use` says what for, in the agent's terms.
func requirePermission(_ permission: SystemPermission, for use: String) throws {
  let state = permissionState(permission)
  if state == .granted { return }
  guard state != .unknown else {
    throw HelperError(code: "permission_missing", message: "\(use) needs \(permission.name), and this version of macOS does not let Backstage tell whether it is on, so it is not available.")
  }
  // A test build outside a bundle holds no permissions and has no window to ask in.
  guard Bundle.main.bundleIdentifier != nil else {
    throw HelperError(code: "permission_missing", message: "\(use) needs \(permission.name), which this build cannot get.")
  }
  let session = currentConnection()?.session
  let client = session.flatMap { session in session.lock.withLock { session.clientName } }
  if PermissionRequests.add(permission, client: client) {
    DispatchQueue.main.async { showControlWindow() }
  }
  throw HelperError(
    code: "permission_missing",
    message: "\(use) needs \(permission.name), which is off. The Backstage window now shows the user an Allow button for it; tell them to click it, then try again.")
}

// MARK: Restarting for a new grant

// A grant made in System Settings reaches this process only after a restart. New requests are turned away from now
// on, and it waits until those running have finished, so no agent loses one; the window opens again where it was.
func restartWhenIdleForNewGrant() {
  guard RequestActivity.planRestart() else { return }
  DispatchQueue.global().async {
    while !RequestActivity.isIdle { Thread.sleep(forTimeInterval: 0.2) }
    DispatchQueue.main.async { restartApp() }
  }
}

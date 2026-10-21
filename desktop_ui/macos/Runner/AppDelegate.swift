import AVFoundation
import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)

    // Request before the Flutter UI can start a recording. Doing this natively
    // avoids the permission prompt being lost while plugins are still starting.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      self.checkMicrophonePermission()
    }
  }

  private func checkMicrophonePermission() {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return
    case .notDetermined:
      NSApp.activate(ignoringOtherApps: true)
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        if !granted {
          DispatchQueue.main.async {
            self.showMicrophoneSettingsAlert()
          }
        }
      }
    case .denied, .restricted:
      showMicrophoneSettingsAlert()
    @unknown default:
      showMicrophoneSettingsAlert()
    }
  }

  private func showMicrophoneSettingsAlert() {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "VoiceShelf нужен доступ к микрофону"
    alert.informativeText = "Без доступа запись голоса невозможна. Разрешите микрофон для VoiceShelf в системных настройках."
    alert.addButton(withTitle: "Открыть настройки")
    alert.addButton(withTitle: "Позже")

    if alert.runModal() == .alertFirstButtonReturn,
       let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
      NSWorkspace.shared.open(url)
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

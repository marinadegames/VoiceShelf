import AVFoundation
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var audioRecorder: AVAudioRecorder?
  private var audioPlayer: AVAudioPlayer?
  private var recordingPath: String?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let recorderChannel = FlutterMethodChannel(
      name: "local.voiceshelf.desktop/recorder",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    recorderChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleRecorderCall(call, result: result)
    }

    super.awakeFromNib()
  }

  private func handleRecorderCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
        result(FlutterError(code: "microphone_denied", message: "Нет доступа к микрофону", details: nil))
        return
      }
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String else {
        result(FlutterError(code: "invalid_path", message: "Не передан путь записи", details: nil))
        return
      }
      do {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        let settings: [String: Any] = [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVSampleRateKey: 48_000.0,
          AVNumberOfChannelsKey: 1,
          AVLinearPCMBitDepthKey: 16,
          AVLinearPCMIsFloatKey: false,
          AVLinearPCMIsBigEndianKey: false,
          AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else {
          result(FlutterError(code: "record_start_failed", message: "macOS не смогла запустить микрофон", details: nil))
          return
        }
        audioRecorder = recorder
        recordingPath = path
        result(true)
      } catch {
        result(FlutterError(code: "record_start_failed", message: error.localizedDescription, details: nil))
      }
    case "amplitude":
      guard let recorder = audioRecorder, recorder.isRecording else {
        result(-160.0)
        return
      }
      recorder.updateMeters()
      result(Double(max(
        recorder.averagePower(forChannel: 0),
        recorder.peakPower(forChannel: 0)
      )))
    case "stop":
      audioRecorder?.stop()
      audioRecorder = nil
      let path = recordingPath
      recordingPath = nil
      result(path)
    case "play":
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String else {
        result(FlutterError(code: "invalid_path", message: "Не передан путь записи", details: nil))
        return
      }
      do {
        audioPlayer?.stop()
        let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
        guard player.prepareToPlay(), player.play() else {
          result(FlutterError(code: "playback_failed", message: "Не удалось воспроизвести запись", details: nil))
          return
        }
        audioPlayer = player
        result(true)
      } catch {
        result(FlutterError(code: "playback_failed", message: error.localizedDescription, details: nil))
      }
    case "stopPlayback":
      audioPlayer?.stop()
      audioPlayer = nil
      result(nil)
    case "isPlaying":
      result(audioPlayer?.isPlaying ?? false)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

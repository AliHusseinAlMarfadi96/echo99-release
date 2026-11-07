import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private var speechResult: FlutterResult?
  private var speechText: String?
  private var speechObserver: NSObjectProtocol?
  private var voiceOverObserver: NSObjectProtocol?
  private var speechChannel: FlutterMethodChannel?

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "EchoSpeechCompletion")!
    speechChannel = FlutterMethodChannel(name: "echo99/speech_completion", binaryMessenger: registrar.messenger())
    voiceOverObserver = NotificationCenter.default.addObserver(
      forName: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self = self, !UIAccessibility.isVoiceOverRunning else { return }
      self.speechResult?(nil); self.speechResult = nil; self.speechText = nil
    }
    speechChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      if call.method == "cancel" {
        self.speechResult?(nil); self.speechResult = nil; self.speechText = nil
        result(nil); return
      }
      guard call.method == "announce", let text = call.arguments as? String else {
        result(FlutterMethodNotImplemented); return
      }
      guard UIAccessibility.isVoiceOverRunning else { result(nil); return }
      self.speechResult?(FlutterError(code: "replaced", message: "Announcement replaced", details: nil))
      self.speechResult = result
      self.speechText = text
      if self.speechObserver == nil {
        self.speechObserver = NotificationCenter.default.addObserver(
          forName: UIAccessibility.announcementDidFinishNotification, object: nil, queue: .main
        ) { [weak self] notice in
          guard let self = self,
                let spoken = notice.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String,
                spoken == self.speechText else { return }
          let finished = self.speechResult
          self.speechResult = nil; self.speechText = nil
          // An interruption ends this presentation, not a second announcement
          // which would fight the user's focus navigation.
          finished?(nil)
        }
      }
      let queued = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
      UIAccessibility.post(notification: .announcement, argument: queued)
    }
  }
}

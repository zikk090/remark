import AVFoundation
import Speech

/// Push-to-talk speech-to-text. Uses on-device recognition when the Mac supports it,
/// so client screens/notes don't leave the machine.
final class Dictation {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer: SFSpeechRecognizer? =
        SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    private(set) var isRunning = false
    var onText: ((String) -> Void)?
    var onStateChange: ((Bool) -> Void)?

    enum DictationError: LocalizedError {
        case unavailable, noMicrophone
        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Speech recognition isn't available. Check System Settings › Keyboard › Dictation."
            case .noMicrophone:
                return "No microphone input found."
            }
        }
    }

    static func requestAccess(_ completion: @escaping (String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async {
                    completion("Speech recognition is off for Remark. Turn it on in System Settings › Privacy & Security › Speech Recognition.")
                }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted ? nil : "Microphone access is off for Remark. Turn it on in System Settings › Privacy & Security › Microphone.")
                }
            }
        }
    }

    var isOnDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    func start() throws {
        stopInternal(notify: false)
        task?.cancel()
        task = nil

        guard let recognizer, recognizer.isAvailable else { throw DictationError.unavailable }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { throw DictationError.noMicrophone }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        try engine.start()

        request = req
        isRunning = true
        onStateChange?(true)

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || (result?.isFinal ?? false)
            DispatchQueue.main.async {
                guard let self else { return }
                if let text, !text.isEmpty { self.onText?(text) }
                if done { self.stop() }
            }
        }
    }

    func stop() { stopInternal(notify: true) }

    private func stopInternal(notify: Bool) {
        guard isRunning else { return }
        isRunning = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        if notify { onStateChange?(false) }
    }
}

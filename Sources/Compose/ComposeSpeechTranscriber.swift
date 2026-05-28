import AVFoundation
import Foundation
import Speech

@MainActor
final class ComposeSpeechTranscriber: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var elapsedMs: Int = 0

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    private var tickerTask: Task<Void, Never>?

    private var latestTranscript = ""
    private var onTranscriptionComplete: ((String) -> Void)?
    private var startedAt: Date?

    deinit {
        tickerTask?.cancel()
        recognitionTask?.cancel()
        recognitionRequest = nil
        guard let audioEngine else { return }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.reset()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func toggleRecording(onTranscript: @escaping (String) -> Void) async -> String? {
        if isRecording {
            stopRecording()
            return nil
        }

        if isTranscribing {
            return nil
        }

        do {
            try await startRecording(onTranscript: onTranscript)
            return nil
        } catch {
            if let speechError = error as? SpeechInputError {
                return speechError.errorDescription
            }
            return SpeechInputError.startupFailed(startupFailureMessage(for: error)).errorDescription
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        isRecording = false
        isTranscribing = true
        stopTicker()

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
    }

    private func startRecording(onTranscript: @escaping (String) -> Void) async throws {
        let speechAuthorization = await requestSpeechAuthorization()
        guard speechAuthorization == .authorized else {
            throw SpeechInputError.speechPermissionDenied
        }

        let hasMicrophonePermission = await requestMicrophonePermission()
        guard hasMicrophonePermission else {
            throw SpeechInputError.microphonePermissionDenied
        }

        cleanupRecognition()

        let locale = Locale.autoupdatingCurrent
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            throw SpeechInputError.recognizerUnavailable
        }

        speechRecognizer = recognizer
        latestTranscript = ""
        elapsedMs = 0
        startedAt = Date()
        onTranscriptionComplete = onTranscript

        var startupError: Error?
        for strategy in RecordingSessionStrategy.allCases {
            do {
                try startRecognitionPipeline(using: recognizer, strategy: strategy)
                isRecording = true
                isTranscribing = false
                startTicker()
                return
            } catch {
                startupError = error
                cleanupRecognition()
            }
        }

        throw SpeechInputError.startupFailed(startupFailureMessage(for: startupError))
    }

    private func finishTranscription() {
        guard isRecording || isTranscribing else { return }

        isRecording = false
        isTranscribing = false
        stopTicker()
        cleanupRecognition()

        let transcript = latestTranscript
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        latestTranscript = ""

        if !transcript.isEmpty {
            onTranscriptionComplete?(transcript)
        }
        onTranscriptionComplete = nil
    }

    private func cleanupRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        releaseAudioEngine()
    }

    private func startRecognitionPipeline(
        using recognizer: SFSpeechRecognizer,
        strategy: RecordingSessionStrategy
    ) throws {
        let audioEngine = recordingAudioEngine()
        let audioSession = AVAudioSession.sharedInstance()
        try configureAudioSession(audioSession, strategy: strategy)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        guard let format = preferredRecordingFormat(for: inputNode) else {
            throw SpeechInputError.microphoneUnavailable
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    self.latestTranscript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.finishTranscription()
                        return
                    }
                }

                if let error {
                    let nsError = error as NSError
                    if nsError.domain == "kAFAssistantErrorDomain", nsError.code == 1110 {
                        self.finishTranscription()
                        return
                    }
                    self.finishTranscription()
                }
            }
        }
    }

    private func recordingAudioEngine() -> AVAudioEngine {
        if let audioEngine {
            return audioEngine
        }

        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine
        return audioEngine
    }

    private func releaseAudioEngine() {
        guard let audioEngine else { return }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.reset()
        audioEngine.inputNode.removeTap(onBus: 0)
        self.audioEngine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func configureAudioSession(
        _ audioSession: AVAudioSession,
        strategy: RecordingSessionStrategy
    ) throws {
        switch strategy {
        case .optimized:
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try? audioSession.setPreferredSampleRate(44_100)
            try? audioSession.setPreferredInputNumberOfChannels(1)
        case .compatible:
            try audioSession.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers]
            )
        }

        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func preferredRecordingFormat(for inputNode: AVAudioInputNode) -> AVAudioFormat? {
        let inputFormat = inputNode.inputFormat(forBus: 0)
        if isUsableRecordingFormat(inputFormat) {
            return inputFormat
        }

        let outputFormat = inputNode.outputFormat(forBus: 0)
        if isUsableRecordingFormat(outputFormat) {
            return outputFormat
        }

        return nil
    }

    private func isUsableRecordingFormat(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    private func startTicker() {
        stopTicker()

        tickerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.isRecording {
                if let startedAt {
                    self.elapsedMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    private func stopTicker() {
        tickerTask?.cancel()
        tickerTask = nil
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func startupFailureMessage(for error: Error?) -> String {
        guard let error else {
            return "Could not start voice input."
        }

        if let speechError = error as? SpeechInputError,
           let description = speechError.errorDescription {
            return description
        }

        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain || nsError.domain == "com.apple.coreaudio.avfaudio" {
            return "Voice input couldn't start with the current microphone or audio route."
        }

        return "Could not start voice input."
    }
}

enum SpeechInputError: LocalizedError {
    case speechPermissionDenied
    case microphonePermissionDenied
    case recognizerUnavailable
    case microphoneUnavailable
    case startupFailed(String)

    var errorDescription: String? {
        switch self {
        case .speechPermissionDenied:
            return "Speech recognition permission is blocked."
        case .microphonePermissionDenied:
            return "Microphone permission is blocked."
        case .recognizerUnavailable:
            return "Voice input isn't available right now."
        case .microphoneUnavailable:
            return "Microphone input isn't available right now."
        case .startupFailed(let message):
            return message
        }
    }
}

private enum RecordingSessionStrategy: CaseIterable {
    case optimized
    case compatible
}

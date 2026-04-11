import AVFoundation
import Speech

/// AudioCaptureService handles microphone input with dual-mode support:
/// - Local mode: Streams to Apple Speech Recognition directly
/// - Server mode: Captures audio to buffer, exports as WAV for server transcription
final class AudioCaptureService {
    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onLocaleUnavailable: ((String) -> Void)?
    var onAudioCaptured: ((Data) -> Void)?  // Server mode: complete audio buffer

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?

    // Audio buffer for server mode
    private var audioBuffer = Data()
    private var isCapturingForServer = false

    var locale: Locale {
        didSet {
            speechRecognizer = SFSpeechRecognizer(locale: locale)
            if speechRecognizer == nil {
                onLocaleUnavailable?("Speech recognition is not supported for \(locale.identifier). Please check that the language is downloaded in System Settings → General → Keyboard → Dictation.")
            }
        }
    }

    init(locale: Locale = Locale(identifier: "zh-CN")) {
        self.locale = locale
        self.speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    // MARK: - Permissions

    static func requestPermissions(completion: @escaping (Bool, String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        DispatchQueue.main.async {
                            if granted {
                                completion(true, nil)
                            } else {
                                completion(false, "Microphone access denied.\nGrant in System Settings → Privacy & Security → Microphone.")
                            }
                        }
                    }
                case .denied, .restricted:
                    completion(false, "Speech recognition denied.\nGrant in System Settings → Privacy & Security → Speech Recognition.")
                case .notDetermined:
                    completion(false, "Speech recognition permission not determined.")
                @unknown default:
                    completion(false, "Unknown speech recognition authorization status.")
                }
            }
        }
    }

    // MARK: - Local Mode Recording (Apple Speech Recognition)

    func startLocalRecording() {
        isCapturingForServer = false
        recognitionTask?.cancel()
        recognitionTask = nil

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            onError?("Speech recognizer not available for \(locale.identifier)")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13, *) {
            request.addsPunctuation = true
        }
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    self.onFinalResult?(text)
                } else {
                    self.onPartialResult?(text)
                }
            }
            if let error, (error as NSError).code != 216 {
                self.onError?(error.localizedDescription)
            }
        }

        startAudioEngine(feedToRequest: request)
    }

    // MARK: - Server Mode Recording (Capture WAV buffer)

    func startServerRecording() {
        isCapturingForServer = true
        audioBuffer = Data()
        startAudioEngine(feedToRequest: nil)
    }

    // MARK: - Common Audio Engine

    private func startAudioEngine(feedToRequest request: SFSpeechAudioBufferRecognitionRequest?) {
        guard audioEngine.inputNode.inputFormat(forBus: 0).sampleRate > 0 else {
            onError?("No audio input device available")
            cleanup()
            return
        }

        let inputNode = audioEngine.inputNode

        // Always remove any existing tap before installing a new one
        inputNode.removeTap(onBus: 0)

        // For server mode, we need a standard format for WAV export
        let serverFormat = isCapturingForServer
            ? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
            : nil

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }

            let tapFormat = buffer.format

            // Feed to Apple Speech Recognition
            request?.append(buffer)

            // Capture for server mode
            if self.isCapturingForServer, let recordingFormat = serverFormat,
               let converter = AVAudioConverter(from: tapFormat, to: recordingFormat) {
                let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * recordingFormat.sampleRate / tapFormat.sampleRate)
                if let convertedBuffer = AVAudioPCMBuffer(pcmFormat: recordingFormat, frameCapacity: frameCount) {
                    var error: NSError?
                    var allConsumed = false
                    converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                        if !allConsumed {
                            allConsumed = true
                            outStatus.pointee = .haveData
                            return buffer
                        }
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    if error == nil, let channelData = convertedBuffer.int16ChannelData {
                        let byteCount = Int(convertedBuffer.frameLength) * MemoryLayout<Int16>.size
                        let data = Data(bytes: channelData[0], count: byteCount)
                        self.audioBuffer.append(data)
                    }
                }
            }

            // Audio level meter
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameLength { sum += channelData[i] * channelData[i] }
            let rms = sqrtf(sum / Float(max(frameLength, 1)))
            let dB = 20 * log10(max(rms, 1e-6))
            let normalized = max(Float(0), min(Float(1), (dB + 50) / 40))
            DispatchQueue.main.async { self.onAudioLevel?(normalized) }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            onError?("Audio engine failed: \(error.localizedDescription)")
            cleanup()
        }
    }

    // MARK: - Stop

    func stopRecording() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()

        // In server mode, deliver the captured audio
        if isCapturingForServer && !audioBuffer.isEmpty {
            let wavData = createWAVData(from: audioBuffer, sampleRate: 16000, channels: 1, bitsPerSample: 16)
            onAudioCaptured?(wavData)
        }
    }

    func cancel() {
        recognitionTask?.cancel()
        cleanup()
    }

    private func cleanup() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest = nil
        recognitionTask = nil
        audioBuffer = Data()
    }

    // MARK: - WAV Creation

    private func createWAVData(from pcmData: Data, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = pcmData.count
        let fileSize = 36 + dataSize

        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.appendLittleEndianUInt32(UInt32(fileSize))
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.appendLittleEndianUInt32(16) // chunk size
        header.appendLittleEndianUInt16(1)  // PCM format
        header.appendLittleEndianUInt16(UInt16(channels))
        header.appendLittleEndianUInt32(UInt32(sampleRate))
        header.appendLittleEndianUInt32(UInt32(byteRate))
        header.appendLittleEndianUInt16(UInt16(blockAlign))
        header.appendLittleEndianUInt16(UInt16(bitsPerSample))
        header.append("data".data(using: .ascii)!)
        header.appendLittleEndianUInt32(UInt32(dataSize))
        header.append(pcmData)
        return header
    }
}

// MARK: - Data helpers for WAV

private extension Data {
    mutating func appendLittleEndianUInt16(_ value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }
    mutating func appendLittleEndianUInt32(_ value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }
}

import AVFoundation
import Foundation

/// Records what a mix plays to an audio file, with no screen capture involved.
///
/// This is the plain case: keep what you are already routing — a call, a
/// stream, one app's sound — as a file.
///
/// The mix arrives on a real-time thread, where opening or writing a file is
/// forbidden: a blocked audio thread is a dropout. So the audio is copied into
/// a ring buffer there, and a timer on a background queue writes whatever has
/// gathered.
final class MixRecorder: @unchecked Sendable {

    /// What the file holds.
    ///
    /// These are the formats macOS itself can encode. MP3 is not among them:
    /// the system has a decoder but no encoder, and AAC is better at the same
    /// bitrate and plays everywhere, so it takes MP3's place here.
    enum FileFormat: String, Codable, CaseIterable, Identifiable {
        case aac, alac, flac, wav, aiff

        var id: String { rawValue }

        var fileExtension: String {
            switch self {
            case .aac, .alac: return "m4a"
            case .flac:       return "flac"
            case .wav:        return "wav"
            case .aiff:       return "aiff"
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .aac:  return "AAC (.m4a) — small, plays everywhere"
            case .alac: return "Apple Lossless (.m4a) — lossless, about half the size of WAV"
            case .flac: return "FLAC — lossless, open"
            case .wav:  return "WAV — uncompressed"
            case .aiff: return "AIFF — uncompressed"
            }
        }

        var isLossy: Bool { self == .aac }
        /// Whether a bit depth applies.
        var hasBitDepth: Bool { self == .wav || self == .aiff }
    }

    /// Bitrates offered for AAC, in bits per second.
    static let bitrates = [128_000, 192_000, 256_000, 320_000]
    static let bitDepths = [16, 24]

    let url: URL
    let channelCount: Int
    let sampleRate: Double

    private let ring: AudioRingBuffer
    private let scratch: AVAudioPCMBuffer
    private var file: AVAudioFile?
    private let fileLock = NSLock()

    private let queue = DispatchQueue(label: "dev.kosuke.Tapdeck.MixRecorder", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let started = Date()

    /// How long the recording has been running.
    var elapsed: TimeInterval { Date().timeIntervalSince(started) }

    /// Frames written so far, for showing progress and the file's length.
    private(set) var writtenFrames: Int64 = 0

    /// How large the file has grown, in bytes.
    var fileSize: Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
    }

    init(url: URL, sampleRate: Double, channels: Int, format: FileFormat,
         bitrate: Int = 256_000, bitDepth: Int = 24) throws {
        self.url = url
        self.sampleRate = sampleRate
        channelCount = max(1, channels)

        guard let streamFormat = AVAudioFormat.discrete(sampleRate: sampleRate, channels: channelCount) else {
            throw CoreAudioError.missing("a format for the recording")
        }
        var settings: [String: Any] = [
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
        ]
        switch format {
        case .aac:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            // More channels need more bits for the same quality.
            settings[AVEncoderBitRateKey] = channelCount > 2 ? bitrate * 2 : bitrate
        case .alac:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = bitDepth
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
        case .wav, .aiff:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = bitDepth
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = format == .aiff
            settings[AVLinearPCMIsNonInterleaved] = false
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)

        // Four seconds of slack: enough that a busy moment on the writing
        // queue costs nothing, while the memory stays small.
        ring = AudioRingBuffer(channels: channelCount,
                               capacityFrames: Int(sampleRate * 4),
                               primeFrames: 0)
        guard let scratch = AVAudioPCMBuffer(pcmFormat: streamFormat, frameCapacity: 16_384) else {
            throw CoreAudioError.missing("a buffer for the recording")
        }
        self.scratch = scratch
    }

    /// Begin writing. The file exists from here on, even if nothing plays.
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    /// Hand over one block of the mix. Runs on the mix's real-time thread.
    func append(_ channels: [UnsafeMutablePointer<Float>], frameCount: Int) {
        ring.write(channels.map { UnsafePointer($0) }, frameCount: frameCount)
    }

    /// Write what is left and close the file.
    func finish() {
        timer?.cancel()
        timer = nil
        queue.sync { drain() }
        fileLock.lock()
        file = nil
        fileLock.unlock()
    }

    private func drain() {
        guard let data = scratch.floatChannelData else { return }
        let channels = (0..<channelCount).map { data[$0] }
        let capacity = Int(scratch.frameCapacity)

        while true {
            let frames = min(ring.availableFrames, capacity)
            guard frames > 0 else { return }
            for channel in channels { channel.update(repeating: 0, count: frames) }
            ring.mixInto(channels, frameCount: frames, gain: 1)
            scratch.frameLength = AVAudioFrameCount(frames)

            fileLock.lock()
            try? file?.write(from: scratch)
            fileLock.unlock()
            writtenFrames += Int64(frames)
        }
    }
}

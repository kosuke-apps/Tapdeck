import AVFoundation
import CoreAudio
import Foundation

/// Wrapper around Core Audio's process tap API (macOS 14.2+).
///
/// This is the heart of what makes per-app capture possible: it pulls out the
/// audio of one chosen app, with no virtual audio driver and no kernel
/// extension involved.
///
/// How it works:
///   1. Declare which processes are wanted with a CATapDescription, and create
///      the tap.
///   2. A tap cannot be read on its own, so build a private aggregate device
///      that contains the tap as a sub-device.
///   3. Attach an IOProc to that aggregate device to receive the audio.
final class ProcessTap {

    enum Mode {
        /// Capture only the audio of the given processes.
        case include([AudioProcess])
        /// Capture all system audio except the given processes.
        case excluding([AudioProcess])
    }

    /// Format of the buffers handed to the callback.
    /// A tap's own format is interleaved, but buffers are always normalised to
    /// non-interleaved Float32 here because that is what the mixer wants.
    private(set) var format: AVAudioFormat?
    private(set) var isRunning = false

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var handler: ((AVAudioPCMBuffer) -> Void)?

    private let queue = DispatchQueue(label: "dev.kosuke.Tapdeck.ProcessTap",
                                      qos: .userInitiated)

    deinit { stop() }

    // MARK: - Starting

    /// - Parameter clock: the device to clock the aggregate from. Defaults to
    ///   the default output device.
    ///
    ///   Note that pointing the clock at some other device stops the tap from
    ///   hearing audio that is not flowing there — measured as complete
    ///   silence — so this is left at the default in practice.
    func start(mode: Mode,
               clock: AudioDevice? = nil,
               mute: CATapMuteBehavior = .unmuted,
               onAudio: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard !isRunning else { return }
        handler = onAudio

        do {
            try createTap(mode: mode, mute: mute)
            // Create the aggregate first: the real format has to be read from
            // it rather than from the tap. See resolveFormat below.
            try createAggregateDevice(clockUID: clock?.uid)
            _ = try resolveFormat()
            listenForRateChanges()
            try attachIOProc()
            isRunning = true
        } catch {
            stop()
            throw error
        }
    }

    private func createTap(mode: Mode, mute: CATapMuteBehavior) throws {
        let description: CATapDescription
        switch mode {
        case .include(let procs):
            description = CATapDescription(
                stereoMixdownOfProcesses: procs.map(\.objectID))
        case .excluding(let procs):
            description = CATapDescription(
                stereoGlobalTapButExcludeProcesses: procs.map(\.objectID))
        }
        description.name = "Tapdeck"
        description.uuid = UUID()
        description.muteBehavior = mute

        try ca("creating the process tap") {
            AudioHardwareCreateProcessTap(description, &tapID)
        }
        guard tapID != 0 else { throw CoreAudioError.missing("the created tap") }
    }

    private func resolveFormat() throws -> AVAudioFormat {
        var asbd: AudioStreamBasicDescription = try AudioObjectID(tapID)
            .read(kAudioTapPropertyFormat, label: "reading the tap format")

        // This is the trap. What actually reaches the IOProc is the aggregate
        // device's input stream, and the aggregate follows the clock of its
        // main sub-device — the default output device. So the rate the tap
        // reports can disagree with the rate the audio arrives at.
        //
        // Measured: the built-in speakers ran at 44100 Hz while
        // kAudioTapPropertyFormat reported 48000 Hz. Trusting the tap shifts
        // every recording by 48000/44100 = 8.8%, turning a 440 Hz tone into
        // 479 Hz.
        if let deviceRate: Float64 = try? AudioObjectID(aggregateID)
            .read(kAudioDevicePropertyNominalSampleRate,
                  label: "reading the aggregate sample rate"),
           deviceRate > 0,
           abs(deviceRate - asbd.mSampleRate) > 1 {
            sampleRateCorrection = (declared: asbd.mSampleRate, actual: deviceRate)
            asbd.mSampleRate = deviceRate
        }

        guard let raw = AVAudioFormat(streamDescription: &asbd) else {
            throw CoreAudioError.missing("the tap format")
        }
        rawFormat = raw

        guard let normalized = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: raw.sampleRate,
                                             channels: raw.channelCount,
                                             interleaved: false) else {
            throw CoreAudioError.missing("the normalised format")
        }
        format = normalized
        return raw
    }

    /// Records a disagreement between the tap's reported rate and the real one.
    private(set) var sampleRateCorrection: (declared: Float64, actual: Float64)?

    // MARK: - Rate changes

    /// How many times the stream's sample rate changed while running.
    private(set) var sampleRateChanges = 0

    /// The rate the audio actually arrives at, measured from the timestamps
    /// over roughly the last second. Zero until measured. For diagnostics.
    private(set) var measuredSampleRate: Double = 0
    private var measureStart: (hostTime: UInt64, sampleTime: Float64)?

    private var rateListener: AudioObjectPropertyListenerBlock?
    private var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                         mScope: kAudioObjectPropertyScopeGlobal,
                                                         mElement: kAudioObjectPropertyElementMain)

    /// The aggregate runs on the default output device's clock, and that
    /// device can change rate while the tap runs — another app opening it at a
    /// different rate, or the default output switching devices. The audio
    /// then arrives at the new rate. Keeping the old format plays it at the
    /// wrong speed: measured, a 997 Hz tone came out of a mix at 916 Hz once
    /// its audio started arriving at 48000 Hz while still read as 44100 Hz.
    /// Changing the clock device's rate under a running tap was confirmed to
    /// fire this listener.
    ///
    /// The listener runs on the IOProc's own serial queue, so the format never
    /// changes in the middle of a callback.
    private func listenForRateChanges() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.adoptNominalRate()
        }
        if AudioObjectAddPropertyListenerBlock(aggregateID, &rateAddress, queue, block) == noErr {
            rateListener = block
        }
    }

    private func adoptNominalRate() {
        guard aggregateID != 0,
              let rate: Float64 = try? AudioObjectID(aggregateID)
                .read(kAudioDevicePropertyNominalSampleRate, label: "reading the aggregate sample rate")
        else { return }
        adopt(rate: rate)
    }

    /// Switch the stream format to a new rate. Runs on the IOProc's queue.
    private func adopt(rate: Float64) {
        guard let current = rawFormat, rate > 0, abs(rate - current.sampleRate) > 1 else { return }
        var asbd = current.streamDescription.pointee
        asbd.mSampleRate = rate
        guard let raw = AVAudioFormat(streamDescription: &asbd),
              let normalized = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                             channels: raw.channelCount, interleaved: false) else { return }
        rawFormat = raw
        format = normalized
        sampleRateChanges += 1
        measureStart = nil
    }

    /// Rates a device can plausibly run at, for snapping a measurement to.
    static let standardSampleRates: [Double] = [8_000, 11_025, 16_000, 22_050, 24_000, 32_000,
                                                44_100, 48_000, 88_200, 96_000, 176_400, 192_000]

    static func nearestStandardRate(to measured: Double) -> Double {
        standardSampleRates.min { abs($0 - measured) < abs($1 - measured) } ?? measured
    }

    private func stopListening() {
        if let rateListener, aggregateID != 0 {
            AudioObjectRemovePropertyListenerBlock(aggregateID, &rateAddress, queue, rateListener)
        }
        rateListener = nil
    }

    /// Update the measured rate from one callback's timestamp.
    private func measureRate(_ time: AudioTimeStamp) {
        guard time.mFlags.contains([.hostTimeValid, .sampleTimeValid]) else { return }
        guard let start = measureStart else {
            measureStart = (time.mHostTime, time.mSampleTime)
            return
        }
        let seconds = Double(time.mHostTime &- start.hostTime) * Self.hostTimeScale
        guard seconds >= 1 else { return }
        measuredSampleRate = (time.mSampleTime - start.sampleTime) / seconds
        measureStart = (time.mHostTime, time.mSampleTime)

        // A safety net for a change the nominal rate property does not
        // report: audio arriving more than 3% away from the assumed rate over
        // a whole second cannot be drift.
        if let assumed = rawFormat?.sampleRate, abs(measuredSampleRate - assumed) > assumed * 0.03 {
            adopt(rate: Self.nearestStandardRate(to: measuredSampleRate))
        }
    }

    private static let hostTimeScale: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    /// How often the sample times handed to the IOProc were discontinuous.
    /// If this climbs, audio is being dropped before it reaches the mixer.
    private(set) var discontinuityCount = 0
    private var lastEndSampleTime: Float64?

    /// The format the tap actually produces (interleaved), for diagnostics.
    private(set) var rawFormat: AVAudioFormat?

    /// Split an interleaved buffer into one plane per channel.
    /// Taps always arrive interleaved while AVAudioFile and AVAudioEngine both
    /// expect the opposite, so they are reconciled here.
    private func normalize(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let outFormat = format else { return nil }
        guard src.format.isInterleaved else { return src }

        guard let dst = AVAudioPCMBuffer(pcmFormat: outFormat,
                                         frameCapacity: src.frameLength),
              let source = src.floatChannelData?[0],
              let target = dst.floatChannelData else { return nil }

        let frames = Int(src.frameLength)
        let channels = Int(src.format.channelCount)
        for frame in 0..<frames {
            let base = frame * channels
            for channel in 0..<channels {
                target[channel][frame] = source[base + channel]
            }
        }
        dst.frameLength = src.frameLength
        return dst
    }

    /// Build a private aggregate device containing the tap.
    /// It needs a clock, so the default output device is always included as a
    /// sub-device.
    private func createAggregateDevice(clockUID: String? = nil) throws {
        guard let tapUID = AudioObjectID(tapID).readString(kAudioTapPropertyUID) else {
            throw CoreAudioError.missing("the tap UID")
        }
        let outputUID = try clockUID ?? defaultOutputDeviceUID()

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tapdeck Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUID,
                ]
            ],
        ]

        try ca("creating the aggregate device") {
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        }
    }

    private func attachIOProc() throws {
        try ca("creating the IOProc") {
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
                [weak self] _, inInputData, inInputTime, _, _ in
                guard let self, let handler = self.handler, let rawFmt = self.rawFormat else { return }
                guard let raw = AVAudioPCMBuffer(pcmFormat: rawFmt,
                                                 bufferListNoCopy: inInputData),
                      let buffer = self.normalize(raw) else { return }
                self.measureRate(inInputTime.pointee)

                // Check the sample times run continuously. If this block does
                // not start where the last one ended, audio was already
                // dropped upstream of us.
                let start = inInputTime.pointee.mSampleTime
                if let previousEnd = self.lastEndSampleTime,
                   abs(start - previousEnd) > 0.5 {
                    self.discontinuityCount += 1
                }
                self.lastEndSampleTime = start + Float64(buffer.frameLength)

                handler(buffer)
            }
        }
        try ca("starting the aggregate device") { AudioDeviceStart(aggregateID, ioProcID) }
    }

    // MARK: - Stopping

    func stop() {
        stopListening()
        if let ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        handler = nil
        isRunning = false
        lastEndSampleTime = nil
    }
}

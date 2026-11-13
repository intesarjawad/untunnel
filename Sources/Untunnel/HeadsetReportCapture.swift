import AVFoundation
import AppKit
import Foundation
import UntunnelAudio
import UntunnelDSP

/// Captures on the existing HAL input and restore pipeline, without playing into speakers.
enum HeadsetReportCapture {
    static func record(
        model: LoadedModel,
        selection: @Sendable () -> DeviceSelection = {
            AudioDevices(source: CoreAudioDeviceSource()).snapshot.selection
        },
        capture: (String) throws -> any AudioCaptureSource = { try HALCaptureSource(uid: $0) },
        profile: () throws -> Data = BluetoothProfile.read,
        deviceLatency: (String, String) -> Double = {
            CoreAudioMicPathHardware().deviceLatencyMs(inputUID: $0, outputUID: $1)
        }
    ) throws -> HeadsetCapture {
        let chosen = selection()
        guard let input = chosen.input ?? chosen.headset else {
            throw UserFacingError.audioDeviceUnavailable("the microphone input")
        }
        guard let current = model.current, let tier = current.tier else {
            throw model.current?.failure ?? UserFacingError.modelMissing
        }
        let identity: HeadsetIdentity
        if input.transport == .builtIn {
            // Built-in Core Audio devices have no Bluetooth VID/PID; zero means unreported.
            identity = HeadsetIdentity(
                name: input.name, vendorID: "0x0000", productID: "0x0000", firmware: nil)
        } else if let found = BluetoothProfile.identity(named: input.name, in: try profile()) {
            identity = found
        } else {
            throw HeadsetReportError.headsetNotFound(input.name)
        }
        let source = try capture(input.uid)
        let rawRing = RingBuffer(capacity: source.format.sampleRate * ABTake.seconds)
        let outputUID = (chosen.headset ?? chosen.output)?.uid ?? input.uid
        let session = try MonitorCapture(
            source: source, model: current,
            deviceLatencyMs: deviceLatency(input.uid, outputUID), recordingRing: rawRing)
        defer { session.stop() }
        let tap = session.pipeline.monitorTap
        let duringCapture = selection()
        guard duringCapture.input?.uid == input.uid else {
            throw UserFacingError.audioDeviceUnavailable("the selected input changed; record again")
        }
        let outputRate = (duringCapture.headset ?? duringCapture.output)?.nominalSampleRate
        guard let outputRate, outputRate.isFinite, outputRate >= 8_000, outputRate <= 96_000 else {
            throw UserFacingError.audioDeviceUnavailable("the headset output rate")
        }
        let required = tier.sampleRate * ABTake.seconds
        var before: [Float] = []
        var after: [Float] = []
        before.reserveCapacity(required)
        after.reserveCapacity(required)
        var pairs = [Float](repeating: 0, count: session.pipeline.tierFramesPerHop * 2)
        let deadline = ContinuousClock.now + .seconds(ABTake.seconds + 5)
        while before.count < required, ContinuousClock.now < deadline {
            let count = pairs.withUnsafeMutableBufferPointer { tap.read(into: $0) } / 2
            for index in 0..<min(count, required - before.count) {
                before.append(pairs[index * 2])
                after.append(pairs[index * 2 + 1])
            }
            if count == 0 { Thread.sleep(forTimeInterval: 0.002) }
        }
        guard before.count == required else { throw HeadsetReportError.tooShort }
        guard tap.droppedFrames == 0, let latency = session.latency.addedLatencyMs else {
            throw UserFacingError.audioDeviceUnavailable("the capture dropped audio; record again")
        }
        var raw = [Float](repeating: 0, count: rawRing.capacity)
        let captured = raw.withUnsafeMutableBufferPointer { rawRing.read(into: $0) }
        guard captured == raw.count else { throw HeadsetReportError.tooShort }
        return HeadsetCapture(
            take: ABTake(sampleRate: tier.sampleRate, before: before, after: after),
            headsetName: input.name, inputRateHz: source.format.sampleRate,
            outputRateHz: Int(outputRate), tier: tier, addedLatencyMs: latency, identity: identity,
            rawInput: raw)
    }
}

@MainActor
final class HeadsetReportAppDelegate: NSObject, NSApplicationDelegate {
    var model: LoadedModel?
    private var recording = false

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            Task {
                do {
                    try await HeadsetReportHandler.handle(
                        url: url,
                        capture: { [self] in
                            try await record()
                        })
                } catch {
                    FileHandle.standardError.write(Data("\(error)\n".utf8))
                }
            }
        }
    }

    private func record() async throws -> HeadsetCapture {
        guard !recording else {
            throw UserFacingError.audioDeviceUnavailable("a headset report is already recording")
        }
        recording = true
        defer { recording = false }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            throw UserFacingError.permissionDenied("the microphone")
        }
        guard let model else { throw UserFacingError.modelMissing }
        let deadline = ContinuousClock.now + .seconds(HeadsetReportCommand.launchTimeout)
        while model.current == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        return try await Task.detached(priority: .userInitiated) {
            try HeadsetReportCapture.record(model: model)
        }.value
    }
}

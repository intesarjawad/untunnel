import Foundation
import Testing
import UntunnelDSP

private let tierRate = 16_000
private let deviceRate = 48_000
private let toneFrequency = 1_000.0
private let analysisLength = 1_024

@Test
func resamplerProducesTheRationalRatioOfFrames() {
    let input = sine(count: 480, sampleRate: Double(tierRate))

    let upsampled = resample(input, inputRate: tierRate, outputRate: deviceRate)
    #expect(upsampled.count == 1_440)

    let roundTrip = resample(upsampled, inputRate: deviceRate, outputRate: tierRate)
    #expect(roundTrip.count == 480)
}

@Test
func resamplerRoundTripKeepsDistortionBelowMinusEightyDecibels() {
    let input = sine(count: 16_000, sampleRate: Double(tierRate))
    let upsampled = resample(input, inputRate: tierRate, outputRate: deviceRate)
    let roundTrip = resample(upsampled, inputRate: deviceRate, outputRate: tierRate)

    let settled = Array(roundTrip.dropFirst(4_000).prefix(analysisLength))
    #expect(settled.count == analysisLength)

    let distortion = distortionToSignalDecibels(settled, toneBin: analysisLength / 16)
    #expect(distortion < -80)
}

@Test
func resamplerFillsTheRequestedFrameCountAndZeroPadsTheShortfall() {
    let input = [Float](repeating: 1, count: 16_000)
    let resampler = PolyphaseResampler(inputRate: 16_000, outputRate: 48_000)

    let output = resampler.resample(input, count: 50_000)

    #expect(output.count == 50_000)
    #expect(abs(output[47_999] - 1) < 0.001)
    #expect(output[49_999] == 0)
}

/// One second of a tone at `toneFrequency`.
private func sine(count: Int, sampleRate: Double) -> [Float] {
    (0..<count).map { index in
        Float(sin(2 * Double.pi * toneFrequency * Double(index) / sampleRate))
    }
}

private func resample(_ input: [Float], inputRate: Int, outputRate: Int) -> [Float] {
    let resampler = PolyphaseResampler(inputRate: inputRate, outputRate: outputRate)
    var output = [Float](repeating: 0, count: input.count * outputRate / inputRate)
    let produced = input.withUnsafeBufferPointer { source in
        output.withUnsafeMutableBufferPointer { destination in
            resampler.process(source, into: destination).produced
        }
    }
    return Array(output.prefix(produced))
}

/// Distortion plus noise relative to the tone, in decibels.
///
/// The window holds an integer number of tone cycles, so the tone occupies the bin at
/// `toneBin` and its mirror while every other bin counts as distortion. The transform is the
/// DFT definition itself, evaluated against a twiddle table, so the check depends on no
/// external library.
private func distortionToSignalDecibels(_ samples: [Float], toneBin: Int) -> Double {
    let count = samples.count
    let twiddles = (0..<count).map { index -> (cosine: Double, sine: Double) in
        let angle = -2 * Double.pi * Double(index) / Double(count)
        return (cos(angle), sin(angle))
    }

    var totalEnergy = 0.0
    var toneEnergy = 0.0
    for bin in 0..<count {
        var real = 0.0
        var imaginary = 0.0
        for index in 0..<count {
            let twiddle = twiddles[(bin * index) % count]
            let sample = Double(samples[index])
            real += sample * twiddle.cosine
            imaginary += sample * twiddle.sine
        }
        let energy = real * real + imaginary * imaginary
        totalEnergy += energy
        if bin == toneBin || bin == count - toneBin {
            toneEnergy += energy
        }
    }
    return 10 * log10((totalEnergy - toneEnergy) / toneEnergy)
}

@Test(arguments: ["process", "resample"])
func resamplerDocumentationDescribesItsOwnEntryPoint(method: String) throws {
    let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/UntunnelDSP/PolyphaseResampler.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let declaration = try #require(source.range(of: "    public func \(method)("))
    let documentation = source[..<declaration.lowerBound]
        .split(separator: "\n", omittingEmptySubsequences: false).dropLast().reversed()
        .prefix { $0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
        .joined(separator: "\n")
    let streaming = "Resamples from `input`"
    let wholeBuffer = "Resamples a whole buffer"
    #expect(documentation.contains(method == "process" ? streaming : wholeBuffer))
    #expect(!documentation.contains(method == "process" ? wholeBuffer : streaming))
}

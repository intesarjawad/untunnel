import Foundation
import Testing
import UntunnelKernels

@testable import UntunnelEngine

/// The argument is scaled by `log2(e)` in single precision before it is split, so the
/// relative error grows with the argument on top of the polynomial's own.
@Test
func theVectorExponentialMatchesTheLibraryToSinglePrecision() {
    let count = 16_384
    let values = Scratch(count: count)
    for index in 0..<count {
        values.pointer[index] = -87 + 175 * Float(index) / Float(count)
    }
    untunnel_exp(values.pointer, count)
    for index in 0..<count {
        let argument = Double(-87 + 175 * Float(index) / Float(count))
        let expected = exp(argument)
        let error = abs(Double(values.pointer[index]) - expected) / expected
        #expect(error < 4e-7 + 1e-7 * abs(argument), "exp(\(argument)) is off by \(error)")
    }
}

@Test
func theVectorExponentialClampsWhatSinglePrecisionCannotHold() {
    let values = Scratch(count: 16)
    values.pointer[0] = -1_000
    values.pointer[1] = 1_000
    untunnel_exp(values.pointer, 16)
    #expect(values.pointer[0] >= 0 && values.pointer[0] < 1e-37)
    #expect(values.pointer[1].isFinite)
    #expect(values.pointer[2] == 1)
}

@Test
func siluMatchesItsDefinition() {
    let count = 64
    let values = Scratch(count: count)
    for index in 0..<count {
        values.pointer[index] = Float(index - 32) * 0.61
    }
    untunnel_silu(values.pointer, count)
    for index in 0..<count {
        let x = Double(index - 32) * 0.61
        #expect(abs(Double(values.pointer[index]) - x / (1 + exp(-x))) < 2e-6)
    }
}

@Test
func layerNormalisationMatchesItsDefinition() {
    let width = 32
    let rows = 3
    let values = Scratch(count: rows * width)
    let scale = Scratch(count: width)
    let shift = Scratch(count: width)
    for index in 0..<(rows * width) {
        values.pointer[index] = Float((index * 37) % 23) * 0.31 - 2
    }
    for index in 0..<width {
        scale.pointer[index] = 0.5 + Float(index) * 0.03
        shift.pointer[index] = Float(index % 5) * 0.2 - 0.4
    }
    let original = values.values
    untunnel_layer_norm(values.pointer, scale.pointer, shift.pointer, 1e-5, width, rows)

    for row in 0..<rows {
        let channels = original[(row * width)..<((row + 1) * width)].map(Double.init)
        let mean = channels.reduce(0, +) / Double(width)
        let variance = channels.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(width)
        for index in 0..<width {
            let expected =
                (channels[index] - mean) / (variance + 1e-5).squareRoot()
                * Double(scale.pointer[index]) + Double(shift.pointer[index])
            #expect(abs(Double(values.pointer[row * width + index]) - expected) < 1e-5)
        }
    }
}

@Test
func preluScalesOnlyTheNegativePart() {
    let values = Scratch(copying: [-2, -0.5, 0, 3])
    let slopeBelowUnity = Scratch(copying: [-0.75, 0, 1, 5])
    untunnel_prelu(values.pointer, slopeBelowUnity.pointer, 4, 1)
    #expect(values.values == [-0.5, -0.5, 0, 3])
}

/// Rows, depth and columns on both sides of a vector's length, and the widest layer the
/// model has.
private let productShapes: [[Int]] = [
    [1, 1, 1], [5, 7, 1], [17, 4, 256], [33, 100, 47], [16, 256, 36], [40, 64, 512],
    [21, 2_304, 64],
]

private typealias Product = (
    UnsafePointer<Float>?, Int, UnsafePointer<Float>?, Int, UnsafeMutablePointer<Float>?, Int,
    Int, Int, Bool
) -> Void

/// Runs `product` on windows into wider rows and returns the whole output, margins included.
private func product(
    _ product: Product, shape: [Int], accumulate: Bool, seed: UInt64
) -> (output: [Float], expected: [Float]) {
    let (rows, depth, columns) = (shape[0], shape[1], shape[2])
    let aStride = depth + 3
    let outStride = columns + 5
    var random = ModelRandom(seed: seed)
    let a = random.values(count: rows * aStride, limit: 1)
    let b = random.values(count: depth * columns, limit: 1)
    let initial = random.values(count: rows * outStride, limit: 1)

    var output = initial
    product(a, aStride, b, columns, &output, outStride, rows, depth, accumulate)

    // The sum over the depth in order, one fused multiply-add per term.
    var expected = initial
    for row in 0..<rows {
        for column in 0..<columns {
            var sum = accumulate ? initial[row * outStride + column] : 0
            for index in 0..<depth {
                sum = sum.addingProduct(a[row * aStride + index], b[index * columns + column])
            }
            expected[row * outStride + column] = sum
        }
    }
    return (output, expected)
}

@Test(arguments: productShapes, [false, true])
func theMatrixProductIsTheOrderedFusedSum(shape: [Int], accumulate: Bool) {
    let result = product(untunnel_matmul, shape: shape, accumulate: accumulate, seed: 0x3A7)
    #expect(result.output == result.expected)
}

/// Machines without a matrix unit run this one, so it is held to the same sums.
@Test(arguments: productShapes, [false, true])
func thePortableMatrixProductIsTheSameSum(shape: [Int], accumulate: Bool) {
    let result = product(
        untunnel_matmul_portable, shape: shape, accumulate: accumulate, seed: 0x3A8)
    #expect(result.output == result.expected)
}

import Foundation

/// The DPI values a mouse sensor accepts, from HID++ 0x2201 getSensorDpiList.
/// The list is big-endian 16-bit values ending in 0. A value with the top three
/// bits set (0xE000) is a step: every `step` DPI from the previous value to the next.
public struct DPIList: Equatable {
    public var values: [Int] = []
    public var ranges: [(min: Int, max: Int, step: Int)] = []

    public static func == (a: DPIList, b: DPIList) -> Bool {
        a.values == b.values && a.ranges.elementsEqual(b.ranges) { $0 == $1 }
    }

    /// `bytes`: the reply parameters after the sensor index.
    public init(bytes: [UInt8]) {
        var words: [Int] = []
        for i in stride(from: 0, to: bytes.count - 1, by: 2) {
            let word = Int(bytes[i]) << 8 | Int(bytes[i + 1])
            if word == 0 { break }
            words.append(word)
        }
        var i = 0
        while i < words.count {
            let word = words[i]
            if word & 0xE000 == 0xE000, let low = values.popLast(), i + 1 < words.count {
                ranges.append((low, words[i + 1], word & 0x1FFF))
                i += 2
            } else {
                values.append(word)
                i += 1
            }
        }
    }

    public var minimum: Int? { (values + ranges.map(\.min)).min() }
    public var maximum: Int? { (values + ranges.map(\.max)).max() }

    /// The accepted DPI closest to `wanted`.
    public func nearest(to wanted: Int) -> Int? {
        var candidates = values
        for range in ranges where range.step > 0 {
            let clamped = Swift.min(Swift.max(wanted, range.min), range.max)
            let snapped = range.min + Int((Double(clamped - range.min) / Double(range.step)).rounded()) * range.step
            candidates.append(Swift.min(snapped, range.max))
        }
        return candidates.min { abs($0 - wanted) < abs($1 - wanted) }
    }
}

extension Device {
    /// Current and factory-default DPI of the first sensor.
    public func sensorDPI() throws -> (current: Int, defaultDPI: Int) {
        let reply = try call(HIDPP.Feature.adjustableDPI, 2, [0])
        return (Int(reply[1]) << 8 | Int(reply[2]), Int(reply[3]) << 8 | Int(reply[4]))
    }

    public func sensorDPIList() throws -> DPIList {
        DPIList(bytes: Array(try call(HIDPP.Feature.adjustableDPI, 1, [0]).dropFirst()))
    }

    /// Sets the nearest DPI the sensor accepts; returns what was set.
    @discardableResult
    public func setSensorDPI(_ wanted: Int) throws -> Int {
        let dpi = (try? sensorDPIList().nearest(to: wanted)) ?? wanted
        try call(HIDPP.Feature.adjustableDPI, 3, [0, UInt8(dpi >> 8), UInt8(dpi & 0xFF)])
        return dpi
    }
}

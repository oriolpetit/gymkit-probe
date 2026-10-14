import Foundation

/// Decoded FTMS Indoor Bike Data (0x2AD2) notification.
struct IndoorBikeData {
    var flags: UInt16
    var speedKmh: Double?
    var averageSpeedKmh: Double?
    var cadenceRpm: Double?
    var averageCadenceRpm: Double?
    var distanceM: Int?
    var resistance: Int?
    var powerW: Int?
    var averagePowerW: Int?
    var energyKcal: Int?
    var heartRate: Int?
    var elapsedS: Int?
    /// True when instantaneous cadence was present without its flag bit set.
    var cadenceFlagQuirk = false

    static func parse(_ data: Data) -> IndoorBikeData? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        let flags = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        func has(_ bit: Int) -> Bool { flags & (1 << bit) != 0 }

        // The Life Fitness Discover SE4 sends flags 0x09FA (bit 2 clear) but still
        // includes the instantaneous cadence field, so trust the length over the flag.
        var cadencePresent = has(2)
        var quirk = false
        if !cadencePresent && bytes.count == expectedLength(flags: flags, forceCadence: true) {
            cadencePresent = true
            quirk = true
        }

        var result = IndoorBikeData(flags: flags)
        result.cadenceFlagQuirk = quirk
        var offset = 2

        func u8() -> Int? {
            guard offset + 1 <= bytes.count else { return nil }
            defer { offset += 1 }
            return Int(bytes[offset])
        }
        func u16() -> Int? {
            guard offset + 2 <= bytes.count else { return nil }
            defer { offset += 2 }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        func s16() -> Int? {
            guard let value = u16() else { return nil }
            return value >= 0x8000 ? value - 0x10000 : value
        }
        func u24() -> Int? {
            guard offset + 3 <= bytes.count else { return nil }
            defer { offset += 3 }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16
        }

        // Bit 0 is "More Data": the instantaneous speed is present when it is clear.
        if !has(0) { result.speedKmh = u16().map { Double($0) / 100 } }
        if has(1) { result.averageSpeedKmh = u16().map { Double($0) / 100 } }
        if cadencePresent { result.cadenceRpm = u16().map { Double($0) / 2 } }
        if has(3) { result.averageCadenceRpm = u16().map { Double($0) / 2 } }
        if has(4) { result.distanceM = u24() }
        if has(5) { result.resistance = s16() }
        if has(6) { result.powerW = s16() }
        if has(7) { result.averagePowerW = s16() }
        if has(8) {
            result.energyKcal = u16()
            _ = u16() // energy per hour
            _ = u8()  // energy per minute
        }
        if has(9) { result.heartRate = u8() }
        if has(10) { _ = u8() } // metabolic equivalent
        if has(11) { result.elapsedS = u16() }
        return result
    }

    static func expectedLength(flags: UInt16, forceCadence: Bool) -> Int {
        func has(_ bit: Int) -> Bool { flags & (1 << bit) != 0 }
        var length = 2
        if !has(0) { length += 2 }
        if has(1) { length += 2 }
        if has(2) || forceCadence { length += 2 }
        if has(3) { length += 2 }
        if has(4) { length += 3 }
        if has(5) { length += 2 }
        if has(6) { length += 2 }
        if has(7) { length += 2 }
        if has(8) { length += 5 }
        if has(9) { length += 1 }
        if has(10) { length += 1 }
        if has(11) { length += 2 }
        if has(12) { length += 2 }
        return length
    }

    var summary: String {
        func decimal(_ value: Double?, _ unit: String) -> String { value.map { String(format: "%.1f", $0) + unit } ?? "-" }
        func whole(_ value: Int?, _ unit: String) -> String { value.map { "\($0)\(unit)" } ?? "-" }
        return "power \(whole(powerW, "W")) cadence \(decimal(cadenceRpm, "rpm")) speed \(decimal(speedKmh, "km/h")) "
            + "dist \(whole(distanceM, "m")) res \(whole(resistance, "")) t \(whole(elapsedS, "s"))"
            + (cadenceFlagQuirk ? " [cadence-flag quirk]" : "")
    }
}

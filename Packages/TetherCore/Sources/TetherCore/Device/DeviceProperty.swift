import Foundation

/// Abstract camera settings. Vendor handlers map these to their own PTP
/// property codes (`tsProp2PtpProp`) and format raw values for display.
public enum TetherProperty: String, Codable, Sendable, CaseIterable, Identifiable {
    case aperture, shutterSpeed, iso, exposureCompensation, whiteBalance, colorTemperature
    case exposureProgram, driveMode, meteringMode, focusMode, imageQuality, imageSize
    case captureDestination, batteryLevel, liveViewEnabled, flashMode, pictureStyle
    case storageFreeImages, lensName, shutterCount

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .aperture: return "Aperture"
        case .shutterSpeed: return "Shutter"
        case .iso: return "ISO"
        case .exposureCompensation: return "Exp. comp."
        case .whiteBalance: return "White balance"
        case .colorTemperature: return "Color temp."
        case .exposureProgram: return "Mode"
        case .driveMode: return "Drive"
        case .meteringMode: return "Metering"
        case .focusMode: return "Focus"
        case .imageQuality: return "Quality"
        case .imageSize: return "Size"
        case .captureDestination: return "Destination"
        case .batteryLevel: return "Battery"
        case .liveViewEnabled: return "Live view"
        case .flashMode: return "Flash"
        case .pictureStyle: return "Picture style"
        case .storageFreeImages: return "Shots left"
        case .lensName: return "Lens"
        case .shutterCount: return "Shutter count"
        }
    }

    /// The settings bar on the shoot screen shows these, in this order.
    public static let exposureBar: [TetherProperty] = [.shutterSpeed, .aperture, .iso, .exposureCompensation, .whiteBalance]
}

/// A readable (and maybe writable) property with its allowed values.
public struct PropertyDescriptor: Equatable, Sendable, Identifiable {
    public enum Form: Equatable, Sendable {
        /// Pick one of the listed choices.
        case choices([PropertyChoice])
        /// Numeric range.
        case range(min: Double, max: Double, step: Double)
        /// Read-only or free-form.
        case other
    }

    public var property: TetherProperty
    public var raw: PTPValue
    public var display: String
    public var isWritable: Bool
    public var form: Form

    public init(property: TetherProperty, raw: PTPValue, display: String, isWritable: Bool, form: Form) {
        self.property = property
        self.raw = raw
        self.display = display
        self.isWritable = isWritable
        self.form = form
    }

    public var id: TetherProperty { property }

    public var choices: [PropertyChoice] {
        if case .choices(let c) = form { return c }
        return []
    }

    public var currentChoiceIndex: Int? { choices.firstIndex { $0.raw == raw } }
}

public struct PropertyChoice: Equatable, Hashable, Sendable, Identifiable {
    public var raw: PTPValue
    public var display: String
    public init(raw: PTPValue, display: String) {
        self.raw = raw
        self.display = display
    }
    public var id: PTPValue { raw }
}

/// Shared formatters for the values every vendor encodes similarly.
public enum PropertyFormat {
    /// PTP FNumber is f-stop × 100.
    public static func aperture(hundredths v: Int64) -> String {
        let f = Double(v) / 100
        return f == f.rounded() ? String(format: "ƒ/%.0f", f) : String(format: "ƒ/%.1f", f)
    }

    /// PTP ExposureTime is seconds × 10 000.
    public static func shutter(tenThousandths v: Int64) -> String {
        shutter(seconds: Double(v) / 10_000)
    }

    public static func shutter(seconds s: Double) -> String {
        if s <= 0 { return "Bulb" }
        if s >= 0.3 {
            return s == s.rounded() ? String(format: "%.0f\"", s) : String(format: "%.1f\"", s)
        }
        let denom = (1 / s).rounded()
        return "1/\(Int(denom))"
    }

    /// Fraction given as numerator/denominator (Nikon, Sony encode this way).
    public static func shutter(numerator n: Int64, denominator d: Int64) -> String {
        guard d != 0 else { return "Bulb" }
        if n >= d { return shutter(seconds: Double(n) / Double(d)) }
        return "1/\(d / max(n, 1))"
    }

    /// PTP ExposureBiasCompensation is in 1/1000 EV.
    public static func exposureCompensation(thousandths v: Int64) -> String {
        let ev = Double(v) / 1000
        if ev == 0 { return "0" }
        return String(format: "%+.1f", ev).replacingOccurrences(of: ".0", with: "")
    }

    public static func iso(_ v: Int64) -> String {
        if v == 0xFFFF || v == 0xFFFFFF || v == 0xFFFFFFFF { return "Auto" }
        return "\(v)"
    }

    public static func whiteBalance(standard v: Int64) -> String {
        switch v {
        case 1: return "Manual"
        case 2: return "Auto"
        case 3: return "One-push auto"
        case 4: return "Daylight"
        case 5: return "Fluorescent"
        case 6: return "Tungsten"
        case 7: return "Flash"
        default: return "WB \(v)"
        }
    }

    public static func battery(percent v: Int64) -> String { "\(max(0, min(100, v)))%" }
}

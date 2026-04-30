import Foundation

// Piecewise-linear fan curve: a sorted list of (temperature, RPM) pivots.
// Below the lowest pivot, the curve resolves to .auto so the firmware takes
// over. Above the highest pivot, the curve pins to the highest pivot's RPM.

struct FanCurve {
    struct Pivot {
        let temp: Double
        let rpm: Double
    }

    enum Target: Equatable {
        case auto
        case rpm(Double)
    }

    enum ParseError: Error, CustomStringConvertible {
        case empty
        case malformed(String)
        case badNumber(String)

        var description: String {
            switch self {
            case .empty: return "Curve has no pivots."
            case .malformed(let p): return "Malformed pivot \"\(p)\". Expected \"<temp>:<rpm>\"."
            case .badNumber(let n): return "Could not parse \"\(n)\" as a number."
            }
        }
    }

    let pivots: [Pivot]

    func evaluate(temp: Double) -> Target {
        guard let first = pivots.first else { return .auto }
        if temp < first.temp { return .auto }
        for i in 1..<pivots.count where temp <= pivots[i].temp {
            let lo = pivots[i - 1]
            let hi = pivots[i]
            let frac = (temp - lo.temp) / (hi.temp - lo.temp)
            return .rpm(lo.rpm + frac * (hi.rpm - lo.rpm))
        }
        return .rpm(pivots.last!.rpm)
    }

    /// Parse a spec like `"50:2500,65:4500,80:max"`. The `max` token resolves
    /// to `maxRPM`, normally the fan's `F0Mx` reading.
    static func parse(_ spec: String, maxRPM: Double) throws -> FanCurve {
        var pivots: [Pivot] = []
        for part in spec.split(separator: ",") {
            let pair = part.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { throw ParseError.malformed(String(part)) }
            let tempStr = pair[0].trimmingCharacters(in: .whitespaces)
            let rpmStr = pair[1].trimmingCharacters(in: .whitespaces)
            guard let temp = Double(tempStr) else { throw ParseError.badNumber(tempStr) }
            let rpm: Double
            if rpmStr == "max" {
                rpm = maxRPM
            } else if let n = Double(rpmStr) {
                rpm = n
            } else {
                throw ParseError.badNumber(rpmStr)
            }
            pivots.append(Pivot(temp: temp, rpm: rpm))
        }
        guard !pivots.isEmpty else { throw ParseError.empty }
        pivots.sort { $0.temp < $1.temp }
        return FanCurve(pivots: pivots)
    }
}

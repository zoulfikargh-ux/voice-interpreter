import Foundation

/// Rough fundamental-frequency estimate used to guess male/female voice.
enum Pitch {
    static let femaleThreshold: Float = 165

    static func median(_ x: [Float], sampleRate sr: Double) -> Float? {
        let factor = max(1, Int((sr / 16000).rounded()))
        let rate = Float(sr) / Float(factor)

        var d = [Float]()
        d.reserveCapacity(x.count / factor + 1)
        var i = 0
        while i + factor <= x.count {
            var s: Float = 0
            for k in 0..<factor { s += x[i + k] }
            d.append(s / Float(factor))
            i += factor
        }

        let frame = Int(rate * 0.04)
        let hop = Int(rate * 0.03)
        let minLag = Int(rate / 400)
        let maxLag = Int(rate / 70)
        guard frame > 0, hop > 0, minLag > 1, maxLag > minLag + 2,
              d.count > frame + maxLag + hop else { return nil }

        let limit = min(d.count - frame - maxLag - 1, Int(rate * 8))
        var f0s = [Float]()
        var start = 0
        var nc = [Float](repeating: 0, count: maxLag + 2)

        while start < limit {
            var e: Float = 0
            for k in 0..<frame { e += d[start + k] * d[start + k] }

            if e / Float(frame) > 1e-4 {
                var best: Float = 0
                for lag in minLag...maxLag {
                    var c: Float = 0
                    var e2: Float = 0
                    for k in 0..<frame {
                        let b = d[start + k + lag]
                        c += d[start + k] * b
                        e2 += b * b
                    }
                    let v = c / (e * e2 + 1e-9).squareRoot()
                    nc[lag] = v
                    if v > best { best = v }
                }
                if best > 0.55 {
                    var chosen = 0
                    for lag in (minLag + 1)..<maxLag {
                        if nc[lag] >= 0.9 * best && nc[lag] >= nc[lag - 1] && nc[lag] >= nc[lag + 1] {
                            chosen = lag
                            break
                        }
                    }
                    if chosen > 0 { f0s.append(rate / Float(chosen)) }
                }
            }
            start += hop
        }

        guard f0s.count >= 5 else { return nil }
        f0s.sort()
        return f0s[f0s.count / 2]
    }
}

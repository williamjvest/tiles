/// An FX5's recording bit rate. The camera shows it ([Project] → [Rec Format] → [Bit Rate]) but doesn't report it: its
/// list has neither Recording Setting (Movie) 0xD242 nor Video Rec Format Bitrate Setting 0xE067
/// (fixtures/fx5-dump-2026-11-14.txt), which would leave the Bit Rate tile empty beside the codec. It
/// follows from the project frame rate, the codec, the video format and [Quality] (High, Mid, Low; not reported
/// either, nor Video Rec Format Quality 0xE0B5), by the table in Sony's Help Guide, "[Video Format] / [Quality] /
/// [Bit Rate] Settings" (helpguide.sony.net/ilc/2630/v1/en/contents/video_quality_setting.html). Where Quality makes a
/// difference, the range. X-OCN isn't in the table: nothing.
enum FX5BitRate {
    /// Mbps at High, Mid and Low, by "<project rate> <codec> <video format>" (the codec as `fileFormatNames` has it).
    static let table: [String: [Int]] = {
        var rows: [String: [Int]] = [:]
        func add(_ rates: [String], _ codec: String, _ format: String, _ mbps: [Int]) {
            for rate in rates { rows["\(rate) \(codec) \(format)"] = mbps.count == 1 ? [mbps[0], mbps[0], mbps[0]] : mbps }
        }
        let uhd = "3840x2160", dci = "4096x2160", hd = "1920x1080"
        add(["119.88", "100"], "XAVC HS-L 422", uhd, [280])
        add(["119.88", "100"], "XAVC HS-L 420", uhd, [200])
        add(["119.88", "100"], "XAVC S-L 422", uhd, [280])
        add(["119.88", "100"], "XAVC S-L 420", uhd, [200])
        add(["119.88", "100"], "XAVC S-L 420", hd, [100, 60, 60])
        add(["59.94", "50"], "XAVC HS-L 422", uhd, [200, 100, 100])
        add(["59.94", "50"], "XAVC HS-L 420", uhd, [150, 75, 45])
        add(["59.94"], "XAVC S-I 422", dci, [600])
        add(["59.94"], "XAVC S-I 422", uhd, [600])
        add(["59.94"], "XAVC S-I 422", hd, [222])
        add(["50"], "XAVC S-I 422", dci, [500])
        add(["50"], "XAVC S-I 422", uhd, [500])
        add(["50"], "XAVC S-I 422", hd, [185])
        add(["59.94", "50"], "XAVC S-L 422", uhd, [200])
        add(["59.94", "50"], "XAVC S-L 422", hd, [50])
        add(["59.94", "50"], "XAVC S-L 420", uhd, [150])
        add(["59.94", "50"], "XAVC S-L 420", hd, [50, 25, 25])
        add(["29.97"], "XAVC S-I 422", dci, [300])
        add(["29.97"], "XAVC S-I 422", uhd, [300])
        add(["29.97"], "XAVC S-I 422", hd, [111])
        add(["25"], "XAVC S-I 422", dci, [250])
        add(["25"], "XAVC S-I 422", uhd, [250])
        add(["25"], "XAVC S-I 422", hd, [93])
        add(["29.97", "25"], "XAVC S-L 422", uhd, [140])
        add(["29.97", "25"], "XAVC S-L 422", hd, [50])
        add(["29.97", "25"], "XAVC S-L 420", uhd, [100, 60, 60])
        add(["29.97", "25"], "XAVC S-L 420", hd, [50, 16, 16])
        add(["24"], "XAVC S-I 422", dci, [240])
        add(["23.98"], "XAVC HS-L 422", uhd, [100, 50, 50])
        add(["23.98"], "XAVC HS-L 420", uhd, [100, 50, 30])
        add(["23.98"], "XAVC S-I 422", dci, [240])
        add(["23.98"], "XAVC S-I 422", uhd, [240])
        add(["23.98"], "XAVC S-I 422", hd, [89])
        add(["23.98"], "XAVC S-L 422", uhd, [100])
        add(["23.98"], "XAVC S-L 422", hd, [50])
        add(["23.98"], "XAVC S-L 420", uhd, [100, 60, 60])
        add(["23.98"], "XAVC S-L 420", hd, [50])
        return rows
    }()

    /// The project rate as the table names it: 23.98, 24, 25, 29.97, 50, 59.94, 100, 119.88.
    static func rateKey(_ fps: Double) -> String {
        let hundredths = (fps * 100).rounded() / 100
        if abs(hundredths - 23.98) < 0.01 { return "23.98" }
        return hundredths == hundredths.rounded() ? String(Int(hundredths)) : String(format: "%.2f", hundredths)
    }

    /// "100 Mbps", or "60–100 Mbps" where Quality makes the difference; nil for what the table hasn't got.
    static func label(fps: Double, codec: String, format: String) -> String? {
        guard let mbps = table["\(rateKey(fps)) \(codec) \(format)"], let low = mbps.min(), let high = mbps.max() else {
            return nil
        }
        return low == high ? "\(high) Mbps" : "\(low)–\(high) Mbps"
    }
}

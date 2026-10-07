import Foundation

enum DashboardChart {
    static func bars(samples: [DashboardSample], metric: DashboardMetric, width: Int, height: Int) -> TerminalScreen {
        var screen = TerminalScreen(width: width, height: height)
        let tail = Array(samples.suffix(screen.width))
        let start = screen.width - tail.count
        let glyphs = Array(" ▁▂▃▄▅▆▇█")
        for (index, sample) in tail.enumerated() {
            guard let value = sample.values[metric], value.isFinite else { continue }
            let units = Int((max(0, min(1, value / metric.ceiling)) * Double(screen.height * 8)).rounded())
            for row in 0..<screen.height {
                let level = max(0, min(8, units - row * 8))
                let glyph = level == 0 && row == 0 ? "·" : String(glyphs[level])
                screen.put(
                    glyph, x: start + index, y: screen.height - 1 - row,
                    style: .init(tone: sample.tones[metric] ?? .muted))
            }
        }
        return screen
    }
}

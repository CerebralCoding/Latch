import Foundation

enum DashboardTone: Int, Equatable {
    case normal = 252
    case muted = 244
    case accent = 81
    case good = 114
    case warning = 221
    case critical = 203
}

struct TerminalStyle: Equatable {
    var tone: DashboardTone = .normal
    var bold = false
    var selected = false
}

enum TerminalText {
    static func safe(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 10: result += "\\n"
            case 13: result += "\\r"
            case 9: result += "    "
            case 0...31, 127...159, 0x2028...0x202E, 0x2066...0x2069:
                result += "\\u{\(String(scalar.value, radix: 16))}"
            default:
                if scalar.properties.generalCategory == .format, scalar.value != 0x200D {
                    result += "\\u{\(String(scalar.value, radix: 16))}"
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result.map { character in
            if character.unicodeScalars.allSatisfy({
                [.nonspacingMark, .enclosingMark, .spacingMark, .format].contains($0.properties.generalCategory)
            }) {
                return character.unicodeScalars.map { "\\u{\(String($0.value, radix: 16))}" }.joined()
            }
            return String(character)
        }.joined()
    }

    static func width(_ character: Character) -> Int {
        let scalars = character.unicodeScalars
        if scalars.contains(where: {
            let v = $0.value
            return $0.properties.isEmojiPresentation || v == 0xFE0F || (0x1100...0x115F).contains(v)
                || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
                || (0xF900...0xFAFF).contains(v) || (0xFE10...0xFE6F).contains(v)
                || (0xFF01...0xFF60).contains(v) || (0xFFE0...0xFFE6).contains(v)
                || (0x20000...0x3FFFD).contains(v)
        }) {
            return 2
        }
        return 1
    }

    static func fit(_ text: String, width: Int) -> String {
        guard width > 0 else { return "" }
        var result = ""
        var used = 0
        for character in safe(text) {
            let size = self.width(character)
            if used + size > width { break }
            result.append(character)
            used += size
        }
        return result + String(repeating: " ", count: width - used)
    }

    static func wrap(_ text: String, width: Int) -> [String] {
        guard width > 0 else { return [] }
        var lines: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = ""
            var used = 0
            for character in safe(String(paragraph)) {
                let size = self.width(character)
                if used + size > width {
                    if let space = line.lastIndex(of: " "), line.distance(from: line.startIndex, to: space) > width / 2
                    {
                        lines.append(String(line[..<space]))
                        line = String(line[line.index(after: space)...])
                        used = line.reduce(0) { $0 + self.width($1) }
                    } else {
                        lines.append(line)
                        line = ""
                        used = 0
                    }
                }
                if size <= width {
                    line.append(character)
                    used += size
                }
            }
            lines.append(line)
        }
        return lines
    }
}

struct TerminalScreen: Equatable {
    struct Cell: Equatable {
        var text = " "
        var style = TerminalStyle()
    }

    let width: Int
    let height: Int
    private(set) var cells: [[Cell]]

    init(width: Int, height: Int) {
        self.width = max(1, min(500, width))
        self.height = max(1, min(200, height))
        cells = Array(repeating: Array(repeating: Cell(), count: self.width), count: self.height)
    }

    mutating func put(_ text: String, x: Int, y: Int, width limit: Int? = nil, style: TerminalStyle = .init()) {
        guard y >= 0, y < height, x >= 0, x < width else { return }
        let end = min(width, x + max(0, limit ?? width))
        var column = x
        for character in TerminalText.safe(text) {
            let size = TerminalText.width(character)
            guard column + size <= end else { break }
            // Erase both halves when overwriting a wide glyph.
            for target in column..<(column + size) {
                if cells[y][target].text.isEmpty, target > 0 { cells[y][target - 1] = Cell() }
                if target + 1 < width, cells[y][target + 1].text.isEmpty { cells[y][target + 1] = Cell() }
                cells[y][target] = Cell()
            }
            cells[y][column] = Cell(text: String(character), style: style)
            if size == 2 { cells[y][column + 1] = Cell(text: "", style: style) }
            column += size
        }
    }

    mutating func fill(y: Int, style: TerminalStyle) {
        guard cells.indices.contains(y) else { return }
        cells[y] = Array(repeating: Cell(style: style), count: width)
    }

    mutating func overlay(_ content: TerminalScreen, x: Int, y: Int) {
        for (row, cells) in content.cells.enumerated() {
            put(String(repeating: " ", count: content.width), x: x, y: y + row)
            for (column, cell) in cells.enumerated() where !cell.text.isEmpty {
                put(cell.text, x: x + column, y: y + row, style: cell.style)
            }
        }
    }

    mutating func box(x: Int, y: Int, width: Int, height: Int, title: String, tone: DashboardTone = .muted) {
        guard width >= 4, height >= 3 else { return }
        let style = TerminalStyle(tone: tone)
        put("┌" + String(repeating: "─", count: width - 2) + "┐", x: x, y: y, style: style)
        for row in (y + 1)..<(y + height - 1) {
            put("│", x: x, y: row, style: style)
            put("│", x: x + width - 1, y: row, style: style)
        }
        put("└" + String(repeating: "─", count: width - 2) + "┘", x: x, y: y + height - 1, style: style)
        put(" \(title) ", x: x + 2, y: y, width: width - 4, style: TerminalStyle(tone: tone, bold: true))
    }

    var plain: String { cells.map { $0.map(\.text).joined() }.joined(separator: "\n") }

    func ansi(previous: TerminalScreen?, color: Bool) -> String {
        let sameSize = previous?.width == width && previous?.height == height
        var result = sameSize ? "" : "\u{1B}[2J"
        for y in 0..<height {
            if sameSize, previous?.cells[y] == cells[y] { continue }
            result += "\u{1B}[\(y + 1);1H\u{1B}[0m"
            var current = TerminalStyle()
            for cell in cells[y] where !cell.text.isEmpty {
                if cell.style != current {
                    current = cell.style
                    result += "\u{1B}[0m"
                    if color { result += "\u{1B}[38;5;\(current.tone.rawValue)m" }
                    if current.bold { result += "\u{1B}[1m" }
                    if current.selected { result += "\u{1B}[7m" }
                }
                result += cell.text
            }
            result += "\u{1B}[0m\u{1B}[K"
        }
        return result
    }
}

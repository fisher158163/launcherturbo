import Foundation
import Darwin
import Darwin.ncurses

final class CursesSession {
    private let window: OpaquePointer
    private var statusLine: String?
    private var footer: String?
    private var progress: ProgressState?
    var title: String = "LaunchNext Updater"

    private struct ProgressState {
        var label: String
        var current: Int
        var total: Int?
    }

    init?() {
        setlocale(LC_ALL, "")
        guard let screen = initscr() else { return nil }
        window = screen
        keypad(window, true)
        noecho()
        cbreak()
        nodelay(window, false)
        curs_set(0)
        if has_colors() {
            start_color()
            use_default_colors()
            init_pair(1, Int16(COLOR_WHITE), -1)
        }
    }

    deinit {
        endwin()
    }

    func close() {
        endwin()
    }

    private func write(_ y: Int32, _ x: Int32, _ text: String, highlight: Bool = false) {
        if highlight { wstandout(window) }
        _ = text.withCString { mvwaddstr(window, y, x, $0) }
        if highlight { wstandend(window) }
    }

    private func refreshWindow() {
        werase(window)
        let width = Int(getmaxx(window))
        write(0, 2, title)
        var row = 2
        if let status = statusLine {
            for line in wrap(status, width: max(1, width - 4)) {
                write(Int32(row), 2, line)
                row += 1
            }
        }
        if let progress = progress {
            let current = progress.current
            let ratio = (progress.total.map { Double(current) / Double(max($0, 1)) } ?? 0.0).clamped(to: 0.0...1.0)
            let percent = Int(ratio * 100)
            let info: String
            if let total = progress.total, total > 0 {
                info = String(format: "%@ %3d%% (%0.1f/%0.1f MB)", progress.label, percent, Double(current) / 1_048_576.0, Double(total) / 1_048_576.0)
            } else {
                info = String(format: "%@ %0.1f MB", progress.label, Double(current) / 1_048_576.0)
            }
            write(Int32(row), 2, info)
            row += 1
            drawProgressBar(row: row, width: max(10, width - 4), ratio: ratio)
            row += 1
        }
        if let footer = footer {
            let height = Int(getmaxy(window))
            write(Int32(height - 2), 2, footer)
        }
        wrefresh(window)
    }

    private func drawProgressBar(row: Int, width: Int, ratio: Double) {
        let filled = Int(Double(width) * ratio)
        let full = String(repeating: "█", count: max(0, min(width, filled)))
        let empty = String(repeating: " ", count: max(0, width - filled))
        write(Int32(row), 2, full + empty, highlight: true)
    }

    func log(_ line: String) {
        statusLine = line
        refreshWindow()
    }

    func updateProgress(label: String, current: Int, total: Int?) {
        progress = ProgressState(label: label, current: current, total: total)
        refreshWindow()
    }

    func clearProgress() {
        progress = nil
        refreshWindow()
    }

    func waitForExit(prompt: String) {
        footer = prompt
        refreshWindow()
        _ = wgetch(window)
        footer = nil
        refreshWindow()
    }

    func pauseForExternal() {
        def_prog_mode()
        endwin()
    }

    func resumeAfterExternal() {
        reset_prog_mode()
        refreshWindow()
    }

    func promptYesNo(message: String, defaultYes: Bool, yesLabel: String, noLabel: String, hint: String?) -> Bool {
        var selection = defaultYes ? 0 : 1
        let choices: [(Bool, String)] = [(true, yesLabel), (false, noLabel)]

        while true {
            werase(window)
            let width = Int(getmaxx(window))
            var row = 2
            for line in wrap(message, width: max(1, width - 4)) {
                write(Int32(row), 2, line)
                row += 1
            }
            if let hint = hint {
                write(Int32(row + 1), 2, hint)
            }
            row += 3
            var col: Int32 = 4
            for (index, option) in choices.enumerated() {
                let block = "[ \(option.1) ]"
                write(Int32(row), col, block, highlight: index == selection)
                col += Int32(block.count + 2)
            }
            wrefresh(window)

            let key = wgetch(window)
            switch Int32(key) {
            case KEY_LEFT, Int32(Character("h").asciiValue ?? 0), Int32(Character("H").asciiValue ?? 0):
                selection = (selection - 1 + choices.count) % choices.count
            case KEY_RIGHT, Int32(Character("l").asciiValue ?? 0), Int32(Character("L").asciiValue ?? 0):
                selection = (selection + 1) % choices.count
            case 10, 13, KEY_ENTER, 27:
                return choices[selection].0
            default:
                continue
            }
        }
    }

    func selectIndex(titleLines: [String], options: [String], hint: String?, initialIndex: Int = 0) -> Int {
        var index = max(0, min(initialIndex, options.count - 1))
        while true {
            werase(window)
            var row: Int32 = 1
            for line in titleLines {
                write(row, 2, line)
                row += 1
            }
            if let hint = hint {
                write(Int32(getmaxy(window) - 2), 2, hint)
            }
            for (offset, option) in options.enumerated() {
                write(row + Int32(offset), 4, option, highlight: offset == index)
            }
            wrefresh(window)

            let key = wgetch(window)
            switch Int32(key) {
            case KEY_UP, Int32(Character("k").asciiValue ?? 0), Int32(Character("K").asciiValue ?? 0):
                index = (index - 1 + options.count) % options.count
            case KEY_DOWN, Int32(Character("j").asciiValue ?? 0), Int32(Character("J").asciiValue ?? 0):
                index = (index + 1) % options.count
            case 10, 13, KEY_ENTER:
                return index
            case Int32(Character("q").asciiValue ?? 0), Int32(Character("Q").asciiValue ?? 0), 27:
                return index
            case Int32(Character("1").asciiValue ?? 0)...Int32(Character("9").asciiValue ?? 0):
                let digit = Int(key) - Int(Character("1").asciiValue ?? 49)
                if digit >= 0 && digit < options.count {
                    return digit
                }
            case Int32(Character("0").asciiValue ?? 0):
                if options.count >= 10 {
                    return 9
                }
            default:
                continue
            }
        }
    }

    func selectLanguage(defaultCode: String?, prompt: [String], options: [(String, String)]) -> String {
        var index = options.firstIndex { $0.0 == defaultCode } ?? 0

        while true {
            werase(window)
            if let header = prompt.first {
                write(1, 2, header)
            }
            let hint = Localization.languageHint(for: options[index].0)
            write(Int32(getmaxy(window) - 2), 2, hint)
            for (offset, option) in options.enumerated() {
                let line = "\(option.1) (\(option.0))"
                write(Int32(3 + offset), 4, line, highlight: offset == index)
            }
            wrefresh(window)

            let key = wgetch(window)
            switch Int32(key) {
            case KEY_UP, Int32(Character("k").asciiValue ?? 0), Int32(Character("K").asciiValue ?? 0):
                index = (index - 1 + options.count) % options.count
            case KEY_DOWN, Int32(Character("j").asciiValue ?? 0), Int32(Character("J").asciiValue ?? 0):
                index = (index + 1) % options.count
            case 10, 13, KEY_ENTER:
                return options[index].0
            case Int32(Character("q").asciiValue ?? 0), Int32(Character("Q").asciiValue ?? 0), 27:
                return options[index].0
            case Int32(Character("1").asciiValue ?? 0)...Int32(Character("9").asciiValue ?? 0):
                let digit = Int(key) - Int(Character("1").asciiValue ?? 49)
                if digit >= 0 && digit < options.count {
                    return options[digit].0
                }
            case Int32(Character("0").asciiValue ?? 0):
                if options.count >= 10 {
                    return options[9].0
                }
            default:
                continue
            }
        }
    }
}

private func wrap(_ message: String, width: Int) -> [String] {
    guard width > 0 else { return [message] }
    var lines: [String] = []
    for rawSegment in message.split(separator: "\n", omittingEmptySubsequences: false) {
        let words = rawSegment.split(separator: " ")
        var current = ""
        for word in words {
            if current.isEmpty {
                current = String(word)
            } else if current.count + word.count + 1 > width {
                lines.append(current)
                current = String(word)
            } else {
                current += " " + word
            }
        }
        if !current.isEmpty {
            lines.append(current)
        }
        if rawSegment.isEmpty {
            lines.append("")
        }
    }
    if lines.isEmpty {
        lines.append(String(message.prefix(width)))
    }
    return lines
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, self))
    }
}

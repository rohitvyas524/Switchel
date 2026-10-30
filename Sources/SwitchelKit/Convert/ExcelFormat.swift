import Foundation

/// Turns a cell's stored number into what Excel shows, using its number format:
/// dates and times, percentages, currency, thousands separators and fixed decimals.
enum ExcelFormat {
    /// Excel's built-in formats that files reference by id instead of storing.
    static let builtIn: [Int: String] = [
        0: "General", 1: "0", 2: "0.00", 3: "#,##0", 4: "#,##0.00", 9: "0%", 10: "0.00%", 11: "0.00E+00",
        14: "m/d/yyyy", 15: "d-mmm-yy", 16: "d-mmm", 17: "mmm-yy", 18: "h:mm AM/PM", 19: "h:mm:ss AM/PM",
        20: "h:mm", 21: "h:mm:ss", 22: "m/d/yyyy h:mm", 37: "#,##0 ;(#,##0)", 38: "#,##0 ;[Red](#,##0)",
        39: "#,##0.00;(#,##0.00)", 40: "#,##0.00;[Red](#,##0.00)", 45: "mm:ss", 46: "[h]:mm:ss", 47: "mm:ss.0", 49: "@",
    ]

    static func display(_ raw: String, format code: String) -> String {
        guard let value = Double(raw), code != "@" else { return raw }
        var sections = code.components(separatedBy: ";")
        var number = value
        // A negative section shows the number without its sign.
        if value < 0, sections.count > 1 { number = -value; sections = [sections[1]] }
        let section = sections[0].replacingOccurrences(of: #"\[(Red|Black|Blue|Green|White|Yellow|Cyan|Magenta|Color\d+|\$[^\]]*)\]"#,
                                                        with: "", options: [.regularExpression, .caseInsensitive])
        if section.isEmpty || section.lowercased() == "general" { return general(number) }
        if isDate(section) { return date(number, section) }
        return numeric(number, section)
    }

    static func general(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 { return String(Int64(value)) }
        // Excel shows up to 10 significant digits.
        var text = String(format: "%.10g", value)
        if text.contains("e") { return text.uppercased() }
        if text.contains(".") { while text.hasSuffix("0") { text.removeLast() } }
        return text
    }

    private static func isDate(_ code: String) -> Bool {
        let stripped = code.replacingOccurrences(of: #""[^"]*"|\\."#, with: "", options: .regularExpression).lowercased()
        return stripped.range(of: "[ymdhs]", options: .regularExpression) != nil && !stripped.contains("0.0e")
    }

    /// Excel counts days from 1899-12-30 (leap-year bug included).
    private static func date(_ serial: Double, _ code: String) -> String {
        var pattern = ""
        let lower = code.lowercased()
        let twelveHour = lower.contains("am/pm") || lower.contains("a/p")
        let characters = Array(code)
        var i = 0
        var previousWasHour = false
        func run(of c: Character) -> Int {
            var n = 0
            while i + n < characters.count, characters[i + n].lowercased() == String(c) { n += 1 }
            return n
        }
        func nextTokenIsSeconds(from index: Int) -> Bool {
            var j = index
            while j < characters.count, !"ymdhs".contains(characters[j].lowercased()) { j += 1 }
            return j < characters.count && characters[j].lowercased() == "s"
        }
        while i < characters.count {
            let c = Character(characters[i].lowercased())
            switch c {
            case "y":
                let n = run(of: "y"); pattern += n <= 2 ? "yy" : "yyyy"; i += n
                previousWasHour = false
            case "d":
                let n = run(of: "d"); pattern += n == 1 ? "d" : n == 2 ? "dd" : n == 3 ? "EEE" : "EEEE"; i += n
                previousWasHour = false
            case "h":
                let n = run(of: "h"); pattern += twelveHour ? (n == 1 ? "h" : "hh") : (n == 1 ? "H" : "HH"); i += n
                previousWasHour = true
            case "m":
                let n = run(of: "m")
                // "m" after hours or before seconds means minutes.
                if n <= 2 && (previousWasHour || nextTokenIsSeconds(from: i + n)) {
                    pattern += n == 1 ? "m" : "mm"
                } else {
                    pattern += ["M", "MM", "MMM", "MMMM", "MMMMM"][min(n, 5) - 1]
                }
                i += n
                previousWasHour = false
            case "s":
                let n = run(of: "s"); pattern += n == 1 ? "s" : "ss"; i += n
                if i < characters.count, characters[i] == "." {
                    var zeros = 0
                    while i + 1 + zeros < characters.count, characters[i + 1 + zeros] == "0" { zeros += 1 }
                    pattern += "." + String(repeating: "S", count: max(zeros, 1))
                    i += 1 + zeros
                }
            case "a" where lower[lower.index(lower.startIndex, offsetBy: i)...].hasPrefix("am/pm"):
                pattern += "a"; i += 5
            case "\"":
                var literal = ""
                i += 1
                while i < characters.count, characters[i] != "\"" { literal.append(characters[i]); i += 1 }
                i += 1
                pattern += "'\(literal.replacingOccurrences(of: "'", with: "''"))'"
            case "\\":
                if i + 1 < characters.count { pattern += "'\(characters[i + 1])'" }
                i += 2
            case "[":
                // Elapsed time such as [h]: show the total hours.
                if let close = characters[i...].firstIndex(of: "]") {
                    let token = String(characters[(i + 1)..<close]).lowercased()
                    if token.hasPrefix("h") { pattern += "'\(Int(serial * 24))'" }
                    i = close + 1
                    if token.hasPrefix("h") { previousWasHour = true }
                } else {
                    i += 1
                }
            case "_", "*":
                i += 2
            default:
                pattern += characters[i].isLetter ? "'\(characters[i])'" : String(characters[i])
                i += 1
            }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = pattern
        let base = Date(timeIntervalSince1970: -2_209_161_600)  // 1899-12-30
        return formatter.string(from: base.addingTimeInterval((serial * 86_400).rounded()))
    }

    private static func numeric(_ value: Double, _ code: String) -> String {
        // Literal text around the digits: "$", "€", " kg", quoted strings, \-escapes; _x pads and *x fills vanish.
        var prefix = "", suffix = "", digits = ""
        var characters = Array(code)[...]
        var seenDigits = false
        while let c = characters.first {
            characters = characters.dropFirst()
            var literal: String?
            switch c {
            case "0", "#", "?", ".", ",", "E", "e", "+", "-" where seenDigits && digits.last.map({ "Ee".contains($0) }) == true:
                digits.append(c)
                if "0#?".contains(c) { seenDigits = true }
                continue
            case "%":
                literal = "%"
            case "\"":
                let end = characters.firstIndex(of: "\"") ?? characters.endIndex
                literal = String(characters[..<end])
                characters = end < characters.endIndex ? characters[characters.index(after: end)...] : []
            case "\\":
                literal = characters.first.map(String.init) ?? ""
                characters = characters.dropFirst()
            case "_", "*":
                characters = characters.dropFirst()
                literal = c == "_" ? "" : nil
            default:
                literal = String(c)
            }
            if let literal { if seenDigits { suffix += literal } else { prefix += literal } }
        }

        var number = value
        if code.contains("%") { number *= 100 }
        let parts = digits.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let fraction = parts.count > 1 ? parts[1].prefix { "0#?".contains($0) } : ""
        let required = fraction.filter { $0 == "0" }.count
        if digits.uppercased().contains("E") {
            return prefix + String(format: "%.\(fraction.count)E", number) + suffix
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = parts[0].contains(",")
        formatter.minimumFractionDigits = required
        formatter.maximumFractionDigits = fraction.count
        formatter.minimumIntegerDigits = max(parts[0].filter { $0 == "0" }.count, digits.isEmpty ? 1 : 0)
        let text = formatter.string(from: NSNumber(value: abs(number))) ?? String(abs(number))
        return (number < 0 ? "-" : "") + prefix + text + suffix
    }
}

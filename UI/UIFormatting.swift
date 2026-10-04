import Foundation

// Pure, Foundation-only presentation logic for the SwiftUI layer.
// Compiled into BOTH the app and SelfControlTests - keep it free of AppKit,
// SwiftUI and Obj-C dependencies.

// MARK: - End time ("today at 6:30 PM" / "Sat, Oct 4 at 6:30 PM")

enum EndTimePhrase {
    static func phrase(for date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = formatter("jmm", calendar, locale).string(from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return String(format: NSLocalizedString("today at %@", comment: "end time later the same day, e.g. 'today at 6:30 PM'"), time)
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = formatter(sameYear ? "EEEMMMd" : "EEEMMMdyyyy", calendar, locale).string(from: date)
        return String(format: NSLocalizedString("%@ at %@", comment: "end time on another day, e.g. 'Sat, Oct 4 at 6:30 PM'"), day, time)
    }

    private static func formatter(_ template: String, _ calendar: Calendar, _ locale: Locale) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = locale
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }
}

// MARK: - Countdown text

enum CountdownText {
    /// "3:41:52", or ("1d", "3:41:52") once a day or more remains.
    static func parts(seconds: Int) -> (days: String?, clock: String) {
        let s = max(0, seconds)
        let days = s / 86400
        let rem = s % 86400
        let clock = String(format: "%d:%02d:%02d", rem / 3600, (rem % 3600) / 60, rem % 60)
        return (days > 0 ? "\(days)d" : nil, clock)
    }

    /// "12:47" (minutes may exceed 59).
    static func minutesSeconds(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Duration text

enum DurationText {
    /// Big display: ("8 hr", "00 min"), ("45 min", nil), ("2 days", "4 hr"), ("1 day", nil).
    static func parts(minutes: Int) -> (primary: String, secondary: String?) {
        let m = max(0, minutes)
        if m < 60 { return ("\(m) min", nil) }
        if m < 1440 { return ("\(m / 60) hr", String(format: "%02d min", m % 60)) }
        let days = m / 1440
        let hours = (m % 1440) / 60
        return (days == 1 ? "1 day" : "\(days) days", hours > 0 ? "\(hours) hr" : nil)
    }

    /// Compact: "45 min", "1 hr 15 min", "1 day", "7 days", "1 day 1 hr".
    static func short(minutes: Int) -> String {
        let m = max(0, minutes)
        if m < 60 { return "\(m) min" }
        if m < 1440 {
            let h = m / 60, r = m % 60
            return r == 0 ? "\(h) hr" : "\(h) hr \(r) min"
        }
        let d = m / 1440, h = (m % 1440) / 60
        let dayStr = d == 1 ? "1 day" : "\(d) days"
        return h == 0 ? dayStr : "\(dayStr) \(h) hr"
    }
}

// MARK: - Duration slider scale (spec §8)

/// Piecewise slider scale: 1–60 min (5-min steps), 1–24 h (15-min steps),
/// 1 day+ (1-hour steps). Segment weights give hours most of the track.
struct DurationScale {
    let maxMinutes: Int
    private let segments: [(lo: Double, hi: Double, p0: Double, p1: Double, step: Int)]

    init(maxMinutes: Int) {
        let maxM = max(1, maxMinutes)
        self.maxMinutes = maxM
        let raw: [(lo: Int, hi: Int, weight: Double, step: Int)] = [(1, 60, 0.2, 5), (60, 1440, 0.5, 15), (1440, Int.max, 0.3, 60)]
        var kept: [(lo: Int, hi: Int, weight: Double, step: Int)] = []
        for seg in raw where seg.lo < maxM {
            let hi = min(seg.hi, maxM)
            let fraction = seg.hi == Int.max ? 1.0 : Double(hi - seg.lo) / Double(seg.hi - seg.lo)
            kept.append((seg.lo, hi, seg.weight * fraction, seg.step))
        }
        if kept.isEmpty { kept = [(1, max(2, maxM), 1, 1)] } // maxM == 1
        let total = kept.reduce(0) { $0 + $1.weight }
        var p = 0.0
        var built: [(lo: Double, hi: Double, p0: Double, p1: Double, step: Int)] = []
        for seg in kept {
            let w = seg.weight / total
            built.append((Double(seg.lo), Double(seg.hi), p, p + w, seg.step))
            p += w
        }
        segments = built
    }

    /// Nearest allowed value: 1, multiples of 5 to 60, of 15 to 1440, of 60 above, or `maxMinutes`.
    func snap(_ minutes: Int) -> Int {
        let m = min(max(minutes, 1), maxMinutes)
        if m == maxMinutes { return maxMinutes }
        let step = m <= 60 ? 5 : (m <= 1440 ? 15 : 60)
        var snapped = Int((Double(m) / Double(step)).rounded()) * step
        if snapped < 5 { snapped = m < 3 ? 1 : 5 }   // 1 is the only allowed value below 5
        if snapped > maxMinutes || (maxMinutes - m) < abs(snapped - m) { snapped = maxMinutes }
        return snapped
    }

    func minutes(at position: Double) -> Int {
        let p = min(max(position, 0), 1)
        if p >= 1 { return maxMinutes }
        let seg = segments.first(where: { p <= $0.p1 }) ?? segments[segments.count - 1]
        let t = seg.p1 > seg.p0 ? (p - seg.p0) / (seg.p1 - seg.p0) : 0
        return snap(Int((seg.lo + t * (seg.hi - seg.lo)).rounded()))
    }

    func position(for minutes: Int) -> Double {
        let m = Double(snap(minutes))
        if Int(m) >= maxMinutes { return 1 }
        let seg = segments.first(where: { m <= $0.hi }) ?? segments[segments.count - 1]
        let t = seg.hi > seg.lo ? (m - seg.lo) / (seg.hi - seg.lo) : 0
        return seg.p0 + t * (seg.p1 - seg.p0)
    }
}

// MARK: - Restrictions summary (spec §9)

enum RestrictionsSummary {
    static func subtitle(entries: [String], isAllowlist: Bool, maxHosts: Int = 2) -> String {
        if entries.isEmpty {
            return isAllowlist
                ? NSLocalizedString("Nothing allowed — blocks everything", comment: "empty allowlist summary")
                : NSLocalizedString("No sites yet", comment: "empty blocklist summary")
        }
        let shown = entries.prefix(maxHosts).joined(separator: ", ")
        let extra = entries.count - min(entries.count, maxHosts)
        let list = extra > 0 ? "\(shown) +\(extra)" : shown
        let format = isAllowlist
            ? NSLocalizedString("Allowing only %@", comment: "allowlist summary, e.g. 'Allowing only a.com +2'")
            : NSLocalizedString("Blocking %@", comment: "blocklist summary, e.g. 'Blocking a.com, b.com +5'")
        return String(format: format, list)
    }

    static func headline(count: Int, isAllowlist: Bool) -> String {
        if isAllowlist {
            if count == 0 { return NSLocalizedString("Blocking everything", comment: "header: allowlist block with no allowed sites") }
            return count == 1
                ? NSLocalizedString("Allowing only 1 site", comment: "header: allowlist with one site")
                : String(format: NSLocalizedString("Allowing only %ld sites", comment: "header: allowlist with N sites"), count)
        }
        return count == 1
            ? NSLocalizedString("Blocking 1 site", comment: "header: blocking one site")
            : String(format: NSLocalizedString("Blocking %ld sites", comment: "header: blocking N sites"), count)
    }
}

// MARK: - Override pills (spec §5)

enum PillState: Equatable {
    case available
    case used
    case using(remainingFraction: Double)
    case pending
}

enum OverridePills {
    static func states(perDay: Int, remainingToday: Int, activeFraction: Double?, pendingSpend: Bool) -> [PillState] {
        let total = max(0, perDay)
        guard total > 0 else { return [] }
        let remaining = min(max(0, remainingToday), total)
        var result: [PillState] = []
        if let f = activeFraction {
            result.append(.using(remainingFraction: min(max(f, 0), 1)))
            result += Array(repeating: .available, count: min(remaining, total - 1))
        } else if pendingSpend && remaining > 0 {
            result.append(.pending)
            result += Array(repeating: .available, count: remaining - 1)
        } else {
            result += Array(repeating: .available, count: remaining)
        }
        result += Array(repeating: .used, count: max(0, total - result.count))
        return result
    }
}

// MARK: - Host validity (port of DomainListWindowController -tableView:willDisplayCell:...)

enum HostValidity {
    private static let ipPattern = "^([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$"
    // Labels may contain underscores (SCMiscUtilities cleanBlocklistEntry keeps them);
    // TLD is 2-63 letters or a punycode "xn--" label.
    private static let hostPattern = "^([a-zA-Z0-9_]([a-zA-Z0-9_\\-]{0,61}[a-zA-Z0-9_])?\\.)+([a-zA-Z]{2,63}|xn--[a-zA-Z0-9\\-]{1,59})$"

    /// Splits entries into those that pass `isValid` and those that don't, preserving order.
    static func partition(_ entries: [String]) -> (valid: [String], invalid: [String]) {
        var valid: [String] = [], invalid: [String] = []
        for e in entries { if isValid(e) { valid.append(e) } else { invalid.append(e) } }
        return (valid, invalid)
    }

    /// Inline note after an import skipped invalid entries; nil when nothing was skipped.
    static func skippedNote(count: Int) -> String? {
        guard count > 0 else { return nil }
        if count == 1 { return NSLocalizedString("Skipped 1 entry that isn’t a valid address.", comment: "import skipped one invalid entry") }
        return String(format: NSLocalizedString("Skipped %ld entries that aren’t valid addresses.", comment: "import skipped N invalid entries"), count)
    }

    /// Legacy "highlight invalid hosts" rules, widened for long/punycode TLDs and underscores.
    static func isValid(_ raw: String) -> Bool {
        var str = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.isEmpty { return true }
        var maskLength = -1
        var portNum = -1

        var split = str.components(separatedBy: "/")
        str = split[0].lowercased()
        var portSearch = str
        var searchedMask = false
        if split.count >= 2 {
            maskLength = Int(split[1].prefix(while: { $0.isNumber })) ?? 0
            if maskLength == 0 { maskLength = -1 }
            portSearch = split[1]
            searchedMask = true
        }
        split = portSearch.components(separatedBy: ":")
        if !searchedMask { str = split[0] }
        if split.count >= 2 {
            portNum = Int(split[1].prefix(while: { $0.isNumber })) ?? 0
            if portNum == 0 { portNum = -1 }
        }

        let isIP = str.range(of: ipPattern, options: .regularExpression) != nil
        if !isIP {
            let isHost = str.range(of: hostPattern, options: .regularExpression) != nil
            if !isHost && str != "*" && !str.isEmpty { return false }
        }
        if !isIP && maskLength != -1 { return false }
        if (str == "*" || str.isEmpty) && portNum == -1 { return false }
        return true
    }
}

// MARK: - Override policy editing limits (spec §6.3)

enum OverridePolicyLimits {
    static let perDayRange = 0...10
    static let minutesRange = 1...60

    static func clampPerDay(_ n: Int) -> Int { min(max(n, perDayRange.lowerBound), perDayRange.upperBound) }

    static func nextMinutes(_ m: Int) -> Int {
        let next = m < 5 ? m + 1 : (m / 5 + 1) * 5
        return min(max(next, minutesRange.lowerBound), minutesRange.upperBound)
    }

    static func previousMinutes(_ m: Int) -> Int {
        let prev = m > 5 ? ((m - 1) / 5) * 5 : m - 1
        return min(max(prev, minutesRange.lowerBound), minutesRange.upperBound)
    }
}


// MARK: - Duration slider tick labels

struct DurationTick: Equatable {
    let minutes: Int
    let label: String
    /// Higher wins when two labels collide.
    let priority: Int
}

enum TickLayout {
    struct Placed: Equatable {
        let index: Int
        /// Unclamped x of the anchor on the track (where the tick mark goes).
        let tickX: Double
        /// Label centre, clamped so the label stays inside the track.
        let labelCenter: Double
    }

    /// 1h, 8h, 1 day, 1 week (each only below the max), then the max itself.
    /// If the max equals an anchor, that anchor stands in for it (with max priority).
    static func anchors(maxMinutes: Int) -> [DurationTick] {
        let maxM = max(1, maxMinutes)
        let fixed: [(minutes: Int, label: String, priority: Int)] = [
            (60, NSLocalizedString("1h", comment: "slider tick: 1 hour"), 2),
            (480, NSLocalizedString("8h", comment: "slider tick: 8 hours"), 1),
            (1440, NSLocalizedString("1 day", comment: "slider tick: 1 day"), 3),
            (10080, NSLocalizedString("1 week", comment: "slider tick: 1 week"), 0),
        ]
        let maxPriority = 4
        var result = fixed.filter { $0.minutes < maxM }.map { DurationTick(minutes: $0.minutes, label: $0.label, priority: $0.priority) }
        // 1 week only counts as an anchor when it's below the max; otherwise the max label covers it.
        if let same = fixed.first(where: { $0.minutes == maxM }), same.minutes != 10080 {
            result.append(DurationTick(minutes: maxM, label: same.label, priority: maxPriority))
        } else {
            result.append(DurationTick(minutes: maxM, label: DurationText.short(minutes: maxM), priority: maxPriority))
        }
        return result
    }

    /// Places labels at `positions` (0...1) along a track of `trackWidth`, clamping the
    /// ends inside the track and hiding lower-priority labels that come within `minGap`.
    /// Returns the visible ticks in anchor order.
    static func visibleTicks(anchors: [DurationTick], positions: [Double], labelWidths: [Double],
                             trackWidth: Double, minGap: Double) -> [Placed] {
        let n = min(anchors.count, positions.count, labelWidths.count)
        guard n > 0, trackWidth > 0 else { return [] }
        var candidates: [Placed] = []
        for i in 0..<n {
            let x = min(max(positions[i], 0), 1) * trackWidth
            let half = min(labelWidths[i], trackWidth) / 2
            candidates.append(Placed(index: i, tickX: x, labelCenter: min(max(x, half), trackWidth - half)))
        }
        let order = (0..<n).sorted { anchors[$0].priority != anchors[$1].priority ? anchors[$0].priority > anchors[$1].priority : $0 < $1 }
        var accepted: [Placed] = []
        for i in order {
            let c = candidates[i]
            let lo = c.labelCenter - labelWidths[i] / 2, hi = c.labelCenter + labelWidths[i] / 2
            let clashes = accepted.contains { a in
                let alo = a.labelCenter - labelWidths[a.index] / 2, ahi = a.labelCenter + labelWidths[a.index] / 2
                return lo < ahi + minGap && alo < hi + minGap
            }
            if !clashes { accepted.append(c) }
        }
        return accepted.sorted { $0.index < $1.index }
    }
}

// MARK: - Override pill fitting

enum PillLayout {
    static let minimumPillWidth = 6.0

    /// Width per pill so `count` pills fit in `available`; nil means draw one continuous bar.
    static func pillWidth(preferred: Double, available: Double, count: Int, gap: Double) -> Double? {
        guard count > 0 else { return preferred }
        let fit = (available - gap * Double(count - 1)) / Double(count)
        let w = min(preferred, fit)
        return w < minimumPillWidth ? nil : w
    }

    static func totalWidth(pillWidth: Double, count: Int, gap: Double) -> Double {
        count > 0 ? pillWidth * Double(count) + gap * Double(count - 1) : 0
    }
}

// MARK: - "Longest block allowed" custom value, in days

enum MaxLengthDays {
    static let range = 1...30

    /// Prefill: whole days, rounded up, within 1-30.
    static func days(fromMinutes m: Int) -> Int {
        min(max(Int((Double(m) / 1440).rounded(.up)), range.lowerBound), range.upperBound)
    }

    /// Whole number of days in 1-30 -> minutes; nil if the input isn't one.
    static func minutes(fromInput text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.allSatisfy({ $0.isASCII && $0.isNumber }), let d = Int(t), range.contains(d) else { return nil }
        return d * 1440
    }
}

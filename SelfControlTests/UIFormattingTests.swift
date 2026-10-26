import XCTest

final class UIFormattingTests: XCTestCase {

    // MARK: helpers
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }
    /// ICU uses U+202F (narrow no-break space) before AM/PM on recent macOS.
    private func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }
    private let us = Locale(identifier: "en_US")

    // MARK: EndTimePhrase
    func testEndTimeSameDay() {
        let now = date(2026, 10, 2, 14, 48)
        XCTAssertEqual(norm(EndTimePhrase.phrase(for: date(2026, 10, 2, 18, 30), now: now, calendar: utc, locale: us)), "today at 6:30 PM")
    }
    func testEndTimeLaterDay() {
        let now = date(2026, 10, 2, 14, 48)
        XCTAssertEqual(norm(EndTimePhrase.phrase(for: date(2026, 10, 4, 18, 30), now: now, calendar: utc, locale: us)), "Sun, Oct 4 at 6:30 PM")
    }
    func testEndTimeNextYearShowsYear() {
        let now = date(2026, 12, 30, 9, 0)
        XCTAssertEqual(norm(EndTimePhrase.phrase(for: date(2027, 1, 2, 9, 5), now: now, calendar: utc, locale: us)), "Sat, Jan 2, 2027 at 9:05 AM")
    }
    func testEndTime24HourLocale() {
        let now = date(2026, 10, 2, 14, 48)
        let s = norm(EndTimePhrase.phrase(for: date(2026, 10, 2, 18, 30), now: now, calendar: utc, locale: Locale(identifier: "en_GB")))
        XCTAssertTrue(s.contains("18:30"), s)
        XCTAssertTrue(s.hasPrefix("today at"), s)
    }

    // MARK: CountdownText
    func testCountdownUnderADay() {
        let p = CountdownText.parts(seconds: 3 * 3600 + 41 * 60 + 52)
        XCTAssertNil(p.days)
        XCTAssertEqual(p.clock, "3:41:52")
    }
    func testCountdownWithDays() {
        let p = CountdownText.parts(seconds: 86400 + 3 * 3600 + 41 * 60 + 52)
        XCTAssertEqual(p.days, "1d")
        XCTAssertEqual(p.clock, "3:41:52")
    }
    func testCountdownClampsNegative() {
        XCTAssertEqual(CountdownText.parts(seconds: -5).clock, "0:00:00")
    }
    func testMinutesSeconds() {
        XCTAssertEqual(CountdownText.minutesSeconds(12 * 60 + 47), "12:47")
        XCTAssertEqual(CountdownText.minutesSeconds(5), "0:05")
        XCTAssertEqual(CountdownText.minutesSeconds(75 * 60), "75:00")
    }

    // MARK: DurationText
    func testDurationTextParts() {
        XCTAssertEqual(DurationText.parts(minutes: 45).primary, "45 min")
        XCTAssertNil(DurationText.parts(minutes: 45).secondary)
        XCTAssertEqual(DurationText.parts(minutes: 480).primary, "8 hr")
        XCTAssertEqual(DurationText.parts(minutes: 480).secondary, "00 min")
        XCTAssertEqual(DurationText.parts(minutes: 495).secondary, "15 min")
        XCTAssertEqual(DurationText.parts(minutes: 1440).primary, "1 day")
        XCTAssertNil(DurationText.parts(minutes: 1440).secondary)
        XCTAssertEqual(DurationText.parts(minutes: 2880 + 240).primary, "2 days")
        XCTAssertEqual(DurationText.parts(minutes: 2880 + 240).secondary, "4 hr")
    }
    func testDurationTextShort() {
        XCTAssertEqual(DurationText.short(minutes: 45), "45 min")
        XCTAssertEqual(DurationText.short(minutes: 60), "1 hr")
        XCTAssertEqual(DurationText.short(minutes: 75), "1 hr 15 min")
        XCTAssertEqual(DurationText.short(minutes: 1440), "1 day")
        XCTAssertEqual(DurationText.short(minutes: 10080), "7 days")
        XCTAssertEqual(DurationText.short(minutes: 1500), "1 day 1 hr")
    }

    // MARK: DurationScale
    func testScaleEndpoints() {
        let s = DurationScale(maxMinutes: 43200)
        XCTAssertEqual(s.minutes(at: 0), 1)
        XCTAssertEqual(s.minutes(at: 1), 43200)
        XCTAssertEqual(s.position(for: 1), 0, accuracy: 1e-9)
        XCTAssertEqual(s.position(for: 43200), 1, accuracy: 1e-9)
    }
    func testScaleIsMonotonic() {
        let s = DurationScale(maxMinutes: 43200)
        var last = 0
        for i in 0...1000 {
            let m = s.minutes(at: Double(i) / 1000)
            XCTAssertGreaterThanOrEqual(m, last)
            last = m
        }
    }
    func testScaleSnapping() {
        let s = DurationScale(maxMinutes: 43200)
        XCTAssertEqual(s.snap(7), 5)
        XCTAssertEqual(s.snap(8), 10)
        XCTAssertEqual(s.snap(97), 90)    // 15-min steps between 1h and 24h
        XCTAssertEqual(s.snap(1530), 1560) // 1-hour steps above a day
        XCTAssertEqual(s.snap(99999), 43200)
        XCTAssertEqual(s.snap(0), 1)
    }
    func testScaleRoundTrips() {
        let s = DurationScale(maxMinutes: 43200)
        for m in [1, 5, 30, 60, 90, 480, 1440, 2880, 10080, 43200] {
            XCTAssertEqual(s.minutes(at: s.position(for: m)), m, "round trip \(m)")
        }
    }
    func testScaleGivesUsefulRoomToHours() {
        // 1h..24h must own a big chunk of the track even when max is 30 days
        let s = DurationScale(maxMinutes: 43200)
        XCTAssertGreaterThan(s.position(for: 1440) - s.position(for: 60), 0.4)
    }
    func testScaleSmallMax() {
        let s = DurationScale(maxMinutes: 90)
        XCTAssertEqual(s.minutes(at: 1), 90)
        XCTAssertEqual(s.snap(500), 90)
        XCTAssertEqual(s.minutes(at: s.position(for: 75)), 75)
    }
    func testScaleMaxNotOnAStep() {
        let s = DurationScale(maxMinutes: 100)
        XCTAssertEqual(s.minutes(at: 1), 100)
        XCTAssertEqual(s.snap(100), 100)
    }

    // MARK: RestrictionsSummary
    func testSummarySubtitle() {
        let seven = ["nytimes.com", "avclub.com", "a.com", "b.com", "c.com", "d.com", "e.com"]
        XCTAssertEqual(RestrictionsSummary.subtitle(entries: seven, isAllowlist: false), "Blocking nytimes.com, avclub.com +5")
        XCTAssertEqual(RestrictionsSummary.subtitle(entries: ["a.com"], isAllowlist: false), "Blocking a.com")
        XCTAssertEqual(RestrictionsSummary.subtitle(entries: ["a.com", "b.com"], isAllowlist: false), "Blocking a.com, b.com")
        XCTAssertEqual(RestrictionsSummary.subtitle(entries: ["a.com", "b.com", "c.com"], isAllowlist: true), "Allowing only a.com, b.com +1")
        XCTAssertEqual(RestrictionsSummary.subtitle(entries: [], isAllowlist: false), "No sites yet")
        XCTAssertEqual(RestrictionsSummary.subtitle(entries: [], isAllowlist: true), "Nothing allowed — blocks everything")
    }
    func testSummaryHeadline() {
        XCTAssertEqual(RestrictionsSummary.headline(count: 7, isAllowlist: false), "Blocking 7 sites")
        XCTAssertEqual(RestrictionsSummary.headline(count: 1, isAllowlist: false), "Blocking 1 site")
        XCTAssertEqual(RestrictionsSummary.headline(count: 3, isAllowlist: true), "Allowing only 3 sites")
        XCTAssertEqual(RestrictionsSummary.headline(count: 0, isAllowlist: true), "Blocking everything")
    }

    // MARK: OverridePills
    func testPillsIdle() {
        XCTAssertEqual(OverridePills.states(perDay: 3, remainingToday: 2, activeFraction: nil, pendingSpend: false),
                       [.available, .available, .used])
    }
    func testPillsActive() {
        XCTAssertEqual(OverridePills.states(perDay: 3, remainingToday: 1, activeFraction: 0.85, pendingSpend: false),
                       [.using(remainingFraction: 0.85), .available, .used])
    }
    func testPillsPending() {
        XCTAssertEqual(OverridePills.states(perDay: 3, remainingToday: 2, activeFraction: nil, pendingSpend: true),
                       [.pending, .available, .used])
    }
    func testPillsClamp() {
        XCTAssertEqual(OverridePills.states(perDay: 2, remainingToday: 9, activeFraction: nil, pendingSpend: false), [.available, .available])
        XCTAssertEqual(OverridePills.states(perDay: 0, remainingToday: 0, activeFraction: nil, pendingSpend: false), [])
    }

    // MARK: HostValidity (port of DomainListWindowController's highlight rules)
    func testHostValidity() {
        XCTAssertTrue(HostValidity.isValid("nytimes.com"))
        XCTAssertTrue(HostValidity.isValid("danieldrezner.substack.com"))
        XCTAssertTrue(HostValidity.isValid("17.0.0.0/8"))
        XCTAssertTrue(HostValidity.isValid("10.0.0.1"))
        XCTAssertTrue(HostValidity.isValid("example.com:8080"))
        XCTAssertTrue(HostValidity.isValid("*:25"))
        XCTAssertFalse(HostValidity.isValid("*"))
        XCTAssertFalse(HostValidity.isValid("nodot"))
        XCTAssertFalse(HostValidity.isValid("example.com/8"))
        XCTAssertTrue(HostValidity.isValid("  "))  // blank rows are never highlighted
    }

    func testHostValidityLongAndPunycodeTLDs() {
        XCTAssertTrue(HostValidity.isValid("studio.photography"))
        XCTAssertTrue(HostValidity.isValid("example.xn--p1ai"))
        XCTAssertTrue(HostValidity.isValid("example.abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijk")) // 63-letter TLD
        XCTAssertFalse(HostValidity.isValid("example.abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijkl")) // 64
        XCTAssertFalse(HostValidity.isValid("example.c"))
        XCTAssertFalse(HostValidity.isValid("example.c0m"))
    }
    func testHostValidityUnderscores() {
        XCTAssertTrue(HostValidity.isValid("_dmarc.example.com"))
        XCTAssertTrue(HostValidity.isValid("my_host.example.com"))
    }
    func testHostValidityStillRejects() {
        XCTAssertFalse(HostValidity.isValid("*"))
        XCTAssertFalse(HostValidity.isValid("reddit"))
        XCTAssertFalse(HostValidity.isValid("photography.com/16"))
        XCTAssertTrue(HostValidity.isValid("10.0.0.0/16"))
        XCTAssertTrue(HostValidity.isValid("example.photography:443"))
        XCTAssertTrue(HostValidity.isValid(":25"))
    }
    func testHostValidityPartition() {
        let p = HostValidity.partition(["a.com", "nodot", "b.org", "*"])
        XCTAssertEqual(p.valid, ["a.com", "b.org"])
        XCTAssertEqual(p.invalid, ["nodot", "*"])
    }
    func testSkippedImportNote() {
        XCTAssertNil(HostValidity.skippedNote(count: 0))
        XCTAssertEqual(HostValidity.skippedNote(count: 1), "Skipped 1 entry that isn’t a valid address.")
        XCTAssertEqual(HostValidity.skippedNote(count: 2), "Skipped 2 entries that aren’t valid addresses.")
    }

    // MARK: TickLayout
    func testTickAnchorsThirtyDays() {
        let a = TickLayout.anchors(maxMinutes: 43200)
        XCTAssertEqual(a.map(\.minutes), [60, 480, 1440, 10080, 43200])
        XCTAssertEqual(a.map(\.label), ["1h", "8h", "1 day", "1 week", "30 days"])
    }
    func testTickAnchorsOneDay() {
        let a = TickLayout.anchors(maxMinutes: 1440)
        XCTAssertEqual(a.map(\.minutes), [60, 480, 1440])
        XCTAssertEqual(a.map(\.label), ["1h", "8h", "1 day"])
        // the 1-day anchor is the maximum, so it carries the max priority
        XCTAssertEqual(a[2].priority, a.map(\.priority).max())
    }
    func testTickAnchorsOneWeekIsMax() {
        let a = TickLayout.anchors(maxMinutes: 10080)
        XCTAssertEqual(a.map(\.minutes), [60, 480, 1440, 10080])
        XCTAssertEqual(a.last?.label, "7 days")
    }
    func testTickAnchorsSmallMax() {
        XCTAssertEqual(TickLayout.anchors(maxMinutes: 30).map(\.label), ["30 min"])
        XCTAssertEqual(TickLayout.anchors(maxMinutes: 120).map(\.label), ["1h", "2 hr"])
    }
    func testTickPriorityOrder() {
        let a = TickLayout.anchors(maxMinutes: 43200)
        let byPriority = a.sorted { $0.priority > $1.priority }.map(\.label)
        XCTAssertEqual(byPriority, ["30 days", "1 day", "1h", "8h", "1 week"])
    }
    func testTickClampsEnds() {
        let a = TickLayout.anchors(maxMinutes: 1440)
        let placed = TickLayout.visibleTicks(anchors: a, positions: [0.0, 0.5, 1.0], labelWidths: [20, 20, 40], trackWidth: 300, minGap: 6)
        XCTAssertEqual(placed.map(\.index), [0, 1, 2])
        XCTAssertEqual(placed[0].labelCenter, 10, accuracy: 1e-9)   // clamped from 0
        XCTAssertEqual(placed[0].tickX, 0, accuracy: 1e-9)
        XCTAssertEqual(placed[1].labelCenter, 150, accuracy: 1e-9)
        XCTAssertEqual(placed[2].labelCenter, 280, accuracy: 1e-9)  // clamped from 300
        XCTAssertEqual(placed[2].tickX, 300, accuracy: 1e-9)
    }
    func testTickCollisionHidesLowerPriority() {
        let a = TickLayout.anchors(maxMinutes: 43200) // 1h, 8h, 1 day, 1 week, 30 days
        // 1 week sits 30pt from 30 days; 8h sits right next to 1h
        let placed = TickLayout.visibleTicks(anchors: a, positions: [0.2, 0.25, 0.7, 0.9, 1.0],
                                             labelWidths: [20, 20, 36, 40, 44], trackWidth: 300, minGap: 6)
        // 1h centre 60 [50,70]; 8h centre 75 [65,85] -> overlaps 1h, hidden
        // 1 week centre 270 [250,290]; 30 days clamped to 278 [256,300] -> hidden
        XCTAssertEqual(placed.map(\.index), [0, 2, 4])
    }
    func testTickGapIsRespected() {
        let a = TickLayout.anchors(maxMinutes: 1440)
        // labels 20pt wide; edges 4pt apart (< 6) -> lower priority (8h) hidden
        var placed = TickLayout.visibleTicks(anchors: a, positions: [0.3, 0.38, 1.0], labelWidths: [20, 20, 30], trackWidth: 300, minGap: 6)
        XCTAssertEqual(placed.map(\.index), [0, 2])
        // 8pt apart -> both shown
        placed = TickLayout.visibleTicks(anchors: a, positions: [0.3, 0.3933333333, 1.0], labelWidths: [20, 20, 30], trackWidth: 300, minGap: 6)
        XCTAssertEqual(placed.map(\.index), [0, 1, 2])
    }

    // MARK: PillLayout
    func testPillWidthPrefersPreferred() {
        XCTAssertEqual(PillLayout.pillWidth(preferred: 26, available: 300, count: 3, gap: 5), 26)
    }
    func testPillWidthShrinksToFit() {
        // 10 pills, 9 gaps of 5 = 45; (300 - 45) / 10 = 25.5
        XCTAssertEqual(PillLayout.pillWidth(preferred: 40, available: 300, count: 10, gap: 5)!, 25.5, accuracy: 1e-9)
    }
    func testPillWidthFallsBackToBar() {
        // (100 - 45) / 10 = 5.5 < 6 -> continuous bar
        XCTAssertNil(PillLayout.pillWidth(preferred: 16, available: 100, count: 10, gap: 5))
        XCTAssertEqual(PillLayout.pillWidth(preferred: 16, available: 105, count: 10, gap: 5)!, 6, accuracy: 1e-9)
    }
    func testPillTotalWidth() {
        XCTAssertEqual(PillLayout.totalWidth(pillWidth: 16, count: 3, gap: 5), 58)
        XCTAssertEqual(PillLayout.totalWidth(pillWidth: 16, count: 0, gap: 5), 0)
    }

    // MARK: MaxLengthDays
    func testMaxLengthDaysPrefill() {
        XCTAssertEqual(MaxLengthDays.days(fromMinutes: 1440), 1)
        XCTAssertEqual(MaxLengthDays.days(fromMinutes: 1441), 2)
        XCTAssertEqual(MaxLengthDays.days(fromMinutes: 60), 1)
        XCTAssertEqual(MaxLengthDays.days(fromMinutes: 43200), 30)
    }
    func testMaxLengthDaysParse() {
        XCTAssertEqual(MaxLengthDays.minutes(fromInput: "7"), 10080)
        XCTAssertEqual(MaxLengthDays.minutes(fromInput: " 30 "), 43200)
        XCTAssertEqual(MaxLengthDays.minutes(fromInput: "1"), 1440)
        XCTAssertNil(MaxLengthDays.minutes(fromInput: "0"))
        XCTAssertNil(MaxLengthDays.minutes(fromInput: "31"))
        XCTAssertNil(MaxLengthDays.minutes(fromInput: "1.5"))
        XCTAssertNil(MaxLengthDays.minutes(fromInput: "abc"))
    }

    // MARK: OverridePolicyLimits
    func testOverrideMinuteSteps() {
        XCTAssertEqual(OverridePolicyLimits.nextMinutes(1), 2)
        XCTAssertEqual(OverridePolicyLimits.nextMinutes(4), 5)
        XCTAssertEqual(OverridePolicyLimits.nextMinutes(5), 10)
        XCTAssertEqual(OverridePolicyLimits.nextMinutes(7), 10)
        XCTAssertEqual(OverridePolicyLimits.nextMinutes(60), 60)
        XCTAssertEqual(OverridePolicyLimits.previousMinutes(10), 5)
        XCTAssertEqual(OverridePolicyLimits.previousMinutes(7), 5)
        XCTAssertEqual(OverridePolicyLimits.previousMinutes(5), 4)
        XCTAssertEqual(OverridePolicyLimits.previousMinutes(1), 1)
        XCTAssertEqual(OverridePolicyLimits.clampPerDay(-1), 0)
        XCTAssertEqual(OverridePolicyLimits.clampPerDay(11), 10)
    }

    func testDeepBlockLimitsClamp() {
        XCTAssertEqual(DeepBlockLimits.clamp(1), 5)
        XCTAssertEqual(DeepBlockLimits.clamp(45), 45)
        XCTAssertEqual(DeepBlockLimits.clamp(500), 240)
        XCTAssertEqual(DeepBlockLimits.scale.maxMinutes, 240)
    }

    // MARK: list entries

    func testListEntriesDropDuplicatesKeepingFirst() {
        XCTAssertEqual(ListEntries.unique(["vox.com", "bbc.com", "vox.com", "archive.ph", "bbc.com"]),
                       ["vox.com", "bbc.com", "archive.ph"])
        XCTAssertEqual(ListEntries.unique([]), [])
    }

    // MARK: extend limit

    func testExtendLimitFillsUpToLongestBlock() {
        // 30-day max, 2 days left: up to 28 days more.
        XCTAssertEqual(ExtendLimit.maxMinutes(maxBlockLengthMinutes: 43200, remainingSeconds: 2 * 86400), 28 * 1440)
        // Partial minutes left round the cap down, never past the max.
        XCTAssertEqual(ExtendLimit.maxMinutes(maxBlockLengthMinutes: 1440, remainingSeconds: 3600 + 30), 1440 - 61)
    }

    func testExtendLimitIsZeroAtOrPastLongestBlock() {
        XCTAssertEqual(ExtendLimit.maxMinutes(maxBlockLengthMinutes: 1440, remainingSeconds: 86400), 0)
        // Max lowered below what's left: nothing more, never negative.
        XCTAssertEqual(ExtendLimit.maxMinutes(maxBlockLengthMinutes: 60, remainingSeconds: 7200), 0)
    }
}

import XCTest
@testable import Strand
import WhoopStore

/// The TODAY anchor that rides beside every coach question: a 7B local model was quoting the 30-day
/// averages (charge 56, HRV 52, rest 8h) as today's numbers on a charge-1 day. The anchor states today's
/// computed charge + zone explicitly, so these tests pin the zone, the numbers and the not-scored path.
@MainActor
final class AICoachTodayAnchorTests: XCTestCase {

    /// A fixed 07:05 New York morning, so zone-prescription assertions don't depend on when tests run
    /// (from 18:00 the brief swaps "prescribe for the zone" for tonight + tomorrow).
    private var morningCal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; return c }
    private var morning: Date { morningCal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 7, minute: 5))! }

    private func day(_ d: String, charge: Double?, hrv: Double?, rhr: Int?, sleepMin: Double?,
                     strain: Double? = nil, skinTemp: Double? = nil) -> DailyMetric {
        DailyMetric(day: d, totalSleepMin: sleepMin, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: charge,
                    strain: strain, exerciseCount: nil, skinTempDevC: skinTemp)
    }

    func testRedDayStatesTodaysNumbersAndZoneNotAverages() {
        let history = [day("2026-10-07", charge: 87, hrv: 63, rhr: 52, sleepMin: 623),
                       day("2026-10-08", charge: 87, hrv: 65, rhr: 53, sleepMin: 568)]
        let today = day("2026-10-10", charge: 0.6, hrv: 13.3, rhr: 83, sleepMin: 329, strain: 39.4, skinTemp: 0.89)
        let out = AICoachEngine.todayAnchor(today: today, latestScored: today, last30: history + [today],
                                            now: morning, calendar: morningCal)

        XCTAssertTrue(out.hasPrefix("TODAY (Saturday 2026-10-10)"))
        XCTAssertTrue(out.contains("charge 1 → RED zone (0-33)"))
        XCTAssertTrue(out.contains("HRV 13ms (30-day avg 47)"))
        XCTAssertTrue(out.contains("RHR 83bpm"))
        XCTAssertTrue(out.contains("last night's sleep 5.5h"))
        XCTAssertTrue(out.contains("effort so far today 39.4 (already done, not a target)"))
        XCTAssertTrue(out.contains("skin-temp deviation +0.89°C"))
        XCTAssertTrue(out.contains("prescribe for the RED zone"))
    }

    func testZoneBoundariesMatchRecoveryBands() {
        func zone(_ c: Double) -> String {
            AICoachEngine.todayAnchor(today: day("d", charge: c, hrv: nil, rhr: nil, sleepMin: nil),
                                      latestScored: nil, last30: [])
        }
        XCTAssertTrue(zone(33.9).contains("RED zone"))
        XCTAssertTrue(zone(34).contains("YELLOW zone"))
        XCTAssertTrue(zone(66.9).contains("YELLOW zone"))
        XCTAssertTrue(zone(67).contains("GREEN zone"))
    }

    func testUnscoredTodaySaysSoAndPointsAtLatestScoredDay() {
        let yesterday = day("2026-10-09", charge: 86, hrv: 64, rhr: 53, sleepMin: 560)
        let today = day("2026-10-10", charge: nil, hrv: nil, rhr: nil, sleepMin: nil)
        let out = AICoachEngine.todayAnchor(today: today, latestScored: yesterday, last30: [yesterday, today])

        XCTAssertTrue(out.contains("TODAY (Saturday 2026-10-10): charge is NOT scored yet"))
        XCTAssertTrue(out.contains("Latest scored day Friday 2026-10-09: charge 86 → GREEN zone"))
        XCTAssertTrue(out.contains("today's charge isn't in yet"))
    }

    /// A 7B labelled Saturday 2026-10-10 "Monday" in a week-ahead plan, so every date carries its weekday.
    func testDatesCarryTheirWeekdayAndTheWeekAheadIsListed() {
        XCTAssertEqual(AICoachEngine.dated("2026-10-10"), "Saturday 2026-10-10")
        XCTAssertEqual(AICoachEngine.dated("2026-03-08"), "Sunday 2026-03-08")   // US DST start
        XCTAssertEqual(AICoachEngine.dated("not-a-day"), "not-a-day")
        let week = AICoachEngine.weekAhead(after: "2026-10-10") ?? ""
        XCTAssertTrue(week.contains("Sunday 2026-10-11, Monday 2026-10-12"))
        XCTAssertTrue(week.hasSuffix("Saturday 2026-10-17"))

        let today = day("2026-10-10", charge: 1, hrv: 27, rhr: 83, sleepMin: 380)
        let out = AICoachEngine.todayAnchor(today: today, latestScored: today, last30: [today])
        XCTAssertTrue(out.contains("Next 7 days (use these exact weekday names"))
    }

    func testClockLineGivesWeekdayTimeAndFlagsTheEvening() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let evening = cal.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 21, minute: 48))!
        let morning = cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 7, minute: 5))!
        XCTAssertTrue(AICoachEngine.clockLine(evening, calendar: cal).hasPrefix("  Local time now: Sunday 9:48 PM (evening"))
        XCTAssertEqual(AICoachEngine.clockLine(morning, calendar: cal), "  Local time now: Monday 7:05 AM")
    }

    func testEveningBriefAsksForTonightAndTomorrowNotATodayWorkout() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let evening = cal.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 22, minute: 14))!
        let morning = cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 7, minute: 5))!
        XCTAssertTrue(AICoachEngine.briefInstruction(now: evening, calendar: cal).contains("tonight to recover"))
        XCTAssertFalse(AICoachEngine.briefInstruction(now: evening, calendar: cal).contains("training to do today"))
        XCTAssertTrue(AICoachEngine.briefInstruction(now: morning, calendar: cal).contains("training to do today"))

        let today = day("2026-10-11", charge: 71, hrv: 60, rhr: 55, sleepMin: 624)
        let eve = AICoachEngine.todayAnchor(today: today, latestScored: today, last30: [today], now: evening, calendar: cal)
        XCTAssertTrue(eve.contains("do NOT prescribe a workout for today"))
        XCTAssertFalse(eve.contains("prescribe for the GREEN zone"))
        let mor = AICoachEngine.todayAnchor(today: today, latestScored: today, last30: [today], now: morning, calendar: cal)
        XCTAssertTrue(mor.contains("prescribe for the GREEN zone"))
    }

    /// Chat questions get today's numbers and an answer-what-was-asked rule, not the brief's prescription
    /// and week list (a 7B bolted a full plan + week-ahead onto "how bad did Thursday and Friday hurt me?").
    func testChatModeAnswersTheQuestionAndOnlyListsTheWeekWhenAsked() {
        let today = day("2026-10-11", charge: 1, hrv: 29, rhr: 80, sleepMin: 390)
        let past = AICoachEngine.todayAnchor(today: today, latestScored: today, last30: [today],
                                             mode: .chat(question: "I went out Thursday and Friday, how bad was it?"))
        XCTAssertTrue(past.contains("ONLY if they ask for one"))
        XCTAssertFalse(past.contains("Next 7 days"))
        XCTAssertFalse(past.contains("prescribe for the RED zone"))

        let ahead = AICoachEngine.todayAnchor(today: today, latestScored: today, last30: [today],
                                              mode: .chat(question: "Plan my week"))
        XCTAssertTrue(ahead.contains("Next 7 days"))

        let brief = AICoachEngine.todayAnchor(today: today, latestScored: today, last30: [today], mode: .brief,
                                              now: morning, calendar: morningCal)
        XCTAssertTrue(brief.contains("prescribe for the RED zone") && brief.contains("Next 7 days"))
    }
}

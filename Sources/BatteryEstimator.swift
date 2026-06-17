import Foundation

/// A single observed strap-battery reading (one row of `battery_samples`).
struct BatterySample {
    let date: Date
    let level: Int
}

/// Estimates how much charge the WHOOP strap has left by measuring how fast it has
/// *actually* been discharging — no hard-coded "the battery lasts N days" assumption.
///
/// It walks the recorded readings and only counts intervals where the level went
/// down (real discharge), so charging stretches and long app-was-closed gaps don't
/// pollute the rate. The average discharge rate over those intervals, divided into the
/// current level, gives the time remaining.
enum BatteryEstimator {
    /// Skip an interval longer than this between two readings: the app was likely closed,
    /// so we can't honestly attribute the drop to steady discharge.
    static let maxGap: TimeInterval = 24 * 3600
    /// Don't show an estimate until we've observed at least this much real drop…
    static let minObservedDrop = 3            // percent
    /// …spread over at least this much discharging time, so one stray 1% tick can't drive it.
    static let minObservedSpan: TimeInterval = 20 * 60

    /// Days of charge left, or `nil` when there isn't enough discharge history yet
    /// (e.g. just charged, or only a couple of readings). `samples` must be oldest-first.
    static func daysRemaining(samples: [BatterySample]) -> Double? {
        guard let current = samples.last?.level, current > 0 else { return nil }

        var droppedPct = 0.0          // total % lost across qualifying discharge intervals
        var dischargingTime = 0.0     // total seconds those intervals spanned
        for (a, b) in zip(samples, samples.dropFirst()) {
            let gap = b.date.timeIntervalSince(a.date)
            let drop = a.level - b.level                       // > 0 means it discharged
            guard gap > 0, gap <= maxGap, drop > 0 else { continue }  // skip charging / stale gaps
            droppedPct += Double(drop)
            dischargingTime += gap
        }

        guard droppedPct >= Double(minObservedDrop), dischargingTime >= minObservedSpan else { return nil }
        let perSecond = droppedPct / dischargingTime           // % per second
        guard perSecond > 0 else { return nil }
        return (Double(current) / perSecond) / 86_400          // seconds left → days
    }
}

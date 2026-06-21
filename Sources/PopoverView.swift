import SwiftUI
import Charts
import AppKit

enum Metric: String, CaseIterable, Identifiable {
    case recovery = "Recovery"
    case hrv = "HRV"
    case strain = "Strain"
    case sleep = "Sleep"
    case rhr = "RHR"
    case heartRate = "HR"          // our own, locally-logged heart rate — split from the cloud metrics
    var id: String { rawValue }

    /// The metrics WHOOP's cloud publishes once a day. `heartRate` is deliberately not here:
    /// it comes from the live BLE log on this Mac, so it's shown separately and at finer granularity.
    static var cloudCases: [Metric] { [.recovery, .hrv, .strain, .sleep, .rhr] }

    var unit: String {
        switch self { case .recovery: return "%"; case .hrv: return "ms"; case .strain: return ""
        case .sleep: return "h"; case .rhr: return "bpm"; case .heartRate: return "bpm" }
    }
    /// Plain-language explainer shown under the picker.
    var explainer: String {
        switch self {
        case .recovery: return "How ready your body is today · 0–100%"
        case .hrv:      return "Heart-rate variability · ms, higher is better"
        case .strain:   return "Cardiovascular load · 0–21 scale"
        case .sleep:    return "Time asleep · hours"
        case .rhr:      return "Resting heart rate · bpm, lower is better"
        case .heartRate: return "Your heart rate · logged live on this Mac"
        }
    }
    func value(_ d: DayPoint) -> Double? {
        switch self {
        case .recovery: return d.recovery
        case .hrv: return d.hrv
        case .strain: return d.strain
        case .sleep: return d.sleep_hours
        case .rhr: return d.rhr
        case .heartRate: return nil          // sourced from local SQLite, not the daily cloud series
        }
    }
    func format(_ v: Double) -> String {
        switch self {
        case .recovery: return "\(Int(v.rounded()))%"
        case .hrv:      return "\(Int(v.rounded())) ms"
        case .strain:   return String(format: "%.1f", v)
        case .sleep:    return String(format: "%.1f", v) + "h"
        case .rhr:      return "\(Int(v.rounded())) bpm"
        case .heartRate: return "\(Int(v.rounded())) bpm"
        }
    }
    var tint: Color {
        switch self {
        case .recovery: return Color(red: 0.27, green: 0.78, blue: 0.52)
        case .hrv:      return Color(red: 0.30, green: 0.66, blue: 0.92)
        case .strain:   return Color(red: 0.36, green: 0.50, blue: 0.96)
        case .sleep:    return Color(red: 0.55, green: 0.48, blue: 0.95)
        case .rhr:      return Color(red: 0.96, green: 0.46, blue: 0.43)
        case .heartRate: return Color(red: 0.96, green: 0.36, blue: 0.42)
        }
    }
    /// A fixed, sensible y-range per metric so the axis means something.
    func domain(_ values: [Double]) -> ClosedRange<Double> {
        switch self {
        case .recovery: return 0...100
        case .strain:   return 0...21
        case .sleep:    return 0...max(8, (values.max() ?? 8).rounded(.up))
        case .hrv:      return 0...max(60, ((values.max() ?? 60) * 1.15).rounded(.up))
        case .rhr, .heartRate:
            let lo = max(30, (values.min() ?? 50) - 5).rounded(.down)
            let hi = ((values.max() ?? 70) + 5).rounded(.up)
            return lo...hi
        }
    }
}

/// Scheme-aware palette so the popover is clean in both light and dark (night) mode.
struct Pal {
    let scheme: ColorScheme
    var dark: Bool { scheme == .dark }
    var bg: Color { dark ? Color(red: 0.10, green: 0.10, blue: 0.12) : Color(red: 0.975, green: 0.975, blue: 0.985) }
    var card: Color { dark ? Color(red: 0.16, green: 0.16, blue: 0.19) : .white }
    var hairline: Color { dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06) }
    var pillRest: Color { dark ? Color.white.opacity(0.08) : Color.black.opacity(0.045) }
    var grid: Color { dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05) }
    var shadow: Color { dark ? Color.black.opacity(0.30) : Color.black.opacity(0.06) }
}

struct ChartPoint: Identifiable {
    let date: Date
    let value: Double
    var id: TimeInterval { date.timeIntervalSince1970 }
}

/// The point currently under the cursor while scrubbing a chart.
struct HoverInfo: Equatable {
    let date: Date
    let value: Double
}

struct PopoverView: View {
    @EnvironmentObject var bt: BluetoothManager
    @EnvironmentObject var store: WhoopStore
    @EnvironmentObject var auth: WhoopAuth
    @EnvironmentObject var updates: UpdateChecker
    @Environment(\.colorScheme) private var scheme
    @State private var metric: Metric = .recovery
    @State private var range = 30
    @State private var hover: HoverInfo?
    @AppStorage("onboarded") private var onboarded = false
    @State private var launchAtLogin = false

    private var pal: Pal { Pal(scheme: scheme) }
    private var showOnboarding: Bool { !onboarded && LoginItem.available }

    /// Open the Connect flow in its own AppKit window (stays open through the browser login).
    private func openConnect() { ConnectWindowController.shared.show(auth: auth) }

    private var series: [ChartPoint] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -range, to: Date()) ?? .distantPast
        return store.days.compactMap { d -> ChartPoint? in
            guard let v = metric.value(d), d.day >= cutoff else { return nil }
            return ChartPoint(date: d.day, value: v)
        }
    }

    /// Nearest data point to a scrubbed x-position.
    private func nearest(_ target: Date, in pts: [(Date, Double)]) -> HoverInfo? {
        guard let best = pts.min(by: { abs($0.0.timeIntervalSince(target)) < abs($1.0.timeIntervalSince(target)) }) else { return nil }
        return HoverInfo(date: best.0, value: best.1)
    }

    var body: some View {
        ZStack {
            pal.bg.ignoresSafeArea()
            if showOnboarding { onboarding } else { mainContent }
        }
        .frame(width: 380)
        .onAppear { launchAtLogin = LoginItem.enabled }
        // No forced color scheme — follows the system, so dark at night.
    }

    private var mainContent: some View {
        // Constant-height layout: the same rows render in every mode, so the
        // menu-bar window never has to animate a resize (that resize is what
        // crashed AppKit's constraint solver). Only the chart's contents swap.
        VStack(alignment: .leading, spacing: 14) {
            header
            statRow
            metricPills
            Text(explainerText)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1)                           // one line always: keeps the window height fixed
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if metric == .heartRate {
                    if range == 1 { dayChart } else { hrTrendChart }   // our HR: intraday or daily band
                } else {
                    trendChart                                         // cloud metric: daily trend
                }
            }
            .transaction { $0.animation = nil }         // swap instantly; never animate a relayout here
            rangePills
            footer
        }
        .padding(18)
        // Day is heart-rate-only (the cloud metrics aren't intraday), so picking Day implies HR and
        // picking a cloud metric while on Day bumps to a multi-day range. Every shown combo stays valid.
        .onChange(of: range) { _, newValue in
            hover = nil
            if newValue == 1 { metric = .heartRate; store.loadTodayHR() } else { store.loadHRDaily() }
        }
        .onChange(of: metric) { _, newValue in
            hover = nil
            if newValue != .heartRate && range == 1 { range = 30 }
            if newValue == .heartRate && range > 1 { store.loadHRDaily() }
        }
    }

    /// Caption under the picker — heart rate gets its own wording at each granularity.
    private var explainerText: String {
        guard metric == .heartRate else { return metric.explainer }
        return range == 1
            ? "Today's live heart rate · logged on this Mac"
            : "Your heart rate each day · low, average and high"
    }

    // MARK: onboarding (first launch)

    private var onboarding: some View {
        VStack(spacing: 13) {
            HeartBeat(active: true)
                .scaleEffect(1.6)
                .padding(.bottom, 2)
            Text("WhoopBar").font(.system(size: 20, weight: .semibold, design: .rounded))
            Text("Your live heart rate, right in the menu bar.\nEverything stays on this Mac.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            broadcastNote
            Toggle("Start automatically at login", isOn: $launchAtLogin)
                .toggleStyle(.switch).font(.system(size: 12)).tint(Metric.recovery.tint)
                .padding(.horizontal, 8).fixedSize()
            VStack(spacing: 8) {
                Button {
                    LoginItem.set(launchAtLogin); onboarded = true; openConnect()
                } label: {
                    Text("Connect Whoop for full data").font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(Metric.recovery.tint)
                Button {
                    LoginItem.set(launchAtLogin); onboarded = true
                } label: {
                    Text("Just heart rate for now").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text("Recovery, Sleep, Strain & HRV need a quick Whoop login.\nYou can add it anytime.")
                .font(.system(size: 10)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { launchAtLogin = true }   // default the choice to on
    }

    /// The one thing WhoopBar can't do for the user: the strap only advertises standard BLE
    /// heart rate once "Broadcast Heart Rate" is on in the WHOOP app. Call it out up front.
    private var broadcastNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 13)).foregroundStyle(hrTint).padding(.top, 1)
            Text("First, open the WHOOP app and turn on **Broadcast Heart Rate** — that's what lets your strap share live BPM over Bluetooth.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(pal.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(pal.hairline, lineWidth: 1))
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("WHOOP").font(.system(size: 11, weight: .bold)).tracking(1.5).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    HeartBeat(active: bt.heartRate != nil)
                    Text(bt.heartRate.map { "\($0)" } ?? "–")
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("bpm").font(.system(size: 13)).foregroundStyle(.secondary).padding(.bottom, 4)
                }
            }
            Spacer()
            statusPill
        }
    }

    private var statusPill: some View {
        let (text, color): (String, Color) = {
            switch bt.state {
            case .connected:  return ("Live", Color(red: 0.27, green: 0.78, blue: 0.52))
            case .connecting: return ("Linking", .orange)
            case .searching:  return ("Searching", .gray)
            case .off:        return ("BT off", Color(red: 0.96, green: 0.46, blue: 0.43))
            case .unknown:    return ("…", .gray)
            }
        }()
        return VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            if let b = bt.batteryLevel {
                Label("\(b)%", systemImage: batteryIcon(b))
                    .font(.system(size: 11)).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            }
        }
    }

    private func batteryIcon(_ b: Int) -> String {
        switch b { case ..<13: return "battery.0percent"; case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"; case ..<88: return "battery.75percent"; default: return "battery.100percent" }
    }

    // MARK: today stats

    private var statRow: some View {
        HStack(spacing: 10) {
            StatCard(label: "Recovery", value: store.latest?.recovery, suffix: "%",
                     tint: recoveryColor(store.latest?.recovery), pal: pal)
            StatCard(label: "Sleep", value: store.latest?.sleep_hours, suffix: "h", tint: Metric.sleep.tint, pal: pal)
            StatCard(label: "Strain", value: store.latest?.strain, suffix: "", tint: Metric.strain.tint, pal: pal)
        }
    }

    private func recoveryColor(_ r: Double?) -> Color {
        guard let r else { return .gray }
        if r >= 67 { return Color(red: 0.27, green: 0.78, blue: 0.52) }
        if r >= 34 { return Color(red: 0.95, green: 0.74, blue: 0.22) }
        return Color(red: 0.96, green: 0.42, blue: 0.40)
    }

    // MARK: metric selector

    // Heart rate (our own, high-granularity log) sits on its own, split off from the daily cloud
    // metrics by a hairline — both share the same selection, so only the active pill lights up.
    private var metricPills: some View {
        HStack(spacing: 6) {
            FluidTabBar(items: [Metric.heartRate], selection: $metric,
                        label: { $0.rawValue }, accent: { $0.tint }, hPad: 8, pal: pal)
            Rectangle().fill(pal.hairline).frame(width: 1, height: 16)
            FluidTabBar(items: Metric.cloudCases, selection: $metric,
                        label: { $0.rawValue }, accent: { $0.tint }, hPad: 8, pal: pal)
        }
    }

    // MARK: charts

    private let hrTint = Color(red: 0.96, green: 0.36, blue: 0.42)

    private func placeholder(_ text: String) -> some View {
        RoundedRectangle(cornerRadius: 14).fill(pal.pillRest).frame(height: 150)
            .overlay(Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 24))
    }

    /// Today's intraday HR (downsampled for rendering if very dense).
    private var dayHRSeries: [HRPoint] {
        let s = store.todayHR
        guard s.count > 1200 else { return s }
        let step = s.count / 1200 + 1
        return s.enumerated().filter { $0.offset % step == 0 }.map(\.element)
    }

    private var dayChart: some View {
        Group {
            if dayHRSeries.isEmpty {
                placeholder("No heart rate yet today.\nTurn on Broadcast Heart Rate in the WHOOP app, then wear the strap near your Mac.")
            } else {
                let vals = dayHRSeries.map(\.bpm)
                let lo = max(40, (vals.min() ?? 50) - 5).rounded(.down)
                let hi = ((vals.max() ?? 120) + 8).rounded(.up)
                let startOfDay = Calendar.current.startOfDay(for: Date())
                Chart {
                    ForEach(dayHRSeries) { p in
                        AreaMark(x: .value("Time", p.date), yStart: .value("lo", lo), yEnd: .value("bpm", p.bpm))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(.linearGradient(colors: [hrTint.opacity(0.22), hrTint.opacity(0.0)],
                                                              startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Time", p.date), y: .value("bpm", p.bpm))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(hrTint)
                            .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    }
                    hoverMarks(tint: hrTint) { h in
                        hoverCard(value: "\(Int(h.value.rounded())) bpm",
                                  sub: h.date.formatted(.dateTime.hour().minute()), tint: hrTint)
                    }
                }
                .chartYScale(domain: lo...hi)
                .chartXScale(domain: startOfDay...max(Date(), dayHRSeries.last?.date ?? Date()))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                        AxisGridLine().foregroundStyle(pal.grid)
                        AxisValueLabel().font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) {
                        AxisValueLabel(format: .dateTime.hour()).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                .chartOverlay { proxy in scrubber(proxy, points: dayHRSeries.map { ($0.date, $0.bpm) }) }
                .frame(height: 150)
            }
        }
    }

    /// Daily HR aggregate within the selected range (7/30/90), from the local SQLite log.
    private var hrSeries: [HRDayStat] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -range, to: Date()) ?? .distantPast
        return store.hrDaily.filter { $0.day >= cutoff }
    }

    /// Heart rate over 7/30/90 days: a low→high band per day with the daily average as the line.
    /// This is the part the WHOOP cloud never gives you — we kept every sample, so we can show it.
    private var hrTrendChart: some View {
        Group {
            if hrSeries.isEmpty {
                placeholder("No heart-rate history yet.\nTurn on Broadcast Heart Rate in the WHOOP app — it builds up here over time.")
            } else {
                let lo = max(35, (hrSeries.map(\.lo).min() ?? 45) - 5).rounded(.down)
                let hi = ((hrSeries.map(\.hi).max() ?? 150) + 8).rounded(.up)
                Chart {
                    ForEach(hrSeries) { s in
                        AreaMark(x: .value("Date", s.day),
                                 yStart: .value("low", s.lo), yEnd: .value("high", s.hi))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(.linearGradient(colors: [hrTint.opacity(0.28), hrTint.opacity(0.06)],
                                                              startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Date", s.day), y: .value("avg", s.avg))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(hrTint)
                            .lineStyle(StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round))
                    }
                    hoverMarks(tint: hrTint) { h in
                        let stat = hrSeries.first { Calendar.current.isDate($0.day, inSameDayAs: h.date) }
                        let date = h.date.formatted(.dateTime.month(.abbreviated).day())
                        hoverCard(value: "\(Int(h.value.rounded())) avg",
                                  sub: stat.map { "\(Int($0.lo))–\(Int($0.hi)) bpm · \(date)" } ?? date,
                                  tint: hrTint)
                    }
                }
                .chartYScale(domain: lo...hi)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                        AxisGridLine().foregroundStyle(pal.grid)
                        AxisValueLabel().font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                .chartOverlay { proxy in scrubber(proxy, points: hrSeries.map { ($0.day, $0.avg) }) }
                .frame(height: 150)
            }
        }
    }

    private var trendChart: some View {
        Group {
            if series.isEmpty {
                VStack(spacing: 10) {
                    Text(store.loading ? "Loading…" : (auth.isConnected ? "No trend data yet" : "Connect Whoop to see your trends"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if !auth.isConnected && !store.loading {
                        Button { openConnect() } label: {
                            Text("Connect Whoop").font(.system(size: 12, weight: .medium))
                        }.buttonStyle(.borderedProminent).controlSize(.small).tint(Metric.recovery.tint)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 150)
                .background(pal.pillRest).clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                let dom = metric.domain(series.map(\.value))
                Chart {
                    ForEach(series) { point in
                        AreaMark(x: .value("Date", point.date),
                                 yStart: .value("min", dom.lowerBound),
                                 yEnd: .value(metric.rawValue, point.value))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(.linearGradient(colors: [metric.tint.opacity(0.22), metric.tint.opacity(0.0)],
                                                              startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Date", point.date), y: .value(metric.rawValue, point.value))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(metric.tint)
                            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    }
                    hoverMarks(tint: metric.tint) { h in
                        hoverCard(value: metric.format(h.value),
                                  sub: h.date.formatted(.dateTime.month(.abbreviated).day()), tint: metric.tint)
                    }
                }
                .chartYScale(domain: dom)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                        AxisGridLine().foregroundStyle(pal.grid)
                        AxisValueLabel().font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                .chartOverlay { proxy in scrubber(proxy, points: series.map { ($0.date, $0.value) }) }
                .frame(height: 150)
            }
        }
    }

    // MARK: hover scrubbing

    /// Guide line + dot + floating value card at the hovered point (added inside a Chart builder).
    @ChartContentBuilder
    private func hoverMarks<A: View>(tint: Color, @ViewBuilder card: (HoverInfo) -> A) -> some ChartContent {
        if let h = hover {
            RuleMark(x: .value("sel", h.date))
                .foregroundStyle(Color.secondary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            PointMark(x: .value("sel", h.date), y: .value("v", h.value))
                .foregroundStyle(tint)
                .symbolSize(60)
                .annotation(position: .top, spacing: 6,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                    card(h)
                }
        }
    }

    /// Transparent overlay that maps the cursor x-position to the nearest data point.
    private func scrubber(_ proxy: ChartProxy, points: [(Date, Double)]) -> some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        guard let anchor = proxy.plotFrame else { return }
                        let frame = geo[anchor]
                        guard frame.contains(loc), let d: Date = proxy.value(atX: loc.x - frame.minX) else {
                            hover = nil; return
                        }
                        hover = nearest(d, in: points)
                    case .ended:
                        hover = nil
                    }
                }
        }
    }

    private func hoverCard(value: String, sub: String, tint: Color) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(tint)
            Text(sub).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(pal.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(pal.hairline, lineWidth: 1))
        .shadow(color: pal.shadow, radius: 5, y: 2)
        .fixedSize()
    }

    // MARK: range + footer

    private var rangePills: some View {
        HStack {
            FluidTabBar(items: [1, 7, 30, 90], selection: $range,
                        label: { $0 == 1 ? "Day" : "\($0)d" }, accent: { _ in .primary }, showTrack: false, pal: pal)
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Text(updatedText).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            if updates.updateAvailable, let v = updates.latest {
                Button { if let u = updates.releaseURL { NSWorkspace.shared.open(u) } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 10))
                        Text("Update \(v)").font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Metric.recovery.tint.opacity(0.16)))
                    .foregroundStyle(Metric.recovery.tint)
                }
                .buttonStyle(.plain)
                .help("A newer WhoopBar is available — brew upgrade --cask whoopbar, or click to view")
            }
            if LoginItem.available {
                // Drive off the live SMAppService state, not a stale @State mirror: the popover
                // hierarchy is reused between opens so onAppear won't re-sync, and the user can
                // also flip this from System Settings. Toggling the live value avoids the
                // "next press does the opposite" bug.
                Button {
                    LoginItem.set(!LoginItem.enabled)
                    launchAtLogin = LoginItem.enabled   // nudge a redraw + keep the mirror honest
                } label: {
                    Image(systemName: LoginItem.enabled ? "bolt.circle.fill" : "bolt.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(LoginItem.enabled ? Metric.recovery.tint : Color.secondary)
                .help("Start WhoopBar at login")
            }
            // Always-available way back into the Connect flow: re-check or update your WHOOP
            // credentials (or disconnect) long after the first-run onboarding is gone.
            Button { openConnect() } label: {
                Image(systemName: "key.fill").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(auth.isConnected ? Metric.recovery.tint : Color.secondary)
            .help(auth.isConnected ? "Whoop connected — re-check your keys or disconnect"
                                   : "Connect Whoop for Recovery, Sleep, Strain & HRV")
            Button { store.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .rotationEffect(.degrees(store.loading ? 360 : 0))
                    .animation(store.loading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: store.loading)
            }.buttonStyle(.plain).foregroundStyle(.secondary)
            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 12, weight: .medium))
            }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    private var updatedText: String {
        guard let d = store.lastUpdated else { return store.errorText ?? "—" }
        let m = Int(Date().timeIntervalSince(d) / 60)
        return m <= 0 ? "Updated just now" : "Updated \(m)m ago"
    }
}

// MARK: small components

struct StatCard: View {
    let label: String
    let value: Double?
    let suffix: String
    let tint: Color
    let pal: Pal
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value.map { fmt($0) } ?? "–")
                    .font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(tint)
                Text(suffix).font(.system(size: 11)).foregroundStyle(tint.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(pal.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(pal.hairline, lineWidth: 1))
        .shadow(color: pal.shadow, radius: 4, y: 1)
    }
    private func fmt(_ v: Double) -> String { v >= 10 || v == v.rounded() ? String(Int(v.rounded())) : String(format: "%.1f", v) }
}

struct HeartBeat: View {
    let active: Bool
    @State private var pulse = false
    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 20))
            .foregroundStyle(active ? Color(red: 0.96, green: 0.36, blue: 0.42) : Color.gray.opacity(0.4))
            .scaleEffect(active && pulse ? 1.14 : 1.0)
            .animation(active ? .easeInOut(duration: 0.55).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = true }
    }
}

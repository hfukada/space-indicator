import AppKit
import Foundation

// MARK: - Model Pricing

private struct ModelPricing {
    let inputPerMTok: Double
    let outputPerMTok: Double
}

// cache_creation billed at input rate; cache_read at 10% of input rate
private let pricingTable: [(prefix: String, pricing: ModelPricing)] = [
    ("claude-opus-4",     ModelPricing(inputPerMTok: 15.0,  outputPerMTok: 75.0)),
    ("claude-3-opus",     ModelPricing(inputPerMTok: 15.0,  outputPerMTok: 75.0)),
    ("claude-sonnet-4",   ModelPricing(inputPerMTok: 3.0,   outputPerMTok: 15.0)),
    ("claude-3-5-sonnet", ModelPricing(inputPerMTok: 3.0,   outputPerMTok: 15.0)),
    ("claude-3-5-haiku",  ModelPricing(inputPerMTok: 0.8,   outputPerMTok: 4.0)),
    ("claude-haiku-4",    ModelPricing(inputPerMTok: 0.8,   outputPerMTok: 4.0)),
    ("claude-3-haiku",    ModelPricing(inputPerMTok: 0.25,  outputPerMTok: 1.25)),
]
private let defaultPricing = ModelPricing(inputPerMTok: 3.0, outputPerMTok: 15.0)

private func pricing(for model: String) -> ModelPricing {
    let lower = model.lowercased()
    return pricingTable.first { lower.hasPrefix($0.prefix) }?.pricing ?? defaultPricing
}

private func tokenCost(model: String, usage: [String: Any]) -> Double {
    let p = pricing(for: model)
    let input      = Double(usage["input_tokens"]                  as? Int ?? 0)
    let output     = Double(usage["output_tokens"]                 as? Int ?? 0)
    let cacheWrite = Double(usage["cache_creation_input_tokens"]   as? Int ?? 0)
    let cacheRead  = Double(usage["cache_read_input_tokens"]       as? Int ?? 0)
    return ((input + cacheWrite) * p.inputPerMTok
          + output               * p.outputPerMTok
          + cacheRead            * p.inputPerMTok * 0.1) / 1_000_000
}

private let jstCalendar: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return cal
}()

// MARK: - Parser

class ClaudeUsageParser {
    private static let projectsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    struct HourUsage {
        let date: Date
        var tokens: Int
    }

    static func loadHourly(hours: Int = 24, completion: @escaping ([HourUsage]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let hourly = loadHourlySync(hours: hours)
            DispatchQueue.main.async { completion(hourly) }
        }
    }

    private static func loadHourlySync(hours: Int) -> [HourUsage] {
        let cal = Calendar.current
        let now = Date()
        let cutoff = cal.date(byAdding: .hour, value: -hours, to: now)!

        var hourlyMap: [DateComponents: Int] = [:]
        var seenIDs = Set<String>()

        guard let enumerator = FileManager.default.enumerator(
            at: projectsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        // withFractionalSeconds is required — timestamps look like "2026-06-25T07:16:19.521Z"
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            if let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let mod = attrs.contentModificationDate, mod < cutoff { continue }

            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }

            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                let s = String(line)
                guard s.contains("\"assistant\"") else { continue }
                guard let data = s.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (json["type"] as? String) == "assistant",
                      let message = json["message"] as? [String: Any],
                      let msgID = message["id"] as? String,
                      seenIDs.insert(msgID).inserted,
                      let usage = message["usage"] as? [String: Any],
                      let tsStr = json["timestamp"] as? String,
                      let date = iso.date(from: tsStr),
                      date > cutoff
                else { continue }

                let tokens = (usage["input_tokens"] as? Int ?? 0)
                    + (usage["output_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)

                let comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
                hourlyMap[comps, default: 0] += tokens
            }
        }

        var hourly: [HourUsage] = []
        for i in (0..<hours).reversed() {
            let date = cal.date(byAdding: .hour, value: -i, to: now)!
            let comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
            hourly.append(HourUsage(date: date, tokens: hourlyMap[comps] ?? 0))
        }
        return hourly
    }

    // MARK: - Enterprise daily spend

    // JST usage day: [9am, 9am next calendar day). Before 9am we're still in yesterday's day.
    private static func jstUsageDayWindow(at now: Date = Date()) -> (start: Date, end: Date) {
        var startComps = jstCalendar.dateComponents([.year, .month, .day], from: now)
        startComps.hour = 9; startComps.minute = 0; startComps.second = 0
        var windowStart = jstCalendar.date(from: startComps)!
        if now < windowStart {
            windowStart = jstCalendar.date(byAdding: .day, value: -1, to: windowStart)!
        }
        let windowEnd = jstCalendar.date(byAdding: .day, value: 1, to: windowStart)!
        return (windowStart, windowEnd)
    }

    // Sums dollar cost of all messages in the current JST usage-day window.
    static func loadDailySpendSync() -> Double {
        let (windowStart, windowEnd) = jstUsageDayWindow()

        var seenIDs = Set<String>()
        var totalCost = 0.0

        guard let enumerator = FileManager.default.enumerator(
            at: projectsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return 0.0 }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            if let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let mod = attrs.contentModificationDate, mod < windowStart { continue }

            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }

            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                let s = String(line)
                guard s.contains("\"assistant\"") else { continue }
                guard let data = s.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (json["type"] as? String) == "assistant",
                      let message = json["message"] as? [String: Any],
                      let msgID = message["id"] as? String,
                      seenIDs.insert(msgID).inserted,
                      let usage = message["usage"] as? [String: Any],
                      let tsStr = json["timestamp"] as? String,
                      let date = iso.date(from: tsStr),
                      date >= windowStart, date < windowEnd
                else { continue }

                let model = (message["model"] as? String) ?? ""
                totalCost += tokenCost(model: model, usage: usage)
            }
        }
        return totalCost
    }

    private static func countWeekdays(from start: Date, through end: Date) -> Int {
        var count = 0
        var date = jstCalendar.startOfDay(for: start)
        let endDay = jstCalendar.startOfDay(for: end)
        while date <= endDay {
            let weekday = jstCalendar.component(.weekday, from: date)
            if weekday != 1 && weekday != 7 { count += 1 }  // Mon–Fri
            date = jstCalendar.date(byAdding: .day, value: 1, to: date)!
        }
        return count
    }

    static func enterpriseUsageStat() -> UsageStat {
        let spend = loadDailySpendSync()
        let now = Date()
        let monthStart = jstCalendar.date(from: jstCalendar.dateComponents([.year, .month], from: now))!
        let monthEnd = jstCalendar.date(byAdding: DateComponents(month: 1, day: -1), to: monthStart)!
        let weekdaysInMonth = max(1, countWeekdays(from: monthStart, through: monthEnd))
        let weekdaysLeft = max(1, countWeekdays(from: now, through: monthEnd))
        let allowanceLeft = 350.0 * (Double(weekdaysLeft) / Double(weekdaysInMonth))
        let dailyBudget = allowanceLeft / Double(weekdaysLeft)
        let percent = Int((spend / dailyBudget * 100).rounded())
        let windowStart = jstUsageDayWindow().start
        let since = jstCalendar.dateComponents([.month, .day, .hour], from: windowStart)
        let sinceStr = String(format: "%d/%d %02d:00 JST", since.month!, since.day!, since.hour!)
        let detail = String(format: "$%.2f of $%.2f daily budget (since %@)", spend, dailyBudget, sinceStr)
        return UsageStat(title: "Today", percent: percent, detail: detail)
    }

    // MARK: - Usage summary

    struct UsageStat {
        let title: String
        let percent: Int
        let detail: String?
    }

    static func fetchUsageSummary(completion: @escaping ([UsageStat]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let stat = enterpriseUsageStat()
            DispatchQueue.main.async { completion([stat]) }
        }
    }
}

// MARK: - Percent Bar

class UsagePercentBarView: NSView {
    var percent: Int = 0 { didSet { needsDisplay = true } }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        NSColor.separatorColor.setFill()
        track.fill()

        guard percent > 0 else { return }
        let frac = CGFloat(min(100, percent)) / 100
        let fillW = frac * bounds.width
        let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: fillW, height: bounds.height),
                                xRadius: 3, yRadius: 3)
        let color: NSColor = percent > 90 ? .systemRed : percent > 70 ? .systemOrange : .controlAccentColor
        color.setFill()
        fill.fill()
    }
}

// MARK: - Bar Chart

class UsageBarChartView: NSView {
    var hourlyUsage: [ClaudeUsageParser.HourUsage] = [] { didSet { needsDisplay = true } }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard !hourlyUsage.isEmpty else { return }
        let maxTokens = max(1, hourlyUsage.map(\.tokens).max() ?? 1)
        let count = CGFloat(hourlyUsage.count)
        let barW = bounds.width / count
        let gap: CGFloat = 1.5

        let cal = Calendar.current
        let now = Date()
        for (i, hour) in hourlyUsage.enumerated() {
            let frac = CGFloat(hour.tokens) / CGFloat(maxTokens)
            let h = max(frac * bounds.height, hour.tokens > 0 ? 2 : 0)
            let x = CGFloat(i) * barW
            let rect = NSRect(x: x + gap, y: 0, width: barW - gap * 2, height: h)

            let isCurrentHour = cal.isDate(hour.date, equalTo: now, toGranularity: .hour)
            let color = isCurrentHour
                ? NSColor.controlAccentColor
                : NSColor.secondaryLabelColor.withAlphaComponent(0.5)
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
    }
}

// MARK: - View Controller

class ClaudeUsageViewController: NSViewController {
    private let usageStack = NSStackView()
    private let barChart = UsageBarChartView()
    private let loadingLabel = NSTextField(labelWithString: "Loading…")

    private let contentStack = NSStackView()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 0))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshChart()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        preferredContentSize = NSSize(width: 280, height: contentStack.fittingSize.height)
    }

    private func buildUI() {
        let stack = contentStack
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let header = NSTextField(labelWithString: "Claude Usage")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(header)

        stack.addArrangedSubview(makeSep())

        usageStack.orientation = .vertical
        usageStack.alignment = .leading
        usageStack.spacing = 8
        stack.addArrangedSubview(usageStack)
        usageStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true

        stack.addArrangedSubview(makeSep())

        let chartTitle = NSTextField(labelWithString: "Last 24 hours")
        chartTitle.font = .systemFont(ofSize: 11)
        chartTitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(chartTitle)

        barChart.translatesAutoresizingMaskIntoConstraints = false
        barChart.heightAnchor.constraint(equalToConstant: 52).isActive = true
        stack.addArrangedSubview(barChart)
        barChart.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true

        loadingLabel.font = .systemFont(ofSize: 11)
        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.isHidden = true
        stack.addArrangedSubview(loadingLabel)
    }

    private func makeSep() -> NSBox {
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.widthAnchor.constraint(equalToConstant: 256).isActive = true
        return sep
    }

    func refreshChart() {
        barChart.hourlyUsage = []
        ClaudeUsageParser.loadHourly(hours: 24) { [weak self] hourly in
            self?.barChart.hourlyUsage = hourly
        }
    }

    func showStats(_ stats: [ClaudeUsageParser.UsageStat]) {
        setUsageStats(stats)
    }

    private func setUsageStats(_ stats: [ClaudeUsageParser.UsageStat] = [], loading: Bool = false) {
        usageStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if loading {
            let label = NSTextField(labelWithString: "Loading…")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            usageStack.addArrangedSubview(label)
            return
        }

        if stats.isEmpty {
            let label = NSTextField(labelWithString: "No usage data")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            usageStack.addArrangedSubview(label)
            return
        }

        for stat in stats {
            let row = NSStackView()
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 3
            row.translatesAutoresizingMaskIntoConstraints = false
            usageStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: usageStack.widthAnchor).isActive = true

            let title = NSTextField(labelWithString: "\(stat.title): \(stat.percent)%")
            title.font = .systemFont(ofSize: 11)
            title.textColor = .labelColor
            row.addArrangedSubview(title)

            let bar = UsagePercentBarView()
            bar.percent = stat.percent
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
            row.addArrangedSubview(bar)
            bar.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true

            if let detail = stat.detail {
                let detailLabel = NSTextField(labelWithString: detail.prefix(1).capitalized + detail.dropFirst())
                detailLabel.font = .systemFont(ofSize: 10)
                detailLabel.textColor = .tertiaryLabelColor
                row.addArrangedSubview(detailLabel)
            }
        }
    }
}

// MARK: - Status Item Manager

class ClaudeStatusItemManager: NSObject {
    private static let refreshInterval: TimeInterval = 5 * 60

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var vc: ClaudeUsageViewController!
    private var iconTimer: Timer?
    private var lastStats: [ClaudeUsageParser.UsageStat] = []

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Claude Usage")
            btn.image?.isTemplate = true
            btn.imagePosition = .imageLeading
            btn.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            btn.action = #selector(togglePopover(_:))
            btn.target = self
        }

        vc = ClaudeUsageViewController()
        popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient

        refreshIcon()
        iconTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshIcon()
        }
    }

    private func refreshIcon() {
        ClaudeUsageParser.fetchUsageSummary { [weak self] stats in
            guard let self else { return }
            self.lastStats = stats
            let stat = stats.first(where: { $0.title == "Current session" }) ?? stats.first
            guard let stat else { return }
            self.statusItem.button?.title = " \(stat.percent)%"
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            vc.showStats(lastStats)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}

import Foundation
import GitCore
import Observation

enum BackgroundFetchInterval: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case every5Minutes = 300
    case every10Minutes = 600
    case every15Minutes = 900
    case every30Minutes = 1800
    case everyHour = 3600

    var id: Int { rawValue }
    var seconds: TimeInterval? { self == .off ? nil : TimeInterval(rawValue) }
    var isEnabled: Bool { self != .off }
    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .every5Minutes: String(localized: "Every 5 minutes")
        case .every10Minutes: String(localized: "Every 10 minutes")
        case .every15Minutes: String(localized: "Every 15 minutes")
        case .every30Minutes: String(localized: "Every 30 minutes")
        case .everyHour: String(localized: "Every hour")
        }
    }
}

@MainActor @Observable
final class AppPreferences {
    static let shared = AppPreferences()
    static let backgroundFetchIntervalDidChangeNotification = Notification.Name("GitPico.backgroundFetchIntervalDidChange")
    var offerAutomaticStash = true { didSet { save() } }
    var backgroundFetchInterval: BackgroundFetchInterval = .off {
        didSet {
            save()
            if !isLoading, oldValue != backgroundFetchInterval {
                NotificationCenter.default.post(name: Self.backgroundFetchIntervalDidChangeNotification, object: self)
            }
        }
    }
    var pullPolicy: PullPolicy = .merge { didSet { save() } }
    var resumeWorkspace = true { didSet { save() } }
    var diffFontSize = 12.0 { didSet { save() } }
    var splitDiff = false { didSet { save() } }
    var historyShowGraph = true { didSet { save() } }
    var historyCompact = false { didSet { save() } }
    var historyGroups = true { didSet { save() } }
    var workingTreeView = false { didSet { save() } }
    var lastSaveError: String?
    private var widths: [String: Double] = [:]
    @ObservationIgnored private var isLoading = true
    private let file: URL

    init(file: URL? = nil) {
        defer { isLoading = false }
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitPico", isDirectory: true).appendingPathComponent("preferences.json")
        if let data = try? Data(contentsOf: self.file), let values = try? JSONDecoder().decode([String: Double].self, from: data) {
            offerAutomaticStash = values["offerAutomaticStash"] != 0
            if let rawInterval = values["backgroundFetchInterval"] {
                backgroundFetchInterval = BackgroundFetchInterval(rawValue: Int(rawInterval)) ?? .off
            } else {
                backgroundFetchInterval = values["backgroundFetch"] == 1 ? .every5Minutes : .off
            }
            pullPolicy = PullPolicy(rawValue: Int(values["pullPolicy"] ?? 1)) ?? .merge
            resumeWorkspace = values["resumeWorkspace"] != 0
            diffFontSize = min(18, max(10, values["fontSize"] ?? 12))
            splitDiff = values["splitDiff"] == 1
            historyShowGraph = values["graph"] != 0
            historyCompact = values["compact"] == 1
            historyGroups = values["groups"] != 0
            workingTreeView = values["workingTreeView"] == 1
            widths = values.filter { $0.key.hasPrefix("split.") }
        }
    }

    func width(for name: String) -> Double? { widths["split." + name] }
    func setWidth(_ width: Double, for name: String) {
        let value = width.rounded()
        guard widths["split." + name] != value else { return }
        widths["split." + name] = value; save()
    }

    private func save() {
        guard !isLoading else { return }
        var values = widths
        values["backgroundFetchInterval"] = Double(backgroundFetchInterval.rawValue)
        values["backgroundFetch"] = backgroundFetchInterval.isEnabled ? 1 : 0
        values["pullPolicy"] = Double(pullPolicy.rawValue)
        values["resumeWorkspace"] = resumeWorkspace ? 1 : 0
        values["offerAutomaticStash"] = offerAutomaticStash ? 1 : 0
        values["fontSize"] = diffFontSize
        values["splitDiff"] = splitDiff ? 1 : 0
        values["graph"] = historyShowGraph ? 1 : 0
        values["compact"] = historyCompact ? 1 : 0
        values["groups"] = historyGroups ? 1 : 0
        values["workingTreeView"] = workingTreeView ? 1 : 0
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(values).write(to: file, options: .atomic)
            lastSaveError = nil
        } catch { lastSaveError = error.localizedDescription }
    }
}

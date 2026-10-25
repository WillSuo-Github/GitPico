import Foundation
import Observation

@MainActor @Observable
final class AppPreferences {
    static let shared = AppPreferences()
    var offerAutomaticStash = true { didSet { save() } }
    var diffFontSize = 12.0 { didSet { save() } }
    var splitDiff = false { didSet { save() } }
    var historyShowGraph = true { didSet { save() } }
    var historyCompact = false { didSet { save() } }
    var historyGroups = true { didSet { save() } }
    var lastSaveError: String?
    private var widths: [String: Double] = [:]
    @ObservationIgnored private var isLoading = true
    private let file: URL

    private init() {
        defer { isLoading = false }
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitPico", isDirectory: true).appendingPathComponent("preferences.json")
        if let data = try? Data(contentsOf: file), let values = try? JSONDecoder().decode([String: Double].self, from: data) {
            offerAutomaticStash = values["offerAutomaticStash"] != 0
            diffFontSize = min(18, max(10, values["fontSize"] ?? 12))
            splitDiff = values["splitDiff"] == 1
            historyShowGraph = values["graph"] != 0
            historyCompact = values["compact"] == 1
            historyGroups = values["groups"] != 0
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
        values["offerAutomaticStash"] = offerAutomaticStash ? 1 : 0
        values["fontSize"] = diffFontSize
        values["splitDiff"] = splitDiff ? 1 : 0
        values["graph"] = historyShowGraph ? 1 : 0
        values["compact"] = historyCompact ? 1 : 0
        values["groups"] = historyGroups ? 1 : 0
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(values).write(to: file, options: .atomic)
            lastSaveError = nil
        } catch { lastSaveError = error.localizedDescription }
    }
}

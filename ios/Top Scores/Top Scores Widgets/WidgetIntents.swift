import AppIntents
import WidgetKit

@available(iOS 17.0, *)
struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Matches"
    static var description = IntentDescription("Refresh match data in the widget")

    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

@available(iOS 16.0, *)
struct WidgetConfigurationIntent: AppIntent {
    static var title: LocalizedStringResource = "Configure Widget"
    static var description = IntentDescription("Configure which matches to show")

    func perform() async throws -> some IntentResult {
        return .result()
    }
}

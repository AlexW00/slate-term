import Testing
import SlateTermCore
@testable import SlateTermSettings

@Test func notificationSettingsRoundtripAndSourcePreservation() throws {
    let source = "# keep\n[terminal]\nfont_size = 14\n[plugins.example]\nvalue = 'keep'\n"
    let changed = try ConfigurationPatch.updating(source: source, values: [
        "notifications.minimum_seconds": .integer(45), "notifications.automatic": .bool(false),
        "notifications.banners": .string("other_apps"), "notifications.sound": .bool(true),
        "notifications.command_details": .bool(true), "notifications.tools": .bool(false)])
    let parsed = try AppConfiguration.parse(changed)
    #expect(parsed.notifications.minimumSeconds == 45 && !parsed.notifications.automatic && !parsed.notifications.tools)
    #expect(parsed.notifications.sound && parsed.notifications.commandDetails && parsed.notifications.banners == .otherApps)
    #expect(parsed.plugins == (try AppConfiguration.parse(source)).plugins)
    #expect(changed.contains("# keep") && changed.contains("value = 'keep'"))
    #expect(parsed.restartRequired(from: try AppConfiguration.parse(source)).isEmpty)
    #expect(parsed.changedKeys(from: try AppConfiguration.parse(source)).filter { $0.hasPrefix("notifications.") }.count == 6)
    for invalid in ["minimum_seconds = 0", "minimum_seconds = 86401", "minimum_seconds = 1.5", "tools = 1", "banners = 'always'", "surprise = true"] {
        #expect(throws: (any Error).self) { try AppConfiguration.parse("[notifications]\n" + invalid) }
    }
    #expect(try AppConfiguration.parse("").notifications == NotificationPolicy())
}

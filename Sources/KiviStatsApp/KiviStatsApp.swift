import KiviCore
import SwiftUI

/// Kivi-Dash — a menu bar app that reads Kivi's dictation history read-only and
/// shows numbers only.
///
/// `MenuBarExtra` is deliberately the ONLY scene: Apple documents that when the
/// user removes the menu bar item the application is quit, so it must not be
/// combined with other scene types. Any settings live inside the popover.
@main
struct KiviStatsApp: App {
    @State private var model: StatsModel

    init() {
        let model = StatsModel()
        _model = State(initialValue: model)
        // Started here rather than from a view's `.task` or `.onAppear`: the
        // popover only exists once the user clicks the icon, and `MenuBarExtra`'s
        // label does not reliably fire `.onAppear`. A user who installs this and
        // only glances at the menu bar would otherwise never ingest anything.
        model.start()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            // The status item doubles as the health indicator: healthy, stale,
            // transient trouble, or needs attention.
            Image(systemName: model.health.symbolName)
                .accessibilityLabel("Kivi-Dash")
        }
        .menuBarExtraStyle(.window)
    }
}

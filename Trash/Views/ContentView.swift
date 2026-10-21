import SwiftUI

struct ContentView: View {
    @State private var model = CleanupViewModel()
    @State private var isCleanupSheetPresented = false

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 300)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    CleanupBar(model: model) {
                        isCleanupSheetPresented = true
                    }
                }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.scan() }
                } label: {
                    Label("Найти мусор заново", systemImage: "arrow.clockwise")
                }
                .disabled(model.phase != .idle)
                .help("Найти мусор заново")
            }
        }
        .toolbarBackground(Theme.background, for: .windowToolbar)
        // Одно окно на всю очистку: подтверждение → ход очистки → отчёт. Второй sheet после закрытия первого
        // мог бы не открыться, если очистка закончится быстрее анимации.
        .sheet(isPresented: $isCleanupSheetPresented, onDismiss: { model.isReportPresented = false }) {
            cleanupSheet
                .interactiveDismissDisabled(model.phase == .cleaning)
        }
        .task {
            guard !Self.isRunningTests else { return }
            await model.scan()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selectedItem {
        case let .category(category):
            CategoryDetailView(model: model, category: category)
        case let .group(group):
            // `id` сбрасывает раскрытые разделы при переходе между группами.
            GroupOverviewView(model: model, group: group)
                .id(group)
        case .overview, nil:
            OverviewView(model: model)
        }
    }

    @ViewBuilder
    private var cleanupSheet: some View {
        if model.isReportPresented, let report = model.lastReport {
            CleanupReportSheet(report: report)
        } else if model.phase == .cleaning {
            CleaningProgressView()
        } else {
            ConfirmCleanupSheet(model: model) { permanently in
                Task { await model.cleanSelected(permanently: permanently) }
            }
        }
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

#Preview {
    ContentView()
        .preferredColorScheme(.dark)
}

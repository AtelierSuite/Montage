import MontageEngine
import MontageFormats
import SwiftUI

/// What an imported project couldn't bring across, shown once it's in:
/// a line for each kind ("3 effects couldn't be imported"), then each thing,
/// with the clip it was on and where.
struct ImportReportView: View {
    let report: ImportReport
    /// The project's frames, to say where things were as timecode.
    let frames: FrameTime
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(String(format: String(localized: "ImportReport.Source"), report.format.displayName))
                    if report.isEmpty {
                        Label("ImportReport.AllClear", systemImage: "checkmark.circle")
                    }
                    ForEach(categories, id: \.self) { category in
                        Label(summary(of: category), systemImage: symbol(for: category))
                    }
                }
                ForEach(categories, id: \.self) { category in
                    Section {
                        ForEach(report.items(in: category)) { item in
                            row(for: item)
                        }
                    } header: {
                        Text(title(of: category))
                    } footer: {
                        if category == .missingMedia { Text("ImportReport.MissingMediaNote") }
                    }
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            .frame(minWidth: 480, minHeight: 360)
            #endif
            .navigationTitle("ImportReport.Title")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("ImportReport.Done", action: dismiss)
                }
            }
        }
    }

    private var categories: [ImportReport.Category] {
        ImportReport.Category.allCases.filter { !report.items(in: $0).isEmpty }
    }

    private func row(for item: ImportReport.Item) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.issue.message)
            let place = [item.clipName, item.time.map(frames.timecode)].compactMap { $0 }
            if !place.isEmpty {
                Text(place.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func summary(of category: ImportReport.Category) -> String {
        let count = report.items(in: category).count
        return switch category {
        case .unsupportedEffect: String(format: String(localized: "ImportReport.Summary.UnsupportedEffect"), count)
        case .missingMedia: String(format: String(localized: "ImportReport.Summary.MissingMedia"), count)
        case .notImported: String(format: String(localized: "ImportReport.Summary.NotImported"), count)
        case .changed: String(format: String(localized: "ImportReport.Summary.Changed"), count)
        }
    }

    private func title(of category: ImportReport.Category) -> LocalizedStringKey {
        switch category {
        case .unsupportedEffect: "ImportReport.Section.UnsupportedEffect"
        case .missingMedia: "ImportReport.Section.MissingMedia"
        case .notImported: "ImportReport.Section.NotImported"
        case .changed: "ImportReport.Section.Changed"
        }
    }

    private func symbol(for category: ImportReport.Category) -> String {
        switch category {
        case .unsupportedEffect: "wand.and.sparkles"
        case .missingMedia: "questionmark.folder"
        case .notImported: "minus.circle"
        case .changed: "arrow.triangle.2.circlepath"
        }
    }
}

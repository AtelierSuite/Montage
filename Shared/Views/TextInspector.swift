import CoreGraphics
import MontageEngine
import SwiftUI

/// A text clip's words and formatting: the words, with bold, italic and
/// colour for the part selected, then the font, fill, outline, shadow and
/// box for the whole clip, each value keyframeable at the playhead. Presets
/// put on a saved look in one go.
struct TextInspector: View {
    let editing: ClipEditing

    @State private var selection: TextSelection?
    @State private var isNamingPreset = false
    @State private var presetName = ""
    private var presets: TextPresetLibrary { TextPresetLibrary.shared }

    private static let families = FontResolver.families

    var body: some View {
        let style = editing.clip.textContent.style
        Section {
            TextEditor(text: words, selection: $selection)
                .frame(minHeight: 72)
                .accessibilityLabel(Text("Inspector.Text.Words"))
            formattingBar
        } header: {
            HStack {
                Text("Inspector.Text")
                Spacer()
                presetMenu
            }
        }
        Section("Inspector.Text.Font") {
            Picker("Inspector.Text.Font", selection: editing.binding(\.textContent.style.fontFamily)) {
                ForEach(Self.families.contains(style.fontFamily) ? Self.families : [style.fontFamily] + Self.families,
                        id: \.self) { family in
                    Text(verbatim: family).tag(family)
                }
            }
            Picker("Inspector.Text.Weight", selection: editing.binding(\.textContent.style.weight)) {
                ForEach(FontWeight.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            }
            Toggle("Inspector.Text.Italic", isOn: editing.binding(\.textContent.style.isItalic))
            ParameterSlider("Inspector.Text.Size", editing.parameter(\.textContent.style.fontSize), in: 8...400,
                            format: ParameterFormat.whole)
            Picker("Inspector.Text.Alignment", selection: editing.binding(\.textContent.style.alignment)) {
                ForEach(TextAlignment.allCases, id: \.self) { alignment in
                    Label(alignment.title, systemImage: alignment.symbol).labelStyle(.iconOnly).tag(alignment)
                }
            }
            .pickerStyle(.segmented)
            ParameterSlider("Inspector.Text.LineSpacing", editing.parameter(\.textContent.style.lineSpacing), in: -40...200,
                            format: ParameterFormat.whole)
            ParameterSlider("Inspector.Text.LetterSpacing", editing.parameter(\.textContent.style.letterSpacing), in: -20...100,
                            format: ParameterFormat.whole)
            LabeledContent("Inspector.Text.WrapWidth") {
                Slider(value: editing.binding(\.textContent.style.wrapWidth), in: 0.1...1)
            }
        }
        Section("Inspector.Fill") {
            FillControls(editing: editing, fill: \.textContent.style.fill)
        }
        Section {
            StrokeControls(editing: editing, stroke: \.textContent.style.outline, title: "Inspector.Text.Outline",
                           showsLineStyle: false)
        }
        Section {
            ShadowControls(editing: editing, shadow: \.textContent.style.shadow)
        }
        Section {
            Toggle("Inspector.Text.Background", isOn: editing.binding(\.textContent.style.background.isEnabled))
            if style.background.isEnabled {
                ColorParameterPicker("Inspector.Text.Background.Color", editing.parameter(\.textContent.style.background.color))
                ParameterSlider("Inspector.Text.Background.Padding", editing.parameter(\.textContent.style.background.padding),
                                in: 0...200, format: ParameterFormat.whole)
                ParameterSlider("Inspector.Text.Background.CornerRadius",
                                editing.parameter(\.textContent.style.background.cornerRadius), in: 0...200,
                                format: ParameterFormat.whole)
            }
        }
        .alert("Inspector.Text.Preset.SaveTitle", isPresented: $isNamingPreset) {
            TextField("Inspector.Text.Preset.Name", text: $presetName)
            Button("Inspector.Text.Preset.Save", action: savePreset)
            Button("Relink.Cancel", role: .cancel) {}
        }
    }

    // MARK: - Words

    /// The words, changed keeping each piece's formatting.
    private var words: Binding<String> {
        Binding {
            editing.clip.textContent.string
        } set: { string in
            guard string != editing.clip.textContent.string else { return }
            editing.change { $0.textContent.replaceString(with: string) }
        }
    }

    /// The characters selected, counted from the start; all of them when
    /// nothing's selected.
    private var formattedRange: Range<Int> {
        let string = editing.clip.textContent.string
        let all = 0..<string.count
        guard let selection, case .selection(let range) = selection.indices else { return all }
        func characters(before index: String.Index) -> Int {
            let offset = min(max(index.utf16Offset(in: string), 0), string.utf16.count)
            return String(decoding: Array(string.utf16.prefix(offset)), as: UTF16.self).count
        }
        let selected = characters(before: range.lowerBound)..<characters(before: range.upperBound)
        return selected.isEmpty ? all : selected
    }

    private var formattingBar: some View {
        let text = editing.clip.textContent
        let range = formattedRange
        let formatting = text.formatting(in: range)
        let isBold = (formatting.weight ?? text.style.weight) >= .bold
        let isItalic = formatting.isItalic ?? text.style.isItalic
        return HStack(spacing: 12) {
            Button {
                format(range) { $0.weight = isBold ? (text.style.weight >= .bold ? .regular : nil) : .bold }
            } label: {
                Label("Inspector.Text.Bold", systemImage: "bold").labelStyle(.iconOnly)
            }
            .foregroundStyle(isBold ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .help(Text("Inspector.Text.Bold"))
            Button {
                format(range) { $0.isItalic = isItalic == text.style.isItalic ? !isItalic : nil }
            } label: {
                Label("Inspector.Text.Italic", systemImage: "italic").labelStyle(.iconOnly)
            }
            .foregroundStyle(isItalic ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .help(Text("Inspector.Text.Italic"))
            ColorPicker(selection: Binding {
                (formatting.color ?? text.style.fill.color.value(at: editing.time)).cgColor
            } set: { color in
                if let color = RGBAColor(color) { format(range) { $0.color = color } }
            }) {
                Text("Inspector.Text.SelectionColor")
            }
            .fixedSize()
            Spacer()
            Button {
                format(range) { $0 = TextRun.Formatting() }
            } label: {
                Label("Inspector.Text.ClearFormatting", systemImage: "eraser").labelStyle(.iconOnly)
            }
            .help(Text("Inspector.Text.ClearFormatting"))
        }
        .buttonStyle(.borderless)
    }

    private func format(_ range: Range<Int>, _ change: @escaping (inout TextRun.Formatting) -> Void) {
        editing.change { $0.textContent.format(range, change) }
    }

    // MARK: - Presets

    private var presetMenu: some View {
        Menu {
            Section("Inspector.Text.Preset.BuiltIn") {
                ForEach(BuiltInTextPreset.allCases, id: \.self) { preset in
                    Button(preset.title) { editing.change { $0.apply(preset.style, position: preset.position) } }
                }
            }
            if !presets.presets.isEmpty {
                Section("Inspector.Text.Preset.Saved") {
                    ForEach(presets.presets) { preset in
                        Button(preset.name) { editing.change { $0.apply(preset.style, position: preset.position) } }
                    }
                }
            }
            Divider()
            Button("Inspector.Text.Preset.SaveCurrent", systemImage: "square.and.arrow.down") {
                presetName = ""
                isNamingPreset = true
            }
            if !presets.presets.isEmpty {
                Menu("Inspector.Text.Preset.Delete", systemImage: "trash") {
                    ForEach(presets.presets) { preset in
                        Button(preset.name, role: .destructive) { presets.remove(preset.id) }
                    }
                }
            }
        } label: {
            Label("Inspector.Text.Presets", systemImage: "textformat.size")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let preset = TextPreset(name: name, from: editing.clip, at: editing.time) else { return }
        presets.save(preset)
    }
}

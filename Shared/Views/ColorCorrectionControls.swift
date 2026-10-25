import MontageEngine
import MontageFormats
import SwiftUI

/// A colour correction's parameters: exposure and tone, white balance, the
/// grade's lift, gamma and gain for each channel, and a look-up table.
struct ColorCorrectionControls: View {
    let editing: EffectEditing

    @State private var isImportingLUT = false
    @State private var lutError: Error?

    var body: some View {
        ParameterSlider("Inspector.Color.Exposure", editing.parameter(\.colorCorrection.exposure), in: -3...3,
                        format: ParameterFormat.stops)
        ParameterSlider("Inspector.Color.Brightness", editing.parameter(\.colorCorrection.brightness), in: -0.5...0.5)
        ParameterSlider("Inspector.Color.Contrast", editing.parameter(\.colorCorrection.contrast), in: 0.25...2)
        ParameterSlider("Inspector.Color.Saturation", editing.parameter(\.colorCorrection.saturation), in: 0...2)
        ParameterSlider("Inspector.Color.Temperature", editing.parameter(\.colorCorrection.temperature), in: 2000...15000,
                        format: ParameterFormat.kelvin)
        ParameterSlider("Inspector.Color.Tint", editing.parameter(\.colorCorrection.tint), in: -100...100,
                        format: ParameterFormat.whole)
        DisclosureGroup("Inspector.Color.Lift") {
            channelSliders(editing.parameter(\.colorCorrection.lift), in: -0.5...0.5)
        }
        DisclosureGroup("Inspector.Color.Gamma") {
            channelSliders(editing.parameter(\.colorCorrection.gamma), in: 0.25...3)
        }
        DisclosureGroup("Inspector.Color.Gain") {
            channelSliders(editing.parameter(\.colorCorrection.gain), in: 0...2)
        }
        lutControls
    }

    /// A slider for each of red, green and blue.
    @ViewBuilder
    private func channelSliders(_ parameter: ParameterEditing<RGBValues>, in range: ClosedRange<Double>) -> some View {
        ParameterSlider("Inspector.Color.Red", parameter, in: range, component: \.red, setComponent: { $0.red = $1 })
        ParameterSlider("Inspector.Color.Green", parameter, in: range, component: \.green, setComponent: { $0.green = $1 })
        ParameterSlider("Inspector.Color.Blue", parameter, in: range, component: \.blue, setComponent: { $0.blue = $1 })
    }

    @ViewBuilder
    private var lutControls: some View {
        let lut = editing.effect.colorCorrection.lut
        LabeledContent("Inspector.Color.LUT") {
            HStack {
                Text(verbatim: lut?.name ?? String(localized: "Inspector.Color.LUT.None"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Menu {
                    Button("Inspector.Color.LUT.Choose") { isImportingLUT = true }
                    if lut != nil {
                        Button("Inspector.Color.LUT.Remove", role: .destructive) {
                            editing.change { $0.colorCorrection.lut = nil }
                        }
                    }
                } label: {
                    Label("Inspector.Color.LUT", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .fileImporter(isPresented: $isImportingLUT, allowedContentTypes: [.cubeLUT]) { result in
            Task {
                do {
                    let url = try result.get()
                    let isScoped = url.startAccessingSecurityScopedResource()
                    defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
                    let lut = try await CubeLUT.load(contentsOf: url)
                    editing.change { $0.colorCorrection.lut = lut }
                } catch {
                    lutError = error
                }
            }
        }
        .alert("Inspector.Color.LUT.Error", isPresented: Binding { lutError != nil } set: { if !$0 { lutError = nil } }) {
        } message: {
            Text(verbatim: lutError?.localizedDescription ?? "")
        }
        if lut != nil {
            ParameterSlider("Inspector.Color.LUT.Intensity", editing.parameter(\.colorCorrection.lutIntensity), in: 0...1,
                            format: ParameterFormat.percent)
        }
    }
}

import MontageEngine

/// What the inspector and the timeline call the parts of text and shapes.
extension ShapeContent.Kind {
    var title: String {
        switch self {
        case .rectangle: String(localized: "Shape.Rectangle")
        case .roundedRectangle: String(localized: "Shape.RoundedRectangle")
        case .ellipse: String(localized: "Shape.Ellipse")
        case .line: String(localized: "Shape.Line")
        case .arrow: String(localized: "Shape.Arrow")
        case .polygon: String(localized: "Shape.Polygon")
        case .star: String(localized: "Shape.Star")
        }
    }

    var symbol: String {
        switch self {
        case .rectangle: "rectangle"
        case .roundedRectangle: "app"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.right"
        case .polygon: "hexagon"
        case .star: "star"
        }
    }
}

extension FontWeight {
    var title: String {
        switch self {
        case .ultraLight: String(localized: "Inspector.Text.Weight.UltraLight")
        case .thin: String(localized: "Inspector.Text.Weight.Thin")
        case .light: String(localized: "Inspector.Text.Weight.Light")
        case .regular: String(localized: "Inspector.Text.Weight.Regular")
        case .medium: String(localized: "Inspector.Text.Weight.Medium")
        case .semibold: String(localized: "Inspector.Text.Weight.Semibold")
        case .bold: String(localized: "Inspector.Text.Weight.Bold")
        case .heavy: String(localized: "Inspector.Text.Weight.Heavy")
        case .black: String(localized: "Inspector.Text.Weight.Black")
        }
    }
}

extension TextAlignment {
    var title: String {
        switch self {
        case .leading: String(localized: "Inspector.Text.Alignment.Leading")
        case .center: String(localized: "Inspector.Text.Alignment.Center")
        case .trailing: String(localized: "Inspector.Text.Alignment.Trailing")
        }
    }

    var symbol: String {
        switch self {
        case .leading: "text.alignleft"
        case .center: "text.aligncenter"
        case .trailing: "text.alignright"
        }
    }
}

extension LayerFill.Style {
    var title: String {
        switch self {
        case .none: String(localized: "Inspector.Fill.None")
        case .solid: String(localized: "Inspector.Fill.Solid")
        case .linearGradient: String(localized: "Inspector.Fill.LinearGradient")
        case .radialGradient: String(localized: "Inspector.Fill.RadialGradient")
        }
    }
}

extension LayerStroke.Dash {
    var title: String {
        switch self {
        case .solid: String(localized: "Inspector.Stroke.Dash.Solid")
        case .dashed: String(localized: "Inspector.Stroke.Dash.Dashed")
        case .dotted: String(localized: "Inspector.Stroke.Dash.Dotted")
        }
    }
}

extension LayerStroke.Cap {
    var title: String {
        switch self {
        case .butt: String(localized: "Inspector.Stroke.Cap.Butt")
        case .round: String(localized: "Inspector.Stroke.Cap.Round")
        case .square: String(localized: "Inspector.Stroke.Cap.Square")
        }
    }
}

extension LayerStroke.Join {
    var title: String {
        switch self {
        case .miter: String(localized: "Inspector.Stroke.Join.Miter")
        case .round: String(localized: "Inspector.Stroke.Join.Round")
        case .bevel: String(localized: "Inspector.Stroke.Join.Bevel")
        }
    }
}

extension FrameFit {
    var title: String {
        switch self {
        case .fit: String(localized: "Inspector.Fit.Fit")
        case .fill: String(localized: "Inspector.Fit.Fill")
        case .stretch: String(localized: "Inspector.Fit.Stretch")
        }
    }
}

extension BuiltInTextPreset {
    var title: String {
        switch self {
        case .title: String(localized: "TextPreset.Title")
        case .lowerThird: String(localized: "TextPreset.LowerThird")
        case .caption: String(localized: "TextPreset.Caption")
        case .subtitle: String(localized: "TextPreset.Subtitle")
        }
    }
}

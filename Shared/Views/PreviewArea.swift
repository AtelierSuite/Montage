import SwiftUI

/// Where the project plays back: a 16:9 frame, fitted into whatever room
/// the editor leaves it, on black like a viewer.
struct PreviewArea: View {
    var body: some View {
        ZStack {
            Color.black
            Rectangle()
                .fill(Color(white: 0.08))
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: "film")
                            .font(.largeTitle)
                        Text("Preview.Empty.Title")
                            .font(.headline)
                        Text("Preview.Empty.Message")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.6))
                    .padding()
                }
                .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

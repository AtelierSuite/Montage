import SwiftUI

/// Shown while an imported project is read and its media copied in.
struct ProjectImportProgressView: View {
    var body: some View {
        ProgressView {
            Text("ProjectImport.Importing")
        }
        .padding(24)
    }
}

import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

/// Seconds.
private func s(_ seconds: Int64) -> CMTime {
    CMTime(value: seconds, timescale: 1)
}

struct MarkerTests {
    @Test func keepsMarkersInOrderOnePerTime() {
        var project = Project()
        let late = project.addMarker(at: s(5))
        project.addMarker(at: s(1))
        #expect(project.addMarker(at: s(5)) == late)
        #expect(project.markers.map(\.time) == [s(1), s(5)])
        project.removeMarkers([late])
        #expect(project.markers.map(\.time) == [s(1)])
    }

    @Test func projectsWithoutMarkersStillOpen() throws {
        let json = #"{"formatVersion": 1}"#
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(project.markers.isEmpty)
        var marked = Project()
        marked.addMarker(at: CMTime(value: 1001, timescale: 30000), name: "Here")
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(marked))
        #expect(decoded.markers == marked.markers)
    }
}

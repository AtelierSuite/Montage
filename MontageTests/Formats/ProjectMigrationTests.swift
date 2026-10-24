import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

struct ProjectMigrationTests {
    private func json(_ string: String) -> Data { Data(string.utf8) }

    @Test func readsTheCurrentVersionAsIs() throws {
        let project = try ProjectPackage.decodeProject(from: json(#"{"formatVersion": 1}"#))
        #expect(project.formatVersion == Project.currentFormatVersion)
    }

    @Test func refusesANewerVersion() {
        #expect(throws: ProjectPackageError.self) {
            try ProjectPackage.decodeProject(from: json(#"{"formatVersion": 99}"#))
        }
    }

    @Test func refusesAProjectWithoutAVersion() {
        #expect(throws: ProjectPackageError.self) {
            try ProjectPackage.decodeProject(from: json(#"{"media": []}"#))
        }
    }

    @Test func runsEachStepFromAnOlderVersionInOrder() throws {
        // Pretend the format is at version 3, and the project was saved in 1
        // with its settings under a different name.
        let migrations = [
            ProjectMigration(from: 2) { object in
                object["settings"] = object.removeValue(forKey: "oldSettings")
            },
            ProjectMigration(from: 1) { object in
                object["oldSettings"] = object.removeValue(forKey: "ancientSettings")
            },
        ]
        let project = try ProjectPackage.decodeProject(
            from: json(#"{"formatVersion": 1, "ancientSettings": {"frameDuration": "1/25"}}"#),
            currentVersion: 3, migrations: migrations
        )
        #expect(project.formatVersion == 3)
        #expect(project.settings.frameDuration.seconds == 0.04)
    }

    @Test func failsWhenAStepIsMissing() {
        #expect(throws: ProjectPackageError.self) {
            try ProjectPackage.decodeProject(from: json(#"{"formatVersion": 1}"#), currentVersion: 2, migrations: [])
        }
    }
}

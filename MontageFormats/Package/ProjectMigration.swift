import Foundation
import MontageEngine

/// A step that brings a project saved in one version of the format up to the
/// next. It works on the JSON as read, before it is decoded, so it can rename,
/// move or fill in whatever the model of that version had differently.
public struct ProjectMigration: Sendable {
    public typealias JSONObject = [String: Any]

    /// The version the step reads. It leaves the project in the version after.
    public let fromVersion: Int
    private let change: @Sendable (inout JSONObject) throws -> Void

    public init(from version: Int, _ change: @escaping @Sendable (inout JSONObject) throws -> Void) {
        fromVersion = version
        self.change = change
    }

    func apply(to object: inout JSONObject) throws {
        try change(&object)
    }

    /// Every step from each past version to the next, in order. Version 1 is
    /// the first, so there's nothing to migrate from yet: when the format
    /// changes, raise `Project.currentFormatVersion` and add the step from the
    /// version before here.
    public static let all: [ProjectMigration] = []

    /// Brings the JSON of a project up to `version`, one step at a time.
    static func migrate(
        _ object: inout JSONObject, from oldVersion: Int, to version: Int, using migrations: [ProjectMigration]
    ) throws {
        var current = oldVersion
        while current < version {
            guard let step = migrations.first(where: { $0.fromVersion == current }) else {
                throw ProjectPackageError.missingMigration(from: current)
            }
            try step.apply(to: &object)
            current += 1
            object[ProjectPackage.formatVersionKey] = current
        }
    }
}

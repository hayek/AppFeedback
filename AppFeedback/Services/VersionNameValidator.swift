import Foundation

/// The one rule for what a version may be called, shared by create and rename.
///
/// Uniqueness is enforced here rather than by the model because CloudKit forbids
/// `@Attribute(.unique)`. It matters: `name` is the key that joins tasks, sent release emails, and
/// saved filters to a version, so two versions sharing a name would silently merge each other's
/// task lists. GitHub's 422 on a duplicate milestone title is only a backstop for the remote write.
enum VersionNameValidator {
    enum Failure: LocalizedError, Equatable {
        case empty
        case duplicate(String)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Enter a version name."
            case .duplicate(let name):
                return "This product already has a version named “\(name)”."
            }
        }
    }

    /// Returns the trimmed name, or throws.
    /// - Parameters:
    ///   - existing: every version in the same product.
    ///   - renaming: the version being renamed — excluded from the duplicate check so it doesn't
    ///     collide with itself. `nil` when creating.
    static func validate(_ proposed: String,
                         existing: [ProjectVersion],
                         renaming: ProjectVersion? = nil) throws -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.empty }

        let subjectID = renaming?.id
        let collides = existing.contains {
            $0.id != subjectID && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !collides else { throw Failure.duplicate(trimmed) }

        return trimmed
    }
}

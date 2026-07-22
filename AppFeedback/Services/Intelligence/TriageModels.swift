import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What kind of actionable feedback this is. Praise, content-free negativity,
/// and questions/support requests are not task-worthy and have no kind.
enum TriageKind: String, Sendable, CaseIterable {
    case bug
    case featureRequest
    case usability

    /// Lenient parse of free-form model output ("Bug Report", "feature request", …).
    init?(modelOutput: String) {
        let folded = modelOutput.lowercased().filter(\.isLetter)
        switch folded {
        case "bug", "bugreport", "crash", "regression": self = .bug
        case "featurerequest", "feature": self = .featureRequest
        case "usability", "usabilitycomplaint", "friction": self = .usability
        default: return nil
        }
    }
}

/// Plain-Swift stage-1 verdict mirror (views/tests don't need FoundationModels).
struct TriageClassificationDTO: Equatable, Sendable {
    var isActionable: Bool
    var kind: TriageKind?
    var signal: String
}

/// A candidate task the stage-2 matcher may assign feedback to.
struct TriageTaskRosterEntry: Equatable, Sendable {
    let number: Int
    let title: String
}

/// Plain-Swift stage-2 decision mirror.
enum TriageDecisionDTO: Equatable, Sendable {
    case assign(taskNumber: Int)
    case createNew(title: String, summary: String)

    /// Hallucination guard: an `assign` whose number was not in the roster actually
    /// sent to the model demotes to `createNew` with the fallback content.
    func validated(againstRoster rosterNumbers: Set<Int>,
                   fallbackTitle: String, fallbackSummary: String) -> TriageDecisionDTO {
        guard case .assign(let number) = self, !rosterNumbers.contains(number) else { return self }
        return .createNew(title: fallbackTitle, summary: fallbackSummary)
    }
}

extension TriageDecisionDTO {
    /// True when a claimed match names a task that was actually in the prompt AND
    /// reproduces its exact title (case-insensitive, whitespace-trimmed). Strictness
    /// is deliberate: diagnostics showed the model claims matches eagerly, and
    /// failing to reproduce the title is the reliable tell. A '#N '-prefixed copy
    /// intentionally fails.
    static func matchClaimIsValid(claimedNumber: Int, claimedTitle: String,
                                  includedRoster: [TriageTaskRosterEntry]) -> Bool {
        guard let entry = includedRoster.first(where: { $0.number == claimedNumber }) else { return false }
        return entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(claimedTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                     options: [.caseInsensitive]) == .orderedSame
    }
}

#if canImport(FoundationModels)
@available(macOS 26, iOS 26, *)
@Generable
struct TriageClassification: Equatable, Sendable {
    @Guide(description: "true only when the feedback describes something a developer can act on: a bug, crash, or regression; a concrete feature request; or a usability complaint (confusing, hard to find, too many steps). false for praise, content-free negativity ('don't like it'), and questions or support requests.")
    var isActionable: Bool

    @Guide(description: "Exactly one of: bug, featureRequest, usability. Use none when not actionable.")
    var kind: String

    @Guide(description: "One short sentence naming the actionable signal — what is broken or wanted, plus platform/version when stated. Empty when not actionable.")
    var signal: String
}

@available(macOS 26, iOS 26, *)
extension TriageClassificationDTO {
    init(_ c: TriageClassification) {
        let kind = TriageKind(modelOutput: c.kind)
        // An "actionable" verdict without a recognizable kind is demoted — garbage
        // kinds must not produce tasks.
        self.isActionable = c.isActionable && kind != nil
        self.kind = c.isActionable ? kind : nil
        self.signal = c.signal
    }
}

@available(macOS 26, iOS 26, *)
@Generable
struct TriageMatchDecision: Equatable, Sendable {
    @Guide(description: "Does one of the listed tasks describe the SAME specific feature or problem as this feedback? Most feedback does not match any existing task — false is the common, correct answer. Only true when the task is clearly about the same thing.")
    var anExistingTaskMatches: Bool

    @Guide(description: "When anExistingTaskMatches is true: the EXACT title of that task, copied verbatim from the list (without the #number). Empty string otherwise.")
    var matchedTaskTitle: String

    @Guide(description: "When anExistingTaskMatches is true: that task's number. 0 otherwise.")
    var taskNumber: Int

    @Guide(description: "When anExistingTaskMatches is false: a short imperative title for a new task, e.g. 'Fix crash when exporting on iPad'. Empty otherwise.")
    var newTaskTitle: String

    @Guide(description: "When anExistingTaskMatches is false: one or two plain sentences describing the new task, grounded in the feedback. Empty otherwise.")
    var newTaskSummary: String
}

@available(macOS 26, iOS 26, *)
extension TriageDecisionDTO {
    /// Converts a raw model decision, demoting unverifiable match claims to createNew.
    init(_ d: TriageMatchDecision, includedRoster: [TriageTaskRosterEntry],
         fallbackTitle: String, fallbackSummary: String) {
        if d.anExistingTaskMatches,
           Self.matchClaimIsValid(claimedNumber: d.taskNumber, claimedTitle: d.matchedTaskTitle,
                                  includedRoster: includedRoster) {
            self = .assign(taskNumber: d.taskNumber)
        } else {
            let title = d.newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = d.newTaskSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            self = .createNew(title: title.isEmpty ? fallbackTitle : title,
                              summary: summary.isEmpty ? fallbackSummary : summary)
        }
    }
}
#endif

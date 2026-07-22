# Triage Debug Clear Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two DEBUG-only buttons in Settings → Intelligence → Feedback Triage that clear pending triage suggestions or all triage verdicts, so the pipeline can be re-tested on existing feedback.

**Architecture:** Store gains `deleteAll()`/`deletePending()`; coordinator exposes thin passthroughs; the settings section gets two optional closures rendered as `#if DEBUG` buttons; `SettingsView` wires them from the environment coordinator.

**Tech Stack:** SwiftUI, SwiftData, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-22-triage-debug-clear-design.md`

## Global Constraints

- Buttons are `#if DEBUG` only and render only when their closure is non-nil.
- Per-repo snapshot markers are NOT touched by either action (clearing them would re-snapshot instead of re-triage).
- Test target `AppFeedbackTests_macOS`: `xcodebuild test -project AppFeedback.xcodeproj -scheme AppFeedback_macOS -destination 'platform=macOS' -only-testing:AppFeedbackTests_macOS/TriageVerdictStoreTests 2>&1 | tail -15`. No new files → no xcodegen.
- Both schemes build (iOS: `-scheme AppFeedback_iOS -destination 'generic/platform=iOS'`).
- Commit: stage only touched files; trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Clear actions end-to-end

**Files:**
- Modify: `AppFeedback/Services/TriageVerdictStore.swift`
- Modify: `AppFeedback/Services/FeedbackTriageCoordinator.swift`
- Modify: `AppFeedback/Views/Settings/IntelligenceSettingsSection.swift` (Feedback Triage section)
- Modify: `AppFeedback/Views/Settings/SettingsView.swift` (`.intelligence` detail case)
- Test: `AppFeedbackTests/TriageVerdictStoreTests.swift` (extend)

**Interfaces:**
- Consumes: `TriageVerdictRecord`, `TriageState.pending`, `@Environment(FeedbackTriageCoordinator.self)` available in `SettingsView`.
- Produces: `TriageVerdictStore.deleteAll()`, `TriageVerdictStore.deletePending()`, `FeedbackTriageCoordinator.clearAllVerdicts()`, `FeedbackTriageCoordinator.clearPendingSuggestions()`, `IntelligenceSettingsSection` params `onClearPendingTriage: (() -> Void)? = nil` / `onClearAllTriage: (() -> Void)? = nil`.

- [ ] **Step 1: Write the failing store tests** — append to `TriageVerdictStoreTests`:

```swift
    @Test func deleteAllRemovesEverything() throws {
        let store = try makeStore()
        store.upsert(owner: "o", repo: "r", number: 1) { $0.state = TriageState.pending.rawValue }
        store.upsert(owner: "o", repo: "other", number: 2) { $0.state = TriageState.autoApplied.rawValue }
        store.deleteAll()
        #expect(!store.hasRecord(owner: "o", repo: "r", number: 1))
        #expect(!store.hasRecord(owner: "o", repo: "other", number: 2))
    }

    @Test func deletePendingLeavesOtherStates() throws {
        let store = try makeStore()
        store.upsert(owner: "o", repo: "r", number: 1) { $0.state = TriageState.pending.rawValue }
        store.upsert(owner: "o", repo: "r", number: 2) { $0.state = TriageState.dismissed.rawValue }
        store.upsert(owner: "o", repo: "r", number: 3) { $0.state = TriageState.notActionable.rawValue }
        store.deletePending()
        #expect(!store.hasRecord(owner: "o", repo: "r", number: 1))
        #expect(store.record(owner: "o", repo: "r", number: 2)?.state == TriageState.dismissed.rawValue)
        #expect(store.record(owner: "o", repo: "r", number: 3)?.state == TriageState.notActionable.rawValue)
    }
```

- [ ] **Step 2: Run to verify failure** — store-tests command from Global Constraints. Expected: BUILD FAILURE (`deleteAll` not found).

- [ ] **Step 3: Implement**

`TriageVerdictStore.swift` — add:

```swift
    /// DEBUG re-test aid: forgets every verdict across all repos. Snapshot markers
    /// are untouched, so the next pass re-triages instead of re-snapshotting.
    func deleteAll() {
        let all = (try? context.fetch(FetchDescriptor<TriageVerdictRecord>())) ?? []
        for record in all { context.delete(record) }
        try? context.save()
    }

    /// DEBUG re-test aid: forgets only pending suggestions (the visible chips).
    func deletePending() {
        let raw = TriageState.pending.rawValue
        let descriptor = FetchDescriptor<TriageVerdictRecord>(predicate: #Predicate { $0.state == raw })
        for record in (try? context.fetch(descriptor)) ?? [] { context.delete(record) }
        try? context.save()
    }
```

`FeedbackTriageCoordinator.swift` — add near the other UI-facing methods (`dismiss`/`pendingSuggestion`):

```swift
    /// DEBUG: forget every triage verdict so unlinked feedback re-triages.
    func clearAllVerdicts() {
        store.deleteAll()
    }

    /// DEBUG: forget pending suggestions only.
    func clearPendingSuggestions() {
        store.deletePending()
    }
```

`IntelligenceSettingsSection.swift` — add the two parameters (defaulted, after `triageSettings`):

```swift
    /// DEBUG-only triage re-test hooks; buttons render only when non-nil.
    var onClearPendingTriage: (() -> Void)? = nil
    var onClearAllTriage: (() -> Void)? = nil
```

and inside the "Feedback Triage" `Section`, after the existing footer text:

```swift
                #if DEBUG
                if let onClearPendingTriage, let onClearAllTriage {
                    HStack {
                        Button("Clear Pending Suggestions", action: onClearPendingTriage)
                        Button("Clear All Triage Verdicts", role: .destructive, action: onClearAllTriage)
                    }
                    Text("Debug: forgets AI triage verdicts so feedback gets triaged again.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                #endif
```

`SettingsView.swift` — in the `.intelligence` case, add a `@Environment(FeedbackTriageCoordinator.self)` property to `SettingsView` if not already present (check first — Task 8 of the triage feature may not have added it here), and pass:

```swift
                onClearPendingTriage: { triageCoordinator.clearPendingSuggestions() },
                onClearAllTriage: { triageCoordinator.clearAllVerdicts() }
```

- [ ] **Step 4: Verify** — store tests pass; full `AppFeedbackTests_macOS` suite no new failures; both schemes build.

- [ ] **Step 5: Commit**

```bash
git add AppFeedback/Services/TriageVerdictStore.swift AppFeedback/Services/FeedbackTriageCoordinator.swift AppFeedback/Views/Settings/IntelligenceSettingsSection.swift AppFeedback/Views/Settings/SettingsView.swift AppFeedbackTests/TriageVerdictStoreTests.swift
git commit -m "feat(triage): debug actions to clear pending or all triage verdicts"
```

---

## Final verification

- [ ] Manual (debug build): both buttons appear under Feedback Triage; Clear Pending removes chips; Clear All also resets AI badges; next refresh/backfill re-triages.

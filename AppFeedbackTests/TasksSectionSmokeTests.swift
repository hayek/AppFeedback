// AppFeedbackTests/TasksSectionSmokeTests.swift
import XCTest
import SwiftUI
@testable import AppFeedback

@MainActor
final class TasksSectionSmokeTests: XCTestCase {

    /// Verifies that TasksSectionView constructs and evaluates its view tree
    /// without crashing when given a populated ProjectInspectorModel.
    /// Behaviour (service calls, status mutations) is exercised by manual K1 verification.
    func testRendersWithoutCrash() {
        let inspector = ProjectInspectorModel()
        inspector.setTasks([
            TaskItem(issue: FeedbackIssue(
                number: 1,
                title: "t",
                createdAt: Date(),
                rawBody: "",
                appName: nil,
                appVersion: nil,
                device: nil,
                osVersion: nil,
                email: nil,
                description: "",
                labels: [IssueLabel(name: AppFeedbackLabels.task, colorHex: "5319e7")]
            ))
        ])
        let view = TasksSectionView(
            repo: RepoConfig(displayName: "P", owner: "o", repo: "r"),
            inspector: inspector
        )
        #if os(macOS)
        let host = NSHostingView(rootView: view)
        XCTAssertNotNil(host)
        #else
        XCTAssertNotNil(view)
        #endif
    }
}

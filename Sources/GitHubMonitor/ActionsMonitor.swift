import Foundation
import SwiftUI

@MainActor
final class ActionsMonitor: ObservableObject {
    @AppStorage("watchedRepositories") private var savedRepositories = ""

    @Published private(set) var runs: [MonitoredWorkflowRun] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isDiscoveringRepositories = false
    @Published private(set) var availableRepositories: [String] = []
    @Published private(set) var errorMessage: String?

    private var refreshTask: Task<Void, Never>?
    private let refreshInterval: Duration = .seconds(30)
    private let recentWorkflowWindow: TimeInterval = 30 * 24 * 60 * 60

    var repositories: [String] {
        savedRepositories
            .split(whereSeparator: { $0.isNewline || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.split(separator: "/").count == 2 }
    }

    var repositoryGroups: [RepositoryGroup] {
        Dictionary(grouping: runs, by: \.repository)
            .map { RepositoryGroup(repository: $0.key, runs: $0.value) }
            .sorted { $0.repository.localizedStandardCompare($1.repository) == .orderedAscending }
    }

    var menuBarSymbol: String {
        if runs.contains(where: { $0.isFailure }) { return "xmark.circle.fill" }
        if runs.contains(where: { $0.isActive }) { return "arrow.triangle.2.circlepath.circle.fill" }
        return "checkmark.circle"
    }

    var statusText: String {
        if repositories.isEmpty { return "Choose repositories to begin" }
        if isLoading { return "Checking \(repositories.count) repositories…" }
        if let errorMessage { return errorMessage }
        let activeCount = runs.filter(\.isActive).count
        return activeCount == 0 ? "No workflow runs in progress" : "\(activeCount) workflow run\(activeCount == 1 ? "" : "s") in progress"
    }

    func start() {
        guard refreshTask == nil else { return }
        if repositories.isEmpty {
            discoverRepositories()
        } else {
            refresh()
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.refreshInterval ?? .seconds(30))
                guard !Task.isCancelled else { return }
                if self?.repositories.isEmpty == false {
                    self?.refresh()
                }
            }
        }
    }

    func setRepositories(_ input: String) {
        savedRepositories = input
        runs = []
        errorMessage = nil
        refresh()
    }

    func discoverRepositories() {
        guard !isDiscoveringRepositories else { return }
        isDiscoveringRepositories = true
        errorMessage = nil
        let recentSince = Date().addingTimeInterval(-recentWorkflowWindow)
        Task {
            defer { isDiscoveringRepositories = false }
            do {
                availableRepositories = try await GitHubActionsClient.fetchRepositoriesWithRecentWorkflowRuns(since: recentSince)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func refresh() {
        let targets = repositories
        guard !targets.isEmpty else {
            runs = []
            return
        }
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        Task {
            defer { isLoading = false }
            do {
                let fetched = try await Self.fetchAllRuns(for: targets)
                runs = fetched.sorted { $0.updatedAt > $1.updatedAt }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    nonisolated private static func fetchAllRuns(for repositories: [String]) async throws -> [MonitoredWorkflowRun] {
        try await withThrowingTaskGroup(of: [MonitoredWorkflowRun].self, returning: [MonitoredWorkflowRun].self) { group in
            for repository in repositories {
                group.addTask { try await GitHubActionsClient.fetchRuns(repository: repository) }
            }

            var fetched: [MonitoredWorkflowRun] = []
            for try await repositoryRuns in group {
                fetched.append(contentsOf: repositoryRuns)
            }
            return fetched
        }
    }
}

struct RepositoryGroup: Identifiable {
    let repository: String
    let runs: [MonitoredWorkflowRun]
    var id: String { repository }
}

struct MonitoredWorkflowRun: Identifiable, Sendable {
    let id: Int64
    let repository: String
    let workflowName: String
    let title: String
    let branch: String?
    let status: String
    let conclusion: String?
    let htmlURL: URL
    let updatedAt: Date

    var isActive: Bool { status == "queued" || status == "in_progress" || status == "waiting" || status == "requested" }
    var isFailure: Bool { conclusion == "failure" || conclusion == "timed_out" || conclusion == "cancelled" || conclusion == "action_required" }

    var stateLabel: String {
        if status != "completed" { return status.replacingOccurrences(of: "_", with: " ").capitalized }
        return (conclusion ?? "completed").replacingOccurrences(of: "_", with: " ").capitalized
    }

    var detail: String {
        let ref = branch.map { " · \($0)" } ?? ""
        return "\(title)\(ref)"
    }

    var symbolName: String {
        if isActive { return status == "queued" ? "clock" : "arrow.triangle.2.circlepath" }
        switch conclusion {
        case "success": return "checkmark.circle.fill"
        case "failure", "timed_out": return "xmark.circle.fill"
        case "cancelled": return "minus.circle.fill"
        default: return "circle.fill"
        }
    }

    var tint: Color {
        if isActive { return .blue }
        switch conclusion {
        case "success": return .green
        case "failure", "timed_out": return .red
        case "cancelled": return .secondary
        default: return .secondary
        }
    }
}

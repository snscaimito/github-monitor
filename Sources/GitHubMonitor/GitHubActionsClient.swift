import Foundation

enum GitHubActionsClient {
    static func fetchRepositoriesWithRecentWorkflowRuns(since: Date) async throws -> [String] {
        let repositories = try await fetchRepositories()
        return await repositoriesWithRecentWorkflowRuns(repositories, since: since)
    }

    private static func fetchRepositories() async throws -> [String] {
        let output = try await GitHubCLI.run([
            "api",
            "--paginate",
            "--slurp",
            "user/repos?affiliation=owner,collaborator,organization_member&per_page=100",
            "--method", "GET"
        ])
        let pages = try JSONDecoder.github.decode([[GitHubRepository]].self, from: output)
        return Set(pages.flatMap { $0.map(\.fullName) }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func repositoriesWithRecentWorkflowRuns(_ repositories: [String], since: Date) async -> [String] {
        let maximumConcurrentRequests = 8
        var remaining = ArraySlice(repositories)
        var matches: [String] = []

        await withTaskGroup(of: String?.self) { group in
            func addNextRepository() {
                guard let repository = remaining.popFirst() else { return }
                group.addTask {
                    await hasRecentWorkflowRun(repository: repository, since: since) ? repository : nil
                }
            }

            for _ in 0..<min(maximumConcurrentRequests, repositories.count) {
                addNextRepository()
            }

            while let repository = await group.next() {
                if let repository { matches.append(repository) }
                addNextRepository()
            }
        }

        return matches.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func hasRecentWorkflowRun(repository: String, since: Date) async -> Bool {
        do {
            let output = try await GitHubCLI.run([
                "api",
                "repos/\(repository)/actions/runs?per_page=1",
                "--method", "GET"
            ])
            let response = try JSONDecoder.github.decode(WorkflowRunsResponse.self, from: output)
            guard let latestRun = response.workflowRuns.first else { return false }
            return latestRun.updatedAt >= since
        } catch {
            return false
        }
    }

    static func fetchRuns(repository: String) async throws -> [MonitoredWorkflowRun] {
        let output = try await GitHubCLI.run([
            "api",
            "repos/\(repository)/actions/runs?per_page=1",
            "--method", "GET"
        ])
        let response = try JSONDecoder.github.decode(WorkflowRunsResponse.self, from: output)
        return response.workflowRuns.map { run in
            MonitoredWorkflowRun(
                id: run.id,
                repository: repository,
                workflowName: run.name ?? "Workflow",
                title: run.displayTitle ?? run.name ?? "Workflow run",
                branch: run.headBranch,
                status: run.status,
                conclusion: run.conclusion,
                htmlURL: run.htmlURL,
                updatedAt: run.updatedAt
            )
        }
    }
}

private struct GitHubRepository: Decodable, Sendable {
    let fullName: String

    enum CodingKeys: String, CodingKey { case fullName = "full_name" }
}

private struct WorkflowRunsResponse: Decodable, Sendable {
    let workflowRuns: [WorkflowRun]

    enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" }
}

private struct WorkflowRun: Decodable, Sendable {
    let id: Int64
    let name: String?
    let displayTitle: String?
    let headBranch: String?
    let status: String
    let conclusion: String?
    let htmlURL: URL
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case displayTitle = "display_title"
        case headBranch = "head_branch"
        case htmlURL = "html_url"
        case updatedAt = "updated_at"
    }
}

private extension JSONDecoder {
    static let github: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private enum GitHubCLI {
    static func run(_ arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("github-monitor-\(UUID().uuidString).out")
            let errorURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("github-monitor-\(UUID().uuidString).err")

            guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
                  FileManager.default.createFile(atPath: errorURL.path, contents: nil),
                  let output = try? FileHandle(forWritingTo: outputURL),
                  let errors = try? FileHandle(forWritingTo: errorURL) else {
                continuation.resume(throwing: GitHubCLIError("Could not create temporary files for gh output."))
                return
            }

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["gh"] + arguments
            process.standardOutput = output
            process.standardError = errors
            process.terminationHandler = { task in
                try? output.close()
                try? errors.close()
                let standardOutput = (try? Data(contentsOf: outputURL)) ?? Data()
                let standardError = (try? Data(contentsOf: errorURL)) ?? Data()
                try? FileManager.default.removeItem(at: outputURL)
                try? FileManager.default.removeItem(at: errorURL)
                if task.terminationStatus == 0 {
                    continuation.resume(returning: standardOutput)
                } else {
                    let message = String(data: standardError, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: GitHubCLIError(message ?? "gh exited with status \(task.terminationStatus)."))
                }
            }
            do {
                try process.run()
            } catch {
                try? output.close()
                try? errors.close()
                try? FileManager.default.removeItem(at: outputURL)
                try? FileManager.default.removeItem(at: errorURL)
                continuation.resume(throwing: GitHubCLIError("Could not run gh. Install GitHub CLI and sign in with gh auth login."))
            }
        }
    }
}

private struct GitHubCLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

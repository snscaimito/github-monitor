import AppKit
import SwiftUI

@main
struct GitHubMonitorApp: App {
    @StateObject private var monitor = ActionsMonitor()

    var body: some Scene {
        MenuBarExtra {
            MonitorPopover(monitor: monitor)
                .frame(width: 430, height: 540)
                .task { monitor.start() }
        } label: {
            Image(systemName: monitor.menuBarSymbol)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MonitorPopover: View {
    @ObservedObject var monitor: ActionsMonitor
    @State private var isEditingRepositories = false
    @State private var repositoryInput = ""
    @State private var repositoryFilter = ""
    @State private var selectedRepositories: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isEditingRepositories || (monitor.repositories.isEmpty && !monitor.availableRepositories.isEmpty) {
                repositoryEditor
            } else if monitor.repositories.isEmpty {
                emptyState
            } else if monitor.isLoading && monitor.runs.isEmpty {
                ProgressView("Checking GitHub Actions…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                runList
            }

            Divider()
            footer
        }
        .onAppear { repositoryInput = monitor.repositories.joined(separator: "\n") }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("GitHub Actions")
                    .font(.headline)
                Text(monitor.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                monitor.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(monitor.isLoading || monitor.repositories.isEmpty)
            .accessibilityLabel("Refresh workflow runs")
        }
        .padding(14)
    }

    private var runList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let error = monitor.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(12)
                }

                ForEach(monitor.repositoryGroups) { group in
                    Text(group.repository)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 5)

                    ForEach(group.runs) { run in
                        Button {
                            NSWorkspace.shared.open(run.htmlURL)
                        } label: {
                            WorkflowRunRow(run: run)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            if monitor.isDiscoveringRepositories {
                ProgressView("Finding repositories with recent Actions…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No repositories selected",
                    systemImage: "play.rectangle.on.rectangle",
                    description: Text("Find repositories with Actions activity in the last 30 days through your existing gh login, then choose the ones to monitor.")
                )
                Button("Find Recent Action Repositories") {
                    beginRepositorySelection()
                    monitor.discoverRepositories()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var repositoryEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Repositories to monitor")
                .font(.headline)
            Text("Only repositories with Actions activity in the last 30 days are listed. The app uses your existing gh login and reads Actions runs only.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    monitor.discoverRepositories()
                } label: {
                    if monitor.isDiscoveringRepositories {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Find recent via gh", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(monitor.isDiscoveringRepositories)
                Spacer()
                Text("\(selectedRepositories.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if monitor.availableRepositories.isEmpty {
                TextEditor(text: $repositoryInput)
                    .font(.body.monospaced())
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.quaternary)
                    }
            } else {
                TextField("Filter repositories", text: $repositoryFilter)
                    .textFieldStyle(.roundedBorder)
                List(filteredRepositories, id: \.self) { repository in
                    Toggle(repository, isOn: selectedBinding(for: repository))
                        .toggleStyle(.checkbox)
                }
                .listStyle(.bordered)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    repositoryInput = monitor.repositories.joined(separator: "\n")
                    isEditingRepositories = false
                }
                Button("Save") {
                    let repositories = monitor.availableRepositories.isEmpty
                        ? repositoryInput
                        : selectedRepositories.sorted().joined(separator: "\n")
                    monitor.setRepositories(repositories)
                    isEditingRepositories = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack {
            Button("Repositories…") {
                beginRepositorySelection()
            }
            Spacer()
            Text("Refreshes every 30 seconds")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
    }

    private var filteredRepositories: [String] {
        guard !repositoryFilter.isEmpty else { return monitor.availableRepositories }
        return monitor.availableRepositories.filter { $0.localizedCaseInsensitiveContains(repositoryFilter) }
    }

    private func selectedBinding(for repository: String) -> Binding<Bool> {
        Binding(
            get: { selectedRepositories.contains(repository) },
            set: { isSelected in
                if isSelected {
                    selectedRepositories.insert(repository)
                } else {
                    selectedRepositories.remove(repository)
                }
            }
        )
    }

    private func beginRepositorySelection() {
        repositoryInput = monitor.repositories.joined(separator: "\n")
        selectedRepositories = Set(monitor.repositories)
        repositoryFilter = ""
        isEditingRepositories = true
    }
}

private struct WorkflowRunRow: View {
    let run: MonitoredWorkflowRun

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: run.symbolName)
                .foregroundStyle(run.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.workflowName)
                    .lineLimit(1)
                Text(run.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(run.stateLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(run.tint)
        }
        .contentShape(Rectangle())
        .padding(8)
    }
}

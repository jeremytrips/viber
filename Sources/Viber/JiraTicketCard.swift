import SwiftUI
import ViberCore

/// The Atlassian tool's `createJiraIssue` call as a ticket to edit: Claude drafted it, nothing reaches Jira until
/// Create. The edits go back as the call's input.
struct JiraTicketCard: View {
    let itemID: String
    let prompt: PermissionPrompt
    let pane: Pane?

    @State private var project = ""
    @State private var type = ""
    @State private var summary = ""
    @State private var description = ""
    @State private var labels = ""
    @State private var priority = ""
    @State private var loaded = false

    static let types = ["Bug", "Story", "Task", "Epic", "Subtask"]
    static let priorities = ["", "Highest", "High", "Medium", "Low", "Lowest"]

    static func handles(_ prompt: PermissionPrompt) -> Bool {
        prompt.toolName.lowercased().hasSuffix("createjiraissue")
    }

    var body: some View {
        if let decision = prompt.decision {
            HStack(spacing: 8) {
                DecisionLabel(decision: decision)
                Text("\(prompt.input["projectKey"]?.string ?? "") · \(prompt.input["issueTypeName"]?.string ?? "") · \(prompt.input["summary"]?.string ?? "")")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            Card(title: "\(prompt.agent ?? "Claude") wants to create a Jira issue", color: .orange) {
                HStack(spacing: 8) {
                    TextField("Project", text: $project).textFieldStyle(.roundedBorder).frame(width: 90)
                        .help("The Jira project key, such as NEX")
                    Picker("Type", selection: $type) {
                        ForEach(Self.types + (Self.types.contains(type) || type.isEmpty ? [] : [type]), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Picker("Priority", selection: $priority) {
                        ForEach(Self.priorities, id: \.self) { Text($0.isEmpty ? "Default priority" : $0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Spacer()
                    Text(prompt.toolName).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                }
                TextField("Summary", text: $summary).textFieldStyle(.roundedBorder).font(.body.weight(.semibold))
                TextEditor(text: $description)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 120, maxHeight: 320)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                HStack(spacing: 8) {
                    Text("Labels").font(.caption).foregroundStyle(.secondary)
                    TextField("comma-separated", text: $labels).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    Spacer()
                }
                if let pane {
                    HStack {
                        Text("Your edits go back to Claude as the call's input.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") {
                            pane.run { [$0.decidePermission(itemID: itemID, allow: false, message: "The user cancelled the ticket. Don't create it, and don't try again.")].compactMap { $0 } }
                        }
                        Button("Create") {
                            let input = edited
                            pane.run { [$0.decidePermission(itemID: itemID, allow: true, updatedInput: input)].compactMap { $0 } }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(summary.trimmingCharacters(in: .whitespaces).isEmpty || project.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let input = prompt.input
        project = input["projectKey"]?.string ?? ""
        type = input["issueTypeName"]?.string ?? "Task"
        summary = input["summary"]?.string ?? ""
        description = input["description"]?.string ?? JiraClient.plainText(input["description"])
        let extra = input["additional_fields"]
        labels = (extra?["labels"]?.array ?? []).compactMap(\.string).joined(separator: ", ")
        priority = extra?["priority"]?["name"]?.string ?? extra?["priority"]?.string ?? ""
    }

    /// The call's input with the form's values; fields the form doesn't show are kept as Claude gave them.
    private var edited: JSON {
        var input = prompt.input
        input = input.setting("projectKey", .string(project.trimmingCharacters(in: .whitespaces).uppercased()))
        input = input.setting("issueTypeName", .string(type))
        input = input.setting("summary", .string(summary.trimmingCharacters(in: .whitespaces)))
        input = input.setting("description", .string(description))
        var extra = prompt.input["additional_fields"]?.object ?? [:]
        let labelList = labels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if labelList.isEmpty { extra["labels"] = nil } else { extra["labels"] = .array(labelList.map { .string($0) }) }
        if priority.isEmpty { extra["priority"] = nil } else { extra["priority"] = ["name": .string(priority)] }
        if extra.isEmpty { var object = input.object ?? [:]; object["additional_fields"] = nil; input = .object(object) }
        else { input = input.setting("additional_fields", .object(extra)) }
        return input
    }
}

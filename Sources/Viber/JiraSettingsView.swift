import SwiftUI
import ViberCore

/// Settings → Jira: the sites Viber can read, each with an API token in the Keychain.
struct JiraSettings: View {
    @Environment(AppModel.self) private var model
    @State private var host = ""
    @State private var email = ""
    @State private var token = ""
    @State private var testing = false
    @State private var note: (text: String, ok: Bool)?
    @State private var tests: [String: (text: String, ok: Bool)] = [:]

    var body: some View {
        Form {
            Section {
                if model.jiraSites.isEmpty {
                    Text("No site yet. Add one below; then link a project to it on its page, under Settings → Tracker.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.jiraSites) { site in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(site.host).fontWeight(.medium)
                            Text(subtitle(site)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if let result = tests[site.host] {
                                Text(result.text).font(.caption).foregroundStyle(result.ok ? .green : .red)
                            }
                        }
                        Spacer()
                        Button("Test") { test(site) }.controlSize(.small)
                        Button("Remove") { model.removeJiraSite(site) }.controlSize(.small)
                            .disabled(!usedBy(site).isEmpty)
                            .help(usedBy(site).isEmpty ? "Forget the site and its token" : "Projects still use it")
                    }
                }
            } header: {
                Text("Sites")
            } footer: {
                Text("Viber reads issues with the token; every change to Jira goes through Claude in a session. A token with the read-only scopes is enough.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Site", text: $host, prompt: Text("yourcompany.atlassian.net"))
                TextField("Email", text: $email, prompt: Text("you@company.com"))
                SecureField("API token", text: $token, prompt: Text("Paste the token"))
                if let note {
                    Text(note.text).font(.caption).foregroundStyle(note.ok ? .green : .red).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Link("Create a token…", destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
                        .font(.caption)
                    Spacer()
                    Button("Test", action: testNew).disabled(!filled || testing)
                    Button("Add Site", action: add).disabled(!filled || testing)
                }
            } header: {
                Text("Add a site")
            } footer: {
                Text("At id.atlassian.com → Security → API tokens, choose Create API token with scopes, then Jira with read:jira-work and read:jira-user. Tokens expire after at most a year; Viber says so when Jira refuses one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func subtitle(_ site: JiraSite) -> String {
        var parts = [site.email]
        if let name = site.displayName { parts.append(name) }
        parts.append("token in the Keychain")
        let projects = usedBy(site)
        if !projects.isEmpty { parts.append("used by " + projects.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private var filled: Bool {
        !JiraSite.cleanHost(host).isEmpty && email.contains("@") && !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func usedBy(_ site: JiraSite) -> [String] {
        model.trackers.projects.filter { $0.value.site == site.host }.map { model.projectName($0.key) }.sorted()
    }

    private func testNew() {
        testing = true
        note = nil
        let site = JiraSite(host: host, email: email.trimmingCharacters(in: .whitespaces))
        let client = JiraClient(site: site, token: token.trimmingCharacters(in: .whitespaces))
        Task {
            do {
                let user = try await client.myself()
                note = ("Signed in as \(user.displayName).", true)
            } catch {
                note = (error.localizedDescription, false)
            }
            testing = false
        }
    }

    private func test(_ site: JiraSite) {
        tests[site.host] = ("Checking…", true)
        guard let token = JiraKeychain.token(for: site.host) else { tests[site.host] = ("No token in the Keychain; remove the site and add it again.", false); return }
        let client = JiraClient(site: site, token: token)
        Task {
            do {
                let user = try await client.myself()
                tests[site.host] = ("Signed in as \(user.displayName).", true)
                model.updateJiraSite(site, displayName: user.displayName)
            } catch {
                tests[site.host] = (error.localizedDescription, false)
            }
        }
    }

    private func add() {
        testing = true
        let site = JiraSite(host: host, email: email.trimmingCharacters(in: .whitespaces))
        let cleaned = token.trimmingCharacters(in: .whitespaces)
        let client = JiraClient(site: site, token: cleaned)
        Task {
            do {
                let user = try await client.myself()
                model.addJiraSite(JiraSite(host: site.host, email: site.email, displayName: user.displayName), token: cleaned)
                host = ""; email = ""; token = ""
                note = ("Added \(site.host), signed in as \(user.displayName).", true)
            } catch {
                note = (error.localizedDescription, false)
            }
            testing = false
        }
    }
}

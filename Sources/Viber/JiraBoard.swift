import Foundation
import ViberCore

/// What a Jira project's Planning tab shows: one view at a time, a page at a time, refreshed now and then.
/// By epic, it loads the epics and the issues outside them, and an epic's issues when it is opened.
@MainActor @Observable
final class JiraBoard {
    let project: String
    var tracker: ProjectTracker
    var site: JiraSite?
    var viewID: String
    var search = ""
    var issues: [JiraIssue] = []
    /// Nil once the last page is loaded.
    var nextPageToken: String?
    var loading = false
    var error: String?
    var loadedAt: Date?
    /// About how many issues the view has, from Jira's estimate.
    var total: Int?
    var me: JiraUser?
    /// Each opened epic's issues, by its key; absent while they load.
    var epicChildren: [String: [JiraIssue]] = [:]
    var openEpics: Set<String> = []
    /// Every issue seen, by key: what sessions' chips read.
    private(set) var known: [String: JiraIssue] = [:]
    @ObservationIgnored private var fetching: Set<String> = []
    @ObservationIgnored private var generation = 0

    init(project: String, tracker: ProjectTracker, site: JiraSite?) {
        self.project = project
        self.tracker = tracker
        self.site = site
        viewID = tracker.views.first?.id ?? ""
    }

    var view: JiraView? { tracker.views.first { $0.id == viewID } ?? tracker.views.first }
    var byEpic: Bool { view?.byEpic == true && search.trimmingCharacters(in: .whitespaces).isEmpty }

    private var client: JiraClient? {
        guard let site, let token = JiraKeychain.token(for: site.host) else { return nil }
        return JiraClient(site: site, token: token)
    }

    func update(tracker: ProjectTracker, site: JiraSite?) {
        let changed = tracker.views != self.tracker.views || site != self.site
        self.tracker = tracker
        self.site = site
        if !tracker.views.contains(where: { $0.id == viewID }) { viewID = tracker.views.first?.id ?? "" }
        if changed { load() }
    }

    func show(_ id: String) {
        guard id != viewID else { return }
        viewID = id
        search = ""
        load()
    }

    /// The view's JQL with the search and, by epic, the top level only; `ORDER BY` stays last.
    func jql(epic: String? = nil) -> String {
        guard let view else { return "" }
        var (whereClause, order) = Self.split(view.jql)
        var clauses = whereClause.isEmpty ? [] : ["(\(whereClause))"]
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            let escaped = query.replacingOccurrences(of: "\"", with: "\\\"")
            clauses.append(JiraIssue.key(inBranch: query) == query.uppercased() ? "(key = \"\(query.uppercased())\" OR text ~ \"\(escaped)\")" : "text ~ \"\(escaped)\"")
        } else if let epic {
            clauses.append("parent = \(epic)")
        } else if view.byEpic {
            clauses.append("parent is EMPTY")
        }
        whereClause = clauses.joined(separator: " AND ")
        return whereClause + (order.isEmpty ? "" : " ORDER BY " + order)
    }

    /// "project = X ORDER BY Rank" → ("project = X", "Rank")
    static func split(_ jql: String) -> (String, String) {
        let upper = jql.uppercased()
        guard let range = upper.range(of: " ORDER BY ") else { return (jql.trimmingCharacters(in: .whitespaces), "") }
        return (String(jql[..<range.lowerBound]).trimmingCharacters(in: .whitespaces), String(jql[range.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    /// Loads the view from the start.
    func load() {
        generation += 1
        let gen = generation
        issues = []
        nextPageToken = nil
        total = nil
        epicChildren = [:]
        error = nil
        guard let client, view != nil else { error = site == nil ? "The project's Jira site is gone; pick one in Settings." : "No token for \(site?.host ?? "the site"); add it in Settings → Jira."; return }
        let jql = jql()
        loading = true
        Task {
            if me == nil { me = try? await client.myself() }
            async let page = client.search(jql)
            async let count = client.count(jql)
            do {
                let loaded = try await page
                guard gen == generation else { return }
                issues = loaded.issues
                nextPageToken = loaded.isLast ? nil : loaded.nextPageToken
                remember(loaded.issues)
                loadedAt = Date()
            } catch {
                guard gen == generation else { return }
                self.error = error.localizedDescription
            }
            total = try? await count
            loading = false
        }
    }

    func loadMore() {
        guard let client, let token = nextPageToken, !loading else { return }
        let gen = generation
        loading = true
        Task {
            do {
                let loaded = try await client.search(jql(), pageToken: token)
                guard gen == generation else { return }
                issues += loaded.issues.filter { issue in !issues.contains { $0.key == issue.key } }
                nextPageToken = loaded.isLast ? nil : loaded.nextPageToken
                remember(loaded.issues)
            } catch {
                guard gen == generation else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    /// Opens or closes an epic; its issues load the first time.
    func toggleEpic(_ key: String) {
        if openEpics.contains(key) { openEpics.remove(key); return }
        openEpics.insert(key)
        guard epicChildren[key] == nil, let client else { return }
        let gen = generation
        Task {
            do {
                var all: [JiraIssue] = []
                var token: String?
                repeat {
                    let page = try await client.search(jql(epic: key), pageToken: token)
                    all += page.issues
                    token = page.isLast ? nil : page.nextPageToken
                } while token != nil && all.count < 500
                guard gen == generation else { return }
                epicChildren[key] = all
                remember(all)
            } catch {
                guard gen == generation else { return }
                self.error = error.localizedDescription
            }
        }
    }

    /// Reloads the view when it is older than the tracker's refresh interval.
    func refreshIfStale(now: Date = Date()) {
        guard !loading, let loadedAt, now.timeIntervalSince(loadedAt) >= Double(tracker.refreshSeconds) else { return }
        reload()
    }

    /// Reloads what is shown without emptying it first.
    func reload() {
        guard let client, view != nil, !loading else { return }
        let gen = generation
        let query = jql()
        let open = openEpics
        loading = true
        Task {
            do {
                var all: [JiraIssue] = []
                var token: String?
                repeat {
                    let page = try await client.search(query, pageToken: token)
                    all += page.issues
                    token = page.isLast ? nil : page.nextPageToken
                } while token != nil && all.count < max(issues.count, JiraClient.pageSize)
                guard gen == generation else { return }
                issues = all
                nextPageToken = token
                remember(all)
                for epic in open where epicChildren[epic] != nil {
                    if let kids = try? await client.search(jql(epic: epic), maxResults: 500).issues { epicChildren[epic] = kids; remember(kids) }
                }
                loadedAt = Date()
                error = nil
            } catch {
                guard gen == generation else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    /// Fetches an issue a session's branch names, once, so its chip can show the status.
    func ensure(_ key: String) {
        guard known[key] == nil, !fetching.contains(key), let client else { return }
        fetching.insert(key)
        Task {
            if let issue = try? await client.issue(key) { known[key] = issue }
            fetching.remove(key)
        }
    }

    private func remember(_ loaded: [JiraIssue]) {
        for issue in loaded { known[issue.key] = issue }
    }

    /// Whether an issue is the signed-in user's.
    func isMine(_ issue: JiraIssue) -> Bool {
        guard let me else { return false }
        return issue.assigneeID == me.accountID
    }
}

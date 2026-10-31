import SwiftUI

// MARK: - Activity (what was done, by whom)

/// The Activity page's day filter.
enum ActivityDay: Hashable {
    case any, today, yesterday, lastWeek
    case on(Date)

    /// The entries' window [from, to), or nil for any day.
    func range(now: Date = Date(), calendar: Calendar = .current) -> (from: Date, to: Date)? {
        let today = calendar.startOfDay(for: now)
        func day(_ start: Date) -> (Date, Date) { (start, calendar.date(byAdding: .day, value: 1, to: start)!) }
        switch self {
        case .any: return nil
        case .today: return day(today)
        case .yesterday: return day(calendar.date(byAdding: .day, value: -1, to: today)!)
        case .lastWeek: return (calendar.date(byAdding: .day, value: -6, to: today)!, day(today).1)
        case .on(let d): return day(calendar.startOfDay(for: d))
        }
    }

    /// The picker's choice (`on` dates share one).
    enum Choice: String, CaseIterable, Identifiable {
        case any = "Any day", today = "Today", yesterday = "Yesterday", lastWeek = "Last 7 days", on = "On a date…"
        var id: String { rawValue }
    }

    var choice: Choice {
        switch self {
        case .any: return .any
        case .today: return .today
        case .yesterday: return .yesterday
        case .lastWeek: return .lastWeek
        case .on: return .on
        }
    }

    static func from(_ c: Choice, date: Date) -> ActivityDay {
        switch c {
        case .any: return .any
        case .today: return .today
        case .yesterday: return .yesterday
        case .lastWeek: return .lastWeek
        case .on: return .on(date)
        }
    }
}

/// The Activity page's "who" filter (applied to the entries read, before grouping).
enum ActivityWho: String, CaseIterable, Identifiable {
    case everyone = "Everyone", agents = "Agents", you = "You"
    var id: String { rawValue }

    func matches(_ e: ActivityEvent) -> Bool {
        switch self {
        case .everyone: return true
        case .agents: return e.actor.isAgent
        case .you: return e.actor == .user
        }
    }
}

/// The content column of the Activity page: filters, then the feed by day, newest first.
/// A row is a run of one actor's entries on one task or page; double-click (or Return,
/// or the code) opens it.
struct ActivityListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ActivityFilterBar()
            Divider()
            if model.activityGroups.isEmpty {
                ContentUnavailableViewCompat(text: "No activity here.\nChanges, notes and wiki edits by you and your agents show up here.")
            } else {
                list
            }
        }
        .navigationTitle("Activity")
        .qbParchment()
    }

    private var list: some View {
        List(selection: $model.activitySelection) {
            ForEach(days, id: \.day) { section in
                Section(dayTitle(section.day)) {
                    ForEach(section.groups) { ActivityRow(group: $0).tag($0.id) }
                }
            }
            if model.activityHasMore { loadMore }
        }
        .contextMenu(forSelectionType: ActivityGroup.ID.self) { ids in
            if let g = group(ids.first) {
                Button(g.subject.taskId == nil ? "Open Page" : "Open Task") { model.openActivity(g) }
                if case .task(_, let code, _) = g.subject { Button("Copy Code (\(code))") { model.copyCode(code) } }
            }
        } primaryAction: { ids in
            if let g = group(ids.first) { model.openActivity(g) }
        }
    }

    private var loadMore: some View {
        HStack {
            Spacer()
            Button("Load older activity") { model.loadMoreActivity() }
                .buttonStyle(QBGhostButtonStyle())
            Spacer()
        }
        .selectionDisabled()
    }

    private func group(_ id: ActivityGroup.ID?) -> ActivityGroup? {
        id.flatMap { id in model.activityGroups.first { $0.id == id } }
    }

    /// The rows by calendar day of their latest entry, newest day first.
    private var days: [(day: Date, groups: [ActivityGroup])] {
        let cal = Calendar.current
        var out: [(day: Date, groups: [ActivityGroup])] = []
        for g in model.activityGroups {
            let d = cal.startOfDay(for: g.latest)
            if out.last?.day == d { out[out.count - 1].groups.append(g) } else { out.append((d, [g])) }
        }
        return out
    }

    private func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}

/// Project, day and who filters above the feed.
private struct ActivityFilterBar: View {
    @EnvironmentObject var model: AppModel
    @State private var date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                projectPicker
                whoPicker
            }
            HStack(spacing: 8) {
                dayPicker
                if case .on = model.activityDay { datePicker }
                Spacer(minLength: 0)
            }
        }
        .font(Theme.Fonts.caption)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
    }

    private var projectPicker: some View {
        Picker("Project", selection: $model.activityProjectId) {
            Text("All projects").tag(Int64?.none)
            ForEach(model.pickerProjects(selected: model.activityProjectId)) { p in
                Text("\(p.code) · \(p.name)").tag(Int64?.some(p.id))
            }
        }
        .labelsHidden()
        .frame(maxWidth: 220)
        .help("Show one project's activity, or every project's")
    }

    private var whoPicker: some View {
        Picker("Who", selection: $model.activityWho) {
            ForEach(ActivityWho.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Everyone, only what agents did, or only what you did")
    }

    private var dayPicker: some View {
        Picker("Day", selection: Binding(
            get: { model.activityDay.choice },
            set: { model.activityDay = ActivityDay.from($0, date: date) })) {
            ForEach(ActivityDay.Choice.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var datePicker: some View {
        DatePicker("Date", selection: Binding(
            get: { date },
            set: { date = $0; model.activityDay = .on($0) }), displayedComponents: .date)
            .labelsHidden()
            .datePickerStyle(.compact)
            .fixedSize()
    }
}

/// Who did it, for a feed row: "You", "Agent · <session>", "CLI", "Import", "Unknown".
struct ActivityActorLabel: View {
    @EnvironmentObject var model: AppModel
    let actor: ActivityActor

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(text).lineLimit(1).truncationMode(.middle)
        }
        .font(Theme.Fonts.micro)
        .foregroundStyle(actor.isAgent ? Theme.Colors.brandBlue : Theme.Colors.steel)
        .help(help)
    }

    private var icon: String {
        switch actor {
        case .user: return "person"
        case .agent: return "sparkles"
        case .cli: return "terminal"
        case .importer: return "square.and.arrow.down"
        case .unknown: return "questionmark.circle"
        }
    }

    private var text: String {
        guard let session = actor.sessionDisplay else { return actor.display }
        return "Agent · \(session)"
    }

    /// The session's folder when QuestBits knows the session.
    private var help: String {
        guard case .agent(let sid?, _) = actor else { return text }
        guard let s = model.agentSessions.first(where: { $0.id == sid }) else { return "Claude Code session \(sid)" }
        return "Claude Code session \(sid)\n\(s.cwd)"
    }
}

/// A feed row: the task (or page), who, when, and its entries in short.
struct ActivityRow: View {
    let group: ActivityGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            header
            Text(title)
                .font(Theme.Fonts.bodySmMedium).foregroundStyle(Theme.Colors.ink).lineLimit(1)
            ForEach(shown) { e in
                Text(e.summary).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate).lineLimit(1)
            }
            if group.events.count > shown.count {
                Text("+\(group.events.count - shown.count) more")
                    .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
            }
        }
        .padding(.vertical, 3)
    }

    private var shown: [ActivityEvent] { Array(group.events.prefix(3)) }

    private var header: some View {
        HStack(spacing: 6) {
            CodeBadge(code: code)
            ActivityActorLabel(actor: group.actor)
            Spacer()
            Text(timeText).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
        }
    }

    private var code: String {
        if case .task(_, let code, _) = group.subject { return code }
        return group.projectCode
    }

    private var title: String {
        switch group.subject {
        case .task(_, _, let title): return title
        case .page(_, let title, let kind): return "\(kind.display): \(title)"
        }
    }

    private var timeText: String {
        let latest = group.latest.formatted(date: .omitted, time: .shortened)
        let earliest = group.earliest.formatted(date: .omitted, time: .shortened)
        return earliest == latest ? latest : "\(earliest)–\(latest)"
    }
}

// MARK: - Detail column

/// The detail column of the Activity page: the selected row's entries in full, and a way
/// to the task or page.
struct ActivityDetailView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let g = model.activitySelection.flatMap({ id in model.activityGroups.first { $0.id == id } }) {
            ActivityGroupDetail(group: g).id(g.id)
        } else {
            ContentUnavailableViewCompat(text: model.activityGroups.isEmpty ? "No activity" : "Pick an entry")
        }
    }
}

private struct ActivityGroupDetail: View {
    @EnvironmentObject var model: AppModel
    let group: ActivityGroup

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                header
                Text(title)
                    .font(Theme.Fonts.heading5).foregroundStyle(Theme.Colors.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                ActivityActorLabel(actor: group.actor)
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(group.events) { ActivityEntryRow(event: $0) }
                }
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .qbParchment()
    }

    private var header: some View {
        HStack(spacing: 6) {
            CodeBadge(code: group.projectCode)
            Button(openLabel) { model.openActivity(group) }
                .buttonStyle(QBLinkButtonStyle())
                .help(group.subject.taskId == nil ? "Open the page in the project's wiki" : "Open the task")
            Spacer()
        }
    }

    private var openLabel: String {
        if case .task(_, let code, _) = group.subject { return "Open \(code)" }
        return "Open page"
    }

    private var title: String {
        switch group.subject {
        case .task(_, _, let title): return title
        case .page(_, let title, let kind): return "\(kind.display): \(title)"
        }
    }
}

/// One entry in full: what changed (or the note's text), and when.
private struct ActivityEntryRow: View {
    let event: ActivityEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(headline).font(Theme.Fonts.captionBold).foregroundStyle(Theme.Colors.ink)
                if let source = event.source {
                    Text("via \(source.display)").font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
                }
                Spacer()
                Text(fmtDateTime(event.timestamp)).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
            }
            Text(bodyText)
                .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private var headline: String {
        switch event.kind {
        case .note: return NoteKind(rawValue: event.field).map { $0 == .note ? "Note" : "\($0.display) note" } ?? "Note"
        case .page: return "Page · " + TaskEvent.label(forField: event.field)
        case .change: return TaskEvent.label(forField: event.field)
        }
    }

    private var bodyText: String {
        if event.kind == .note { return event.newValue }
        if event.field == "created" { return event.newValue }
        if event.kind == .page, event.field == "body" { return "Text edited" }
        let old = event.oldValue, new = event.newValue
        if new.isEmpty { return old.isEmpty ? "Cleared" : "\(old) removed" }
        return old.isEmpty ? new : "\(old) → \(new)"
    }
}

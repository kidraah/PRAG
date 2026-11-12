import SwiftUI
import PRAGCore

/// Tabs across the top of the shelf: Recent (where new drops land), Screenshots (auto-caught),
/// then the user's own groups. Drop files or shelf tiles on a tab to park them there.
struct TabStripView: View {
    let state: AppState
    @State private var editing: UUID?
    @State private var draftName = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        chip(.recent, title: "Recent", symbol: "clock").demoAnchor("tab.recent")
                        if state.showsScreenshotsTab {
                            chip(.screenshots, title: "Screenshots", symbol: "camera.viewfinder")
                        }
                        if !state.groups.isEmpty {
                            Rectangle().fill(Theme.hairline).frame(width: 1, height: 14).padding(.horizontal, 3)
                        }
                        ForEach(state.groups) { group in
                            if editing == group.id {
                                renameField(group).id(group.id)
                            } else {
                                chip(.group(group.id), title: group.name, symbol: "folder")
                                    .demoAnchor("tab.group.\(group.name)")
                                    .id(group.id)
                                    .contextMenu { groupMenu(group) }
                            }
                        }
                    }
                    .padding(.horizontal, 1)
                    .frame(height: 24)
                }
                .onChange(of: state.groups.count) { old, new in
                    guard new > old, let last = state.groups.last else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { proxy.scrollTo(last.id) }
                }
            }
            .mask(HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 12)
            })

            NewTabButton(hasSelection: !state.selection.isEmpty) { newGroup() }
                .demoAnchor("tab.new")
        }
        .onPreferenceChange(TabFramesKey.self) { frames in
            MainActor.assumeIsolated { state.tabFrames = frames }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: state.groups)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: state.showsScreenshotsTab)
    }

    // MARK: Pieces

    private func chip(_ tab: ShelfTab, title: String, symbol: String) -> some View {
        TabChip(title: title, symbol: symbol,
                count: state.items(in: tab).count,
                isActive: state.activeTab == tab,
                isDropTarget: state.dropTargetTab == tab) {
            state.activeTab = tab
        } onDoubleClick: {
            if case .group(let id) = tab { beginRename(id) }
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: TabFramesKey.self, value: [tab: g.frame(in: .named(ShelfSpace.name))])
        })
    }

    private func renameField(_ group: ShelfGroup) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "folder").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.accent)
            TextField("Tab name", text: $draftName)
                .textFieldStyle(.plain)
                .font(Theme.label(11, .semibold))
                .foregroundStyle(Theme.text)
                .focused($fieldFocused)
                .frame(width: 96)
                .onSubmit { commitRename(group.id) }
                .onExitCommand { editing = nil }
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(Theme.fill))
        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.8), lineWidth: 1))
        .onChange(of: fieldFocused) { _, focused in if !focused { commitRename(group.id) } }
    }

    @ViewBuilder
    private func groupMenu(_ group: ShelfGroup) -> some View {
        Button("Rename") { beginRename(group.id) }
        Button("Clear Items") { state.remove(Set(state.items(in: .group(group.id)).map(\.id))) }
        Divider()
        Button("Delete Tab (items return to Recent)", role: .destructive) { state.deleteGroup(group.id) }
    }

    // MARK: Actions

    private func newGroup() {
        let moving = state.selection
        let group = state.createGroup(moving: moving)
        state.activeTab = .group(group.id)
        beginRename(group.id)
    }

    private func beginRename(_ id: UUID) {
        draftName = state.groupName(id)
        editing = id
        state.requestKeyFocus()
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func commitRename(_ id: UUID) {
        guard editing == id else { return }
        state.renameGroup(id, to: draftName)
        editing = nil
    }
}

struct TabFramesKey: PreferenceKey {
    static let defaultValue: [ShelfTab: CGRect] = [:]
    static func reduce(value: inout [ShelfTab: CGRect], nextValue: () -> [ShelfTab: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct TabChip: View {
    let title: String
    let symbol: String
    let count: Int
    let isActive: Bool
    let isDropTarget: Bool
    let action: () -> Void
    let onDoubleClick: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isDropTarget ? "tray.and.arrow.down.fill" : symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(isDropTarget || isActive ? Theme.accent : Theme.secondary)
                .contentTransition(.symbolEffect(.replace))
            Text(title)
                .font(Theme.label(11, isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? Theme.text : Theme.secondary)
                .lineLimit(1)
            if count > 0 {
                Text("\(count)")
                    .font(Theme.numeric(9.5, .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(isDropTarget ? Theme.accent.opacity(0.18)
                                   : (isActive ? Theme.fillPressed : (hover ? Theme.fill : .clear))))
        .overlay(Capsule().strokeBorder(isDropTarget ? Theme.accent : .clear, lineWidth: 1))
        .scaleEffect(isDropTarget ? 1.06 : 1)
        .contentShape(Capsule())
        .onTapGesture {
            // No double-tap recognizer (it delays every single click while it waits).
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { onDoubleClick() } else { action() }
        }
        .onHover { hover = $0 }
        .fixedSize()
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDropTarget)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: isActive)
    }
}

private struct NewTabButton: View {
    let hasSelection: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 9.5, weight: .bold))
                if hasSelection {
                    Text("Tab from Selection").font(Theme.label(10.5, .semibold)).fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                }
            }
            .foregroundStyle(hover ? Theme.text : Theme.secondary)
            .padding(.horizontal, hasSelection ? 9 : 0)
            .frame(minWidth: 22, minHeight: 22)
            .background(Capsule().fill(hover ? Theme.fillHover : Theme.fill))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .help(hasSelection ? "Move the selected items into a new tab" : "New tab")
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: hasSelection)
    }
}

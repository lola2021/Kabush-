import AppKit
import SwiftUI

/// The page area while Split View is on: the AppKit stage that holds the
/// pages (see PaneStage.swift), and over each page what SwiftUI draws there —
/// its cover, its trouble, the field, the find bar — placed from where the
/// stage says the pages are.
struct SplitStage: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var drag = TabDrag.shared
    /// Where each page on screen is, as the stage last said.
    @State private var frames: [Tab.ID: CGRect] = [:]

    var body: some View {
        let split = browser.activeSplit
        let shown: [Tab] = split.map { pair in pair.tabs.compactMap { id in browser.tabs.first { $0.id == id } } }
            ?? browser.active.map { [$0] } ?? []
        ZStack(alignment: .topLeading) {
            PaneStageView(
                tabs: shown, split: split, focused: browser.activeID,
                commit: { id, sizes in browser.setSplitFraction(id, fraction: sizes[0]) },
                focus: { tab in browser.focusPane(tab) },
                frames: { frames = $0 },
                action: { action in
                    switch action {
                    case .swap: browser.swapSplit()
                    case .even: browser.evenSplit()
                    case .separate: if let tab = browser.active { browser.detachSplit(tab) }
                    case .closeBoth: browser.closeSplit()
                    }
                }
            )
            ForEach(shown) { tab in
                if let frame = frames[tab.id] {
                    PaneLayers(browser: browser, tab: tab, paired: shown.count > 1, width: frame.width)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
            if let preview = drag.preview, preview.browserID == ObjectIdentifier(browser) {
                SplitDropPreview(preview: preview, tabs: browser.tabs)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(Motion.quick, value: drag.preview)
    }
}

/// What is drawn over one page of the stage. Nothing here takes a click
/// meant for the page: where it draws nothing, the page is under the pointer.
private struct PaneLayers: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let paired: Bool
    let width: CGFloat

    private var focused: Bool { browser.activeID == tab.id }

    var body: some View {
        ZStack {
            // The page's own layers — its cover, the floating video's line,
            // its trouble, the history disc — without the page, which is
            // the stage's.
            Page(tab: tab, holdsPage: false)

            if browser.fieldShowing && focused {
                Omnibox(browser: browser, over: !tab.isBlank, fitted: true)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }

            // An empty page of a pair: the field, and the tabs already open,
            // to bring one in. Gone while something is typed, when the field's
            // own list is there.
            if paired, tab.isBlank, browser.typed.isEmpty {
                OpenTabs(browser: browser, blank: tab)
                    .transition(.opacity)
            }
        }
        .overlay {
            if browser.prefs.showsLinks, focused {
                LinkBubble(status: browser.linkStatus)
            }
        }
        .overlay(alignment: .topTrailing) {
            if browser.finding, focused {
                FindBar(browser: browser, availableWidth: width)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .clipped()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topLeading) {
            if let asked = browser.suggesting, asked.tab == tab.id {
                AccountList(browser: browser, asked: asked)
                    .transition(.opacity)
            }
        }
        .background { SplitDropZone(browser: browser, tab: tab, kind: .stage) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tab.label.isEmpty ? "New Tab" : tab.label)
        .accessibilityHint(paired && !focused ? "Click to focus this page" : "")
        .accessibilityAction(named: "Focus page") {
            if paired { browser.focusPane(tab) }
        }
        .clipped()
        .animation(Motion.quick, value: browser.suggesting)
    }
}

private struct SplitDropPreview: View {
    let preview: TabDrag.Preview
    let tabs: [Tab]

    private var target: Tab? { tabs.first { $0.id == preview.targetID } }

    var body: some View {
        HStack(spacing: 2) {
            half(title: preview.side == .left ? "Tab" : target?.label ?? "Page", proposed: preview.side == .left)
            half(title: preview.side == .right ? "Tab" : target?.label ?? "Page", proposed: preview.side == .right)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground.opacity(0.12))
    }

    private func half(title: String, proposed: Bool) -> some View {
        ZStack {
            Rectangle().fill(proposed ? Palette.ink.opacity(0.06) : Palette.ground.opacity(0.42))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(proposed ? Palette.ink.opacity(0.3) : Palette.ink.opacity(0.12), lineWidth: 1)
                .padding(6)
            Text(title.isEmpty ? "New Tab" : title)
                .font(.system(size: 13, weight: proposed ? .medium : .regular))
                .foregroundStyle(Palette.ink.opacity(proposed ? 0.78 : 0.48))
                .lineLimit(1)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The open tabs an empty page of a pair can take, most recently used
/// first. A click brings one in; the empty page goes.
private struct OpenTabs: View {
    @ObservedObject var browser: Browser
    let blank: Tab

    private var candidates: [Tab] {
        let pair = browser.split(for: blank)
        return browser.tabs
            .filter { tab in
                tab.id != blank.id && pair?.contains(tab.id) != true && tab.pin == nil && !tab.bench
                    && !tab.isBlank && tab.shy == blank.shy
            }
            .sorted { $0.touched > $1.touched }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        let list = candidates
        GeometryReader { geo in
            if !list.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Or bring in an open tab")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 4)
                    ForEach(list) { tab in
                        OpenTabRow(tab: tab) { browser.fill(blank, with: tab) }
                    }
                }
                // As wide as the field, its rows' text under the field's.
                .padding(.horizontal, 12)
                .frame(width: min(Metrics.fieldWidth, max(0, geo.size.width - 28)), alignment: .leading)
                .frame(maxWidth: .infinity)
                // Under the field, which stands 60 points above the middle.
                .offset(y: geo.size.height / 2 + 10)
            }
        }
    }
}

private struct OpenTabRow: View {
    @ObservedObject var tab: Tab
    let bring: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Mark(icon: tab.icon, letter: tab.monogram, size: 15)
                .frame(width: 15, height: 15)
            Text(tab.label.isEmpty ? "New Tab" : tab.label)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(hovering ? Palette.ink : Palette.ink.opacity(0.75))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: bring)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Bring this tab into the split")
    }
}

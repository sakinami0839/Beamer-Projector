import SwiftUI

struct NavigatorPanel: View {
    @ObservedObject var session: Session
    let source: PDFSource
    private var motion = PresenterMotion()
    @State private var showsPages = false
    @State private var expanded: Set<String> = []
    @State private var visibleThumbnails: Set<Int> = []

    private var activeBookmark: String? {
        let destination = source.outline.compactMap(\.page).filter { $0 <= session.index }.max()
        guard let destination else { return nil }
        return source.outline.last(where: { $0.page == destination })?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            if !source.outline.isEmpty {
                navigationBar
            }
            ZStack(alignment: .top) {
                if showsPages || source.outline.isEmpty {
                    thumbnailPane.transition(.asymmetric(insertion: .opacity, removal: .identity))
                } else {
                    outlinePane.transition(.asymmetric(insertion: .opacity, removal: .identity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(motion.fade, value: showsPages)
        }
    }

    private var navigationBar: some View {
        Picker("页面导航", selection: $showsPages) {
            Text("大纲").tag(false)
            Text("缩略图").tag(true)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 154)
        .padding(.horizontal, 34)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) {
            Menu {
                Button("展开全部") {
                    withAnimation(motion.animation) { expanded = Set(source.navigation.flatMap(\.branches)) }
                }
                Button("折叠全部") {
                    withAnimation(motion.animation) { expanded = [] }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("大纲显示选项")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.trailing, 8)
            .opacity(showsPages ? 0 : 1)
            .allowsHitTesting(!showsPages)
            .disabled(showsPages)
            .accessibilityHidden(showsPages)
            .animation(motion.fade, value: showsPages)
        }
        .padding(.vertical, 9)
    }

    private var thumbnailPane: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    thumbnails(width: geometry.size.width)
                }
                .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.01) { visible in
                    visibleThumbnails = Set(visible)
                }
                .onAppear { revealThumbnail(session.index, using: proxy) }
                .onChange(of: session.index) { _, page in
                    if !visibleThumbnails.contains(page) { revealThumbnail(page, using: proxy) }
                }
            }
        }
    }

    private var outlinePane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(source.navigation) { entry in
                    OutlineBranchRow(entry: entry, depth: 0, currentPage: session.index,
                                     activeBookmark: activeBookmark, expanded: $expanded,
                                     navigate: session.navigate)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    private func revealThumbnail(_ page: Int, using proxy: ScrollViewProxy) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(page)
        }
    }

    private func thumbnails(width: CGFloat) -> some View {
        let columnCount = width >= 290 ? 2 : 1
        let tileWidth = (width - 16 - CGFloat(columnCount - 1) * 8) / CGFloat(columnCount) - 12
        let ratio = CGFloat(session.output.width) / CGFloat(session.output.height)
        let previewHeight = min(172, max(46, tileWidth / ratio))
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount)
        return LazyVGrid(columns: columns, spacing: 7) {
            ForEach(source.labels.indices, id: \.self) { index in
                let active = session.index == index
                Button {
                    session.navigate(to: index)
                } label: {
                    VStack(spacing: 5) {
                        preview(source, index: index, height: previewHeight)
                        Text("第 \(index + 1) 页").font(.caption.monospacedDigit())
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .background(active ? Color.accentColor.opacity(0.17) : .clear, in: .rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("跳转到第 \(index + 1) 页")
                .accessibilityAddTraits(active ? .isSelected : [])
                .id(index)
            }
        }
        .scrollTargetLayout()
        .padding(.horizontal, 8)
        .padding(.bottom, 12)
    }

    private func preview(_ source: PDFSource, index: Int, height: CGFloat) -> some View {
        OutputPreview(source: source, index: index, marks: session.marks(for: index), settings: session.output)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(.primary.opacity(0.035), in: .rect(cornerRadius: 4))
            .accessibilityHidden(true)
    }
}

private struct OutlineBranchRow: View {
    let entry: NavigationEntry
    let depth: Int
    let currentPage: Int
    let activeBookmark: String?
    @Binding var expanded: Set<String>
    let navigate: (Int) -> Void
    private var motion = PresenterMotion()

    var body: some View {
        let isExpanded = expanded.contains(entry.id)
        let sectionActive = activeBookmark == entry.id ||
            (!isExpanded && (activeBookmark?.hasPrefix(entry.id + ".") ?? false))
        let childHighlightsPage = isExpanded && entry.children.contains { $0.isPage && $0.page == currentPage }
        let active = entry.isPage ? entry.page == currentPage : sectionActive && !childHighlightsPage

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                if entry.children.isEmpty {
                    Color.clear.frame(width: 26)
                } else {
                    Button {
                        toggleExpansion()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 26, height: 33)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel((isExpanded ? "折叠" : "展开") + entry.title)
                }
                Button {
                    if let page = entry.page { navigate(page) }
                    else { toggleExpansion() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.title)
                            .font(entry.isPage ? .subheadline : .callout.weight(depth == 0 ? .medium : .regular))
                            .foregroundStyle(childHighlightsPage ? Color.accentColor : Color.primary)
                            .lineLimit(2)
                        Spacer(minLength: 3)
                        if let page = entry.page, !entry.isPage {
                            Text("\(page + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.trailing, 8)
                    .frame(minHeight: 33)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
            .padding(.leading, CGFloat(min(depth, 7) * 13))
            .background(active ? Color.accentColor.opacity(0.17) : .clear, in: .rect(cornerRadius: 7))
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(entry.children) { child in
                        OutlineBranchRow(entry: child, depth: depth + 1, currentPage: currentPage,
                                         activeBookmark: activeBookmark, expanded: $expanded, navigate: navigate)
                    }
                }
                .transition(.opacity)
            }
        }
        .id(entry.id)
    }

    private func toggleExpansion() {
        withAnimation(motion.animation) {
            if expanded.contains(entry.id) { expanded.remove(entry.id) }
            else { expanded.insert(entry.id) }
        }
    }
}

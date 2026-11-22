import KurnCore
import SwiftUI

/// The Graph Explorer (K4.3): a neighbourhood drawn on a `Canvas`, with one
/// button per node laid over it for touch and VoiceOver, and a list of the
/// same claims as the alternative; as it is (relationships), on a day
/// (evolution), between two days (compare) or by context (lanes). What it shows comes from
/// `KnowledgeGraphQueryService`; words and links from `KnowledgeGraphPresentation`.
struct KnowledgeGraphView: View {
    let read: KnowledgeBrowserRead
    let service: KnowledgeGraphQueryService
    let entityID: UUID
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    /// Root, selection, filters and view; the service keeps it while the
    /// reader reloads, so a page opened from here comes back to the same graph.
    @State private var exploration: KnowledgeGraphPresentation.Exploration

    init(read: KnowledgeBrowserRead, entityID: UUID, service: KnowledgeGraphQueryService) {
        self.read = read
        self.service = service
        self.entityID = entityID
        _exploration = State(initialValue: service.exploration(from: entityID))
    }

    private var isList: Bool { exploration.showsList ?? voiceOver }
    private var selected: UUID { exploration.selected }

    var body: some View {
        let laidOut = service.laidOut(exploration, from: entityID, in: read)
        Group {
            if let laidOut {
                let days = KnowledgeGraphPresentation.days(exploration, pages: read.pages, entityID: entityID, now: Date())
                let states = KnowledgeGraphPresentation.states(exploration, graph: laidOut.graph, pages: read.pages, days: days)
                let scene = KnowledgeGraphPresentation.scene(laidOut.graph, layout: laidOut.layout, pages: read.pages, states: states)
                content(exploration.mode == .lanes
                    ? KnowledgeGraphPresentation.laned(scene, pages: read.pages, contexts: read.meetingContexts) : scene, days: days)
            } else {
                KnowledgeBrowserUnavailable()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { filterMenu }
        }
        .onChange(of: exploration) { _, exploration in service.remember(exploration, from: entityID) }
        .accessibilityIdentifier("knowledge.graph")
    }

    private func content(_ scene: KnowledgeGraphPresentation.Scene, days: KnowledgeGraphPresentation.Days) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                modeCard(days: days)
                if let legend = KnowledgeGraphPresentation.legend(exploration.mode) { footnote(legend) }
                Picker(KnowledgeGraphPresentation.copy("view"), selection: Binding(get: { isList }, set: { exploration.showsList = $0 })) {
                    Text(KnowledgeGraphPresentation.copy("view.graph")).tag(false)
                    Text(KnowledgeGraphPresentation.copy("view.list")).tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.top, 4)
                .accessibilityIdentifier("knowledge.graph.view")
                if !isList {
                    KnowledgeGraphCanvas(scene: scene, selected: selected) { exploration.selected = $0 }
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 520)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                summary(scene)
                if isList {
                    ForEach(KnowledgeGraphPresentation.listSections(scene)) { item in
                        nodeCard(item.node, edges: item.edges)
                    }
                } else if let node = scene.node(selected) ?? scene.node(scene.rootID) {
                    nodeCard(node, edges: scene.edges(touching: node.id))
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
        }
        .knowledgeReadingSurface()
    }

    /// The mode, and the days the evolution and compare modes read.
    private func modeCard(days: KnowledgeGraphPresentation.Days) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(KnowledgeGraphPresentation.copy("mode"), selection: $exploration.mode) {
                ForEach(KnowledgeGraphPresentation.GraphMode.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("knowledge.graph.mode")
            switch exploration.mode {
            case .relationships, .lanes:
                EmptyView()
            case .evolution:
                Divider().overlay(Theme.separator).accessibilityHidden(true)
                DatePicker(KnowledgeGraphPresentation.copy("on"),
                           selection: Binding(get: { days.day }, set: { exploration.day = $0 }), displayedComponents: .date)
                    .accessibilityIdentifier("knowledge.graph.day")
                knownThenToggle
            case .compare:
                Divider().overlay(Theme.separator).accessibilityHidden(true)
                DatePicker(KnowledgeComparePresentation.copy("from"),
                           selection: Binding(get: { days.from }, set: { exploration.from = $0 }), displayedComponents: .date)
                    .accessibilityIdentifier("knowledge.graph.from")
                DatePicker(KnowledgeComparePresentation.copy("to"),
                           selection: Binding(get: { days.to }, set: { exploration.to = $0 }), displayedComponents: .date)
                    .accessibilityIdentifier("knowledge.graph.to")
                knownThenToggle
            }
        }
        .font(Theme.subheadline)
        .knowledgeCard()
    }

    private var knownThenToggle: some View {
        Toggle(KnowledgeComparePresentation.copy("as_known_then"), isOn: $exploration.asKnownThen)
            .accessibilityIdentifier("knowledge.graph.asKnownThen")
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(Theme.footnote).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func summary(_ scene: KnowledgeGraphPresentation.Scene) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            footnote(scene.summary)
            if scene.isTruncated { footnote(KnowledgeGraphPresentation.copy("truncated")) }
            if scene.nodes.contains(where: \.hasMore) { footnote(KnowledgeGraphPresentation.copy("has_more_footer")) }
            ForEach(Array(scene.cycles.enumerated()), id: \.offset) { _, names in
                footnote(String(format: KnowledgeGraphPresentation.copy("cycle"), names.joined(separator: ", ")))
                    .accessibilityIdentifier("knowledge.graph.cycle")
            }
        }
    }

    private func nodeCard(_ node: KnowledgeGraphPresentation.Node, edges: [KnowledgeGraphPresentation.Edge]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                KnowledgeIconWell(systemImage: node.isRoot ? "scope" : "circle.hexagongrid")
                Text(verbatim: node.name).font(Theme.headline).foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("knowledge.graph.selected")
            }
            HStack(spacing: 8) {
                NavigationLink(value: KnowledgeBrowserRoute.entity(node.id)) {
                    KnowledgeChipLabel(title: KnowledgeGraphPresentation.copy("open_page"), systemImage: "doc.text")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("knowledge.graph.openPage")
                if !node.isRoot {
                    KnowledgeChipButton(title: KnowledgeGraphPresentation.copy("recentre"), systemImage: "scope") {
                        exploration.recentre(on: node.id)
                    }
                    .accessibilityIdentifier("knowledge.graph.recentre")
                }
            }
            ForEach(edges) { edge in
                Divider().overlay(Theme.separator).accessibilityHidden(true)
                edgeRow(edge)
            }
            if node.hasMore {
                Text(KnowledgeGraphPresentation.copy("has_more")).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .knowledgeCard()
    }

    @ViewBuilder
    private func edgeRow(_ edge: KnowledgeGraphPresentation.Edge) -> some View {
        let notes = KnowledgeGraphPresentation.notes(edge)
        let content = VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: edge.text).font(Theme.subheadlineEmphasized).foregroundStyle(Theme.textPrimary)
            if !notes.isEmpty {
                Text(verbatim: notes.joined(separator: " · ")).font(Theme.caption2Emphasized).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let route = edge.evidence {
            NavigationLink(value: route) {
                HStack(spacing: 12) {
                    content
                    KnowledgeChevron()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("knowledge.graph.claim")
        } else {
            content.accessibilityIdentifier("knowledge.graph.claim")
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker(KnowledgeGraphPresentation.copy("depth"), selection: $exploration.options.depth) {
                Text(KnowledgeGraphPresentation.copy("depth.one")).tag(1)
                Text(KnowledgeGraphPresentation.copy("depth.two")).tag(2)
            }
            Toggle(KnowledgeGraphPresentation.copy("show_tentative"), isOn: $exploration.options.includesTentative)
            Toggle(KnowledgeGraphPresentation.copy("show_negated"), isOn: $exploration.options.includesNegated)
            Toggle(KnowledgeGraphPresentation.copy("show_inferred"), isOn: $exploration.options.includesInferred)
        } label: {
            Label(KnowledgeGraphPresentation.copy("filter"), systemImage: "line.3.horizontal.decrease.circle")
        }
        .accessibilityIdentifier("knowledge.graph.filter")
    }
}

/// The drawing itself and its hit-testing overlay. The canvas is decorative
/// for assistive technologies; each node's button carries its name and state.
private struct KnowledgeGraphCanvas: View {
    let scene: KnowledgeGraphPresentation.Scene
    let selected: UUID
    let onSelect: (UUID) -> Void
    private let radius: CGFloat = 9

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Canvas { context, size in draw(in: &context, size: size) }
                    .accessibilityHidden(true)
                ForEach(scene.nodes) { node in
                    let point = KnowledgeGraphPresentation.point(node.point, in: size)
                    Button { onSelect(node.id) } label: {
                        Color.clear.frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .position(point)
                    .accessibilityLabel(KnowledgeGraphPresentation.label(node, scene: scene))
                    .accessibilityAddTraits(node.id == selected ? .isSelected : [])
                    .accessibilityIdentifier("knowledge.graph.node")
                }
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        drawLanes(in: &context, size: size)
        let touching = Set(scene.edges(touching: selected).map(\.factID))
        for edge in scene.edges {
            guard let source = scene.node(edge.sourceID), let target = scene.node(edge.targetID) else { continue }
            let from = KnowledgeGraphPresentation.point(source.point, in: size)
            let to = KnowledgeGraphPresentation.point(target.point, in: size)
            var line = Path()
            line.move(to: from)
            line.addLine(to: to)
            // Tentative claims are dashed, inferred ones dotted and negated ones crossed out: a
            // shape, not only a colour, carries each state.
            let style = StrokeStyle(lineWidth: touching.contains(edge.factID) ? 2.5 : 1.2, dash: edge.isTentative ? [6, 4] : edge.isInferred ? [1, 4] : [])
            let shading: GraphicsContext.Shading = .color(touching.contains(edge.factID) ? Theme.accent : Theme.textSecondary)
            context.stroke(line, with: shading, style: style)
            context.fill(arrowhead(from: from, to: to), with: shading)
            if edge.isNegated { context.stroke(cross(at: midpoint(from, to)), with: shading, lineWidth: 2) }
            if let mark = stateMark(edge.state, at: along(from, to, 0.35)) { context.stroke(mark, with: shading, lineWidth: 2) }
        }
        for node in scene.nodes {
            let centre = KnowledgeGraphPresentation.point(node.point, in: size)
            // The centre is a square, every other node a circle: its shape,
            // not only its colour, says which one the graph is centred on.
            let frame = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
            let mark = node.isRoot ? Path(roundedRect: frame, cornerRadius: 3) : Path(ellipseIn: frame)
            context.fill(mark, with: .color(node.isRoot ? Theme.accent : Theme.textSecondary))
            if node.hasMore {
                let outer = Path(ellipseIn: CGRect(x: centre.x - radius - 5, y: centre.y - radius - 5,
                                                   width: (radius + 5) * 2, height: (radius + 5) * 2))
                context.stroke(outer, with: .color(Theme.textSecondary), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            if node.id == selected {
                let ring = Path(ellipseIn: CGRect(x: centre.x - radius - 9, y: centre.y - radius - 9,
                                                  width: (radius + 9) * 2, height: (radius + 9) * 2))
                context.stroke(ring, with: .color(Theme.textPrimary), lineWidth: 2.5)
            }
            context.draw(Text(verbatim: node.name).font(Theme.captionEmphasized).foregroundStyle(Theme.textPrimary),
                         at: CGPoint(x: centre.x, y: centre.y + radius + 14), anchor: .center)
        }
    }

    /// Lines between the context lanes, and each lane's name at its top left.
    private func drawLanes(in context: inout GraphicsContext, size: CGSize) {
        let count = CGFloat(scene.lanes.count)
        for (index, lane) in scene.lanes.enumerated() {
            let top = CGFloat(index) / count * size.height
            if index > 0 {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: top))
                line.addLine(to: CGPoint(x: size.width, y: top))
                context.stroke(line, with: .color(Theme.separator), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            context.draw(Text(verbatim: lane.title.uppercased()).font(Theme.caption2Emphasized).foregroundStyle(Theme.textTertiary),
                         at: CGPoint(x: 6, y: top + 6), anchor: .topLeading)
        }
    }

    private func midpoint(_ from: CGPoint, _ to: CGPoint) -> CGPoint { along(from, to, 0.5) }

    private func along(_ from: CGPoint, _ to: CGPoint, _ fraction: CGFloat) -> CGPoint {
        CGPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction)
    }

    /// The shape that marks an edge's state in the evolution and compare modes:
    /// a plus for a relationship that started, a square for one that ended,
    /// and a ring around either, or alone, for one that may not have held on a
    /// day it is shown for (the footer and the rows say so in words).
    private func stateMark(_ state: KnowledgeGraphPresentation.EdgeState?, at point: CGPoint) -> Path? {
        guard let state else { return nil }
        var path = Path()
        switch state {
        case .started:
            path.move(to: CGPoint(x: point.x - 5, y: point.y))
            path.addLine(to: CGPoint(x: point.x + 5, y: point.y))
            path.move(to: CGPoint(x: point.x, y: point.y - 5))
            path.addLine(to: CGPoint(x: point.x, y: point.y + 5))
        case .ended:
            path.addRect(CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
        case .holds, .kept:
            break
        }
        if state.isUncertain { path.addEllipse(in: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)) }
        return path.isEmpty ? nil : path
    }

    private func cross(at point: CGPoint) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: point.x - 5, y: point.y - 5))
        path.addLine(to: CGPoint(x: point.x + 5, y: point.y + 5))
        path.move(to: CGPoint(x: point.x + 5, y: point.y - 5))
        path.addLine(to: CGPoint(x: point.x - 5, y: point.y + 5))
        return path
    }

    /// A small arrowhead on the target's rim, pointing in the claim's direction.
    private func arrowhead(from: CGPoint, to: CGPoint) -> Path {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = max((dx * dx + dy * dy).squareRoot(), 0.001)
        let ux = dx / length, uy = dy / length
        let tip = CGPoint(x: to.x - ux * (radius + 2), y: to.y - uy * (radius + 2))
        let base = CGPoint(x: tip.x - ux * 8, y: tip.y - uy * 8)
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: base.x - uy * 4, y: base.y + ux * 4))
        path.addLine(to: CGPoint(x: base.x + uy * 4, y: base.y - ux * 4))
        path.closeSubpath()
        return path
    }
}

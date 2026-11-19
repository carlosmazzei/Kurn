import KurnCore
import SwiftUI

/// The Graph Explorer's relationships mode (K4.3): a neighbourhood drawn on a
/// `Canvas`, with one button per node laid over it for touch and VoiceOver,
/// and a list of the same claims as the alternative. What it shows comes from
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
                let scene = KnowledgeGraphPresentation.scene(laidOut.graph, layout: laidOut.layout, pages: read.pages)
                content(scene)
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

    private func content(_ scene: KnowledgeGraphPresentation.Scene) -> some View {
        List {
            Section {
                Picker(KnowledgeGraphPresentation.copy("view"), selection: Binding(get: { isList }, set: { exploration.showsList = $0 })) {
                    Text(KnowledgeGraphPresentation.copy("view.graph")).tag(false)
                    Text(KnowledgeGraphPresentation.copy("view.list")).tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("knowledge.graph.view")
                if !isList {
                    KnowledgeGraphCanvas(scene: scene, selected: selected) { exploration.selected = $0 }
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 520)
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
            } footer: {
                footer(scene)
            }
            if isList {
                ForEach(KnowledgeGraphPresentation.listSections(scene)) { item in
                    nodeSection(item.node, edges: item.edges)
                }
            } else if let node = scene.node(selected) ?? scene.node(scene.rootID) {
                nodeSection(node, edges: scene.edges(touching: node.id))
            }
        }
    }

    @ViewBuilder
    private func footer(_ scene: KnowledgeGraphPresentation.Scene) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: scene.summary)
            if scene.isTruncated { Text(KnowledgeGraphPresentation.copy("truncated")) }
            if scene.nodes.contains(where: \.hasMore) { Text(KnowledgeGraphPresentation.copy("has_more_footer")) }
            ForEach(Array(scene.cycles.enumerated()), id: \.offset) { _, names in
                Text(String(format: KnowledgeGraphPresentation.copy("cycle"), names.joined(separator: ", ")))
                    .accessibilityIdentifier("knowledge.graph.cycle")
            }
        }
    }

    private func nodeSection(_ node: KnowledgeGraphPresentation.Node, edges: [KnowledgeGraphPresentation.Edge]) -> some View {
        Section {
            NavigationLink(value: KnowledgeBrowserRoute.entity(node.id)) {
                Label(KnowledgeGraphPresentation.copy("open_page"), systemImage: "doc.text")
            }
            .accessibilityIdentifier("knowledge.graph.openPage")
            if !node.isRoot {
                Button { exploration.recentre(on: node.id) } label: {
                    Label(KnowledgeGraphPresentation.copy("recentre"), systemImage: "scope")
                }
                .accessibilityIdentifier("knowledge.graph.recentre")
            }
            ForEach(edges) { edge in edgeRow(edge) }
            if node.hasMore {
                Text(KnowledgeGraphPresentation.copy("has_more")).font(Theme.footnote).foregroundStyle(Theme.textSecondary)
            }
        } header: {
            Text(verbatim: node.name).accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("knowledge.graph.selected")
        }
    }

    @ViewBuilder
    private func edgeRow(_ edge: KnowledgeGraphPresentation.Edge) -> some View {
        let notes = KnowledgeGraphPresentation.notes(edge)
        let content = VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: edge.text).font(Theme.bodyEmphasized)
            if !notes.isEmpty {
                Text(verbatim: notes.joined(separator: " · ")).font(Theme.captionEmphasized)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let route = edge.evidence {
            NavigationLink(value: route) { content }.accessibilityIdentifier("knowledge.graph.claim")
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

    private func midpoint(_ from: CGPoint, _ to: CGPoint) -> CGPoint { CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2) }

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

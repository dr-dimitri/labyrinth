import AppKit
import simd
import BlacksiteCore

/// The briefing consumes authored geography only. It has no simulation, enemy
/// state, perception query or gesture that can change a running mission.
@MainActor
final class NativeBriefingMapView: NSView {
    private var map: MapDefinition
    private var mission: MissionKind
    private var markers: [Marker] = []
    private(set) var accessibilitySummary = ""

    private enum Symbol { case start, objective, extraction, device }
    private struct Marker {
        let position: SIMD3<Float>
        let code: String
        let title: String
        let symbol: Symbol
        let emphasized: Bool
        let color: NSColor
    }
    private static let ink=NSColor(calibratedRed:0.91,green:0.94,blue:0.86,alpha:1)
    private static let muted=NSColor(calibratedRed:0.64,green:0.72,blue:0.66,alpha:1)
    private static let objective=NSColor(calibratedRed:0.97,green:0.66,blue:0.32,alpha:1)
    private static let exit=NSColor(calibratedRed:0.43,green:0.78,blue:0.72,alpha:1)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width:340,height:330) }

    init(frame: NSRect = .zero, map: MapDefinition, mission: MissionKind) {
        self.map=map;self.mission=mission
        super.init(frame:frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityHelp("Schematische bekannte Lage. Norden ist oben. Die Buchstaben und Ziffern entsprechen der Legende.")
        update(map:map,mission:mission)
    }
    required init?(coder: NSCoder) { return nil }

    func update(map: MapDefinition, mission: MissionKind) {
        self.map=map;self.mission=mission
        var known=[Marker(position:map.playerStart.position,code:"S",title:"Start",symbol:.start,
                          emphasized:true,color:Self.ink)]
        let dataMission=mission == .recoverData || mission == .operation
        known.append(Marker(position:map.dataSite,code:"D",title:"Datenstation",symbol:.objective,
                            emphasized:dataMission,color:Self.objective))
        known.append(Marker(position:map.radioSite,code:"F",title:"Funkstation",symbol:.objective,
                            emphasized:mission == .secureRadio || (mission == .operation &&
                                map.operation?.requiredStages.contains { $0.kind == .radioTransfer } == true),color:Self.objective))
        if mission == .operation, let operation=map.operation {
            let relays = operation.requiredStages.filter { $0.kind == .relayGroup }.flatMap(\.targets)
            for (index, relay) in relays.enumerated() {
                known.append(Marker(position: relay.position, code: "R\(index + 1)", title: relay.title,
                    symbol: .objective, emphasized: true, color: Self.objective))
            }
            for (index,exit) in operation.extractions.enumerated() {
                known.append(Marker(position:exit.position,code:String(index+1),title:exit.title,
                    symbol:.extraction,emphasized:true,color:Self.exit))
            }
        } else {
            known.append(Marker(position:map.extraction,code:"X",title:"Evakuierung",symbol:.extraction,
                                emphasized:mission != .secureRadio,color:Self.exit))
        }
        for device in map.environment.devices {
            guard let owner=map.obstacles.first(where: { $0.id==device.ownerObstacleID }) else { continue }
            let generator=device.kind == .generator
            known.append(Marker(position:owner.position,code:generator ? "G":"T",title:generator ? "Generator":"Servicetor",
                                symbol:.device,emphasized:mission == .operation,color:Self.muted))
        }
        markers=known
        let extent=SIMD2(map.maximum.x-map.minimum.x,map.maximum.z-map.minimum.z)
        let dimensions="\(Int(extent.x.rounded())) mal \(Int(extent.y.rounded())) Meter"
        var descriptions=known.map { "\($0.code): \($0.title), \(sector(of:$0.position))" }
        if mission == .operation, let operation=map.operation {
            descriptions += operation.extractions.map { "\($0.title): \($0.detail) Im Bereich \(formatted($0.holdDuration)) Sekunden am Boden bleiben." }
        }
        accessibilitySummary="\(map.displayName), schematische Einsatzkarte, \(dimensions). Norden oben. " +
            "Flächen zeigen bekannte Bauten und Deckung; breite Streifen zeigen Straßen. " +
            (map.environment.shallowWaterZones.isEmpty ? "" : "Blaue Flächen zeigen flache Watbecken; trockene Umgehungen bleiben frei. ") +
            descriptions.joined(separator:". ")
        setAccessibilityLabel("Einsatzkarte: \(map.displayName)")
        setAccessibilityValue(accessibilitySummary)
        needsDisplay=true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed:0.052,green:0.092,blue:0.077,alpha:1).setFill()
        NSBezierPath(rect:bounds).fill()
        guard bounds.width>=120, bounds.height>=150 else { return }
        let outer=bounds.insetBy(dx:0.5,dy:0.5)
        Self.muted.withAlphaComponent(0.32).setStroke();NSBezierPath(rect:outer).stroke()
        label("BEKANNTE LAGE",rect:NSRect(x:14,y:11,width:bounds.width-68,height:15),size:10,color:Self.ink,weight:.semibold)
        label("N ↑",rect:NSRect(x:bounds.width-48,y:10,width:34,height:16),size:11,color:Self.ink,alignment:.right)
        let frame=mapFrame
        NSColor(calibratedRed:0.080,green:0.132,blue:0.107,alpha:1).setFill()
        NSBezierPath(rect:frame).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect:frame).addClip()
        drawGrid(in:frame)
        for water in map.environment.shallowWaterZones {
            let minimum = project(SIMD3(water.minimum.x, 0, water.minimum.y), in: frame)
            let maximum = project(SIMD3(water.maximum.x, 0, water.maximum.y), in: frame)
            NSColor(calibratedRed: 0.11, green: 0.25, blue: 0.30, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: minimum.x, y: minimum.y,
                width: maximum.x - minimum.x, height: maximum.y - minimum.y)).fill()
        }
        for road in map.roads {
            let minimum=project(SIMD3(road.minimum.x,0,road.minimum.y),in:frame)
            let maximum=project(SIMD3(road.maximum.x,0,road.maximum.y),in:frame)
            let area=NSRect(x:minimum.x,y:minimum.y,width:maximum.x-minimum.x,height:maximum.y-minimum.y)
            NSColor(calibratedRed:0.18,green:0.22,blue:0.20,alpha:1).setFill()
            NSBezierPath(rect:area).fill()
        }
        for obstacle in map.obstacles where !obstacle.destroyed {
            let minimum=project(obstacle.position-SIMD3(obstacle.size.x*0.5,0,obstacle.size.z*0.5),in:frame)
            let maximum=project(obstacle.position+SIMD3(obstacle.size.x*0.5,0,obstacle.size.z*0.5),in:frame)
            let area=NSRect(x:minimum.x,y:minimum.y,width:max(0.8,maximum.x-minimum.x),height:max(0.8,maximum.y-minimum.y))
            let shape=obstacle.kind == .barrel ? NSBezierPath(ovalIn:area):NSBezierPath(rect:area)
            let permanent = !obstacle.health.isFinite
            NSColor(calibratedRed:permanent ? 0.30:0.22,green:permanent ? 0.36:0.30,blue:permanent ? 0.29:0.24,alpha:1).setFill()
            shape.fill();Self.muted.withAlphaComponent(permanent ? 0.70:0.42).setStroke()
            shape.lineWidth=0.7;shape.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        Self.muted.withAlphaComponent(0.48).setStroke();NSBezierPath(rect:frame).stroke()
        // Small, inactive known locations are drawn first. Objective codes stay
        // legible when authored features are close together on a compact map.
        for marker in markers.sorted(by: { !$0.emphasized && $1.emphasized }) { draw(marker,in:frame) }
        let legendY=bounds.height-52
        label("S Start  ·  D Daten  ·  F Funk",rect:NSRect(x:14,y:legendY,width:bounds.width-28,height:15),size:9,color:Self.ink)
        let exits=mission == .operation && map.operation != nil ? "1 / 2 Ausgänge":"X Ausgang"
        var legend = [exits]
        if markers.contains(where: { $0.code.hasPrefix("R") }) { legend.append("R Relais") }
        if markers.contains(where: { $0.code == "G" }) { legend.append("G Strom") }
        if markers.contains(where: { $0.code == "T" }) { legend.append("T Tor") }
        label(legend.joined(separator: " · "),rect:NSRect(x:14,y:legendY+17,width:bounds.width-28,height:15),size:9,color:Self.muted)
        drawScale(in:frame)
    }

    private var mapFrame: NSRect {
        let available=NSRect(x:20,y:37,width:max(1,bounds.width-40),height:max(1,bounds.height-104))
        let width=CGFloat(map.maximum.x-map.minimum.x),height=CGFloat(map.maximum.z-map.minimum.z)
        let scale=min(available.width/max(width,0.001),available.height/max(height,0.001))
        return NSRect(x:available.midX-width*scale*0.5,y:available.midY-height*scale*0.5,width:width*scale,height:height*scale)
    }
    private func project(_ point: SIMD3<Float>,in frame:NSRect)->NSPoint {
        NSPoint(x:frame.minX+CGFloat((point.x-map.minimum.x)/(map.maximum.x-map.minimum.x))*frame.width,
                y:frame.minY+CGFloat((point.z-map.minimum.z)/(map.maximum.z-map.minimum.z))*frame.height)
    }
    private func drawGrid(in frame:NSRect) {
        let grid=NSBezierPath();grid.lineWidth=0.5
        for fraction:CGFloat in [0.25,0.5,0.75] {
            grid.move(to:NSPoint(x:frame.minX+frame.width*fraction,y:frame.minY))
            grid.line(to:NSPoint(x:frame.minX+frame.width*fraction,y:frame.maxY))
            grid.move(to:NSPoint(x:frame.minX,y:frame.minY+frame.height*fraction))
            grid.line(to:NSPoint(x:frame.maxX,y:frame.minY+frame.height*fraction))
        }
        Self.muted.withAlphaComponent(0.13).setStroke();grid.stroke()
    }
    private func draw(_ marker:Marker,in frame:NSRect) {
        let point=project(marker.position,in:frame),radius:CGFloat=marker.emphasized ? 7.5:6
        let shape:NSBezierPath
        switch marker.symbol {
        case .start: shape=NSBezierPath(ovalIn:NSRect(x:point.x-radius,y:point.y-radius,width:radius*2,height:radius*2))
        case .objective: shape=NSBezierPath(roundedRect:NSRect(x:point.x-radius,y:point.y-radius,width:radius*2,height:radius*2),xRadius:2,yRadius:2)
        case .extraction:
            shape=NSBezierPath();shape.move(to:NSPoint(x:point.x,y:point.y-radius-2))
            shape.line(to:NSPoint(x:point.x+radius+2,y:point.y+radius));shape.line(to:NSPoint(x:point.x-radius-2,y:point.y+radius));shape.close()
        case .device:
            shape=NSBezierPath();shape.move(to:NSPoint(x:point.x,y:point.y-radius-2))
            shape.line(to:NSPoint(x:point.x+radius+2,y:point.y));shape.line(to:NSPoint(x:point.x,y:point.y+radius+2))
            shape.line(to:NSPoint(x:point.x-radius-2,y:point.y));shape.close()
        }
        NSColor(calibratedRed:0.055,green:0.09,blue:0.075,alpha:1).setFill();shape.fill()
        marker.color.withAlphaComponent(marker.emphasized ? 1:0.68).setStroke();shape.lineWidth=marker.emphasized ? 1.6:1;shape.stroke()
        let y=point.y-(marker.symbol == .extraction ? 3.5:5.5)
        label(marker.code,rect:NSRect(x:point.x-radius-2,y:y,width:radius*2+4,height:13),size:9,
              color:marker.emphasized ? marker.color:Self.muted,weight:.bold,alignment:.center)
    }
    private func drawScale(in frame:NSRect) {
        let span=map.maximum.x-map.minimum.x
        let metres:Float = span>=60 ? 10:span>=25 ? 5:2
        let width=frame.width*CGFloat(metres/span),x=frame.minX,y=frame.maxY+7
        let line=NSBezierPath();line.lineWidth=1
        line.move(to:NSPoint(x:x,y:y-2));line.line(to:NSPoint(x:x,y:y+2))
        line.move(to:NSPoint(x:x,y:y));line.line(to:NSPoint(x:x+width,y:y))
        line.move(to:NSPoint(x:x+width,y:y-2));line.line(to:NSPoint(x:x+width,y:y+2))
        Self.muted.setStroke();line.stroke()
        label("\(Int(metres)) m",rect:NSRect(x:x+width+5,y:y-6,width:38,height:13),size:8,color:Self.muted)
    }
    private func sector(of position:SIMD3<Float>)->String {
        let center=(map.minimum+map.maximum)*0.5,span=map.maximum-map.minimum
        let north=position.z<center.z-span.z*0.18,south=position.z>center.z+span.z*0.18
        let west=position.x<center.x-span.x*0.18,east=position.x>center.x+span.x*0.18
        if north { return west ? "im Nordwesten":east ? "im Nordosten":"im Norden" }
        if south { return west ? "im Südwesten":east ? "im Südosten":"im Süden" }
        return west ? "im Westen":east ? "im Osten":"im Zentrum"
    }
    private func formatted(_ value:Float)->String { String(format:"%.1f",value) }
    private func label(_ value:String,rect:NSRect,size:CGFloat,color:NSColor,weight:NSFont.Weight = .regular,
                       alignment:NSTextAlignment = .left) {
        let paragraph=NSMutableParagraphStyle();paragraph.alignment=alignment;paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in:rect,withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:size,weight:weight),
            .foregroundColor:color,.paragraphStyle:paragraph])
    }
}

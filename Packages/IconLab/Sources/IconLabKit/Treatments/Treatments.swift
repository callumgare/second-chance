import Foundation

/// Treatments: each makes a document from a program's media and the suggestion parameters. The first lab's
/// treatments, ported so that what they make stays editable: a figure is a cut-out image layer placed by a
/// transform, a background picture is a cropped image layer, and pixel work is an effect with parameters.
nonisolated public struct Treatment: Sendable {
    public let key: String
    public let title: String
    public let uses: [String]
    public let about: String
    let make: @Sendable (Ctx) async throws -> Doc?
}

nonisolated public struct TreatmentInfo: Codable, Sendable {
    public let key: String, title: String, about: String, uses: [String]
}

nonisolated public struct Suggestion: Codable, Sendable {
    public let treatment: String
    public let title: String
    public let about: String
    public let uses: [String]
    public let doc: Doc
}

nonisolated let canvasSide = 1024.0

/// What a treatment builds from.
nonisolated public struct Ctx: Sendable {
    public let program: String
    public let media: [String: MediaRecord]
    public let roles: [String: String]
    public let p: SuggestionParams
    let assets: Assets
    let treatment: String

    var primary: RGB { p.primary.flatMap(RGB.init(hex:)) ?? RGB(0x3c, 0x7f, 0x8f) }
    var hasSecondary: Bool { p.secondary != "transparent" }
    var secondary: RGB { hasSecondary ? (p.secondary.flatMap(RGB.init(hex:)) ?? RGB(0xf4, 0xef, 0xe6)) : RGB(255, 255, 255) }
    var scale: Double { p.scale ?? 1 }
    var dx: Double { p.dx ?? 0 }
    var dy: Double { p.dy ?? 0 }
    var dx2: Double { p.dx2 ?? 0 }
    var dy2: Double { p.dy2 ?? 0 }
    var angle: Double { p.angle ?? 45 }

    func id(_ role: String) -> String? { roles[role] ?? roles["subject"] }
    func has(_ role: String) -> Bool { roles[role] != nil }

    func doc(_ name: String, fill: Fill, _ groups: [Group]) -> Doc {
        var fill = fill
        if fill.kind != .none, let bg = p.background.flatMap(RGB.init(hex:)) { fill.color = bg; fill.dark = nil }
        return Doc(name: name, program: program, origin: Origin(treatment: treatment, params: p), fill: fill, groups: groups)
    }

    static func gradient(_ c: RGB, dark: RGB? = nil) -> Fill { Fill(kind: .gradient, color: c, dark: dark) }
    static func solid(_ c: RGB, dark: RGB? = nil) -> Fill { Fill(kind: .solid, color: c, dark: dark) }

    // MARK: Placement (the first lab's rules, answering a transform instead of pixels)

    struct CutInfo { let w: Double, h: Double, box: (x: Int, y: Int, w: Int, h: Int), imageW: Double, imageH: Double }

    func cut(_ role: String) async throws -> CutInfo {
        guard let id = id(role) else { throw IconLabError.notFound("no image for \(role)") }
        let c = try await assets.cutout(program, id)
        let img = try await assets.image(program, id)
        return CutInfo(w: Double(c.bitmap.width), h: Double(c.bitmap.height), box: c.box, imageW: Double(img.width), imageH: Double(img.height))
    }

    func transform(x: Double, y: Double, w: Double) -> Transform {
        Transform(x: x / canvasSide, y: y / canvasSide, width: w / canvasSide)
    }

    /// Tall cut-outs bleed off the bottom, wide ones off the sides.
    func place(w: Double, h: Double, height: Double = 1, anchorX: Double = 0.46, bottom: Double = 1.04) -> Transform {
        let wide = w / h > 1.3
        var sc = canvasSide * (wide ? height * 1.15 : height) * scale / (wide ? w : h)
        if !wide, w * sc > canvasSide * 1.15 * scale { sc = canvasSide * 1.15 * scale / w }
        let dw = w * sc, dh = h * sc
        let x = canvasSide * (wide ? 0.5 : anchorX) - dw / 2 + dx * canvasSide
        let y = (wide ? canvasSide * 0.52 - dh / 2 : canvasSide * bottom - dh) + dy * canvasSide
        return transform(x: x + dw / 2, y: y + dh / 2, w: dw)
    }

    /// Flat sides flush with the canvas's edges.
    func placeFlush(w: Double, h: Double, sides: Set<String>, height: Double = 1) -> Transform {
        var sc: Double
        if sides.isSuperset(of: ["left", "right"]) { sc = canvasSide / w } else if sides.isSuperset(of: ["top", "bottom"]) { sc = canvasSide / h } else {
            sc = canvasSide * height * (sides.isEmpty ? 1 : 0.95) / max(w, h)
        }
        sc *= scale
        let dw = w * sc, dh = h * sc
        let x = sides.contains("left") ? 0 : sides.contains("right") ? canvasSide - dw : (canvasSide - dw) / 2
        let y = sides.contains("top") ? 0 : sides.contains("bottom") ? canvasSide - dh : (canvasSide - dh) / 2
        return transform(x: x + dw / 2 + dx * canvasSide, y: y + dh / 2 + dy * canvasSide, w: dw)
    }

    /// The role's cut-out as a layer: flush when it has flat sides (and snapping is on), else placed.
    func figure(_ role: String = "subject", height: Double = 1, anchorX: Double = 0.46, bottom: Double = 1.04,
                name: String = "Subject", effects: [Effect] = []) async throws -> Layer {
        let c = try await cut(role)
        let sides = Set((p.snap ?? true) ? (id(role).flatMap { media[$0]?.analysis.flatSides } ?? []) : [])
        let t = sides.isEmpty ? place(w: c.w, h: c.h, height: height, anchorX: anchorX, bottom: bottom)
            : placeFlush(w: c.w, h: c.h, sides: sides, height: height)
        return Layer(name: name, role: "subject", content: .image(ImageContent(asset: id(role) ?? "", cutout: true, effects: effects)), transform: t)
    }

    /// The role's whole image filling the canvas around a focus point (a crop of it, the canvas's size).
    func full(_ role: String, focus: (Double, Double) = (0.5, 0.5), zoom: Double = 1, rows: (Double, Double)? = nil,
              second: Bool = false, name: String = "Art", effects: [Effect] = []) async throws -> Layer {
        guard let id = id(role) else { throw IconLabError.notFound("no image for \(role)") }
        let img = try await assets.image(program, id)
        let (mx, my) = second ? (dx2, dy2) : (dx, dy)
        let fullW = Double(img.width), fullH0 = Double(img.height)
        let r0 = rows?.0 ?? 0, r1 = rows?.1 ?? 1
        let fullH = fullH0 * (r1 - r0)
        let sc = canvasSide / min(fullW, fullH) * zoom * scale
        let scaledW = fullW * sc, scaledH = fullH * sc
        let x = min(max(focus.0 * scaledW - canvasSide / 2 - mx * canvasSide, 0), max(scaledW - canvasSide, 0))
        let y = min(max(focus.1 * scaledH - canvasSide / 2 - my * canvasSide, 0), max(scaledH - canvasSide, 0))
        let crop = [x / scaledW, (r0 * fullH0 + y / sc) / fullH0, min(canvasSide, scaledW) / scaledW, min(canvasSide, scaledH) / sc / fullH0]
        return Layer(name: name, role: "backdrop", content: .image(ImageContent(asset: id, cutout: false, crop: crop, effects: effects)),
                     transform: .full)
    }

    /// The role's whole image filling the canvas, its subject's larger side `fill` of it, centred at `at`; and
    /// the subject's cut-out lying exactly over it.
    func fullAligned(_ role: String, at: (Double, Double), fill: Double) async throws -> (back: Layer, front: Layer) {
        guard let id = id(role) else { throw IconLabError.notFound("no image for \(role)") }
        let c = try await cut(role)
        let fullW = c.imageW, fullH = c.imageH
        let side = Double(max(c.box.w, c.box.h))
        let sc = max(canvasSide / min(fullW, fullH), canvasSide * fill / side) * scale
        let scaledW = fullW * sc, scaledH = fullH * sc
        let cx = (Double(c.box.x) + Double(c.box.w) / 2) * sc, cy = (Double(c.box.y) + Double(c.box.h) / 2) * sc
        // the picture behind stays put; the subject's own move shifts the cut-out (the crop window stops at the
        // picture's edge, so moving it would often do nothing)
        let x = min(max(cx - at.0 * canvasSide, 0), max(scaledW - canvasSide, 0))
        let y = min(max(cy - at.1 * canvasSide, 0), max(scaledH - canvasSide, 0))
        let back = Layer(name: "Art", role: "backdrop",
                         content: .image(ImageContent(asset: id, cutout: false, crop: [x / scaledW, y / scaledH, min(1, canvasSide / scaledW), min(1, canvasSide / scaledH)])),
                         transform: .full)
        let fw = Double(c.box.w) * sc
        let front = Layer(name: "Subject", role: "subject", content: .image(ImageContent(asset: id, cutout: true)),
                          transform: transform(x: Double(c.box.x) * sc - x + fw / 2 + dx * canvasSide,
                                               y: Double(c.box.y) * sc - y + Double(c.box.h) * sc / 2 + dy * canvasSide, w: fw))
        return (back, front)
    }
}

nonisolated func g(_ name: String, _ layers: [Layer], specular: Bool = true, shadow: Double = 0.35, translucency: Double? = nil) -> Group {
    Group(name: name, glass: Glass(specular: specular, shadow: shadow, translucency: translucency), layers: layers)
}

nonisolated func shapeLayer(_ name: String, _ shape: Shape, role: String = "pattern") -> Layer {
    Layer(name: name, role: role, content: .shape(shape))
}

nonisolated public enum Treatments {
    public static let all: [Treatment] = [
        Treatment(key: "lifted", title: "Lifted subject", uses: ["subject"],
                  about: "The figure cut out in full colour on the primary. Flat sides sit flush against the icon's edges; otherwise it bleeds off the bottom.", make: t_lifted),
        Treatment(key: "sticker", title: "Die-cut sticker", uses: ["subject"],
                  about: "The figure with a thick border in the secondary colour, on the primary.", make: t_sticker),
        Treatment(key: "screenprint", title: "Screenprint", uses: ["subject"],
                  about: "The figure in three flat tones (deep primary, primary, secondary) on a pale primary, each tone its own glass layer.", make: t_screenprint),
        Treatment(key: "double-exposure", title: "Double exposure", uses: ["subject", "fill"],
                  about: "The subject's outline, filled with the fill image (best: a strong outline, and a busy picture).", make: t_double_exposure),
        Treatment(key: "disc", title: "Disc", uses: ["disc", "subject"],
                  about: "A CD: the disc image's own label if there is one (cut to its circle), otherwise the subject's art printed on one.", make: t_disc),
        Treatment(key: "diagonal-fade", title: "Diagonal fade", uses: ["subject"],
                  about: "The subject's picture in the bottom right, fading into the primary towards the top left, the subject itself kept crisp. "
                      + "Angle sets the direction.", make: t_diagonal_fade),
        Treatment(key: "duotone", title: "Duotone with figure", uses: ["fill", "subject"],
                  about: "The fill art gradient-mapped to the primary and secondary, with the figure in its own colours in front.", make: t_duotone),
        Treatment(key: "halftone", title: "Halftone", uses: ["subject"],
                  about: "The figure as halftone dots of the primary on the secondary, like comic print.", make: t_halftone),
        Treatment(key: "halftone-art", title: "Halftone over art", uses: ["fill", "subject"],
                  about: "The fill art softened behind, the figure's halftone dots in the secondary over it.", make: t_halftone_art),
        Treatment(key: "line-art", title: "Line art", uses: ["subject"],
                  about: "The figure's edges traced as a glowing line of the secondary on a deep primary.", make: t_line_art),
        Treatment(key: "bands", title: "Palette bands", uses: ["subject"],
                  about: "Stripes from primary to secondary, the figure's silhouette in front.", make: t_bands),
        Treatment(key: "window", title: "Old window", uses: ["fill"],
                  about: "The art inside a retro window with a title bar in the primary: says old software.", make: t_window),
        Treatment(key: "logo-plate", title: "Logo plate", uses: ["logo", "subject"],
                  about: "The logo keyed off its background, on a glass plate over the subject's art.", make: t_logo_plate),
        Treatment(key: "exe-icon", title: "Program's own icon", uses: ["icon"],
                  about: "The program's own icon, pixels kept hard, on a glass tile of the primary.", make: t_exe_icon),
        Treatment(key: "risograph", title: "Risograph", uses: ["subject"],
                  about: "Two spot inks (primary and secondary) printed slightly out of register, with grain: each ink its own glass layer.", make: t_risograph),
        Treatment(key: "enamel-pin", title: "Enamel pin", uses: ["subject"],
                  about: "The figure as a pin: flat enamel fills in its own colours, a gold rim, the glass as its gloss.", make: t_enamel_pin),
        Treatment(key: "monogram", title: "Monogram", uses: ["fill"],
                  about: "The title's first letter, huge, filled with the art, on the primary.", make: t_monogram),
        Treatment(key: "crt", title: "CRT", uses: ["fill"],
                  about: "The art (best: a title screen) on a CRT in a bezel of the primary, with scanlines.", make: t_crt),
    ]

    public static let more: [Treatment] = [
        Treatment(key: "badge", title: "Badge", uses: ["subject"],
                  about: "The figure breaking out of a round plate of the secondary, on the primary.", make: t_badge),
        Treatment(key: "disc-and-box", title: "Disc and box", uses: ["disc", "subject"],
                  about: "The box front with the disc slipping out from behind it, each its own glass layer.", make: t_disc_box),
        Treatment(key: "scene", title: "Scene in depth", uses: ["fill", "subject", "logo"],
                  about: "The picture blurred at the back, the figure in the middle, the title in front: all three glass depths.", make: t_scene),
        Treatment(key: "title-lockup", title: "Title lockup", uses: ["logo", "subject"],
                  about: "The logo large across the icon with the figure tucked under it.", make: t_lockup),
    ]

    public static var info: [TreatmentInfo] { (all + more).map { TreatmentInfo(key: $0.key, title: $0.title, about: $0.about, uses: $0.uses) } }

    /// Which image each role starts with: the strongest outline, the best fill, a disc and a logo if there are any.
    /// How well each kind of picture tends to serve each role.
    static let subjectWeight: [String: Double] = ["cutout": 1.6, "box-front": 1.4, "banner": 1.1, "art": 1, "title-screen": 0.9,
                                                  "screenshot": 0.6, "logo": 0.5, "icon": 0.5, "box-back": 0.3, "disc": 0.3, "box-spine": 0.1,
                                                  "manual": 0.2, "unknown": 0.8, "media": 0.4]
    static let fillWeight: [String: Double] = ["title-screen": 1.3, "screenshot": 1.2, "box-front": 1.1, "art": 1, "banner": 1,
                                               "box-back": 0.5, "manual": 0.2, "unknown": 0.8]

    /// Which image each role starts with: the strongest outline, the best fill, a disc and a logo if there are any.
    public static func defaultRoles(_ media: [MediaRecord]) -> [String: String] {
        let picked = media.filter(\.picked)
        let pool = picked.isEmpty ? media : picked
        func score(_ m: MediaRecord, _ s: String, _ weights: [String: Double]) -> Double {
            let small = min(m.width, m.height) < 200 ? 0.5 : 1
            return (m.analysis.scores[s] ?? 0) * (weights[m.kind] ?? 0) * small * (0.6 + m.suitability / 12)
        }
        var roles: [String: String] = [:]
        let subject = pool.max { score($0, "silhouette", subjectWeight) < score($1, "silhouette", subjectWeight) }
        roles["subject"] = subject?.id
        let fills = pool.filter { $0.id != subject?.id && fillWeight[$0.kind] != nil }
        roles["fill"] = (fills.max { score($0, "fill", fillWeight) < score($1, "fill", fillWeight) } ?? subject)?.id
        let discs = pool.filter { $0.kind == "disc" }
        if let d = discs.max(by: { ($0.analysis.scores["disc"] ?? 0) * Double(min($0.width, 1200)) < ($1.analysis.scores["disc"] ?? 0) * Double(min($1.width, 1200)) }) {
            roles["disc"] = d.id
        }
        if let l = pool.filter({ $0.kind == "logo" }).max(by: { ($0.analysis.scores["logo"] ?? 0) < ($1.analysis.scores["logo"] ?? 0) }) { roles["logo"] = l.id }
        if let i = pool.filter({ $0.kind == "icon" }).max(by: { $0.width < $1.width }) { roles["icon"] = i.id }
        return roles
    }

    public static func suggestions(program: String, media: [MediaRecord], params: SuggestionParams, only: [String]?,
                                   assets: Assets, progress: (@Sendable (Double, String?) async -> Void)? = nil) async -> [Suggestion] {
        var roles = defaultRoles(media)
        for (k, v) in params.roles ?? [:] { roles[k] = v }
        guard roles["subject"] != nil else { return [] }
        var p = params
        if p.primary == nil || p.secondary == nil, let sid = roles["subject"], let img = try? await assets.image(program, sid) {
            let opts = Dictionary(Palette.options(img).map { ($0.name, $0.colour.hex) }, uniquingKeysWith: { a, _ in a })
            if p.primary == nil { p.primary = opts["striking"] }
            if p.secondary == nil { p.secondary = opts["lightest"] }
        }
        let byId = Dictionary(media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Suggestion] = []
        let chosen = (all + more).filter { only == nil || only?.contains($0.key) == true }
        for (n, t) in chosen.enumerated() {
            await progress?(Double(n) / Double(max(1, chosen.count)), t.title)
            let ctx = Ctx(program: program, media: byId, roles: roles, p: p, assets: assets, treatment: t.key)
            do {
                if let d = try await t.make(ctx) { out.append(Suggestion(treatment: t.key, title: t.title, about: t.about, uses: t.uses, doc: d)) }
            } catch {
                continue   // a treatment that can't be made from this program's media is left out
            }
        }
        return out
    }

    // MARK: The treatments

    static func t_lifted(_ c: Ctx) async throws -> Doc? {
        return c.doc("Lifted", fill: Ctx.gradient(c.primary), [g("Subject", [try await c.figure()])])
    }

    static func t_sticker(_ c: Ctx) async throws -> Doc? {
        let cut = try await c.cut("subject")
        let t = c.place(w: cut.w, h: cut.h, height: 0.8, anchorX: 0.5, bottom: 0.9)
        let effects = c.hasSecondary ? [Effect("outline", ["color": c.secondary.json, "width": .number(20.0 / canvasSide)])] : []
        let l = Layer(name: "Sticker", role: "subject", content: .image(ImageContent(asset: c.id("subject") ?? "", cutout: true, effects: effects)), transform: t)
        return c.doc("Sticker", fill: Ctx.gradient(c.primary), [g("Sticker", [l], shadow: 0.5)])
    }

    static func t_screenprint(_ c: Ctx) async throws -> Doc? {
        let fig = try await c.figure()
        let tones = [c.primary.shade(0.28), c.primary, c.secondary]
        var groups: [Group] = []
        for i in [2, 1, 0] {
            if i == 2 && !c.hasSecondary { continue }
            var l = fig
            l.id = UUID().uuidString.lowercased()
            l.name = ["Dark tone", "Mid tone", "Light tone"][i]
            if case .image(var ic) = l.content { ic.effects = [Effect("tone", ["level": .number(Double(i)), "color": tones[i].json])]; l.content = .image(ic) }
            groups.append(g(l.name, [l], shadow: i == 0 ? 0.35 : 0.15))
        }
        return c.doc("Screenprint", fill: Ctx.gradient(c.primary.shade(1.45)), groups)
    }

    static func t_double_exposure(_ c: Ctx) async throws -> Doc? {
        guard c.has("fill"), c.id("fill") != c.id("subject") else { return nil }
        let fig = try await c.figure()
        var art = try await c.full("fill", zoom: 1.25, second: true, effects: [Effect("blur", ["radius": .number(1.0 / canvasSide)]), Effect("autocontrast")])
        var mvals: [String: JSONValue] = ["asset": .string(c.id("subject") ?? ""), "cutout": true, "transform": JSONValue.from(fig.transform)]
        if case .image(let ic) = fig.content, let crop = ic.crop { mvals["crop"] = JSONValue.from(crop) }
        art.addMask(Mask("image", mvals))
        art.name = "Exposure"
        return c.doc("Double exposure", fill: Ctx.gradient(c.secondary), [g("Exposure", [art], shadow: 0.25)])
    }

    static func t_disc(_ c: Ctx) async throws -> Doc? {
        let d = 880.0
        var art: Layer
        if let discId = c.roles["disc"], let rec = c.media[discId] {
            var crop: [Double]?
            if let at = rec.analysis.circle, at.count == 3 {
                let m = Double(min(rec.width, rec.height))
                let r = at[2] * m, cx = at[0] * Double(rec.width), cy = at[1] * Double(rec.height)
                crop = [(cx - r) / Double(rec.width), (cy - r) / Double(rec.height), 2 * r / Double(rec.width), 2 * r / Double(rec.height)]
            }
            art = Layer(name: "Disc", role: "disc", content: .image(ImageContent(asset: discId, cutout: false, crop: crop)),
                        transform: Transform(x: 0.5, y: 0.5, width: d / canvasSide, rotation: c.angle - 45))
        } else {
            let cut = try await c.cut("subject")
            let side = Double(max(cut.box.w, cut.box.h)) * 1.15 / c.scale
            let cx = Double(cut.box.x) + Double(cut.box.w) / 2 - c.dx * side, cy = Double(cut.box.y) + Double(cut.box.h) / 2 - c.dy * side
            art = Layer(name: "Disc art", role: "disc",
                        content: .image(ImageContent(asset: c.id("subject") ?? "", cutout: false,
                                                     crop: [(cx - side / 2) / cut.imageW, (cy - side / 2) / cut.imageH, side / cut.imageW, side / cut.imageH])),
                        transform: .full)
        }
        art.addMask(Mask("ring", ["outer": .number(d / 2 / canvasSide), "inner": .number(70 / canvasSide)]))
        let rims = shapeLayer("Rims", Shape("disc-rims", ["color": "#ffffff"]), role: "decoration")
        return c.doc("Disc", fill: Ctx.gradient(c.primary), [g("Rims", [rims], shadow: 0, translucency: 0.4), g("Disc", [art], shadow: 0.45)])
    }

    static func t_diagonal_fade(_ c: Ctx) async throws -> Doc? {
        var (back, front) = try await c.fullAligned("subject", at: (0.6, 0.62), fill: 0.72)
        back.addMask(Mask("linear-fade", ["angle": .number(c.angle), "start": 0.25, "end": 0.7]))
        var groups = [g("Subject", [front], shadow: 0), g("Art", [back], specular: false, shadow: 0)]
        if let pat = c.p.pattern, pat != "solid" {
            groups.append(g("Pattern", [shapeLayer("Pattern", Shape("pattern", ["pattern": .string(pat), "a": c.primary.json, "b": c.secondary.json]))],
                            specular: false, shadow: 0))
        }
        return c.doc("Diagonal fade", fill: Ctx.solid(c.primary), groups)
    }

    static func t_duotone(_ c: Ctx) async throws -> Doc? {
        let back = try await c.full("fill", second: true, name: "Duotone art",
                                    effects: [Effect("blur", ["radius": .number(1.5 / canvasSide)]),
                                              Effect("gradient-map", ["dark": c.primary.shade(0.35).json, "light": c.secondary.json])])
        let fig = try await c.figure(height: 0.92)
        return c.doc("Duotone", fill: Ctx.gradient(c.primary), [g("Subject", [fig], shadow: 0.45), g("Art", [back], specular: false, shadow: 0)])
    }

    static func t_halftone(_ c: Ctx) async throws -> Doc? {
        let fig = try await c.figure(name: "Dots", effects: [Effect("halftone", ["ink": c.primary.json, "cell": .number((c.p.cell ?? 26) / canvasSide), "angle": 15])])
        return c.doc("Halftone", fill: Ctx.gradient(c.secondary), [g("Dots", [fig], shadow: 0.25)])
    }

    static func t_halftone_art(_ c: Ctx) async throws -> Doc? {
        let back = try await c.full("fill", second: true, effects: [Effect("blur", ["radius": .number(14 / canvasSide)]),
                                                                    Effect("tint", ["color": c.primary.json, "amount": 0.45])])
        let fig = try await c.figure(name: "Dots", effects: [Effect("halftone", ["ink": c.secondary.json, "cell": .number((c.p.cell ?? 26) / canvasSide), "angle": 15])])
        return c.doc("Halftone over art", fill: .none, [g("Dots", [fig], shadow: 0.3), g("Art", [back], specular: false, shadow: 0)])
    }

    static func t_line_art(_ c: Ctx) async throws -> Doc? {
        let fig = try await c.figure(name: "Lines", effects: [Effect("edges", ["color": c.secondary.json])])
        return c.doc("Line art", fill: Ctx.gradient(c.primary.shade(0.3)), [g("Lines", [fig], shadow: 0.2)])
    }

    static func t_bands(_ c: Ctx) async throws -> Doc? {
        let fig = try await c.figure(name: "Silhouette", effects: [Effect("silhouette", ["color": c.primary.shade(0.25).json])])
        let cols = (0..<5).map { JSONValue.string(c.secondary.mix(c.primary, Double($0) / 4).hex) }
        let bands = shapeLayer("Bands", Shape("bands", ["colors": .array(cols)]))
        return c.doc("Bands", fill: .none, [g("Silhouette", [fig], shadow: 0.4), g("Bands", [bands], specular: false, shadow: 0)])
    }

    static func t_window(_ c: Ctx) async throws -> Doc? {
        var art = try await c.full("fill", zoom: 1.1, name: "Pane")
        art.addMask(Mask("shape", ["shape": JSONValue.from(Shape("rounded-rect", ["rect": [0.117, 0.166, 0.766, 0.694], "radius": 0, "color": "#ffffff"])),
                                  "transform": JSONValue.from(Transform.full)]))
        let frame = shapeLayer("Window", Shape("window", ["frame": c.secondary.json, "bar": c.primary.json]), role: "frame")
        return c.doc("Old window", fill: Ctx.gradient(c.primary.shade(1.4)), [g("Window", [frame, art], shadow: 0.5)])
    }

    static func t_logo_plate(_ c: Ctx) async throws -> Doc? {
        guard let logoId = c.roles["logo"], let rec = c.media[logoId] else { return nil }
        let w = Double(rec.width), h = Double(rec.height)
        let sc = min(canvasSide * 0.86 / w, canvasSide * 0.5 / h) * c.scale * (c.p.logoScale ?? 1)
        let logo = Layer(name: "Logo", role: "logo", content: .image(ImageContent(asset: logoId, cutout: false, effects: [Effect("key", ["tolerance": 30])])),
                         transform: Transform(x: 0.5 + c.dx, y: 0.5 + c.dy, width: w * sc / canvasSide))
        let back = try await c.full("subject", second: true, effects: [Effect("blur", ["radius": .number(10 / canvasSide)]),
                                                                       Effect("gradient-map", ["dark": c.primary.shade(0.4).json, "light": c.primary.json])])
        return c.doc("Logo plate", fill: .none, [g("Logo", [logo], shadow: 0.5), g("Art", [back], specular: false, shadow: 0)])
    }

    static func t_exe_icon(_ c: Ctx) async throws -> Doc? {
        guard let iconId = c.roles["icon"], let rec = c.media[iconId] else { return nil }
        let sc = (canvasSide * 0.62 / Double(max(rec.width, rec.height))).rounded(.down)
        let l = Layer(name: "Program icon", role: "icon", content: .image(ImageContent(asset: iconId, cutout: false, smoothing: "pixel")),
                      transform: Transform(x: 0.5, y: 0.5, width: Double(rec.width) * max(1, sc) / canvasSide))
        return c.doc("Program's own icon", fill: Ctx.gradient(c.primary), [g("Icon", [l], shadow: 0.45)])
    }

    static func t_risograph(_ c: Ctx) async throws -> Doc? {
        let shift = (c.p.offset ?? 14) / canvasSide
        let ink1 = try await c.figure(name: "Ink 1", effects: [Effect("riso", ["ink": c.primary.json, "band": "dark", "offset": [0, 0]])])
        var ink2 = ink1
        ink2.id = UUID().uuidString.lowercased(); ink2.name = "Ink 2"
        if case .image(var ic) = ink2.content {
            ic.effects = [Effect("riso", ["ink": c.secondary.json, "band": "mid", "offset": .array([.number(-shift + c.dx2), .number(shift + c.dy2)])])]
            ink2.content = .image(ic)
        }
        let paper = RGB(245, 240, 228)
        var groups = [g("Ink 1", [ink1], shadow: 0.15)]
        if c.hasSecondary { groups.append(g("Ink 2", [ink2], shadow: 0.1)) }
        return c.doc("Risograph", fill: Ctx.gradient(paper, dark: paper.shade(0.2)), groups)
    }

    static func t_enamel_pin(_ c: Ctx) async throws -> Doc? {
        let cut = try await c.cut("subject")
        let t = c.place(w: cut.w, h: cut.h, height: 0.78, anchorX: 0.5, bottom: 0.89)
        let l = Layer(name: "Enamel", role: "subject",
                      content: .image(ImageContent(asset: c.id("subject") ?? "", cutout: true,
                                                   effects: [Effect("posterize", ["colors": 5]), Effect("outline", ["color": "#d6ac4c", "width": .number(15 / canvasSide)])])),
                      transform: t)
        return c.doc("Enamel pin", fill: Ctx.gradient(c.primary), [g("Enamel", [l], shadow: 0.5)])
    }

    static func t_monogram(_ c: Ctx) async throws -> Doc? {
        let given = c.p.letter ?? ""
        let letter = String((given.isEmpty ? c.program : given).prefix(2)).uppercased()
        var art = try await c.full("fill", second: true, name: "Letter")
        art.addMask(Mask("shape", ["shape": JSONValue.from(Shape("text", ["text": .string(String(letter.prefix(1))), "font": "Arial Black",
                                                                          "size": .number(0.86 * c.scale), "color": "#ffffff"])),
                                  "transform": JSONValue.from(Transform(x: 0.5 + c.dx, y: 0.5 + c.dy, width: 1))]))
        return c.doc("Monogram", fill: Ctx.gradient(c.primary), [g("Letter", [art], shadow: 0.45)])
    }

    static func t_crt(_ c: Ctx) async throws -> Doc? {
        var screen = try await c.full("fill", name: "Screen", effects: [Effect("scanlines")])
        let rect: JSONValue = .array([.number(150 / canvasSide), .number(190 / canvasSide), .number(724 / canvasSide), .number(570 / canvasSide)])
        screen.addMask(Mask("shape", ["shape": JSONValue.from(Shape("rounded-rect", ["rect": rect, "radius": .number(70 / canvasSide), "color": "#ffffff"])),
                                     "transform": JSONValue.from(Transform.full)]))
        let bezel = shapeLayer("Bezel", Shape("crt", ["bezel": c.primary.json]), role: "frame")
        return c.doc("CRT", fill: Ctx.gradient(c.secondary), [g("Bezel", [bezel], shadow: 0.45), g("Screen", [screen], specular: false, shadow: 0)])
    }

    static func t_badge(_ c: Ctx) async throws -> Doc? {
        let cut = try await c.cut("subject")
        // the figure's bottom sits inside the plate, its top breaks out
        var t = c.place(w: cut.w, h: cut.h, height: 0.78, anchorX: 0.5, bottom: 0.84)
        t.width = min(t.width, 0.9)
        let fig = Layer(name: "Subject", role: "subject", content: .image(ImageContent(asset: c.id("subject") ?? "", cutout: true)), transform: t)
        let plate = shapeLayer("Plate", Shape("circle", ["radius": 0.36, "color": c.secondary.json]), role: "frame")
        var plateL = plate
        plateL.transform = Transform(x: 0.5, y: 0.56, width: 1)
        return c.doc("Badge", fill: Ctx.gradient(c.primary), [g("Subject", [fig], shadow: 0.5), g("Plate", [plateL], shadow: 0.25)])
    }

    static func t_disc_box(_ c: Ctx) async throws -> Doc? {
        guard let discId = c.roles["disc"], let rec = c.media[discId] else { return nil }
        guard let boxId = c.media.values.filter({ $0.kind == "box-front" && $0.picked }).max(by: { $0.suitability < $1.suitability })?.id
            ?? c.id("subject"), let box = c.media[boxId] else { return nil }
        var crop: [Double]?
        if let at = rec.analysis.circle, at.count == 3 {
            let m = Double(min(rec.width, rec.height)), r = at[2] * m
            let cx = at[0] * Double(rec.width), cy = at[1] * Double(rec.height)
            crop = [(cx - r) / Double(rec.width), (cy - r) / Double(rec.height), 2 * r / Double(rec.width), 2 * r / Double(rec.height)]
        }
        var disc = Layer(name: "Disc", role: "disc", content: .image(ImageContent(asset: discId, cutout: false, crop: crop)),
                         transform: Transform(x: 0.62 + c.dx2, y: 0.47 + c.dy2, width: 0.66 * c.scale, rotation: c.angle - 45))
        disc.addMask(Mask("shape", ["shape": JSONValue.from(Shape("circle", ["radius": 0.5, "color": "#ffffff"])),
                                   "transform": JSONValue.from(disc.transform)]))
        let aspect = Double(box.height) / Double(max(1, box.width))
        let bw = min(0.62, 0.8 / aspect) * c.scale
        let boxL = Layer(name: "Box", role: "subject", content: .image(ImageContent(asset: boxId, cutout: false)),
                         transform: Transform(x: 0.38 + c.dx, y: 0.52 + c.dy, width: bw, rotation: -4))
        return c.doc("Disc and box", fill: Ctx.gradient(c.primary), [g("Box", [boxL], shadow: 0.5), g("Disc", [disc], shadow: 0.4)])
    }

    static func t_scene(_ c: Ctx) async throws -> Doc? {
        let back = try await c.full("fill", second: true, name: "Scene", effects: [Effect("blur", ["radius": .number(6 / canvasSide)])])
        let fig = try await c.figure(height: 0.8)
        var groups = [g("Subject", [fig], shadow: 0.45), g("Scene", [back], specular: false, shadow: 0)]
        if let logoId = c.roles["logo"], let rec = c.media[logoId] {
            let w = min(0.84, 0.3 * Double(rec.width) / Double(max(1, rec.height))) * (c.p.logoScale ?? 1)
            let logo = Layer(name: "Title", role: "logo", content: .image(ImageContent(asset: logoId, cutout: false, effects: [Effect("key", ["tolerance": 30])])),
                             transform: Transform(x: 0.5, y: 0.2, width: w))
            groups.insert(g("Title", [logo], shadow: 0.5), at: 0)
        }
        return c.doc("Scene in depth", fill: .none, groups)
    }

    static func t_lockup(_ c: Ctx) async throws -> Doc? {
        guard let logoId = c.roles["logo"], let rec = c.media[logoId] else { return nil }
        let w = min(0.9, 0.42 * Double(rec.width) / Double(max(1, rec.height))) * (c.p.logoScale ?? 1)
        let logo = Layer(name: "Logo", role: "logo", content: .image(ImageContent(asset: logoId, cutout: false, effects: [Effect("key", ["tolerance": 30])])),
                         transform: Transform(x: 0.5 + c.dx2, y: 0.34 + c.dy2, width: w))
        let fig = try await c.figure(height: 0.55, anchorX: 0.5, bottom: 1.02)
        return c.doc("Title lockup", fill: Ctx.gradient(c.primary), [g("Logo", [logo], shadow: 0.5), g("Subject", [fig], shadow: 0.4)])
    }

}

nonisolated extension Layer {
    /// A mask as the layer's last effect, locked to the canvas (where the treatments' masks belong: a disc's ring,
    /// a window's pane, a monogram's letter stay put while the picture moves behind them).
    mutating func addMask(_ m: Mask, lock: String = "canvas") {
        guard case .image(var ic) = content else { mask = m; return }
        ic.effects.append(Effect("mask", ["mask": JSONValue.from(m), "lock": .string(lock)]))
        content = .image(ic)
    }
}

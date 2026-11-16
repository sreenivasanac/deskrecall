import AppKit

/// Pure assignment arithmetic, kept apart so `--selfcheck` can exercise it.
enum Matching {
    /// One-to-one pairing of open windows and saved slots from Jev's probabilities, best pairs
    /// first. Fills as many slots as there are windows; extra windows stay where they are.
    static func assign(_ scored: [(live: Int, slot: Int, p: Double)]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var taken = Set<Int>()
        for s in scored.sorted(by: { $0.p > $1.p }) where result[s.live] == nil && !taken.contains(s.slot) {
            result[s.live] = s.slot
            taken.insert(s.slot)
        }
        return result
    }
}

/// The Arrange button: pick the profile for the connected displays, decide which open window
/// goes in which saved slot, then move everything. Identity cases (same monitors, same title,
/// one window for one slot) are decided locally; every judgement call is a question to Jev.
@MainActor
enum Arranger {
    struct Outcome {
        var summary: String
        var arranged = false
        var exact = false          // the profile was saved on exactly this set of displays
        var profile: Profile?
    }

    static func arrange(interactive: Bool, forced: Profile? = nil) async -> Outcome {
        guard Windows.trusted else { return Outcome(summary: "Needs Accessibility permission") }
        let displays = Displays.current()
        let profiles = Store.load()
        guard !profiles.isEmpty else { return Outcome(summary: "No profiles saved yet") }
        let live = Windows.capture()
        var notes: [String] = []

        // 1. Which profile? One saved on exactly these monitors wins outright.
        let key = Displays.setKey(displays)
        let same = profiles.filter { $0.setKey == key }
        var chosen = forced ?? (same.count == 1 ? same[0] : nil)
        if chosen == nil {
            let (pick, note) = await chooseProfile(among: same.isEmpty ? profiles : same, displays: displays, live: live, interactive: interactive)
            chosen = pick
            if let note { notes.append(note) }
        }
        guard let profile = chosen else { return Outcome(summary: "No saved profile fits this display setup") }
        let exact = profile.setKey == key

        // 2. Saved display -> connected display.
        var questions: [String: [String: Any]] = [:]
        var displayMap: [Int: DisplayInfo] = [:]
        if exact {
            var free = displays     // both lists are sorted left to right, so identical twins keep their order
            for (i, d) in profile.displays.enumerated() {
                if let j = free.firstIndex(where: { $0.hardwareKey == d.hardwareKey }) { displayMap[i] = free.remove(at: j) }
            }
        } else if displays.count == 1 {
            for i in profile.displays.indices { displayMap[i] = displays[0] }
        } else {
            let options = Dictionary(uniqueKeysWithValues: displays.enumerated().map { ("c\($0)", $1.summary) })
            for (i, d) in profile.displays.enumerated() {
                questions["d\(i)"] = Jev.choice("The saved layout used this display: \(d.summary). Which currently connected display should take its place? Prefer the same kind (built-in for built-in), then the most similar monitor, size and position.", options)
            }
        }

        // 3. Open window -> saved slot, app by app.
        var pairs: [(live: Int, slot: Int)] = []
        var groups: [(lives: [Int], slots: [Int])] = []       // what is left for Jev
        let liveByApp = Dictionary(grouping: live.indices, by: { live[$0].bundleID })
        for (app, appSlots) in Dictionary(grouping: profile.windows.indices, by: { profile.windows[$0].bundleID }) {
            guard var lives = liveByApp[app] else { continue }  // app isn't open: nothing to place, and that's fine
            var slots: [Int] = []
            for s in appSlots {                                 // same title = same window
                if let k = lives.firstIndex(where: { live[$0].title == profile.windows[s].title }) { pairs.append((lives.remove(at: k), s)) }
                else { slots.append(s) }
            }
            if lives.isEmpty || slots.isEmpty { continue }
            if lives.count == 1 && slots.count == 1 { pairs.append((lives[0], slots[0])); continue }
            groups.append((lives, slots))
            if slots.count == 1 {   // several windows compete for one slot
                let s = slots[0]
                questions["s\(s)"] = Jev.choice("The saved layout has this \(profile.windows[s].appName) window: \(describe(profile.windows[s], profile)). Which open window is the same window, or serves the same purpose?",
                                               Dictionary(uniqueKeysWithValues: lives.map { ("l\($0)", "Open window titled \"\(live[$0].title)\"") }))
            } else {
                let options = Dictionary(uniqueKeysWithValues: slots.map { ("s\($0)", describe(profile.windows[$0], profile)) })
                for l in lives {
                    questions["w\(l)"] = Jev.choice("An open \(live[l].appName) window is titled \"\(live[l].title)\". Which saved window is it, judging by title, document, project, site or purpose?", options)
                }
            }
        }

        var answers: [String: Jev.Answer] = [:]
        if !questions.isEmpty {
            let ambiguous = groups.flatMap(\.lives)
            let state: [String: Any] = [
                "current_displays": displays.map(\.summary),
                "saved_profile": profile.name,
                "saved_displays": profile.displays.map(\.summary),
                "saved_windows": groups.flatMap(\.slots).map { describe(profile.windows[$0], profile) },
                "open_windows": ambiguous.map { "\(live[$0].appName): \"\(live[$0].title)\"" },
            ]
            do { answers = try await Jev.ask(state: state, questions: questions) }
            catch Jev.Failure.noKey { notes.append("no Jev key, so same-app windows were matched in order") }
            catch { notes.append("Jev unreachable, so same-app windows were matched in order") }
        }

        for i in profile.displays.indices where displayMap[i] == nil {
            if let c = answers["d\(i)"]?.choice, let j = Int(c.dropFirst()), displays.indices.contains(j) {
                displayMap[i] = displays[j]
            } else {
                // ponytail: no Jev answer -> built-in to built-in, the rest by position. Fine for 1-2 displays.
                displayMap[i] = displays.first { $0.builtin == profile.displays[i].builtin } ?? displays[min(i, displays.count - 1)]
            }
        }

        var unsure: [(live: Int, slot: Int, slots: [Int])] = []
        for group in groups {
            var scored: [(live: Int, slot: Int, p: Double)] = []
            var confidence: [Int: Double] = [:]
            if group.slots.count == 1, let a = answers["s\(group.slots[0])"] {
                for l in group.lives { scored.append((l, group.slots[0], a.probabilities["l\(l)"] ?? 0)); confidence[l] = a.confidence }
            } else {
                for l in group.lives {
                    guard let a = answers["w\(l)"] else { continue }
                    confidence[l] = a.confidence
                    for s in group.slots { scored.append((l, s, a.probabilities["s\(s)"] ?? 0)) }
                }
            }
            if scored.isEmpty {
                // ponytail: without Jev, pair same-app windows in window order (what Rectangle Pro does).
                pairs.append(contentsOf: zip(group.lives, group.slots).map { ($0, $1) })
                continue
            }
            for (l, s) in Matching.assign(scored) {
                if (confidence[l] ?? 0) < Config.jevMinConfidence { unsure.append((l, s, group.slots)) } else { pairs.append((l, s)) }
            }
        }

        // 4. Conflicts: Jev's low-confidence guesses go to the user, in one dialog.
        if !unsure.isEmpty {
            if interactive && UserDefaults.standard.bool(forKey: Keys.askWhenUnsure) {
                let rows = unsure.map { u in
                    (label: "\(live[u.live].appName): \(live[u.live].title.prefix(48))",
                     options: u.slots.map { describe(profile.windows[$0], profile) } + ["Leave where it is"],
                     selected: u.slots.firstIndex(of: u.slot) ?? 0)
                }
                if let picks = UI.resolve("Where should these windows go?", "\(Config.appName) wasn't sure about these. Its best guess is preselected.", rows: rows) {
                    for (u, pick) in zip(unsure, picks) where pick < u.slots.count { pairs.append((u.live, u.slots[pick])) }
                } else {
                    notes.append("\(unsure.count) uncertain window(s) left alone")
                }
            } else {
                pairs.append(contentsOf: unsure.map { ($0.live, $0.slot) })
            }
        }

        // 5. Move. Frames first (a frame on another display carries the window there), then Spaces.
        let spaces = Spaces.userSpaces()
        var moves: [UInt64: [CGWindowID]] = [:]
        var changed = 0, missingDesktops = false
        for (l, s) in pairs {
            let slot = profile.windows[s], window = live[l]
            guard let display = displayMap[slot.display] else { continue }
            let target = slot.frame(on: display)
            var touched = false
            if !near(window.frame, target) { Windows.setFrame(window.element, target); touched = true }
            if slot.space > 0, let desktops = spaces[display.uuid], !desktops.isEmpty {
                if slot.space > desktops.count { missingDesktops = true }
                let space = desktops[min(slot.space, desktops.count) - 1]
                if window.spaces != [space] { moves[space, default: []].append(window.id); touched = true }
            }
            if touched { changed += 1 }
        }
        if !moves.isEmpty {
            try? await Task.sleep(nanoseconds: 200_000_000)
            for (space, ids) in moves { Spaces.move(ids, to: space) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            let stuck = moves.flatMap { space, ids in ids.filter { Spaces.of($0) != [space] } }.count
            if stuck > 0 { notes.append("\(stuck) window(s) could not change desktop") }
        }
        if missingDesktops { notes.append("the profile uses more desktops than exist now; add some in Mission Control") }

        var summary = changed == 0 ? "Everything already in place" : "Arranged \(changed) window\(changed == 1 ? "" : "s")"
        summary += " · “\(profile.name)”" + (exact ? "" : " (adapted)")
        if !notes.isEmpty { summary += " · " + notes.joined(separator: "; ") }
        return Outcome(summary: summary, arranged: true, exact: exact, profile: profile)
    }

    /// No profile was saved on exactly these monitors (or several were): ask Jev for the closest.
    private static func chooseProfile(among candidates: [Profile], displays: [DisplayInfo], live: [LiveWindow], interactive: Bool) async -> (Profile?, String?) {
        var questions = ["close": Jev.noul("Is at least one of saved_profiles made for a display setup similar enough to current_displays (the same monitors, or the same number and kind of displays) that its window layout could reasonably be reused here?")]
        if candidates.count > 1 {
            questions["profile"] = Jev.choice("Which saved profile was made for the display setup most similar to current_displays? Weigh, in order: the same physical monitors (vendor, model, serial, name), the same number of displays, resolution, arrangement, and which apps are open now.",
                Dictionary(uniqueKeysWithValues: candidates.enumerated().map { ("p\($0)", "\($1.name): " + $1.displays.map(\.summary).joined(separator: " + ")) }))
        }
        let state: [String: Any] = [
            "current_displays": displays.map(\.summary),
            "open_apps": Set(live.map(\.appName)).sorted(),
            "saved_profiles": Dictionary(uniqueKeysWithValues: candidates.enumerated().map {
                ("p\($0)", ["name": $1.name, "displays": $1.displays.map(\.summary), "apps": Set($1.windows.map(\.appName)).sorted()] as [String: Any])
            }),
        ]
        var guess = candidates.count == 1 ? 0 : nil as Int?
        var sure = false
        var note: String?
        do {
            let answers = try await Jev.ask(state: state, questions: questions)
            let close = (answers["close"]?.yes ?? 0) >= 0.5
            if candidates.count == 1 {
                sure = close
            } else if let a = answers["profile"], let i = a.choice.flatMap({ Int($0.dropFirst()) }), candidates.indices.contains(i) {
                guess = i
                sure = close && a.confidence >= Config.jevMinConfidence
            }
        } catch Jev.Failure.noKey { note = "no Jev key" } catch { note = "Jev unreachable" }

        if sure, let guess { return (candidates[guess], note) }
        guard interactive else { return (nil, note) }           // never guess a layout unattended
        if candidates.count == 1 { return (candidates[0], note) }   // only one to try; the user is offered a new profile afterwards
        let pick = UI.pick("Which profile should be used?", "No saved profile clearly matches the displays connected now.",
                           options: candidates.map(\.name), selected: guess ?? 0)
        return (pick.map { candidates[$0] }, note)
    }

    private static func describe(_ w: SavedWindow, _ profile: Profile) -> String {
        let display = profile.displays.indices.contains(w.display) ? profile.displays[w.display].name : "display"
        return "\"\(w.title)\" on \(display)" + (w.space > 0 ? ", desktop \(w.space)" : "") + ", \(Int(w.fw * 100))% wide"
    }

    private static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        let t = Config.frameTolerance
        return abs(a.minX - b.minX) <= t && abs(a.minY - b.minY) <= t && abs(a.width - b.width) <= t && abs(a.height - b.height) <= t
    }
}

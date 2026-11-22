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

    /// How alike two monitors are, for reusing a layout on a setup it was not saved on: the same
    /// unit, then another unit of the model, then the same kind (built-in or external) and resolution.
    /// Twins with a placeholder serial are told apart as in `Profile.closeness`: by manufacture
    /// date and by the identifier macOS gives each.
    static func alike(_ a: DisplayInfo, _ b: DisplayInfo) -> Double {
        var score = 0.0
        let otherUnit = a.made != nil && b.made != nil && a.made != b.made
        if a.hardwareKey == b.hardwareKey && !otherUnit { score += 8 } else if a.vendor == b.vendor && a.model == b.model && a.builtin == b.builtin { score += 4 }
        if a.uuid == b.uuid { score += 2 }
        if a.builtin == b.builtin { score += 2 }
        if a.width == b.width && a.height == b.height { score += 1 }
        return score
    }

    /// Which connected display (index) stands in for each saved one, and how well the whole setup
    /// fits. One for one while they last; with fewer displays now, the rest share the most alike.
    /// Both lists run left to right, which settles ties.
    static func standIns(for saved: [DisplayInfo], among current: [DisplayInfo]) -> (map: [Int: Int], score: Double) {
        guard !current.isEmpty else { return ([:], 0) }
        func p(_ i: Int, _ j: Int) -> Double { alike(saved[i], current[j]) - 0.01 * Double(abs(i - j)) }
        var map = assign(saved.indices.flatMap { i in current.indices.map { (live: i, slot: $0, p: p(i, $0)) } })
        let score = map.reduce(0) { $0 + alike(saved[$1.key], current[$1.value]) } - 3 * Double(abs(saved.count - current.count))
        for i in saved.indices where map[i] == nil { map[i] = current.indices.max { p(i, $0) < p(i, $1) } }
        return (map, score)
    }

    /// The words of a window title, for comparing titles that have changed since the save.
    static func words(_ title: String) -> Set<String> {
        Set(title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// 0 to 1: how many of two titles' words are shared.
    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        let all = a.union(b).count
        return all == 0 ? 0 : Double(a.intersection(b).count) / Double(all)
    }

    /// `assign`, split into the pairs that stand clear of every rival (another slot for the same
    /// window, another window for the same slot) and the ones that are only the best guess.
    static func settle(_ scored: [(live: Int, slot: Int, p: Double)], floor: Double, margin: Double) -> (sure: [Int: Int], unsure: [Int: Int]) {
        var sure: [Int: Int] = [:], unsure: [Int: Int] = [:]
        for (l, s) in assign(scored) {
            let p = scored.first { $0.live == l && $0.slot == s }?.p ?? 0
            let rival = scored.filter { ($0.live == l) != ($0.slot == s) }.map(\.p).max() ?? 0
            if p >= floor && p - rival >= margin { sure[l] = s } else { unsure[l] = s }
        }
        return (sure, unsure)
    }

    /// The group a window is matched within: its app, and for Chromium browsers its profile, which
    /// they put at the end of the title ("Inbox - Google Chrome - Work"). A window never changes profile.
    /// ponytail: other browsers name the profile elsewhere or not at all; those are left to Jev.
    static func family(_ bundleID: String, _ appName: String, _ title: String) -> String {
        let profile = title.range(of: " - \(appName) - ", options: .backwards).map { String(title[$0.upperBound...]) }
        return bundleID + "\u{1}" + (profile ?? "")
    }
}

/// The Arrange button, in three stages: pick the profile for the connected displays, decide which
/// open window fills which saved slot, then move everything. All of it is decided on the Mac. Jev,
/// when a key is saved, is asked only about reopened windows the rules cannot tell apart.
@MainActor
enum Arranger {
    struct Outcome {
        var summary: String
        var arranged = false
        var exact = false          // the profile was saved on exactly this set of displays
        var cancelled = false      // the user dismissed a question: no follow-up dialogs
    }

    /// An open window (index into the captured list) and the saved slot (index into profile.windows) it fills.
    typealias Pair = (live: Int, slot: Int)

    static func arrange(interactive: Bool, forced: Profile? = nil) async -> Outcome {
        guard Windows.trusted else { return Outcome(summary: "Needs Accessibility permission") }
        let displays = Displays.current()
        // Lid closed or every display asleep, as can happen mid-change: nothing to arrange onto.
        guard !displays.isEmpty else { return Outcome(summary: "No displays connected") }
        let profiles = Store.load()
        guard !profiles.isEmpty else { return Outcome(summary: "No profiles saved yet") }
        let live = Windows.capture()
        var notes: [String] = []

        // 1. Which profile? One saved on exactly these monitors wins. With several, the one whose
        //    monitors are most surely these very units; if that is still a tie, the one last used here.
        let same = Store.candidates(profiles, for: displays)
        var chosen = forced ?? Store.current(profiles, for: displays)
        if chosen == nil {
            let pick = chooseProfile(among: same.isEmpty ? profiles : same, displays: displays, interactive: interactive)
            if pick.cancelled { return Outcome(summary: "Arrange cancelled", cancelled: true) }
            chosen = pick.profile
        }
        guard let profile = chosen else { return Outcome(summary: "No saved profile fits this display setup") }
        let exact = profile.fits(displays)
        if exact { Store.prefer(profile, on: displays) }

        // 2. Which display stands in for which, and which window is which.
        let plan = await match(profile, displays: displays, live: live, exact: exact, interactive: interactive)
        // 3. Move.
        let result = await apply(plan.pairs, profile: profile, displayMap: plan.displayMap, live: live)
        notes += plan.notes + result.notes

        var summary = result.changed == 0 ? "Everything already in place" : "Arranged \(result.changed) window\(result.changed == 1 ? "" : "s")"
        summary += " · “\(profile.name)”" + (exact ? "" : " (adapted)")
        if !notes.isEmpty { summary += " · " + notes.joined(separator: "; ") }
        return Outcome(summary: summary, arranged: true, exact: exact)
    }

    // MARK: 1. Profile

    /// No profile was saved on exactly these monitors (or several were, none used yet): the one whose
    /// displays are most like these. It is used without asking only when it stands alone and the
    /// setup has the same shape, the same number of built-in and external displays.
    private static func chooseProfile(among candidates: [Profile], displays: [DisplayInfo], interactive: Bool) -> (profile: Profile?, cancelled: Bool) {
        let scores = candidates.map { Matching.standIns(for: $0.displays, among: displays).score }
        guard let top = scores.max(), let best = scores.firstIndex(of: top) else { return (nil, false) }
        let saved = candidates[best].displays
        let sameShape = saved.count == displays.count && saved.filter(\.builtin).count == displays.filter(\.builtin).count
        if sameShape && scores.filter({ $0 == top }).count == 1 { return (candidates[best], false) }
        guard interactive else { return (nil, false) }                    // never guess a layout unattended
        if candidates.count == 1 { return (candidates[0], false) }        // only one to try; the user is offered a new profile afterwards
        let pick = UI.pick("Which profile should be used?", "No saved profile clearly matches the displays connected now.",
                           options: candidates.map(\.name), selected: best)
        return (pick.map { candidates[$0] }, pick == nil)
    }

    // MARK: 2. Displays and windows

    /// Decides which connected display stands in for each saved one and which open window fills
    /// which saved slot. Reopened windows the rules leave unsure go to Jev in one request, if a key is saved.
    private static func match(_ profile: Profile, displays: [DisplayInfo], live: [LiveWindow], exact: Bool, interactive: Bool) async
        -> (displayMap: [Int: DisplayInfo], pairs: [Pair], notes: [String]) {
        var notes: [String] = []
        var questions: [String: [String: Any]] = [:]

        // Saved display -> connected display.
        var displayMap: [Int: DisplayInfo] = [:]
        if exact {
            displayMap = Displays.pair(profile.displays, with: displays)
        } else {
            for (i, j) in Matching.standIns(for: profile.displays, among: displays).map { displayMap[i] = displays[j] }
        }

        // Open window -> saved slot: what identifies a window for certain first. A group that leaves
        // open is scored by title and place; only where that is still unsure is Jev asked.
        let local = pairLocally(profile, live)
        var pairs = local.pairs
        let desktops = Spaces.userSpaces()
        // What stays open in each group once its sure pairs are taken out, with the best guess for it.
        var undecided: [(lives: [Int], slots: [Int], guess: [Int: Int])] = []
        for group in local.groups {
            let settled = Matching.settle(score(group, profile, live, displayMap, desktops), floor: Config.matchFloor, margin: Config.matchMargin)
            pairs.append(contentsOf: settled.sure.map { ($0.key, $0.value) })
            if settled.unsure.isEmpty { continue }
            undecided.append((group.lives.filter { settled.sure[$0] == nil }, group.slots.filter { !settled.sure.values.contains($0) }, settled.unsure))
        }
        let groups = undecided.map { (lives: $0.lives, slots: $0.slots) }    // only these are worth a question, and only these are sent
        func open(_ l: Int) -> String { "\"\(live[l].title)\"" + (live[l].minimized ? " (minimized)" : "") }
        for (lives, slots) in groups {
            if slots.count == 1 {   // several windows compete for one slot
                let s = slots[0]
                questions["s\(s)"] = Jev.choice("The saved layout has this \(profile.windows[s].appName) window: \(describe(profile.windows[s], profile)). Which open window is the same window, or serves the same purpose?",
                                               Dictionary(uniqueKeysWithValues: lives.map { ("l\($0)", "Open window titled \(open($0))") }))
            } else {
                let options = Dictionary(uniqueKeysWithValues: slots.map { ("s\($0)", describe(profile.windows[$0], profile)) })
                for l in lives {
                    questions["w\(l)"] = Jev.choice("An open \(live[l].appName) window is titled \(open(l)). Which saved window is it, judging by title, document, project, site, account or purpose?", options)
                }
            }
        }

        var answers: [String: Jev.Answer] = [:]
        if !questions.isEmpty {
            let state: [String: Any] = [
                "saved_profile": profile.name,
                "saved_windows": groups.flatMap(\.slots).map { describe(profile.windows[$0], profile) },
                "open_windows": groups.flatMap(\.lives).map { "\(live[$0].appName): \(open($0))" },
            ]
            do { answers = try await Jev.ask(state: state, questions: questions) }
            catch Jev.Failure.noKey {}      // the usual case: Jev is optional
            catch { notes.append("Jev unreachable") }
        }

        var unsure: [(live: Int, slot: Int, slots: [Int])] = []
        for group in undecided {
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
            if scored.isEmpty {     // no answer from Jev: the Mac's own best guess
                unsure.append(contentsOf: group.guess.sorted { $0.key < $1.key }.map { ($0.key, $0.value, group.slots) })
                continue
            }
            for (l, s) in Matching.assign(scored) {
                if (confidence[l] ?? 0) < Config.jevMinConfidence { unsure.append((l, s, group.slots)) } else { pairs.append((l, s)) }
            }
        }

        // Conflicts: the best guesses nobody was sure of go to the user, in one dialog.
        if !unsure.isEmpty {
            switch Unsure.current {
            case .guess:
                pairs.append(contentsOf: unsure.map { ($0.live, $0.slot) })
                notes.append("\(unsure.count) window(s) placed by best guess")
            case .ask where interactive:
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
            default:    // told to leave them, or nobody is there to ask (auto-arrange)
                notes.append("\(unsure.count) uncertain window(s) left alone")
            }
        }
        return (displayMap, pairs, notes)
    }

    /// How well each open window of a group fits each of its saved slots, when nothing identifies
    /// them for certain (an app quit and reopened, titles since changed). Two signs: the words the
    /// titles share, leaving out the ones every title in the group has ("Google Chrome"), and whether
    /// the window already sits where the slot was saved, as it does when macOS reopens an app's windows.
    /// ponytail: shared words, not meaning; "Pull request #42" and "GitHub" score 0. That is Jev's part.
    private static func score(_ group: (lives: [Int], slots: [Int]), _ profile: Profile, _ live: [LiveWindow],
                              _ displayMap: [Int: DisplayInfo], _ desktops: [String: [UInt64]]) -> [(live: Int, slot: Int, p: Double)] {
        let liveWords = group.lives.map { Matching.words(live[$0].title) }, slotWords = group.slots.map { Matching.words(profile.windows[$0].title) }
        let everywhere = (liveWords + slotWords).dropFirst().reduce(liveWords.first ?? []) { $0.intersection($1) }
        var scored: [(live: Int, slot: Int, p: Double)] = []
        for (a, l) in group.lives.enumerated() {
            for (b, s) in group.slots.enumerated() {
                let slot = profile.windows[s]
                let placed = displayMap[slot.display].map { inPlace(slot, live[l], on: $0, desktops: desktops) } ?? false
                // The last term only orders ties: first open window to first saved one.
                scored.append((l, s, Config.titleWeight * Matching.overlap(liveWords[a].subtracting(everywhere), slotWords[b].subtracting(everywhere))
                                     + (placed ? Config.placeWeight : 0) - 0.001 * Double(abs(a - b))))
            }
        }
        return scored
    }

    /// The pairs the rules settle on their own, app by app, and the groups (several windows of one
    /// app that the rules can't tell apart) they leave for scoring and, last, for Jev.
    static func pairLocally(_ profile: Profile, _ live: [LiveWindow]) -> (pairs: [Pair], groups: [(lives: [Int], slots: [Int])]) {
        var pairs: [Pair] = []
        var groups: [(lives: [Int], slots: [Int])] = []
        // Windows only ever compete within their own app, and within their own browser profile.
        let liveByApp = Dictionary(grouping: live.indices, by: { Matching.family(live[$0].bundleID, live[$0].appName, live[$0].title) })
        let slotsByApp = Dictionary(grouping: profile.windows.indices, by: { Matching.family(profile.windows[$0].bundleID, profile.windows[$0].appName, profile.windows[$0].title) })
        for (app, appSlots) in slotsByApp {
            guard var lives = liveByApp[app] else { continue }  // app isn't open: nothing to place, and that's fine
            var slots = appSlots
            // Surest evidence first, each rule over every slot before the next rule gets a turn.
            for same in sameWindow {
                slots.removeAll { s in
                    guard let k = lives.firstIndex(where: { same(profile.windows[s], live[$0]) }) else { return false }
                    pairs.append((lives.remove(at: k), s))
                    return true
                }
            }
            if lives.isEmpty || slots.isEmpty { continue }
            if lives.count == 1 && slots.count == 1 { pairs.append((lives[0], slots[0])) } else { groups.append((lives, slots)) }
        }
        return (pairs, groups)
    }

    /// How many of a profile's windows are no longer where the profile has them: what the menu
    /// reports as "moved". Asks nobody, so only windows the rules identify for certain are counted.
    /// ponytail: windows only Jev could identify are not counted; ask Jev here if that proves misleading.
    static func moved(from profile: Profile, displays: [DisplayInfo], live: [LiveWindow]) -> Int {
        let displayMap = Displays.pair(profile.displays, with: displays)
        let desktops = Spaces.userSpaces()
        return pairLocally(profile, live).pairs.filter { l, s in
            guard let display = displayMap[profile.windows[s].display] else { return false }
            return !inPlace(profile.windows[s], live[l], on: display, desktops: desktops)
        }.count
    }

    /// Whether an open window already is where a slot has it: same state, desktop and frame.
    static func inPlace(_ slot: SavedWindow, _ window: LiveWindow, on display: DisplayInfo, desktops: [String: [UInt64]]) -> Bool {
        if slot.isMinimized != window.minimized { return false }
        // On a desktop that no longer exists (Arrange would add it), or on another desktop.
        if slot.space > 0, let row = desktops[display.uuid], !row.isEmpty, slot.space > row.count || window.spaces != [row[slot.space - 1]] { return false }
        return window.minimized || near(window.frame, slot.frame(on: display), Config.driftTolerance)
    }

    /// What makes an open window the one a slot was saved from, surest first.
    private static let sameWindow: [(SavedWindow, LiveWindow) -> Bool] = [
        { $0.windowID == $1.id && $0.pid == $1.pid },                     // never closed since the save
        { $0.document != nil && $0.document == $1.document },            // shows the same file
        { $0.title == $1.title && $0.isMinimized == $1.minimized },      // same title; among twins, the one in the same state
        { $0.title == $1.title },
    ]

    // MARK: 3. Move

    /// Out of the Dock, then frames (a frame on another display carries the window there), then
    /// desktops, then into the Dock. Returns how many windows had to change.
    private static func apply(_ pairs: [Pair], profile: Profile, displayMap: [Int: DisplayInfo], live: [LiveWindow]) async -> (changed: Int, notes: [String]) {
        var notes: [String] = []
        var changed = Set<CGWindowID>()

        // Windows the profile wants on screen come out of the Dock first, so they can be placed like
        // any other. Restoring one on a desktop that isn't showing does not switch desktops.
        let restoring = pairs.filter { live[$0.live].minimized && !profile.windows[$0.slot].isMinimized }.map { live[$0.live] }
        for w in restoring { Windows.setMinimized(w.element, false); changed.insert(w.id) }
        if !restoring.isEmpty { try? await Task.sleep(nanoseconds: Config.minimizeSettle) }

        // A profile can use more desktops than a display has now: add the missing ones first.
        var desktopsByDisplay = Spaces.userSpaces()
        var wanted: [String: Int] = [:]
        for (_, s) in pairs {
            guard let display = displayMap[profile.windows[s].display] else { continue }
            wanted[display.uuid] = max(wanted[display.uuid] ?? 0, profile.windows[s].space)
        }
        let before = desktopsByDisplay.values.map(\.count).reduce(0, +)
        for (uuid, count) in wanted {
            guard let have = desktopsByDisplay[uuid]?.count, have > 0, count > have else { continue }
            _ = await Spaces.addDesktops(count - have, displayUUID: uuid)
        }
        // Count what is really there now: adding can stop part of the way.
        desktopsByDisplay = Spaces.userSpaces()
        let added = desktopsByDisplay.values.map(\.count).reduce(0, +) - before
        if added > 0 { notes.append("added \(added) desktop\(added == 1 ? "" : "s")") }

        var moves: [UInt64: [CGWindowID]] = [:]
        var toDock: [LiveWindow] = []
        var missingDesktops = false
        for (l, s) in pairs {
            let slot = profile.windows[s], window = live[l]
            guard let display = displayMap[slot.display] else { continue }
            // A window in the Dock, or bound for it, is placed too, so it reappears in its saved spot when restored.
            let target = slot.frame(on: display)
            if !near(window.frame, target) { Windows.setFrame(window.element, target); changed.insert(window.id) }
            if slot.space > 0, let desktops = desktopsByDisplay[display.uuid], !desktops.isEmpty {
                if slot.space > desktops.count { missingDesktops = true }
                let space = desktops[min(slot.space, desktops.count) - 1]
                if window.spaces != [space] { moves[space, default: []].append(window.id); changed.insert(window.id) }
            }
            if slot.isMinimized && !window.minimized { toDock.append(window); changed.insert(window.id) }
        }
        if !moves.isEmpty {
            try? await Task.sleep(nanoseconds: 200_000_000)
            for (space, ids) in moves { Spaces.move(ids, to: space) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            let stuck = moves.flatMap { space, ids in ids.filter { Spaces.of($0) != [space] } }.count
            if stuck > 0 { notes.append("\(stuck) window(s) could not change desktop") }
        }
        for w in toDock { Windows.setMinimized(w.element, true) }
        if missingDesktops { notes.append("the profile uses more desktops than exist and they could not be added; add some in Mission Control") }
        return (changed.count, notes)
    }

    private static func describe(_ w: SavedWindow, _ profile: Profile) -> String {
        let display = profile.displays.indices.contains(w.display) ? profile.displays[w.display].name : "display"
        return "\"\(w.title)\" on \(display)" + (w.space > 0 ? ", desktop \(w.space)" : "") + ", \(Int(w.fw * 100))% wide" + (w.isMinimized ? ", minimized" : "")
    }

    private static func near(_ a: CGRect, _ b: CGRect, _ t: CGFloat = Config.frameTolerance) -> Bool {
        return abs(a.minX - b.minX) <= t && abs(a.minY - b.minY) <= t && abs(a.width - b.width) <= t && abs(a.height - b.height) <= t
    }
}

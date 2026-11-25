//
//  KnowledgeStore.swift
//  Edison Parent
//
//  Owns the knowledge pack: loads the copy bundled with the app, and can
//  replace it with a newer one fetched from a URL.
//
//  The app ships with a working pack so it answers on first launch, offline,
//  with no server to stand up. Refresh is optional and additive: host
//  knowledge-pack.json anywhere static (GitHub Pages, S3, the district's own
//  web space) and set `refreshURL`.
//

import Foundation

@MainActor
final class KnowledgeStore: ObservableObject {

    @Published private(set) var pack: KnowledgePack?
    @Published private(set) var rules: Rules?
    @Published private(set) var loadError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshNote: String?

    /// Where to look for a newer pack. Leave nil to ship bundle-only.
    /// Example: URL(string: "https://example.org/edison/knowledge-pack.json")
    var refreshURL: URL? {
        guard let s = UserDefaults.standard.string(forKey: "refreshURL"), !s.isEmpty else { return nil }
        return URL(string: s)
    }

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("knowledge-pack.json")
    }

    /// Closings read from the live feed this session, merged over whatever the
    /// pack shipped with.
    @Published private(set) var liveAlerts: [ClosingAlert] = []
    @Published private(set) var lastAlertCheck: Date?

    /// Who works at the saved schools, read from each school's own published
    /// directory. Not in the file on disk - see StaffDirectory for why.
    @Published private(set) var liveStaff: [StaffMember] = []

    /// The pack the engine actually answers from: the bundled one with live
    /// alerts folded in, so a snow closing beats the published calendar, and
    /// the staff list folded in the same way.
    var effectivePack: KnowledgePack? {
        guard var p = pack else { return nil }
        p.alerts = AlertParser.merge((p.alerts ?? []) + liveAlerts)
        p.staff = (p.staff ?? []) + liveStaff
        return p
    }

    /// Loads the staff list for each saved school.
    ///
    /// Whatever is already on the phone is adopted first, so a question asked
    /// a second after opening the app is answered from the roster rather than
    /// told to wait. Only then does it go to the network, and only for a
    /// school whose copy is missing or more than a week old.
    ///
    /// Nothing depends on this: a staff question that arrives before the first
    /// load finishes says so plainly, and the one after it works. The
    /// calendar, the hours and the closings never touch this path.
    @MainActor
    func refreshStaff() async {
        guard let p = pack else { return }
        // The district's own number is not on the pack's district record -
        // Swift never decoded that field - but the picker saves it, which is
        // the only place it is needed: a district built in the app, whose
        // schools have no org ids of their own.
        let districtOrgId = chosenDistrictOrgId
        let saved = UserDefaults.standard.string(forKey: "defaultSchoolId") ?? ""
        let schools = saved.isEmpty ? [] : p.schools.filter { $0.id == saved }
        guard !schools.isEmpty || districtOrgId != 0 else { return }

        let onPhone = StaffDirectory.cached(for: schools)
        if !onPhone.isEmpty { liveStaff = onPhone }

        var rows: [StaffMember] = []
        if schools.contains(where: { $0.orgId != 0 }) {
            for s in schools { rows += await StaffDirectory.load(school: s) }
        } else {
            rows = await StaffDirectory.loadDistrictWide(orgId: districtOrgId)
        }
        if !rows.isEmpty { liveStaff = rows }
    }

    var engine: AnswerEngine? {
        guard let p = effectivePack, let rules else { return nil }
        return AnswerEngine(pack: p, rules: rules)
    }

    /// The saved school's display name, for notification wording.
    var defaultSchoolName: String? {
        guard let id = UserDefaults.standard.string(forKey: "defaultSchoolId"), !id.isEmpty else { return nil }
        return pack?.schools.first { $0.id == id }?.name
    }

    /// Alerts that still matter: today or later. Dates are ISO yyyy-MM-dd, so
    /// a string comparison is a date comparison.
    var activeAlerts: [ClosingAlert] {
        let today = AnswerEngine.iso(Date())
        return (effectivePack?.alerts ?? [])
            .filter { $0.date >= today }
            .sorted { $0.date < $1.date }
    }

    // MARK: - Loading

    func load() {
        let decoder = JSONDecoder()

        // Rules only ever come from the bundle - they pair with this build's
        // engine code, so a downloaded pack must not be able to change them.
        do {
            guard let url = Bundle.main.url(forResource: "intents", withExtension: "json") else {
                loadError = "intents.json is missing from the app bundle."
                return
            }
            rules = try decoder.decode(Rules.self, from: Data(contentsOf: url))
        } catch {
            loadError = "Could not read intents.json: \(error.localizedDescription)"
            return
        }

        // A district the parent chose beats everything else, including the
        // one the app shipped with. It was chosen on purpose.
        if chosenDistrictOrgId != 0,
           let saved = try? Data(contentsOf: districtCacheURL),
           let p = try? decoder.decode(KnowledgePack.self, from: saved) {
            pack = p
            return
        }

        // Prefer a downloaded pack, but only if it parses and is newer.
        if let cached = try? Data(contentsOf: cacheURL),
           let p = try? decoder.decode(KnowledgePack.self, from: cached),
           let bundled = loadBundledPack() {
            pack = (p.generatedDate ?? .distantPast) >= (bundled.generatedDate ?? .distantPast) ? p : bundled
            return
        }

        if let bundled = loadBundledPack() {
            pack = bundled
        } else {
            loadError = "knowledge-pack.json is missing from the app bundle."
        }
    }

    private func loadBundledPack() -> KnowledgePack? {
        guard let url = Bundle.main.url(forResource: "knowledge-pack", withExtension: "json") else { return nil }
        do {
            return try JSONDecoder().decode(KnowledgePack.self, from: Data(contentsOf: url))
        } catch {
            loadError = "Could not read the bundled knowledge pack: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Choosing a district

    /// Only ever one district's calendar is kept. A parent has one set of
    /// children at one set of schools, and keeping every district they ever
    /// looked at would be a few megabytes of somebody else's calendar.
    private var districtCacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("district-pack.json")
    }

    var chosenDistrictOrgId: Int {
        UserDefaults.standard.integer(forKey: "districtOrgId")
    }

    var chosenDistrictName: String {
        UserDefaults.standard.string(forKey: "districtName") ?? ""
    }

    /// True when this pack was read off the district's own calendar rather
    /// than prepared on a desktop, so the screens that show bell times and
    /// office numbers can say they are not available instead of showing
    /// nothing and looking broken.
    var packWasBuiltInApp: Bool { pack?.builtInApp == true }

    @Published private(set) var buildStep: String?
    @Published private(set) var isBuildingDistrict = false

    /// Reads a district's published calendar and answers from it from now on.
    @discardableResult
    func useDistrict(_ ref: DistrictRef) async -> String? {
        isBuildingDistrict = true
        buildStep = "Starting"
        defer { isBuildingDistrict = false; buildStep = nil }

        let info = DistrictBuilder.Info(orgId: ref.o,
                                        name: ref.name,
                                        shortName: "",
                                        url: ref.siteURL,
                                        timeZone: "")
        do {
            let built = try await DistrictBuilder.build(info: info, rules: rules) { [weak self] step in
                Task { @MainActor in self?.buildStep = step }
            }

            // Written before it is adopted, so a crash here cannot leave the
            // app pointing at a district whose calendar it never saved.
            let data = try JSONEncoder().encode(built)
            try data.write(to: districtCacheURL, options: .atomic)

            UserDefaults.standard.set(ref.o, forKey: "districtOrgId")
            UserDefaults.standard.set(ref.name, forKey: "districtName")
            // The old district's school is meaningless here.
            UserDefaults.standard.removeObject(forKey: "defaultSchoolId")

            pack = built
            liveAlerts = []
            lastAlertCheck = nil
            loadError = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Back to the district the app shipped with.
    func clearDistrict() {
        UserDefaults.standard.removeObject(forKey: "districtOrgId")
        UserDefaults.standard.removeObject(forKey: "districtName")
        UserDefaults.standard.removeObject(forKey: "defaultSchoolId")
        try? FileManager.default.removeItem(at: districtCacheURL)
        liveAlerts = []
        lastAlertCheck = nil
        load()
    }

    // MARK: - Refresh

    func refresh() async {
        guard let url = refreshURL else {
            lastRefreshNote = "No refresh URL is set, so the app is using the pack it shipped with."
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 30
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: req)

            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                lastRefreshNote = "Update failed (HTTP \(http.statusCode)). Still using the previous pack."
                return
            }

            // Parse before replacing: a truncated or wrong-shaped download
            // must never leave the app with no data.
            let fresh = try JSONDecoder().decode(KnowledgePack.self, from: data)
            guard fresh.schemaVersion == 1 else {
                lastRefreshNote = "That pack is schema v\(fresh.schemaVersion); this app reads v1. Update the app."
                return
            }
            guard !fresh.schools.isEmpty, !fresh.calendar.isEmpty else {
                lastRefreshNote = "The downloaded pack looked empty, so it was ignored."
                return
            }

            try data.write(to: cacheURL, options: .atomic)
            pack = fresh
            lastRefreshNote = "Updated. Pack built \(fresh.generatedAt)."
        } catch {
            lastRefreshNote = "Update failed: \(error.localizedDescription). Still using the previous pack."
        }
    }

    // MARK: - Closing alerts

    /// Reads the district's public live feed and merges any closings found.
    /// Cheap: one request, ~40 KB, no auth. Safe to call on every launch, on
    /// pull-to-refresh and from a background task.
    ///
    /// Returns the alerts that are new since the last check, so the caller can
    /// decide whether to notify.
    @discardableResult
    func checkAlerts() async -> [ClosingAlert] {
        guard let rules, let pack else { return [] }
        let parser = AlertParser(rules: rules, timeZone: pack.district.timeZone)

        // The district feed always; the saved school's own feed too, because a
        // single-building closure only ever appears there. Two small requests.
        var sources: [(url: URL, schoolId: String)] = []
        if let s = pack.alertFeedUrl, let u = URL(string: s) {
            sources.append((u, ""))
        }
        if let id = UserDefaults.standard.string(forKey: "defaultSchoolId"), !id.isEmpty,
           let s = pack.schoolFeedUrls?[id], let u = URL(string: s) {
            sources.append((u, id))
        }
        guard !sources.isEmpty else { return [] }

        var fresh: [ClosingAlert] = []
        var anySucceeded = false

        for source in sources {
            do {
                var req = URLRequest(url: source.url)
                req.timeoutInterval = 20
                req.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    continue
                }
                fresh += parser.alerts(inFeed: data, schoolId: source.schoolId)
                anySucceeded = true
            } catch {
                // One feed failing is not fatal: the other may still carry the
                // closing, and the calendar still answers everything else.
                continue
            }
        }
        guard anySucceeded else { return [] }

        let merged = AlertParser.merge(fresh)
        let known = Set(liveAlerts.map(\.id))
        let new = merged.filter { !known.contains($0.id) }

        liveAlerts = AlertParser.merge(liveAlerts + merged)
        lastAlertCheck = Date()

        // Only announce things still ahead of us.
        let today = AnswerEngine.iso(Date())
        return new.filter { $0.date >= today }
    }
}

import Foundation

/// Who works at a school.
///
/// Every district on this platform publishes a staff directory the same way it
/// publishes a calendar: an open feed, keyed only by the school's number. The
/// school's own Staff page is built from it. So the app does not need to crawl
/// anything to say who teaches science; it reads the same list the website
/// reads, for the school the parent actually picked.
///
/// WHAT THIS DELIBERATELY DOES NOT CARRY
///
/// The feed has an email and a phone field for each person. Across Edison's
/// twenty schools, 2,105 staff are listed and 156 have an email in the feed -
/// two elementary schools fill it in, eighteen leave it blank, and Edison High
/// School has gone further and set every one of its 275 entries to the literal
/// value "hidden". That is a district making a choice about its staff's
/// contact details, school by school, and it is not the app's to overturn.
///
/// So names, job titles and departments are kept, and the contact fields are
/// dropped on the floor as the rows come in - `Row` has nowhere to put them. A
/// parent who needs to email a teacher is sent to that school's own Staff
/// page, which is current, is the district's to change, and already shows an
/// address wherever the school chose to publish one. The app never holds a
/// roster of educators' email addresses, which is also the kind of compiled
/// contact list both app stores reject an app for shipping.
///
/// WHY IT IS FETCHED RATHER THAN BUILT IN
///
/// Those 2,105 people would add about four hundred kilobytes to a
/// two-megabyte app, go stale the first time somebody changes job, and mostly
/// describe nineteen schools the parent has no child at. One school's roster
/// is a few seconds and about ten kilobytes, so it is read for the school that
/// was picked, kept on the phone, and answered from there afterwards -
/// including with no signal. The first staff question of the fortnight needs a
/// connection; the calendar questions that get asked at 6:45am never do.
///
/// Mirrors web/staff.js.
enum StaffDirectory {

    static let api = "https://thrillshare-cmsv2.services.thrillshare.com/api/v4/o"
    private static let perPage = 20      // what the feed returns, not our choice
    private static let maxPages = 40     // 800 people; Edison's largest school has 305
    private static let freshFor: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - The feed's shape

    /// Only the fields that are kept. `email` and `phone_number` are in the
    /// JSON and are simply not decoded - see the note above before adding
    /// them.
    private struct Row: Decodable {
        var first: String?
        var last: String?
        var full_name: String?
        var title: String?
        var department: String?
    }

    private struct Page: Decodable {
        var directories: [Row]?
        var meta: Meta?
        struct Meta: Decodable {
            var links: Links?
            struct Links: Decodable { var total_entries: Int? }
        }
    }

    /// One feed row -> one record, carrying only what the app will answer with.
    ///
    /// The feed gives first and last separately and also a full_name, and they
    /// do not always agree: a few entries have the whole name in `last` and
    /// nothing in `first`, and some have a full_name with a middle initial the
    /// parts leave out. Whichever is longer is the one a parent would
    /// recognise.
    private static func normalise(_ r: Row, schoolId: String) -> StaffMember? {
        let first = (r.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let last = (r.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let joined = "\(first) \(last)".trimmingCharacters(in: .whitespacesAndNewlines)
        let full = (r.full_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = full.count >= joined.count ? full : joined
        if name.isEmpty { return nil }
        return StaffMember(
            schoolId: schoolId,
            name: name,
            first: first,
            last: last,
            title: (r.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            department: (r.department ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - On the phone

    /// The org id in full. An earlier version of the calendar cache shortened
    /// its keys and merged twenty feeds into one; a key is never worth saving
    /// bytes on.
    private static func cacheURL(_ orgId: Int) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("staff-\(orgId).json")
    }

    private struct Cached: Codable { var at: Date; var rows: [StaffMember] }

    private static func readCache(_ orgId: Int) -> Cached? {
        guard let data = try? Data(contentsOf: cacheURL(orgId)) else { return nil }
        return try? JSONDecoder().decode(Cached.self, from: data)
    }

    private static func writeCache(_ orgId: Int, _ rows: [StaffMember]) {
        guard let data = try? JSONEncoder().encode(Cached(at: Date(), rows: rows)) else { return }
        try? data.write(to: cacheURL(orgId), options: .atomic)
    }

    // MARK: - Reading the feed

    private static func page(_ orgId: Int, _ pageNo: Int) async throws -> Page {
        var s = "\(api)/\(orgId)/cms/directories"
        if pageNo > 1 { s += "?page_no=\(pageNo)" }
        guard let url = URL(string: s) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Page.self, from: data)
    }

    /// Reads every page of one school's directory.
    ///
    /// The feed reports total_entries, so the number of pages is known after
    /// the first request rather than guessed at by fetching until something
    /// comes back empty.
    private static func roster(orgId: Int, schoolId: String) async throws -> [StaffMember] {
        let first = try await page(orgId, 1)
        var rows: [StaffMember] = (first.directories ?? []).compactMap { normalise($0, schoolId: schoolId) }

        let total = first.meta?.links?.total_entries ?? 0
        let pages = min(Int(ceil(Double(total) / Double(perPage))), maxPages)
        if pages > 1 {
            for p in 2...pages {
                do {
                    let next = try await page(orgId, p)
                    rows += (next.directories ?? []).compactMap { normalise($0, schoolId: schoolId) }
                } catch {
                    break    // a partial roster still answers most questions
                }
            }
        }
        return rows
    }

    // MARK: - What the app calls

    /// Whatever is already on the phone, for the schools given. Never waits.
    static func cached(for schools: [School]) -> [StaffMember] {
        var out: [StaffMember] = []
        for s in schools where s.orgId != 0 {
            if let c = readCache(s.orgId) { out += c.rows }
        }
        return out
    }

    /// The roster for one school, from the phone if it is there and recent.
    ///
    /// An expired copy is still returned rather than waited on: a stale list
    /// is a better answer than no answer, and the refresh happens behind the
    /// question.
    static func load(school: School) async -> [StaffMember] {
        guard school.orgId != 0 else { return [] }
        let cachedCopy = readCache(school.orgId)
        if let c = cachedCopy, Date().timeIntervalSince(c.at) < freshFor { return c.rows }
        do {
            let rows = try await roster(orgId: school.orgId, schoolId: school.id)
            if !rows.isEmpty { writeCache(school.orgId, rows) }
            return rows.isEmpty ? (cachedCopy?.rows ?? []) : rows
        } catch {
            return cachedCopy?.rows ?? []
        }
    }

    /// A district the app has never crawled knows its own number but not its
    /// schools' - DistrictBuilder gets the calendar from section ids, which
    /// are not org ids. Some districts keep one directory at district level;
    /// where that is so this finds it, and where it is not there is nothing to
    /// find and the engine says so.
    static func loadDistrictWide(orgId: Int) async -> [StaffMember] {
        guard orgId != 0 else { return [] }
        let cachedCopy = readCache(orgId)
        if let c = cachedCopy, Date().timeIntervalSince(c.at) < freshFor { return c.rows }
        do {
            let rows = try await roster(orgId: orgId, schoolId: "")
            if !rows.isEmpty { writeCache(orgId, rows) }
            return rows.isEmpty ? (cachedCopy?.rows ?? []) : rows
        } catch {
            return cachedCopy?.rows ?? []
        }
    }
}

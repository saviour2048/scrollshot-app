import AppKit

/// A search shortcut: type the keyword, then a query, and it opens the URL with
/// `{query}` replaced by the (percent-encoded) argument in the default browser.
struct Quicklink: Codable, Identifiable, Equatable {
    var keyword: String     // "bing"
    var title: String       // "Bing 搜索"
    var urlTemplate: String // "https://cn.bing.com/search?q={query}"
    var id: String { keyword }

    /// Build the final URL for a query.
    func url(for query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? query
        return URL(string: urlTemplate.replacingOccurrences(of: "{query}", with: encoded))
    }

    func matches(_ q: String) -> Bool {
        q.isEmpty || keyword.lowercased().hasPrefix(q) || title.localizedCaseInsensitiveContains(q)
    }
}

/// The built-in + user quicklinks. Persisted (and iCloud-synced) as JSON.
@MainActor
enum Quicklinks {
    private static let key = "launcher.quicklinks"

    static let defaults: [Quicklink] = [
        Quicklink(keyword: "bing", title: "Bing 搜索", urlTemplate: "https://cn.bing.com/search?q={query}"),
        Quicklink(keyword: "google", title: "Google 搜索", urlTemplate: "https://www.google.com/search?q={query}"),
        Quicklink(keyword: "baidu", title: "百度搜索", urlTemplate: "https://www.baidu.com/s?wd={query}"),
        Quicklink(keyword: "github", title: "GitHub 搜索", urlTemplate: "https://github.com/search?q={query}&type=repositories"),
        Quicklink(keyword: "youtube", title: "YouTube 搜索", urlTemplate: "https://www.youtube.com/results?search_query={query}"),
    ]

    static var all: [Quicklink] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Quicklink].self, from: data), !list.isEmpty else {
            return defaults
        }
        return list
    }

    static func save(_ list: [Quicklink]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

extension CharacterSet {
    /// Query-value safe set (drops `&`, `=`, `+`, `?`, `/`, space, etc.).
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?/ ")
        return set
    }()
}

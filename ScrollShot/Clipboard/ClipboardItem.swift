import Foundation

/// One entry in the clipboard history.
struct ClipboardItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case text, image, file }

    let id: UUID
    var kind: Kind
    var text: String?          // .text plain content
    var rtfData: Data?         // .text rich (RTF) content, when the source had it
    var imageFileName: String? // .image: PNG stored beside index.json
    var filePaths: [String]?   // .file: absolute paths
    var sourceApp: String?
    var sourceBundleID: String?
    var timestamp: Date
    var charCount: Int
    var wordCount: Int
    var pinned: Bool
    /// True when `text` was cut down to the byte cap on capture.
    var textTruncated: Bool

    /// Pre-computed free-text index used by the search box.
    /// Kept as a stored property so searching does not rebuild strings on every keystroke.
    private(set) var searchText: String

    init(id: UUID = UUID(),
         kind: Kind,
         text: String? = nil,
         rtfData: Data? = nil,
         imageFileName: String? = nil,
         filePaths: [String]? = nil,
         sourceApp: String? = nil,
         sourceBundleID: String? = nil,
         timestamp: Date = Date(),
         charCount: Int = 0,
         wordCount: Int = 0,
         pinned: Bool = false,
         textTruncated: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.rtfData = rtfData
        self.imageFileName = imageFileName
        self.filePaths = filePaths
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
        self.timestamp = timestamp
        self.charCount = charCount
        self.wordCount = wordCount
        self.pinned = pinned
        self.textTruncated = textTruncated
        self.searchText = Self.makeSearchText(kind: kind, text: text, sourceApp: sourceApp, filePaths: filePaths)
    }

    /// One-line label for the list row.
    var preview: String {
        switch kind {
        case .text:
            let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "(空白)" : t
        case .image:
            return "图片"
        case .file:
            let names = (filePaths ?? []).map { ($0 as NSString).lastPathComponent }
            return names.isEmpty ? "文件" : names.joined(separator: ", ")
        }
    }


    private static func makeSearchText(kind: Kind, text: String?, sourceApp: String?, filePaths: [String]?) -> String {
        let preview: String
        switch kind {
        case .text:
            preview = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        case .image:
            preview = "图片"
        case .file:
            preview = (filePaths ?? []).map { ($0 as NSString).lastPathComponent }.joined(separator: " ")
        }
        return [preview, sourceApp ?? ""].joined(separator: " ")
    }

    // MARK: Codable

    /// We intentionally do not persist `searchText`; it is rebuilt on decode so the
    /// index.json stays small and remains readable by older versions.
    enum CodingKeys: String, CodingKey {
        case id, kind, text, rtfData, imageFileName, filePaths
        case sourceApp, sourceBundleID, timestamp, charCount, wordCount, pinned
        case textTruncated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        rtfData = try container.decodeIfPresent(Data.self, forKey: .rtfData)
        imageFileName = try container.decodeIfPresent(String.self, forKey: .imageFileName)
        filePaths = try container.decodeIfPresent([String].self, forKey: .filePaths)
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        charCount = try container.decode(Int.self, forKey: .charCount)
        wordCount = try container.decode(Int.self, forKey: .wordCount)
        pinned = try container.decode(Bool.self, forKey: .pinned)
        textTruncated = try container.decodeIfPresent(Bool.self, forKey: .textTruncated) ?? false
        searchText = Self.makeSearchText(kind: kind, text: text, sourceApp: sourceApp, filePaths: filePaths)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(rtfData, forKey: .rtfData)
        try container.encodeIfPresent(imageFileName, forKey: .imageFileName)
        try container.encodeIfPresent(filePaths, forKey: .filePaths)
        try container.encodeIfPresent(sourceApp, forKey: .sourceApp)
        try container.encodeIfPresent(sourceBundleID, forKey: .sourceBundleID)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(charCount, forKey: .charCount)
        try container.encode(wordCount, forKey: .wordCount)
        try container.encode(pinned, forKey: .pinned)
        try container.encode(textTruncated, forKey: .textTruncated)
    }
}

import SwiftUI
import AppKit

/// One acknowledgement entry.
struct Credit: Identifiable {
    let id = UUID()
    let name: String        // proper noun — not localized
    let purposeKey: String  // localized "what we used it for"
    let author: String?     // shown after the name when useful
    let license: String?    // e.g. "MIT", "Apache-2.0"; nil for pure inspiration
    let url: String
}

enum Credits {
    /// Third-party code COMPILED into ScrollShot — real license obligations.
    static let libraries: [Credit] = [
        Credit(name: "Sparkle", purposeKey: "credits.use.sparkle", author: nil,
               license: "MIT", url: "https://github.com/sparkle-project/Sparkle"),
        Credit(name: "KeyboardShortcuts", purposeKey: "credits.use.shortcuts", author: "Sindre Sorhus",
               license: "MIT", url: "https://github.com/sindresorhus/KeyboardShortcuts"),
        Credit(name: "DDMathParser", purposeKey: "credits.use.math", author: "Dave DeLong",
               license: "MIT", url: "https://github.com/davedelong/DDMathParser"),
        Credit(name: "WhatCable", purposeKey: "credits.use.whatcable", author: "Darryl Morley",
               license: "MIT", url: "https://github.com/darrylmorley/whatcable"),
        Credit(name: "m1ddc", purposeKey: "credits.use.m1ddc", author: "waydabber",
               license: "MIT", url: "https://github.com/waydabber/m1ddc"),
        Credit(name: "SMCKit", purposeKey: "credits.use.smckit", author: "beltex",
               license: "MIT", url: "https://github.com/beltex/SMCKit"),
        Credit(name: "Stats", purposeKey: "credits.use.stats", author: "Serhiy Mytrovtsiy",
               license: "MIT", url: "https://github.com/exelban/stats"),
        Credit(name: "Rectangle", purposeKey: "credits.use.rectangle", author: "Ryan Hanson",
               license: "MIT", url: "https://github.com/rxhanson/Rectangle"),
    ]

    /// Bundled ASSETS (the RunCat sprite frames ship in the app, with license).
    static let assets: [Credit] = [
        Credit(name: "menubar_runcat", purposeKey: "credits.use.runcat", author: "Takuto Nakamura (Kyome22)",
               license: "Apache-2.0", url: "https://github.com/Kyome22/menubar_runcat"),
    ]

    /// Concepts / UX / techniques we studied — NO code or assets copied.
    static let inspiration: [Credit] = [
        Credit(name: "Flameshot", purposeKey: "credits.use.flameshot", author: nil,
               license: nil, url: "https://github.com/flameshot-org/flameshot"),
        Credit(name: "CleanShot X", purposeKey: "credits.use.cleanshot", author: nil,
               license: nil, url: "https://cleanshot.com"),
        Credit(name: "Raycast", purposeKey: "credits.use.raycast", author: nil,
               license: nil, url: "https://raycast.com"),
        Credit(name: "Yoink", purposeKey: "credits.use.yoink", author: "Eternal Storms",
               license: nil, url: "https://eternalstorms.at/yoink/"),
        Credit(name: "CodexBar", purposeKey: "credits.use.codexbar", author: "Peter Steinberger",
               license: nil, url: "https://github.com/steipete/CodexBar"),
        Credit(name: "KeyStats", purposeKey: "credits.use.keystats", author: nil,
               license: nil, url: "https://github.com/debugtheworldbot/keyStats"),
        Credit(name: "SteelSeries ExactMouse", purposeKey: "credits.use.exactmouse", author: nil,
               license: nil, url: "https://steelseries.com"),
    ]
}

/// A tappable acknowledgement row: name (+ author) · purpose · license badge,
/// opening the project's page.
struct CreditRow: View {
    let credit: Credit

    var body: some View {
        Button {
            if let url = URL(string: credit.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(credit.name).font(.system(size: 13, weight: .medium)).foregroundColor(.ssText)
                        if let author = credit.author {
                            Text("· \(author)").font(.system(size: 11)).foregroundColor(.ssMuted)
                        }
                        if let license = credit.license {
                            Text(license)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.ssBlue.opacity(0.12), in: Capsule())
                                .foregroundColor(.ssBlue)
                        }
                    }
                    Text(L(credit.purposeKey)).font(.system(size: 11)).foregroundColor(.ssMuted)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12)).foregroundColor(.ssMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(credit.url)
    }
}

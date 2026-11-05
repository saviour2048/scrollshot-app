import AppKit
import SwiftUI
import XCTest
@testable import ScrollShot

final class AppThemeTests: XCTestCase {
    func testStoredThemeDefaultsToSystemWhenMissingOrInvalid() {
        XCTAssertEqual(AppThemeMode.resolve(storedValue: nil), .system)
        XCTAssertEqual(AppThemeMode.resolve(storedValue: "not-a-theme"), .system)
    }

    func testStoredThemeRoundTripsEveryMode() {
        for mode in AppThemeMode.allCases {
            XCTAssertEqual(AppThemeMode.resolve(storedValue: mode.rawValue), mode)
        }
    }

    func testAppearanceMapping() {
        XCTAssertNil(AppThemeMode.system.appearanceName)
        XCTAssertEqual(AppThemeMode.light.appearanceName, .aqua)
        XCTAssertEqual(AppThemeMode.dark.appearanceName, .darkAqua)
    }

    func testThemeSurfacesResolveDifferentlyInLightAndDarkAppearances() {
        let light = NSAppearance(named: .aqua)!
        let dark = NSAppearance(named: .darkAqua)!

        let lightPage = resolved(Color.ssPage, in: light)
        let darkPage = resolved(Color.ssPage, in: dark)
        let lightCard = resolved(Color.ssCard, in: light)
        let darkCard = resolved(Color.ssCard, in: dark)
        let darkText = resolved(Color.ssText, in: dark)

        XCTAssertGreaterThan(abs(lightPage.redComponent - darkPage.redComponent), 0.5)
        XCTAssertGreaterThan(abs(lightCard.redComponent - darkCard.redComponent), 0.5)
        XCTAssertGreaterThan(darkText.redComponent - darkCard.redComponent, 0.5)
    }

    private func resolved(_ color: Color, in appearance: NSAppearance) -> NSColor {
        var result: NSColor!
        appearance.performAsCurrentDrawingAppearance {
            result = NSColor(color).usingColorSpace(.sRGB)
        }
        return result
    }
}

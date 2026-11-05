import XCTest
@testable import ScrollShot

/// Smoke test for the vendored WhatCable diagnostic engine (CableInfo module).
/// Verifies the Darwin backend can actually read this Mac's USB-C port state
/// via IOKit and that the cable database loads from the app bundle.
final class CableInfoSmokeTests: XCTestCase {

    func testSnapshotReadsPorts() async throws {
        let provider = makeDefaultSnapshotProvider()
        let snapshot = try await provider.snapshot()
        XCTAssertFalse(snapshot.ports.isEmpty, "expected at least one USB-C port from IOKit")
        for port in snapshot.ports {
            print("[CableInfo] port: \(port)")
        }
    }

    /// Live charger-input watts shown by the Cable Info pane. Reads the real
    /// IOKit/SMC path on this Mac. Records idle vs. under-load values, so a
    /// reading that never moves under a known CPU stimulus is visible in the log.
    @MainActor
    func testLiveChargerWattsReadsWhilePaneVisible() async throws {
        guard #available(macOS 14, *) else { throw XCTSkip("needs macOS 14") }
        let store = CableInfoStore()
        store.start()
        defer { store.stop() }

        try await Task.sleep(for: .seconds(3))
        let idle = store.chargerInputWatts
        print("[LiveWatts] idle input=\(idle)W")

        // Known stimulus: saturate every core for 10 s. Sample while it runs
        // (sampling after it ends would measure idle and prove nothing).
        let deadline = Date().addingTimeInterval(10)
        let busy = Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
                    group.addTask {
                        var x = 0.0
                        while Date() < deadline { x += 1; if x > 1e12 { x = 0 } }
                    }
                }
            }
        }
        try await Task.sleep(for: .seconds(5))
        let loaded = store.chargerInputWatts
        print("[LiveWatts] loaded input=\(loaded)W")
        await busy.value

        XCTAssertGreaterThan(idle, 0,
            "Mac is on external power, so live input watts must be > 0")
        XCTAssertGreaterThan(loaded, idle,
            "live watts must rise under a known CPU load (idle=\(idle), loaded=\(loaded))")
    }

    func testCableDatabaseLoads() {
        // whatcable.db must ship inside the app bundle and be readable.
        XCTAssertNotNil(Bundle.main.url(forResource: "whatcable", withExtension: "db"),
                        "whatcable.db missing from bundle resources")
    }
}

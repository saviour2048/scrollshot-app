import XCTest
@testable import ScrollShot

final class SimulatorReaderTests: XCTestCase {

    /// 真实 ps 输出样本（本机 2026-10-20 无 booted 设备时实测）：常驻守护进程
    /// 不得触发 "running"，也不得计入总量。
    func testIdleDaemonsDoNotCount() {
        let ps = """
          78729    800  0.0 /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/bin/simdiskimaged
          78882   3664  0.0 /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/XPCServices/com.apple.CoreSimulator.CoreSimulatorService.xpc/Contents/MacOS/com.apple.CoreSimulator.CoreSimulatorService
          78886   3536  0.0 /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/XPCServices/SimulatorTrampoline.xpc/Contents/MacOS/SimulatorTrampoline
          62000 153600  2.5 /Applications/Visual Studio Code.app/Contents/MacOS/Electron
        """
        let status = SimulatorReader.parse(psOutput: ps)
        XCTAssertFalse(status.running)
        XCTAssertEqual(status.memory, 0)
        XCTAssertTrue(status.top.isEmpty)
    }

    /// booted 设备：运行时进程(路径含 /CoreSimulator/Volumes/, 注意运行时目录名
    /// 带空格 "iOS 26.5.simruntime") + Simulator.app 界面, 全部计入总量。
    /// pid 用不可能真实存在的值, 避免撞上本机真实进程导致 processName 查出名。
    func testBootedRuntimeCounts() {
        let ps = """
          90000001 2097152  3.5 /Library/Developer/CoreSimulator/Volumes/iOS_23G420/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.5.simruntime/Contents/Resources/RuntimeRoot/System/Library/CoreServices/SpringBoard.app/SpringBoard
          90000002  512000  1.0 /Users/example/Library/Developer/CoreSimulator/Devices/ABC123/data/Containers/Bundle/Application/DEADBEEF/Demo.app/Demo
          90000003  102400  0.5 /Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator
          78886    3536  0.0 /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/XPCServices/SimulatorTrampoline.xpc/Contents/MacOS/SimulatorTrampoline
        """
        let status = SimulatorReader.parse(psOutput: ps)
        XCTAssertTrue(status.running)
        // (2097152 + 512000 + 102400) KB → bytes; SimulatorTrampoline 不计
        XCTAssertEqual(status.memory, (2097152 + 512000 + 102400) * 1024)
        XCTAssertEqual(status.cpu, 5.0, accuracy: 0.001)
        XCTAssertEqual(status.top.map(\.name), ["SpringBoard", "Demo", "Simulator"])
    }

    func testSimctlBootedDeviceNames() {
        let out = """
        == Devices ==
        -- iOS 26.5 --
            iPhone 17 Pro (3F8A1C2E-1234-5678-9ABC-DEF012345678) (Booted)
            iPhone Air (AAAA-BBBB) (Shutdown)
        -- watchOS 26.5 --
            Apple Watch Series 11 (46mm) (CCCC-DDDD) (Booted)
        """
        XCTAssertEqual(SimulatorDeviceReader.parse(simctlOutput: out),
                       ["iPhone 17 Pro", "Apple Watch Series 11 (46mm)"])
    }
}

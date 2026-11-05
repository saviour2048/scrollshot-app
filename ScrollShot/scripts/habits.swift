#!/usr/bin/env swift
//
// habits.swift — ScrollShot "Mac 习惯档案" 引擎 (CLI, 无 UI)
//
//   swift scripts/habits.swift export   <out.json>      # 捕获本机习惯(只收偏离默认的项)→ 档案
//   swift scripts/habits.swift preview  <profile.json>  # 逐项预览:现值 → 档案值(会不会变)
//   swift scripts/habits.swift apply    <profile.json> [--yes] [--only k1,k2] [--skip k1,k2]
//                                                       # 不带 --yes = 干跑(=预览);带 --yes 才写入 + 重启相关服务
//   swift scripts/habits.swift selftest                 # 安全闭环自测:改一个无害项→应用→校验→还原
//
// 设计红线:导入默认干跑;--yes 才落盘;支持 --only/--skip 逐项勾选;绝不碰凭据。
//
import Foundation

// MARK: - 值模型(支持 bool/int/double/string/data,覆盖 defaults 常见类型)

enum HabitValue: Equatable {
    case bool(Bool), int(Int), double(Double), string(String), data(Data)

    /// 从 CFPreferences 读到的 CFType 转过来。
    static func from(_ cf: CFTypeRef) -> HabitValue? {
        let id = CFGetTypeID(cf)
        if id == CFBooleanGetTypeID() { return .bool(CFBooleanGetValue((cf as! CFBoolean))) }
        if id == CFStringGetTypeID()  { return .string(cf as! String) }
        if id == CFDataGetTypeID()    { return .data(cf as! Data) }
        if id == CFNumberGetTypeID() {
            let n = cf as! NSNumber
            switch CFNumberGetType(n as CFNumber) {
            case .float32Type, .float64Type, .floatType, .doubleType, .cgFloatType:
                return .double(n.doubleValue)
            default:
                return .int(n.intValue)
            }
        }
        return nil
    }

    /// 写回 CFPreferences 用的属性列表值。
    var cf: CFPropertyList {
        switch self {
        case .bool(let b):   return (b ? kCFBooleanTrue : kCFBooleanFalse) as CFBoolean
        case .int(let i):    return NSNumber(value: i)
        case .double(let d): return NSNumber(value: d)
        case .string(let s): return s as CFString
        case .data(let d):   return d as CFData
        }
    }

    var display: String {
        switch self {
        case .bool(let b):   return b ? "开(true)" : "关(false)"
        case .int(let i):    return "\(i)"
        case .double(let d): return "\(d)"
        case .string(let s): return "\"\(s)\""
        case .data(let d):   return "<\(d.count) 字节数据>"
        }
    }
}

extension HabitValue: Codable {
    enum CodingKeys: String, CodingKey { case t, v }
    func encode(to enc: Encoder) throws {
        var c = enc.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let b):   try c.encode("bool", forKey: .t);   try c.encode(b, forKey: .v)
        case .int(let i):    try c.encode("int", forKey: .t);    try c.encode(i, forKey: .v)
        case .double(let d): try c.encode("double", forKey: .t); try c.encode(d, forKey: .v)
        case .string(let s): try c.encode("string", forKey: .t); try c.encode(s, forKey: .v)
        case .data(let d):   try c.encode("data", forKey: .t);   try c.encode(d.base64EncodedString(), forKey: .v)
        }
    }
    init(from dec: Decoder) throws {
        let c = try dec.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .t) {
        case "bool":   self = .bool(try c.decode(Bool.self, forKey: .v))
        case "int":    self = .int(try c.decode(Int.self, forKey: .v))
        case "double": self = .double(try c.decode(Double.self, forKey: .v))
        case "string": self = .string(try c.decode(String.self, forKey: .v))
        case "data":   self = .data(Data(base64Encoded: try c.decode(String.self, forKey: .v)) ?? Data())
        default: throw DecodingError.dataCorruptedError(forKey: .t, in: c, debugDescription: "未知类型")
        }
    }
}

// MARK: - CFPreferences 读写(domain "GLOBAL" = NSGlobalDomain)

func appID(_ domain: String) -> CFString { domain == "GLOBAL" ? kCFPreferencesAnyApplication : (domain as CFString) }

func readPref(_ domain: String, _ key: String) -> HabitValue? {
    guard let cf = CFPreferencesCopyAppValue(key as CFString, appID(domain)) else { return nil }
    return HabitValue.from(cf)
}

func writePref(_ domain: String, _ key: String, _ value: HabitValue?) {
    CFPreferencesSetAppValue(key as CFString, value?.cf, appID(domain))
    CFPreferencesAppSynchronize(appID(domain))
}

// MARK: - 白名单(A 系统手感 + B 键盘映射)

struct Spec { let domain, key, label, category, effect: String }

let WHITELIST: [Spec] = [
    .init(domain: "GLOBAL", key: "KeyRepeat",                 label: "按键重复速率",        category: "键盘",   effect: "注销"),
    .init(domain: "GLOBAL", key: "InitialKeyRepeat",          label: "重复前延迟",          category: "键盘",   effect: "注销"),
    .init(domain: "GLOBAL", key: "ApplePressAndHoldEnabled",  label: "长按重复",            category: "键盘",   effect: "注销"),
    .init(domain: "GLOBAL", key: "com.apple.swipescrolldirection", label: "自然滚动方向",    category: "触控板", effect: "即时"),
    .init(domain: "GLOBAL", key: "com.apple.trackpad.scaling",     label: "触控板跟踪速度",  category: "触控板", effect: "即时"),
    .init(domain: "com.apple.AppleMultitouchTrackpad", key: "Clicking", label: "轻点来点按",  category: "触控板", effect: "即时"),
    .init(domain: "com.apple.dock", key: "autohide",      label: "自动隐藏程序坞",  category: "程序坞", effect: "重启Dock"),
    .init(domain: "com.apple.dock", key: "tilesize",      label: "程序坞图标大小",  category: "程序坞", effect: "重启Dock"),
    .init(domain: "com.apple.dock", key: "orientation",   label: "程序坞位置",      category: "程序坞", effect: "重启Dock"),
    .init(domain: "com.apple.dock", key: "magnification", label: "程序坞放大",      category: "程序坞", effect: "重启Dock"),
    .init(domain: "com.apple.dock", key: "show-recents",  label: "显示最近应用",    category: "程序坞", effect: "重启Dock"),
    .init(domain: "com.apple.dock", key: "wvous-tl-corner", label: "触发角·左上",   category: "程序坞", effect: "重启Dock"),
    .init(domain: "com.apple.dock", key: "wvous-tr-corner", label: "触发角·右上",   category: "程序坞", effect: "重启Dock"),
    .init(domain: "com.apple.dock", key: "wvous-bl-corner", label: "触发角·左下",   category: "程序坞", effect: "重启Dock"),
    .init(domain: "com.apple.dock", key: "wvous-br-corner", label: "触发角·右下",   category: "程序坞", effect: "重启Dock"),
    .init(domain: "GLOBAL", key: "AppleShowAllExtensions", label: "显示所有扩展名", category: "访达", effect: "重启Finder"),
    .init(domain: "com.apple.finder", key: "ShowPathbar",   label: "显示路径栏",      category: "访达",   effect: "重启Finder"),
    .init(domain: "com.apple.finder", key: "ShowStatusBar", label: "显示状态栏",      category: "访达",   effect: "重启Finder"),
    .init(domain: "com.apple.finder", key: "FXPreferredViewStyle", label: "默认视图样式", category: "访达", effect: "重启Finder"),
    .init(domain: "com.apple.finder", key: "_FXShowPosixPathInTitle", label: "标题栏显示完整路径", category: "访达", effect: "重启Finder"),
    .init(domain: "com.apple.screencapture", key: "location",       label: "截图保存位置",  category: "截图", effect: "重启SystemUI"),
    .init(domain: "com.apple.screencapture", key: "type",           label: "截图格式",      category: "截图", effect: "重启SystemUI"),
    .init(domain: "com.apple.screencapture", key: "disable-shadow", label: "去窗口截图阴影", category: "截图", effect: "重启SystemUI"),
    // B 层:ScrollShot 自己的键盘重映射就是本 App 的 defaults
    .init(domain: "com.scrollshot.app", key: "KeyMappingStore.enabled", label: "键盘映射开关", category: "键盘映射", effect: "重启App"),
    .init(domain: "com.scrollshot.app", key: "KeyMappingStore.rules",   label: "键盘映射规则", category: "键盘映射", effect: "重启App"),
]

// MARK: - 档案

struct HabitItem: Codable {
    let domain, key, label, category, effect: String
    let value: HabitValue
}
struct Profile: Codable {
    var version = 1
    var createdAt: String
    var items: [HabitItem]
}

let restartCmd: [String: [String]] = [
    "重启Dock": ["Dock"], "重启Finder": ["Finder"], "重启SystemUI": ["SystemUIServer"],
]

// MARK: - 子命令

func cmdExport(_ path: String) {
    var items: [HabitItem] = []
    for s in WHITELIST {
        guard let v = readPref(s.domain, s.key) else { continue }   // 只收偏离默认(已设置)的项
        items.append(HabitItem(domain: s.domain, key: s.key, label: s.label, category: s.category, effect: s.effect, value: v))
    }
    let df = ISO8601DateFormatter()
    let profile = Profile(createdAt: df.string(from: Date()), items: items)
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dataEncodingStrategy = .base64
    do {
        try enc.encode(profile).write(to: URL(fileURLWithPath: path))
        print("✅ 已导出 \(items.count) 项习惯 → \(path)")
        var cat = ""
        for it in items {
            if it.category != cat { print("  ── \(it.category) ──"); cat = it.category }
            print("    \(it.label)  =  \(it.value.display)")
        }
        print("\n(白名单共 \(WHITELIST.count) 项;其余为系统默认、未捕获——新机上本就是默认,无需迁移)")
    } catch { print("✗ 导出失败: \(error)"); exit(1) }
}

func loadProfile(_ path: String) -> Profile {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(Profile.self, from: data)
    } catch { print("✗ 读取档案失败: \(error)"); exit(1) }
}

func cmdApply(_ path: String, write: Bool, only: Set<String>, skip: Set<String>) {
    let profile = loadProfile(path)
    print(write ? "▶︎ 应用档案(会写入)" : "▶︎ 预览(干跑,不写入;加 --yes 才真正应用)")
    print("  档案创建于 \(profile.createdAt),共 \(profile.items.count) 项\n")

    var willChange: [HabitItem] = []
    var effects = Set<String>()
    var cat = ""
    for it in profile.items {
        let id = "\(it.domain)/\(it.key)"
        if it.category != cat { print("── \(it.category) ──"); cat = it.category }
        if !only.isEmpty && !only.contains(it.key) { print("  ⃠ \(it.label)（--only 跳过）"); continue }
        if skip.contains(it.key) { print("  ⃠ \(it.label)（--skip 跳过）"); continue }

        let cur = readPref(it.domain, it.key)
        let same = (cur == it.value)
        let curStr = cur?.display ?? "（未设置）"
        if same {
            print("  ＝ \(it.label)  已是  \(it.value.display)")
        } else {
            print("  \(write ? "✓" : "△") \(it.label)  \(curStr)  →  \(it.value.display)   [\(it.effect)]")
            willChange.append(it)
            effects.insert(it.effect)
            if write { writePref(it.domain, it.key, it.value) }
        }
        _ = id
    }

    print("")
    if !write {
        print("将改动 \(willChange.count) 项。确认后用:  apply \(path) --yes   真正应用(可加 --only / --skip 勾选)")
        return
    }
    print("✅ 已写入 \(willChange.count) 项。")
    // 重启相关服务让其生效
    var restarted = Set<String>()
    for e in effects { for proc in (restartCmd[e] ?? []) where !restarted.contains(proc) {
        restarted.insert(proc)
        let p = Process(); p.launchPath = "/usr/bin/killall"; p.arguments = [proc]
        p.standardError = FileHandle.nullDevice; try? p.run(); p.waitUntilExit()
        print("  ↻ 已重启 \(proc)")
    } }
    if effects.contains("注销") || effects.contains("重启App") {
        print("  ⚠︎ 有项目需要『注销重登』或『重开 ScrollShot』才完全生效(键盘重复速率 / 键盘映射规则)。")
    }
}

func cmdSelftest() {
    print("▶︎ 闭环自测(无害项 com.apple.dock/show-recents,验证后还原)")
    let d = "com.apple.dock", k = "show-recents"
    let original = readPref(d, k)
    print("  原值: \(original?.display ?? "（未设置）")")
    let test: HabitValue = (original == .bool(false)) ? .bool(true) : .bool(false)
    writePref(d, k, test)
    let after = readPref(d, k)
    let ok = (after == test)
    print("  写入 \(test.display) → 读回 \(after?.display ?? "nil")  \(ok ? "✓ 写入生效" : "✗ 没生效")")
    writePref(d, k, original)   // 还原(original 为 nil 则删除该键)
    let restored = readPref(d, k)
    let rok = (restored == original)
    print("  还原 → \(restored?.display ?? "（未设置）")  \(rok ? "✓ 已还原" : "✗ 还原失败")")
    print(ok && rok ? "\n✅ 自测通过:导出/读/写/还原 闭环成立。" : "\n✗ 自测失败,需改用 `defaults write` 路径。")
    if !(ok && rok) { exit(1) }
}

// MARK: - 入口

let args = Array(CommandLine.arguments.dropFirst())
func flagSet(_ name: String) -> Set<String> {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return [] }
    return Set(args[i + 1].split(separator: ",").map(String.init))
}
switch args.first {
case "export":   guard args.count >= 2 else { print("用法: export <out.json>"); exit(1) }; cmdExport(args[1])
case "preview":  guard args.count >= 2 else { print("用法: preview <profile.json>"); exit(1) }; cmdApply(args[1], write: false, only: flagSet("--only"), skip: flagSet("--skip"))
case "apply":    guard args.count >= 2 else { print("用法: apply <profile.json> [--yes]"); exit(1) }; cmdApply(args[1], write: args.contains("--yes"), only: flagSet("--only"), skip: flagSet("--skip"))
case "selftest": cmdSelftest()
default:
    print("""
    用法:
      swift scripts/habits.swift export   <out.json>
      swift scripts/habits.swift preview  <profile.json>
      swift scripts/habits.swift apply    <profile.json> [--yes] [--only k1,k2] [--skip k1,k2]
      swift scripts/habits.swift selftest
    """)
}

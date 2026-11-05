import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let tileLeftHalf    = Self("tileLeftHalf")
    static let tileRightHalf   = Self("tileRightHalf")
    static let tileTopHalf     = Self("tileTopHalf")
    static let tileBottomHalf  = Self("tileBottomHalf")
    static let tileTopLeft     = Self("tileTopLeft")
    static let tileTopRight    = Self("tileTopRight")
    static let tileBottomLeft  = Self("tileBottomLeft")
    static let tileBottomRight = Self("tileBottomRight")
    static let tileMaximize    = Self("tileMaximize")
    static let tileCenter      = Self("tileCenter")
    static let tileNextDisplay     = Self("tileNextDisplay")
    static let tilePreviousDisplay = Self("tilePreviousDisplay")
}

extension Tile {
    /// The global-shortcut slot the user assigns for this arrangement.
    var shortcutName: KeyboardShortcuts.Name {
        switch self {
        case .leftHalf:    return .tileLeftHalf
        case .rightHalf:   return .tileRightHalf
        case .topHalf:     return .tileTopHalf
        case .bottomHalf:  return .tileBottomHalf
        case .topLeft:     return .tileTopLeft
        case .topRight:    return .tileTopRight
        case .bottomLeft:  return .tileBottomLeft
        case .bottomRight: return .tileBottomRight
        case .maximize:    return .tileMaximize
        case .center:      return .tileCenter
        case .nextDisplay:     return .tileNextDisplay
        case .previousDisplay: return .tilePreviousDisplay
        }
    }
}

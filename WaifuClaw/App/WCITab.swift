import SwiftUI

/// Main tab selection. An enum (not Int) so tab routing can't silently drift
/// when tabs are reordered — TabView(selection:) binds to this, and features
/// route with `.home` / `.runs` / etc. instead of magic indices.
enum WCITab: Hashable {
    case home
    case runs
    case team
    case chat
    case settings
}

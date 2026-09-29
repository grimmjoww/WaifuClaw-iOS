import SwiftUI

/// State of one step in a run timeline. Done/failed/current/pending are
/// distinguished by icon as well as color (differentiate-without-color).
enum TimelineState {
    case done
    case current
    case pending
    case failed
}

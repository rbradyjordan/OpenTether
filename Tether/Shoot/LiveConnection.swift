import Foundation
import TetherCore

/// Everything the shoot screen needs after a successful connect.
struct LiveConnection {
    let session: TetherSession
    let shoot: ShootSession
    let identity: CameraIdentity?
    let context: ReconnectContext
    /// True when resumed from the store without a camera link.
    var needsReconnect: Bool = false
}

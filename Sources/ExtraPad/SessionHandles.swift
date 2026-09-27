import CoreGraphics
import Foundation

/// A session's moving parts, in a form the network queue can hold.
///
/// Sessions live on the main actor because they create displays; the server
/// runs on its own queue and must not reach into them directly. Resolving a
/// session hands back this, which is only lock-guarded broadcasters and
/// closures - safe to keep for the life of a connection.
struct SessionHandles {
    let deviceID: String
    let frames: FrameBroadcaster
    let patches: PatchBroadcaster
    let video: PatchBroadcaster
    let requestPatchKeyframe: () -> Void
    let requestVideoKeyframe: () -> Void
    let videoParameterSets: () -> Data?
    let width: Int
    let height: Int
    let scale: Int
}

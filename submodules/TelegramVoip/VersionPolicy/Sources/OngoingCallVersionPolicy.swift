import Foundation

/// Which tgcalls library versions this build advertises in phone.requestCall / phone.acceptCall.
///
/// The server A/B-serves 14.0.0 to one end of a call and 8.0.0 to the other. The vendored tgcalls
/// (e306932) frames 14.0.0 signaling as gzip over SCTP while 8.0.0 uses EncryptedConnection's
/// reliable messages, so no signaling message crosses and the call never connects (upstream fixed
/// this in tgcalls d96e244, which this build does not have). Not advertising 14.0.0 keeps the server
/// from serving it to this build; every version left speaks a framing its peers share.
public enum OngoingCallVersionPolicy {
    /// Versions whose signaling framing does not interoperate with what the server pairs them against.
    public static let withheldVersions: Set<String> = ["14.0.0"]

    public static func advertisedVersions(_ available: [String]) -> [String] {
        return available.filter { !withheldVersions.contains($0) }
    }
}

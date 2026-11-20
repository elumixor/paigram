import AuthenticationServices
import CryptoKit
import Foundation
import PaiPasskeyCore
import TelegramCore
import UIKit

/// A change an agent wants to make that waits for a passkey (`GET /changes/<hash>`).
public struct PaiChange: Decodable, Equatable {
    public struct Operation: Decodable, Equatable {
        public let connector: String?
        public let op: String?
        public let args: JSONValue?
    }

    public struct Page: Decodable, Equatable {
        public let host: String?
        public let path: String?
        public let changes: JSONValue?
        public let clickTarget: JSONValue?
        public let before: JSONValue?
    }

    public let hash: String
    public let status: String
    /// Epoch milliseconds.
    public let expires: Double?
    public let executor: String?
    public let agent: String?
    public let site: String?
    public let reason: String?
    public let op: Operation?
    public let page: Page?

    public var isPending: Bool { status == "pending" }
}

/// pai's passkeys on this phone (docs/paigram-passkeys.md in pai): enrol one bound to this device, then sign unlock
/// windows and change approvals with it. Every call carries the device token too; the token alone gets a 401 here,
/// which says nothing about the token, so these calls never forget it.
@available(iOS 16.0, *)
public enum PaiPasskeys {
    public static let relyingParty = "pai.desk.atmagaming.com"
    /// Posted on the main queue after an enrol, so Settings shows the passkey without a refetch.
    public static let didChange = Notification.Name("PaiPasskeys.didChange")

    private static let client = PaiClient()

    // MARK: Enrolled flag

    /// The credential this phone enrolled, kept per device token: a new sign-in is a new device on the box.
    public static var enrolledCredential: String? {
        guard let key = enrolledKey else { return nil }
        return UserDefaults.standard.string(forKey: key)
    }

    /// Stored instead of a credential id when the passkey prompt said this phone already holds one of the box's passkeys.
    public static let alreadySaved = "already-saved"

    private static var enrolledKey: String? {
        guard let token = PaiAuth.token else { return nil }
        let digest = SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "pai.passkey.\(digest)"
    }

    private static func setEnrolled(_ credential: String?) {
        guard let key = enrolledKey else { return }
        UserDefaults.standard.set(credential, forKey: key)
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    // MARK: Enrol

    /// A ticket the box handed out, with the passkey request it made for it: everything the confirm screen shows
    /// (`options.user.name` = the account) before anything is created.
    public struct PreparedEnrol {
        let options: PasskeyCreationOptions
        let ticket: String
        let verifier: String
        let name: String
        let challenge: Data
        let userID: Data

        public var accountName: String { options.user.name }
    }

    /// Opens the box's sign-in sheet for a ticket, then creates a passkey for it. `invite` = an add-device code from a
    /// device that already has a passkey.
    @MainActor
    public static func enrol(invite: String?) async throws {
        try await finish(try await prepare(invite: invite))
    }

    /// The sign-in sheet for a ticket, then the box's passkey request for it. Creates nothing.
    @MainActor
    public static func prepare(invite: String?) async throws -> PreparedEnrol {
        let verifier = PKCE.makeVerifier()
        let state = PaiPasskeyEnrol.makeState()
        let name = UIDevice.current.name
        guard let url = PaiPasskeyEnrol.url(base: PaiSecrets.baseURL, state: state, challenge: PKCE.challenge(for: verifier), name: name, invite: invite) else {
            throw PaiClientError(message: "Server address is not a valid URL")
        }
        let callback = try PaiPasskeyEnrol.parse(callback: try await PaiWebSheet.run(url: url, callbackScheme: PaiPasskeyEnrol.callbackScheme, cookies: PaiPasskeyEnrol.sheetCookies), expectedState: state)

        let options = try await client.call(PasskeyCreationOptions.self, "/unlock/passkeys/options", method: "POST", body: try PasskeyEnrolOptionsBody(ticket: callback.ticket, codeVerifier: verifier).jsonObject(), keepTokenOn401: true)
        guard let challenge = Base64URL.decode(options.challenge), let userID = Base64URL.decode(options.user.id) else {
            throw PaiClientError(message: "The box sent a malformed passkey request")
        }
        return PreparedEnrol(options: options, ticket: callback.ticket, verifier: verifier, name: name, challenge: challenge, userID: userID)
    }

    /// Face ID creates the passkey for a prepared request, then the box stores it.
    @MainActor
    public static func finish(_ prepared: PreparedEnrol) async throws {
        let options = prepared.options
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: try PaiPasskeyGuard.relyingParty(options.rp.id, pinned: relyingParty))
        let request = provider.createCredentialRegistrationRequest(challenge: prepared.challenge, name: options.user.name, userID: prepared.userID)
        request.displayName = options.user.displayName
        request.userVerificationPreference = .required
        request.attestationPreference = .none
        if #available(iOS 17.4, *) {
            request.excludedCredentials = (options.excludeCredentials ?? []).compactMap(\.idData).map(ASAuthorizationPlatformPublicKeyCredentialDescriptor.init(credentialID:))
        }
        let credential: ASAuthorizationCredential
        do {
            credential = try await PaiPasskeyPrompt.perform(request)
        } catch PaiPasskeyPromptError.matchedExcludedCredential {
            // The box excludes every passkey it holds for this account, so this phone's keychain already has one.
            setEnrolled(alreadySaved)
            return
        }
        guard let registration = credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
            throw PaiClientError(message: "The passkey prompt returned no passkey")
        }
        guard let attestation = registration.rawAttestationObject else { throw PaiClientError(message: "The passkey came without its attestation") }
        let response = PasskeyRegistrationResponse(credentialID: registration.credentialID, clientDataJSON: registration.rawClientDataJSON, attestationObject: attestation)

        struct Row: Decodable { let id: String? }
        _ = try await client.call(Row.self, "/unlock/passkeys", method: "POST", body: try PasskeyEnrolFinishBody(ticket: prepared.ticket, codeVerifier: prepared.verifier, response: response, name: prepared.name).jsonObject(), keepTokenOn401: true)
        setEnrolled(response.id)
    }

    // MARK: Unlock

    public static func state() async throws -> PaiUnlockState {
        try await client.call(PaiUnlockState.self, "/unlock", keepTokenOn401: true)
    }

    /// Signs a fresh challenge and opens the unlock window for `minutes` (the box's default when nil).
    @MainActor
    public static func unlock(minutes: Int?) async throws -> PaiUnlockState {
        let response = try await assert(challengePath: "/unlock/challenge")
        return try await passkeyCall(PaiUnlockState.self, "/unlock", body: PasskeyUnlockBody(minutes: minutes, response: response))
    }

    public static func lock() async throws -> PaiUnlockState {
        try await client.call(PaiUnlockState.self, "/lock", method: "POST", keepTokenOn401: true)
    }

    // MARK: Changes

    public static func change(_ hash: String) async throws -> PaiChange {
        let change = try await client.call(PaiChange.self, "/changes/\(escaped(hash))", keepTokenOn401: true)
        try PaiPasskeyGuard.checkChange(requested: hash, returned: change.hash)
        return change
    }

    @MainActor
    public static func approve(_ hash: String) async throws {
        let response = try await assert(challengePath: "/changes/\(escaped(hash))/challenge")
        _ = try await passkeyCall(JSONValue.self, "/changes/\(escaped(hash))/approve", body: PasskeyApproveBody(response: response))
    }

    /// Denying needs no passkey: the token alone may say no.
    public static func deny(_ hash: String) async throws {
        _ = try await client.call(JSONValue.self, "/changes/\(escaped(hash))/deny", method: "POST", keepTokenOn401: true)
    }

    // MARK: Apple Watch

    /// A watch key pai holds for this phone (`GET /watch-keys`).
    public struct WatchKey: Decodable, Equatable {
        public let id: String
        public let name: String
    }

    private struct WatchKeyOptionsBody: Encodable {
        let publicKey: String
    }

    private struct WatchKeyBody: Encodable {
        let publicKey: String
        let name: String
        let vouch: PasskeyAssertionResponse
    }

    public static func watchKeys() async throws -> [WatchKey] {
        try await client.call([WatchKey].self, "/watch-keys", keepTokenOn401: true)
    }

    /// Adds the paired watch's approval key: the watch hands over its Secure Enclave key's public half, this phone's
    /// passkey signs over exactly that key (Face ID), and pai keeps it bound to this phone. The watch then approves
    /// ordinary change cards by itself.
    @MainActor
    public static func addWatch() async throws {
        let watch = try await PaiGlanceSync.shared.watchKey()
        let vouch = try await assert(challengePath: "/watch-keys/options", body: WatchKeyOptionsBody(publicKey: watch.publicKey))
        _ = try await passkeyCall(WatchKey.self, "/watch-keys", body: WatchKeyBody(publicKey: watch.publicKey, name: watch.name, vouch: vouch))
    }

    // MARK: Signing

    @MainActor
    private static func assert(challengePath: String, body: Encodable? = nil) async throws -> PasskeyAssertionResponse {
        let options = try await passkeyCall(PasskeyRequestOptions.self, challengePath, body: body)
        guard let challenge = Base64URL.decode(options.challenge) else { throw PaiClientError(message: "The box sent a malformed passkey request") }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: try PaiPasskeyGuard.relyingParty(options.rpId, pinned: relyingParty))
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.allowedCredentials = (options.allowCredentials ?? []).compactMap(\.idData).map(ASAuthorizationPlatformPublicKeyCredentialDescriptor.init(credentialID:))
        request.userVerificationPreference = .required
        guard let assertion = try await PaiPasskeyPrompt.perform(request) as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw PaiClientError(message: "The passkey prompt returned no signature")
        }
        return PasskeyAssertionResponse(credentialID: assertion.credentialID, clientDataJSON: assertion.rawClientDataJSON, authenticatorData: assertion.rawAuthenticatorData, signature: assertion.signature, userHandle: assertion.userID)
    }

    /// The box's errors meaning this phone holds no usable passkey.
    private static let notEnrolledPrefixes = ["no passkey on this device", "that passkey is not bound to this device", "that passkey is not enrolled here"]

    /// A POST on a passkey route; the box saying this phone has no usable passkey clears the local flag.
    /// The flag is display-only (the Settings row): signing never reads it, the box decides.
    private static func passkeyCall<T: Decodable>(_ type: T.Type, _ path: String, body: Encodable?) async throws -> T {
        do {
            return try await client.call(type, path, method: "POST", body: try body?.jsonObject(), keepTokenOn401: true)
        } catch let error as PaiClientError where notEnrolledPrefixes.contains(where: { error.message.hasPrefix($0) }) {
            setEnrolled(nil)
            throw error
        }
    }

    private static func escaped(_ hash: String) -> String {
        hash.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? hash
    }
}

enum PaiPasskeyPromptError: Error {
    /// The request excluded a passkey this device already holds.
    case matchedExcludedCredential
}

/// One `ASAuthorizationController` request as an async call.
@available(iOS 16.0, *)
final class PaiPasskeyPrompt: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private static var running: PaiPasskeyPrompt?
    private var continuation: CheckedContinuation<ASAuthorizationCredential, Error>?
    private var controller: ASAuthorizationController?
    private var registering = false

    @MainActor
    static func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorizationCredential {
        try await withCheckedThrowingContinuation { continuation in
            let prompt = PaiPasskeyPrompt()
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = prompt
            controller.presentationContextProvider = prompt
            prompt.controller = controller
            prompt.continuation = continuation
            prompt.registering = request is ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest
            running = prompt
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<ASAuthorizationCredential, Error>) {
        continuation?.resume(with: result)
        continuation = nil
        controller = nil
        PaiPasskeyPrompt.running = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        finish(.success(authorization.credential))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard let error = error as? ASAuthorizationError else {
            finish(.failure(error))
            return
        }
        Logger.shared.log("PaiPasskey", "authorization error \(error.code.rawValue)")
        switch error.code.rawValue {
        case ASAuthorizationError.canceled.rawValue:
            finish(.failure(CancellationError()))
        case 1006: // ASAuthorizationError.matchedExcludedCredential (iOS 18 SDK)
            finish(.failure(PaiPasskeyPromptError.matchedExcludedCredential))
        default:
            finish(.failure(PaiClientError(message: registering ? "Couldn't add passkey. Try again." : "Couldn't use passkey. Try again.")))
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first ?? ASPresentationAnchor()
    }
}

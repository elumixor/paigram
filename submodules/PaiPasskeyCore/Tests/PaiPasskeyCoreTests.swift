import Foundation
import XCTest
@testable import PaiPasskeyCore

final class Base64URLTests: XCTestCase {
    func testEncodeUsesURLAlphabetWithoutPadding() {
        XCTAssertEqual(Base64URL.encode(Data([0xfb, 0xff, 0xfe])), "-__-")
        XCTAssertEqual(Base64URL.encode(Data([0x01])), "AQ")
        XCTAssertEqual(Base64URL.encode(Data([0x01, 0x02])), "AQI")
        XCTAssertEqual(Base64URL.encode(Data()), "")
    }

    func testDecodeAcceptsMissingAndPresentPadding() {
        XCTAssertEqual(Base64URL.decode("AQ"), Data([0x01]))
        XCTAssertEqual(Base64URL.decode("AQ=="), Data([0x01]))
        XCTAssertEqual(Base64URL.decode("AQI"), Data([0x01, 0x02]))
        XCTAssertEqual(Base64URL.decode("-__-"), Data([0xfb, 0xff, 0xfe]))
    }

    func testDecodeRejectsInvalidInput() {
        XCTAssertNil(Base64URL.decode("+/+/"))
        XCTAssertNil(Base64URL.decode("A"))
        XCTAssertNil(Base64URL.decode("AQ I"))
    }

    func testRoundTrip() {
        for length in 0..<64 {
            let data = PKCE.randomBytes(length)
            let encoded = Base64URL.encode(data)
            XCTAssertFalse(encoded.contains("="))
            XCTAssertEqual(Base64URL.decode(encoded), data)
        }
    }
}

final class PKCETests: XCTestCase {
    func testRFC7636AppendixBVector() {
        XCTAssertEqual(
            PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testVerifierIsValidAndChallengeIs43Characters() {
        let verifier = PKCE.makeVerifier()
        XCTAssertEqual(verifier.count, 43)
        XCTAssertTrue(PKCE.isValidVerifier(verifier))
        XCTAssertEqual(PKCE.challenge(for: verifier).count, 43)
        XCTAssertNotEqual(verifier, PKCE.makeVerifier())
    }

    func testVerifierValidation() {
        XCTAssertFalse(PKCE.isValidVerifier(String(repeating: "a", count: 42)))
        XCTAssertTrue(PKCE.isValidVerifier(String(repeating: "a", count: 43)))
        XCTAssertTrue(PKCE.isValidVerifier(String(repeating: "-._~", count: 32)))
        XCTAssertFalse(PKCE.isValidVerifier(String(repeating: "a", count: 129)))
        XCTAssertFalse(PKCE.isValidVerifier(String(repeating: "a", count: 42) + "+"))
    }
}

final class EnrolTests: XCTestCase {
    func testURLCarriesQuery() throws {
        let url = try XCTUnwrap(PaiPasskeyEnrol.url(base: "https://pai.desk.atmagaming.com", state: "st", challenge: "ch", name: "Pai's iPhone", invite: "inv"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "pai.desk.atmagaming.com")
        XCTAssertEqual(components.path, "/link")
        XCTAssertNil(components.fragment)
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items, ["enrol": "1", "state": "st", "code_challenge": "ch", "name": "Pai's iPhone", "invite": "inv"])
    }

    func testURLOmitsEmptyInvite() throws {
        let url = try XCTUnwrap(PaiPasskeyEnrol.url(base: "https://pai.desk.atmagaming.com/", state: "s", challenge: "c", name: "n", invite: nil))
        XCTAssertFalse(url.absoluteString.contains("invite"))
        XCTAssertTrue(url.absoluteString.hasPrefix("https://pai.desk.atmagaming.com/link?"))
    }

    func testCallbackWithMatchingState() throws {
        let url = URL(string: "paigram://pai-auth?ticket=tk&expires=1700000000000&state=abc")!
        let callback = try PaiPasskeyEnrol.parse(callback: url, expectedState: "abc")
        XCTAssertEqual(callback.ticket, "tk")
        XCTAssertEqual(callback.expires, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testCallbackRejectsWrongState() {
        let url = URL(string: "paigram://pai-auth?ticket=tk&state=other")!
        XCTAssertThrowsError(try PaiPasskeyEnrol.parse(callback: url, expectedState: "abc")) {
            XCTAssertEqual($0 as? PaiPasskeyEnrolError, .stateMismatch)
        }
        let missing = URL(string: "paigram://pai-auth?ticket=tk")!
        XCTAssertThrowsError(try PaiPasskeyEnrol.parse(callback: missing, expectedState: "abc")) {
            XCTAssertEqual($0 as? PaiPasskeyEnrolError, .stateMismatch)
        }
    }

    func testCallbackRejectsWrongHostAndMissingTicket() {
        XCTAssertThrowsError(try PaiPasskeyEnrol.parse(callback: URL(string: "paigram://other?ticket=tk&state=abc")!, expectedState: "abc")) {
            XCTAssertEqual($0 as? PaiPasskeyEnrolError, .wrongCallback)
        }
        XCTAssertThrowsError(try PaiPasskeyEnrol.parse(callback: URL(string: "https://pai-auth?ticket=tk&state=abc")!, expectedState: "abc")) {
            XCTAssertEqual($0 as? PaiPasskeyEnrolError, .wrongCallback)
        }
        XCTAssertThrowsError(try PaiPasskeyEnrol.parse(callback: URL(string: "paigram://pai-auth?state=abc&ticket=")!, expectedState: "abc")) {
            XCTAssertEqual($0 as? PaiPasskeyEnrolError, .missingTicket)
        }
    }

    func testStateIsRandom() {
        XCTAssertNotEqual(PaiPasskeyEnrol.makeState(), PaiPasskeyEnrol.makeState())
        XCTAssertGreaterThanOrEqual(PaiPasskeyEnrol.makeState().count, 22)
    }
}

final class JSONShapeTests: XCTestCase {
    private func object(_ value: Encodable) throws -> NSDictionary {
        try XCTUnwrap(try value.jsonObject() as? NSDictionary)
    }

    func testRegistrationResponseShape() throws {
        let response = PasskeyRegistrationResponse(credentialID: Data([1, 2, 3]), clientDataJSON: Data("{}".utf8), attestationObject: Data([0xff]))
        let expected: NSDictionary = [
            "id": "AQID",
            "rawId": "AQID",
            "type": "public-key",
            "response": ["clientDataJSON": "e30", "attestationObject": "_w", "transports": ["internal", "hybrid"]],
            "clientExtensionResults": [String: Any](),
        ]
        XCTAssertEqual(try object(response), expected)
    }

    func testAssertionResponseShape() throws {
        let response = PasskeyAssertionResponse(credentialID: Data([1, 2, 3]), clientDataJSON: Data("{}".utf8), authenticatorData: Data([0xfb]), signature: Data([0x00, 0x01]), userHandle: Data([0x07]))
        let expected: NSDictionary = [
            "id": "AQID",
            "rawId": "AQID",
            "type": "public-key",
            "response": ["clientDataJSON": "e30", "authenticatorData": "-w", "signature": "AAE", "userHandle": "Bw"],
            "clientExtensionResults": [String: Any](),
        ]
        XCTAssertEqual(try object(response), expected)
    }

    func testBodiesUseSnakeCaseKeys() throws {
        let registration = PasskeyRegistrationResponse(credentialID: Data([1]), clientDataJSON: Data([2]), attestationObject: Data([3]))
        XCTAssertEqual(try object(PasskeyEnrolOptionsBody(ticket: "t", codeVerifier: "v")), ["ticket": "t", "code_verifier": "v"])
        let finish = try object(PasskeyEnrolFinishBody(ticket: "t", codeVerifier: "v", response: registration, name: "iPhone"))
        XCTAssertEqual(Set(finish.allKeys as! [String]), ["ticket", "code_verifier", "response", "name"])
        XCTAssertEqual(finish["code_verifier"] as? String, "v")

        let assertion = PasskeyAssertionResponse(credentialID: Data([1]), clientDataJSON: Data([2]), authenticatorData: Data([3]), signature: Data([4]), userHandle: nil)
        let unlock = try object(PasskeyUnlockBody(minutes: 60, response: assertion))
        XCTAssertEqual(unlock["minutes"] as? Int, 60)
        XCTAssertNotNil(unlock["response"] as? NSDictionary)
        let unlockNoMinutes = try object(PasskeyUnlockBody(minutes: nil, response: assertion))
        XCTAssertNil(unlockNoMinutes["minutes"])
        XCTAssertEqual(Set(try object(PasskeyApproveBody(response: assertion)).allKeys as! [String]), ["response"])
    }

    func testDecodesCreationOptions() throws {
        let json = """
        {"challenge":"Y2hhbGxlbmdl","rp":{"name":"pai","id":"pai.desk.atmagaming.com"},
         "user":{"id":"dXNlcg","name":"pai","displayName":"pai"},
         "pubKeyCredParams":[{"type":"public-key","alg":-7},{"type":"public-key","alg":-257}],
         "timeout":60000,"attestation":"none",
         "excludeCredentials":[{"id":"AQID","type":"public-key","transports":["internal"]}],
         "authenticatorSelection":{"residentKey":"required","userVerification":"required"},
         "extensions":{"credProps":true},"hints":[]}
        """
        let options = try JSONDecoder().decode(PasskeyCreationOptions.self, from: Data(json.utf8))
        XCTAssertEqual(options.rp.id, "pai.desk.atmagaming.com")
        XCTAssertEqual(Base64URL.decode(options.challenge), Data("challenge".utf8))
        XCTAssertEqual(Base64URL.decode(options.user.id), Data("user".utf8))
        XCTAssertEqual(options.excludeCredentials?.first?.idData, Data([1, 2, 3]))
        XCTAssertEqual(options.pubKeyCredParams?.map(\.alg), [-7, -257])
    }

    func testDecodesRequestOptions() throws {
        let json = """
        {"challenge":"Y2hhbGxlbmdl","rpId":"pai.desk.atmagaming.com","timeout":60000,
         "allowCredentials":[{"id":"AQID","type":"public-key"}],"userVerification":"required"}
        """
        let options = try JSONDecoder().decode(PasskeyRequestOptions.self, from: Data(json.utf8))
        XCTAssertEqual(options.rpId, "pai.desk.atmagaming.com")
        XCTAssertEqual(options.allowCredentials?.first?.idData, Data([1, 2, 3]))
        XCTAssertEqual(options.userVerification, "required")

        let minimal = try JSONDecoder().decode(PasskeyRequestOptions.self, from: Data(#"{"challenge":"AQ"}"#.utf8))
        XCTAssertNil(minimal.allowCredentials)
    }

    func testDecodesUnlockState() throws {
        let state = try JSONDecoder().decode(PaiUnlockState.self, from: Data(#"{"unlocked":true,"until":1700000000000,"by":"iPhone","machines":["box"],"paused":false,"passkeys":1}"#.utf8))
        XCTAssertTrue(state.unlocked)
        XCTAssertEqual(state.untilDate, Date(timeIntervalSince1970: 1_700_000_000))
        let locked = try JSONDecoder().decode(PaiUnlockState.self, from: Data(#"{"unlocked":false,"until":null,"by":null,"machines":[],"paused":false,"passkeys":0}"#.utf8))
        XCTAssertNil(locked.untilDate)
    }
}

final class GuardTests: XCTestCase {
    let pinned = "pai.desk.atmagaming.com"

    func testRelyingPartyAcceptsPinnedOrMissing() throws {
        XCTAssertEqual(try PaiPasskeyGuard.relyingParty(pinned, pinned: pinned), pinned)
        XCTAssertEqual(try PaiPasskeyGuard.relyingParty(nil, pinned: pinned), pinned)
    }

    func testRelyingPartyRefusesOtherIds() {
        for sent in ["evil.example.com", "desk.atmagaming.com", "PAI.desk.atmagaming.com", "pai.desk.atmagaming.com.evil.com", ""] {
            XCTAssertThrowsError(try PaiPasskeyGuard.relyingParty(sent, pinned: pinned)) { error in
                XCTAssertEqual(error as? PaiPasskeyGuardError, .wrongRelyingParty(sent))
            }
        }
    }

    func testChangeHashMustMatch() {
        XCTAssertNoThrow(try PaiPasskeyGuard.checkChange(requested: "abc123", returned: "abc123"))
        XCTAssertThrowsError(try PaiPasskeyGuard.checkChange(requested: "abc123", returned: "def456")) { error in
            XCTAssertEqual(error as? PaiPasskeyGuardError, .wrongChange(requested: "abc123", returned: "def456"))
        }
    }
}

final class ChangeFormatTests: XCTestCase {
    func testStringShownRaw() {
        XCTAssertEqual(PaiChangeFormat.text("Send invoice to https://x.com/a"), "Send invoice to https://x.com/a")
    }

    func testObjectIsPrettySortedWithoutEscapedSlashes() {
        let text = PaiChangeFormat.text(["to": "a@b.com", "amount": "10", "url": "https://x.com/p"])
        XCTAssertEqual(text, "{\n  \"amount\" : \"10\",\n  \"to\" : \"a@b.com\",\n  \"url\" : \"https://x.com/p\"\n}")
    }

    func testNullIsNil() {
        XCTAssertNil(PaiChangeFormat.text(String?.none))
    }

    let inviteHost = "pai.desk.atmagaming.com"
    let inviteCode = "Qx3v_9-AbCdEfGhIjKlMnOpQrStUvWx"

    func testInviteFromWebQR() {
        let code = "Qx3v_9-AbCdEfGhIjKlMnOpQrStUvWx"
        XCTAssertEqual(PaiPasskeyEnrol.invite(fromScanned: "https://pai.desk.atmagaming.com/settings/account?enrol=\(code)", host: inviteHost), code)
    }

    func testInviteBareCode() {
        XCTAssertEqual(PaiPasskeyEnrol.invite(fromScanned: "  Qx3v_9-AbCdEfGhIjKlMnOpQrStUvWx\n", host: inviteHost), "Qx3v_9-AbCdEfGhIjKlMnOpQrStUvWx")
    }

    func testInviteJunkIsNil() {
        XCTAssertNil(PaiPasskeyEnrol.invite(fromScanned: "hello world", host: inviteHost))
        XCTAssertNil(PaiPasskeyEnrol.invite(fromScanned: "https://example.com/?q=1", host: inviteHost))
        XCTAssertNil(PaiPasskeyEnrol.invite(fromScanned: "https://pai.desk.atmagaming.com/link?enrol=1", host: inviteHost))
        XCTAssertNil(PaiPasskeyEnrol.invite(fromScanned: "", host: inviteHost))
    }

    func testInviteRefusesForeignHost() {
        for text in [
            "https://example.com/settings/account?enrol=\(inviteCode)",
            "https://pai.desk.atmagaming.com.evil.com/settings/account?enrol=\(inviteCode)",
            "https://evil.com/?enrol=\(inviteCode)",
            "https://desk.atmagaming.com/settings/account?enrol=\(inviteCode)",
        ] {
            XCTAssertNil(PaiPasskeyEnrol.invite(fromScanned: text, host: inviteHost), text)
        }
    }

    func testInviteRefusesHttp() {
        for text in [
            "http://pai.desk.atmagaming.com/settings/account?enrol=\(inviteCode)",
            "paigram://pai.desk.atmagaming.com/settings/account?enrol=\(inviteCode)",
            "HTTPS://pai.desk.atmagaming.com/settings/account?enrol=\(inviteCode)",
        ] {
            XCTAssertNil(PaiPasskeyEnrol.invite(fromScanned: text, host: inviteHost), text)
        }
    }

    func testInviteRefusesUserinfoOrPort() {
        for text in [
            "https://evil.com@pai.desk.atmagaming.com/settings/account?enrol=\(inviteCode)",
            "https://user:pass@pai.desk.atmagaming.com/settings/account?enrol=\(inviteCode)",
            "https://pai.desk.atmagaming.com:8443/settings/account?enrol=\(inviteCode)",
            "https://pai.desk.atmagaming.com:443/settings/account?enrol=\(inviteCode)",
            "https://pai.desk.atmagaming.com/settings/other?enrol=\(inviteCode)",
        ] {
            XCTAssertNil(PaiPasskeyEnrol.invite(fromScanned: text, host: inviteHost), text)
        }
    }
}

final class InviteFlowTests: XCTestCase {
    private func confirming(_ name: String = "me@x.com") -> PaiInviteFlow {
        var flow = PaiInviteFlow()
        flow.handle(.scanned(code: "abc"))
        flow.handle(.prepared(accountName: name))
        return flow
    }

    func testScanPreparesThenConfirmsWithTrimmedAccount() {
        var flow = PaiInviteFlow()
        XCTAssertTrue(flow.handle(.scanned(code: "abc")))
        XCTAssertEqual(flow.state, .preparing(code: "abc"))
        XCTAssertTrue(flow.handle(.prepared(accountName: "  me@x.com ")))
        XCTAssertEqual(flow.state, .confirming(account: "me@x.com"))
    }

    func testAddPasskeyEnrols() {
        var flow = confirming()
        XCTAssertTrue(flow.handle(.confirm))
        XCTAssertEqual(flow.state, .enrolling)
    }

    func testCancelClosesFromEveryStepBeforeEnrol() {
        var scanning = PaiInviteFlow()
        XCTAssertTrue(scanning.handle(.cancel))
        XCTAssertEqual(scanning.state, .closed)
        var preparing = PaiInviteFlow()
        preparing.handle(.scanned(code: "abc"))
        XCTAssertTrue(preparing.handle(.cancel))
        XCTAssertEqual(preparing.state, .closed)
        var flow = confirming()
        XCTAssertTrue(flow.handle(.cancel))
        XCTAssertEqual(flow.state, .closed)
    }

    func testSecondScanWhileConfirmingIsIgnored() {
        var flow = confirming()
        XCTAssertFalse(flow.handle(.scanned(code: "other")))
        XCTAssertEqual(flow.state, .confirming(account: "me@x.com"))
    }

    func testFailureAndBackReturnToScanning() {
        var flow = PaiInviteFlow()
        flow.handle(.scanned(code: "abc"))
        XCTAssertTrue(flow.handle(.failed))
        XCTAssertEqual(flow.state, .scanning)
        var back = confirming()
        XCTAssertTrue(back.handle(.back))
        XCTAssertEqual(back.state, .scanning)
    }

    func testEmptyNameFallsBack() {
        XCTAssertEqual(confirming("  ").state, .confirming(account: PaiInviteFlow.fallbackAccount))
    }

    func testNothingLeavesClosedOrEnrolling() {
        var flow = confirming()
        flow.handle(.cancel)
        XCTAssertFalse(flow.handle(.confirm))
        XCTAssertFalse(flow.handle(.scanned(code: "abc")))
        var enrolling = confirming()
        enrolling.handle(.confirm)
        XCTAssertFalse(enrolling.handle(.cancel))
        XCTAssertEqual(enrolling.state, .enrolling)
    }
}

final class PaiWebSheetCookiesTests: XCTestCase {
    /// An enrol sheet on Safari's cookies reuses an old sign-in, which the box refuses for a ticket: the page then
    /// loops through the suite's sign-in and never returns one.
    func testEnrolSheetStartsWithoutSafariCookies() {
        XCTAssertEqual(PaiPasskeyEnrol.sheetCookies, .fresh)
        XCTAssertTrue(PaiPasskeyEnrol.sheetCookies.prefersEphemeralSession)
    }

    func testSharedSheetKeepsSafariCookies() {
        XCTAssertFalse(PaiWebSheetCookies.shared.prefersEphemeralSession)
    }
}

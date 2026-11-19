import Foundation

/// A credential pai already knows (`excludeCredentials` / `allowCredentials`).
public struct PasskeyDescriptor: Codable, Equatable {
    public let id: String
    public let type: String?
    public let transports: [String]?

    public init(id: String, type: String? = "public-key", transports: [String]? = nil) {
        self.id = id
        self.type = type
        self.transports = transports
    }

    public var idData: Data? { Base64URL.decode(id) }
}

/// `PublicKeyCredentialCreationOptionsJSON` as pai sends it.
public struct PasskeyCreationOptions: Codable, Equatable {
    public struct RelyingParty: Codable, Equatable {
        public let name: String?
        public let id: String?
    }

    public struct User: Codable, Equatable {
        public let id: String
        public let name: String
        public let displayName: String?
    }

    public struct Param: Codable, Equatable {
        public let type: String
        public let alg: Int
    }

    public let challenge: String
    public let rp: RelyingParty
    public let user: User
    public let pubKeyCredParams: [Param]?
    public let excludeCredentials: [PasskeyDescriptor]?
    public let attestation: String?
    public let timeout: Double?
}

/// `PublicKeyCredentialRequestOptionsJSON` as pai sends it.
public struct PasskeyRequestOptions: Codable, Equatable {
    public let challenge: String
    public let rpId: String?
    public let timeout: Double?
    public let allowCredentials: [PasskeyDescriptor]?
    public let userVerification: String?
}

public struct PasskeyClientExtensionResults: Codable, Equatable {
    public init() {}
}

/// `RegistrationResponseJSON`: what the app posts after creating a credential.
public struct PasskeyRegistrationResponse: Codable, Equatable {
    public struct Body: Codable, Equatable {
        public let clientDataJSON: String
        public let attestationObject: String
        public let transports: [String]
    }

    public let id: String
    public let rawId: String
    public let type: String
    public let response: Body
    public let clientExtensionResults: PasskeyClientExtensionResults

    public init(credentialID: Data, clientDataJSON: Data, attestationObject: Data) {
        let id = Base64URL.encode(credentialID)
        self.id = id
        self.rawId = id
        self.type = "public-key"
        self.response = Body(
            clientDataJSON: Base64URL.encode(clientDataJSON),
            attestationObject: Base64URL.encode(attestationObject),
            transports: ["internal", "hybrid"]
        )
        self.clientExtensionResults = PasskeyClientExtensionResults()
    }
}

/// `AuthenticationResponseJSON`: what the app posts after signing a challenge.
public struct PasskeyAssertionResponse: Codable, Equatable {
    public struct Body: Codable, Equatable {
        public let clientDataJSON: String
        public let authenticatorData: String
        public let signature: String
        public let userHandle: String?
    }

    public let id: String
    public let rawId: String
    public let type: String
    public let response: Body
    public let clientExtensionResults: PasskeyClientExtensionResults

    public init(credentialID: Data, clientDataJSON: Data, authenticatorData: Data, signature: Data, userHandle: Data?) {
        let id = Base64URL.encode(credentialID)
        self.id = id
        self.rawId = id
        self.type = "public-key"
        self.response = Body(
            clientDataJSON: Base64URL.encode(clientDataJSON),
            authenticatorData: Base64URL.encode(authenticatorData),
            signature: Base64URL.encode(signature),
            userHandle: userHandle.map(Base64URL.encode)
        )
        self.clientExtensionResults = PasskeyClientExtensionResults()
    }
}

// MARK: Request bodies

public struct PasskeyEnrolOptionsBody: Codable, Equatable {
    public let ticket: String
    public let codeVerifier: String

    public init(ticket: String, codeVerifier: String) {
        self.ticket = ticket
        self.codeVerifier = codeVerifier
    }

    enum CodingKeys: String, CodingKey {
        case ticket
        case codeVerifier = "code_verifier"
    }
}

public struct PasskeyEnrolFinishBody: Codable, Equatable {
    public let ticket: String
    public let codeVerifier: String
    public let response: PasskeyRegistrationResponse
    public let name: String

    public init(ticket: String, codeVerifier: String, response: PasskeyRegistrationResponse, name: String) {
        self.ticket = ticket
        self.codeVerifier = codeVerifier
        self.response = response
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case ticket
        case codeVerifier = "code_verifier"
        case response
        case name
    }
}

public struct PasskeyUnlockBody: Codable, Equatable {
    public let minutes: Int?
    public let response: PasskeyAssertionResponse

    public init(minutes: Int?, response: PasskeyAssertionResponse) {
        self.minutes = minutes
        self.response = response
    }
}

public struct PasskeyApproveBody: Codable, Equatable {
    public let response: PasskeyAssertionResponse

    public init(response: PasskeyAssertionResponse) {
        self.response = response
    }
}

/// `GET /unlock`, `POST /unlock`, `POST /lock`.
public struct PaiUnlockState: Codable, Equatable {
    public let unlocked: Bool
    /// Epoch milliseconds.
    public let until: Double?
    public let by: String?
    public let machines: [String]?
    public let paused: Bool?
    public let passkeys: Int?

    public var untilDate: Date? { until.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

public extension Encodable {
    /// The value as a `JSONSerialization` object, for clients that take `Any` bodies.
    func jsonObject() throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(self))
    }
}

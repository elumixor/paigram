import Foundation

/// A saved place as `GET /places` returns it.
public struct PaiPlace: Codable, Equatable {
    public let id: String
    public let name: String
    public let lat: Double
    public let lon: Double
    public let radius_m: Double
    public let ssids: [String]?
    public let bssids: [String]?

    public init(id: String, name: String, lat: Double, lon: Double, radius_m: Double, ssids: [String]? = nil, bssids: [String]? = nil) {
        self.id = id
        self.name = name
        self.lat = lat
        self.lon = lon
        self.radius_m = radius_m
        self.ssids = ssids
        self.bssids = bssids
    }
}

public struct PaiPlacesResponse: Decodable {
    public let places: [PaiPlace]
}

/// A geofence as Core Location keeps it, reduced to what the sync compares.
public struct PaiPlaceRegion: Equatable, Hashable {
    public static let prefix = "pai.place."

    public let identifier: String
    public let lat: Double
    public let lon: Double
    public let radius: Double

    public init(identifier: String, lat: Double, lon: Double, radius: Double) {
        self.identifier = identifier
        self.lat = lat
        self.lon = lon
        self.radius = radius
    }

    /// The place id a Paigram region stands for, nil for any other app region.
    public var placeId: String? { Self.placeId(identifier) }

    public static func placeId(_ identifier: String) -> String? {
        identifier.hasPrefix(prefix) ? String(identifier.dropFirst(prefix.count)) : nil
    }

    public static func identifier(for placeId: String) -> String { prefix + placeId }

    /// Same fence: coordinates within ~1 m and radius within 1 m (Core Location rounds what it stores).
    func sameFence(as other: PaiPlaceRegion) -> Bool {
        identifier == other.identifier && abs(lat - other.lat) < 0.00001 && abs(lon - other.lon) < 0.00001 && abs(radius - other.radius) < 1
    }
}

public struct PaiPlacesDiff: Equatable {
    public var add: [PaiPlaceRegion]
    public var remove: [String]
}

/// Which regions to start and stop so Core Location watches the places nearest to `location` (all of them when
/// they fit), at most `limit` in total counting regions other code of the app monitors.
public enum PaiPlacesSync {
    public static let regionLimit = 20
    /// Below ~100 m iOS fires late or not at all.
    public static let minimumRadius: Double = 100

    public static func desired(places: [PaiPlace], location: (lat: Double, lon: Double)?, limit: Int, maximumRadius: Double) -> [PaiPlaceRegion] {
        var ordered = places
        if let location {
            ordered = places.enumerated().sorted { a, b in
                let da = distance(location, (a.element.lat, a.element.lon)), db = distance(location, (b.element.lat, b.element.lon))
                return da == db ? a.offset < b.offset : da < db
            }.map { $0.element }
        }
        var seen = Set<String>()
        return ordered.filter { seen.insert($0.id).inserted }.prefix(max(0, limit)).map {
            PaiPlaceRegion(identifier: PaiPlaceRegion.identifier(for: $0.id), lat: $0.lat, lon: $0.lon, radius: min(max($0.radius_m, minimumRadius), maximumRadius))
        }
    }

    /// `monitored` is every region Core Location holds for the app; only `pai.place.` ones are touched.
    public static func diff(places: [PaiPlace], monitored: [PaiPlaceRegion], location: (lat: Double, lon: Double)?, maximumRadius: Double = 200_000, limit: Int = regionLimit) -> PaiPlacesDiff {
        let ours = monitored.filter { $0.placeId != nil }
        let foreign = monitored.count - ours.count
        let want = desired(places: places, location: location, limit: limit - foreign, maximumRadius: maximumRadius)
        let remove = ours.filter { have in !want.contains { $0.sameFence(as: have) } }.map(\.identifier)
        let add = want.filter { w in !ours.contains { $0.sameFence(as: w) } }
        return PaiPlacesDiff(add: add, remove: remove)
    }

    /// Great-circle distance in metres.
    static func distance(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Double {
        let r = 6_371_000.0, rad = Double.pi / 180
        let dLat = (b.lat - a.lat) * rad, dLon = (b.lon - a.lon) * rad
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.lat * rad) * cos(b.lat * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}

/// One call to pai's places API, before auth and base URL are applied.
public struct PaiPlacesRequest: Equatable {
    public let method: String
    public let path: String
    public let body: [String: String]?

    public static let places = PaiPlacesRequest(method: "GET", path: "/places", body: nil)

    public static func arrived(place: String, at: Date) -> PaiPlacesRequest {
        PaiPlacesRequest(method: "POST", path: "/location/arrived", body: ["place": place, "at": iso(at)])
    }

    public static func left(place: String, at: Date) -> PaiPlacesRequest {
        PaiPlacesRequest(method: "POST", path: "/location/left", body: ["place": place, "at": iso(at)])
    }

    /// No network (or not on Wi-Fi) sends only the source: the box reads that as off every known Wi-Fi.
    public static func wifi(ssid: String?, bssid: String?) -> PaiPlacesRequest {
        var body = ["source": "paigram"]
        if let ssid, !ssid.isEmpty { body["ssid"] = ssid }
        if let bssid, !bssid.isEmpty { body["bssid"] = bssid }
        return PaiPlacesRequest(method: "POST", path: "/location/wifi", body: body)
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

public struct PaiPlacesHTTPError: Error {
    public let status: Int
}

/// Sends a request to the box and answers its body; throws `PaiPlacesHTTPError` for a non-2xx answer.
public typealias PaiPlacesTransport = (PaiPlacesRequest) async throws -> Data

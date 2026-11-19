import XCTest
@testable import PaiPlaces

final class PaiPlacesSyncTests: XCTestCase {
    private func place(_ id: String, _ lat: Double, _ lon: Double, radius: Double = 150) -> PaiPlace {
        PaiPlace(id: id, name: id, lat: lat, lon: lon, radius_m: radius)
    }

    private func region(_ id: String, _ lat: Double, _ lon: Double, radius: Double = 150) -> PaiPlaceRegion {
        PaiPlaceRegion(identifier: PaiPlaceRegion.identifier(for: id), lat: lat, lon: lon, radius: radius)
    }

    func testAddsNewPlacesAndRemovesStale() {
        let diff = PaiPlacesSync.diff(
            places: [place("office", 50, 14), place("gym", 50.1, 14.1)],
            monitored: [region("office", 50, 14), region("old", 51, 15)],
            location: nil
        )
        XCTAssertEqual(diff.add, [region("gym", 50.1, 14.1)])
        XCTAssertEqual(diff.remove, ["pai.place.old"])
    }

    func testUnchangedPlacesAreLeftAlone() {
        let diff = PaiPlacesSync.diff(places: [place("office", 50, 14)], monitored: [region("office", 50.000001, 14, radius: 150.4)], location: nil)
        XCTAssertEqual(diff, PaiPlacesDiff(add: [], remove: []))
    }

    func testMovedPlaceIsReplaced() {
        let diff = PaiPlacesSync.diff(places: [place("office", 50, 14, radius: 300)], monitored: [region("office", 50, 14)], location: nil)
        XCTAssertEqual(diff.remove, ["pai.place.office"])
        XCTAssertEqual(diff.add, [region("office", 50, 14, radius: 300)])
    }

    func testForeignRegionsAreKeptAndCountTowardTheLimit() {
        let foreign = PaiPlaceRegion(identifier: "other.app.region", lat: 0, lon: 0, radius: 100)
        let places = (0..<25).map { place("p\($0)", 50 + Double($0) * 0.01, 14) }
        let diff = PaiPlacesSync.diff(places: places, monitored: [foreign], location: nil)
        XCTAssertEqual(diff.add.count, 19)
        XCTAssertFalse(diff.remove.contains("other.app.region"))
    }

    func testLimitKeepsNearestFirst() {
        let places = (0..<25).map { place("p\($0)", 50 + Double($0) * 0.01, 14) }
        let diff = PaiPlacesSync.diff(places: places, monitored: [], location: (lat: 50.24, lon: 14))
        XCTAssertEqual(diff.add.count, 20)
        XCTAssertEqual(diff.add.first?.placeId, "p24")
        XCTAssertFalse(diff.add.contains { $0.placeId == "p0" })
        XCTAssertTrue(diff.add.contains { $0.placeId == "p5" })
    }

    func testLimitDropsFarRegionAlreadyMonitored() {
        let places = (0..<21).map { place("p\($0)", 50 + Double($0) * 0.01, 14) }
        let monitored = (0..<20).map { region("p\($0)", 50 + Double($0) * 0.01, 14) }
        let diff = PaiPlacesSync.diff(places: places, monitored: monitored, location: (lat: 50.2, lon: 14))
        XCTAssertEqual(diff.add.map(\.identifier), ["pai.place.p20"])
        XCTAssertEqual(diff.remove, ["pai.place.p0"])
    }

    func testRadiusIsClamped() {
        let diff = PaiPlacesSync.diff(places: [place("a", 50, 14, radius: 20), place("b", 51, 14, radius: 900)], monitored: [], location: nil, maximumRadius: 500)
        XCTAssertEqual(diff.add.map(\.radius), [100, 500])
    }

    func testDisabledEmptyListRemovesAllOurs() {
        let diff = PaiPlacesSync.diff(places: [], monitored: [region("a", 1, 1), PaiPlaceRegion(identifier: "x", lat: 0, lon: 0, radius: 1)], location: nil)
        XCTAssertEqual(diff.remove, ["pai.place.a"])
        XCTAssertTrue(diff.add.isEmpty)
    }
}

final class PaiPlacesRequestTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_800_000_000.5)

    func testPlacesListRequest() {
        XCTAssertEqual(PaiPlacesRequest.places, PaiPlacesRequest(method: "GET", path: "/places", body: nil))
    }

    func testArrivedAndLeft() {
        XCTAssertEqual(PaiPlacesRequest.arrived(place: "office", at: at), PaiPlacesRequest(method: "POST", path: "/location/arrived", body: ["place": "office", "at": "2027-01-15T08:00:00.500Z"]))
        XCTAssertEqual(PaiPlacesRequest.left(place: "office", at: at).path, "/location/left")
        XCTAssertEqual(PaiPlacesRequest.left(place: "office", at: at).body?["place"], "office")
    }

    func testWifiWithNetwork() {
        XCTAssertEqual(PaiPlacesRequest.wifi(ssid: "ATMA", bssid: "aa:bb:cc:dd:ee:ff").body, ["source": "paigram", "ssid": "ATMA", "bssid": "aa:bb:cc:dd:ee:ff"])
    }

    func testWifiWithoutNetworkSendsOnlySource() {
        XCTAssertEqual(PaiPlacesRequest.wifi(ssid: nil, bssid: "").body, ["source": "paigram"])
    }

    func testMockTransportReceivesRequests() async throws {
        var sent: [PaiPlacesRequest] = []
        let transport: PaiPlacesTransport = { request in
            sent.append(request)
            return Data(#"{"places":[{"id":"office","name":"Office","lat":50,"lon":14,"radius_m":150,"ssids":["ATMA"]}]}"#.utf8)
        }
        let data = try await transport(.places)
        let places = try JSONDecoder().decode(PaiPlacesResponse.self, from: data).places
        XCTAssertEqual(places, [PaiPlace(id: "office", name: "Office", lat: 50, lon: 14, radius_m: 150, ssids: ["ATMA"])])
        XCTAssertEqual(sent, [.places])
    }
}

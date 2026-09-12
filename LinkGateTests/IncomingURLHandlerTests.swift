import XCTest
@testable import LinkGate

final class IncomingURLHandlerTests: XCTestCase {
    func testAcceptsHTTPAndHTTPSSchemesCaseInsensitively() {
        let destination = RecordingDestination()
        let handler = IncomingURLHandler(destination: destination)
        let httpURL = URL(string: "HTTP://example.com/path")!
        let httpsURL = URL(string: "hTtPs://example.com/secure")!

        XCTAssertTrue(handler.handleIncomingURL(httpURL))
        XCTAssertTrue(handler.handleIncomingURL(httpsURL))
        XCTAssertEqual(destination.receivedURLs, [httpURL, httpsURL])
    }

    func testRejectsUnsupportedAndMissingSchemesWithoutDispatching() {
        let destination = RecordingDestination()
        let handler = IncomingURLHandler(destination: destination)
        let unsupportedURLs = [
            URL(string: "mailto:person@example.com")!,
            URL(string: "ssh://example.com/repository.git")!,
            URL(string: "ftp://example.com/file.txt")!,
            URL(string: "linkgate-test://example.com/item")!,
            URL(string: "/relative/path")!,
        ]

        for url in unsupportedURLs {
            XCTAssertFalse(handler.handleIncomingURL(url), "Expected \(url.absoluteString) to be rejected")
        }

        XCTAssertTrue(destination.receivedURLs.isEmpty)
    }

    func testDispatchesComplexAcceptedURLWithoutChangingItsRepresentation() {
        let destination = RecordingDestination()
        let handler = IncomingURLHandler(destination: destination)
        let expectedURLString = "https://example.com:8443/a%20path/%E2%9C%93?first=one%20two&encoded=%2Fvalue#section%20two"
        let incomingURL = URL(string: expectedURLString)!

        XCTAssertEqual(incomingURL.absoluteString, expectedURLString)
        XCTAssertTrue(handler.handleIncomingURL(incomingURL))
        XCTAssertEqual(destination.receivedURLs, [incomingURL])
        XCTAssertEqual(destination.receivedURLs.first?.absoluteString, expectedURLString)
    }

    func testDispatchesURLIntegrityMatrixWithoutReconstructingAcceptedURLs() {
        let destination = RecordingDestination()
        let handler = IncomingURLHandler(destination: destination)
        let incomingURLs = [
            URL(string: "https://example.com/search?tag=one&tag=two&escaped=%2f%2F&space=%20#fragment%20part")!,
            URL(string: "https://[2001:db8::1]:8443/a%2Fb?key=one&key=two#part")!,
            URL(string: "https://example.com/über/東京?label=naïve&emoji=😀#é")!,
            URL(string: "https://example.com/" + String(repeating: "path%20segment/", count: 80) + "final?first=one&second=two#fragment")!,
        ]

        for incomingURL in incomingURLs {
            let expectedAbsoluteString = incomingURL.absoluteString

            XCTAssertTrue(handler.handleIncomingURL(incomingURL))
            XCTAssertEqual(destination.receivedURLs.last?.absoluteString, expectedAbsoluteString)
        }

        XCTAssertEqual(destination.receivedURLs.map(\.absoluteString), incomingURLs.map(\.absoluteString))
    }

    func testDispatchesEachSequentialAcceptedEventInDeliveryOrder() {
        let destination = RecordingDestination()
        let handler = IncomingURLHandler(destination: destination)
        let firstURL = URL(string: "https://example.com/first")!
        let secondURL = URL(string: "http://example.com/second?query=value")!
        let thirdURL = URL(string: "https://example.com/third#fragment")!

        XCTAssertTrue(handler.handleIncomingURL(firstURL))
        XCTAssertTrue(handler.handleIncomingURL(secondURL))
        XCTAssertTrue(handler.handleIncomingURL(thirdURL))

        XCTAssertEqual(destination.receivedURLs, [firstURL, secondURL, thirdURL])
    }

}

private final class RecordingDestination: IncomingURLReceiving {
    private(set) var receivedURLs: [URL] = []

    func receiveIncomingURL(_ url: URL) {
        receivedURLs.append(url)
    }
}

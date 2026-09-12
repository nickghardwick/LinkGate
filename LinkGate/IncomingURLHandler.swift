import Foundation

protocol IncomingURLReceiving: AnyObject {
    func receiveIncomingURL(_ url: URL)
}

final class IncomingURLHandler {
    private let destination: any IncomingURLReceiving

    init(destination: any IncomingURLReceiving) {
        self.destination = destination
    }

    @discardableResult
    func handleIncomingURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }

        destination.receiveIncomingURL(url)
        return true
    }
}

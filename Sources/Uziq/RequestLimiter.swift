import Foundation

/// Reserves request start times across every client instance for a provider.
/// Reserving before sleeping prevents concurrent callers from waking together.
actor RequestLimiter {
    private let minimumInterval: Duration
    private let clock = ContinuousClock()
    private var nextRequestTime: ContinuousClock.Instant?

    init(minimumInterval: Duration) {
        self.minimumInterval = minimumInterval
    }

    func waitForTurn() async throws {
        let now = clock.now
        let requestTime = max(now, nextRequestTime ?? now)
        nextRequestTime = requestTime.advanced(by: minimumInterval)
        if requestTime > now {
            try await clock.sleep(until: requestTime)
        }
        try Task.checkCancellation()
    }
}

enum ProviderRequestLimiters {
    // MusicBrainz requires clients to remain at or below one request per second.
    static let musicBrainz = RequestLimiter(minimumInterval: .seconds(1))
    static let acoustID = RequestLimiter(minimumInterval: .milliseconds(350))
    static let coverArtArchive = RequestLimiter(minimumInterval: .milliseconds(200))
    static let lastFM = RequestLimiter(minimumInterval: .milliseconds(200))
}

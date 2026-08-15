import Foundation

@MainActor
final class PasteboardWatcher {
    struct Clock: Sendable {
        let nowNanoseconds: @Sendable () -> UInt64
        let sleepUntil: @Sendable (UInt64) async throws -> Void

        static let continuous = Clock(
            nowNanoseconds: { DispatchTime.now().uptimeNanoseconds },
            sleepUntil: { deadline in
                let now = DispatchTime.now().uptimeNanoseconds
                guard deadline > now else { return }
                try await Task.sleep(nanoseconds: deadline - now)
            }
        )
    }

    private let intervalNanoseconds: UInt64
    private let clock: Clock
    private var task: Task<Void, Never>?

    init(interval: TimeInterval = 0.5) {
        intervalNanoseconds = max(1, UInt64(max(0, interval) * 1_000_000_000))
        clock = .continuous
    }

    init(intervalNanoseconds: UInt64, clock: Clock) {
        self.intervalNanoseconds = max(1, intervalNanoseconds)
        self.clock = clock
    }

    deinit {
        task?.cancel()
    }

    func start(poll: @escaping @MainActor () async -> Void) {
        stop()
        let intervalNanoseconds = intervalNanoseconds
        let clock = clock
        task = Task {
            var deadline = clock.nowNanoseconds() &+ intervalNanoseconds
            while !Task.isCancelled {
                do {
                    try await clock.sleepUntil(deadline)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await poll()
                let now = clock.nowNanoseconds()
                repeat {
                    deadline &+= intervalNanoseconds
                } while deadline <= now
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

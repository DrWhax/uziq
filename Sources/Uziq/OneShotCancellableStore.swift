import Combine
import Foundation

/// Retains finite Combine pipelines only until they complete or are cancelled.
@MainActor
final class OneShotCancellableStore {
    private var storage: [UUID: AnyCancellable] = [:]
    private var completedBeforeInsertion: Set<UUID> = []

    var count: Int { storage.count }

    func sink<P: Publisher>(
        _ publisher: P,
        receiveCompletion: @escaping (Subscribers.Completion<P.Failure>) -> Void,
        receiveValue: @escaping (P.Output) -> Void
    ) {
        let id = UUID()
        let cancellable = publisher.sink { [weak self] completion in
            receiveCompletion(completion)
            self?.finish(id)
        } receiveValue: { value in
            receiveValue(value)
        }
        if completedBeforeInsertion.remove(id) == nil {
            storage[id] = cancellable
        }
    }

    func cancelAll() {
        let subscriptions = Array(storage.values)
        storage.removeAll()
        completedBeforeInsertion.removeAll()
        for subscription in subscriptions { subscription.cancel() }
    }

    private func finish(_ id: UUID) {
        if storage.removeValue(forKey: id) == nil {
            completedBeforeInsertion.insert(id)
        }
    }
}

extension Publisher {
    @MainActor
    func sinkOneShot(
        in store: OneShotCancellableStore,
        receiveCompletion: @escaping (Subscribers.Completion<Failure>) -> Void,
        receiveValue: @escaping (Output) -> Void
    ) {
        store.sink(self, receiveCompletion: receiveCompletion, receiveValue: receiveValue)
    }
}

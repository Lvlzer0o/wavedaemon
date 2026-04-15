import Foundation
import Combine

enum CamillaWebSocketError: LocalizedError {
    case invalidURL(String)
    case notConnected
    case timeout(String)
    case encodingFailed
    case invalidResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid WebSocket URL"
        case .notConnected:
            return "CamillaDSP is not connected"
        case let .timeout(command):
            return "Timed out waiting for \(command)"
        case .encodingFailed:
            return "Failed to encode CamillaDSP command"
        case .invalidResponse:
            return "Invalid response from CamillaDSP"
        case let .serverError(message):
            return message
        }
    }
}

enum CamillaCommand: Equatable {
    case getState
    case getVolume
    case getMute
    case toggleMute
    case setVolume(Double)
    case setConfig(String)
    case setUpdateInterval(Int)

    var responseKey: String {
        switch self {
        case .getState:
            return "GetState"
        case .getVolume:
            return "GetVolume"
        case .getMute:
            return "GetMute"
        case .toggleMute:
            return "ToggleMute"
        case .setVolume:
            return "SetVolume"
        case .setConfig:
            return "SetConfig"
        case .setUpdateInterval:
            return "SetUpdateInterval"
        }
    }

    func encodedMessage() throws -> String {
        let object: Any
        switch self {
        case .getState, .getVolume, .getMute, .toggleMute:
            object = responseKey
        case let .setVolume(value):
            object = [responseKey: value]
        case let .setConfig(configText):
            object = [responseKey: configText]
        case let .setUpdateInterval(milliseconds):
            object = [responseKey: milliseconds]
        }

        let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        guard let payload = String(data: data, encoding: .utf8) else {
            throw CamillaWebSocketError.encodingFailed
        }

        return payload
    }
}

@MainActor
final class CamillaWebSocket: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var isMuted = false
    @Published private(set) var currentVolume: Double = 0
    @Published private(set) var lastErrorMessage: String?

    private struct PendingRequest {
        let id: UUID
        let continuation: CheckedContinuation<[String: Any], Error>
    }

    private let session: URLSession
    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pending: [String: [PendingRequest]] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    func connect(urlString: String) async throws {
        guard var components = URLComponents(string: urlString) else {
            throw CamillaWebSocketError.invalidURL(urlString)
        }

        if components.scheme == "http" {
            components.scheme = "ws"
        } else if components.scheme == "https" {
            components.scheme = "wss"
        }

        guard let url = components.url else {
            throw CamillaWebSocketError.invalidURL(urlString)
        }

        disconnect()

        let task = session.webSocketTask(with: url)
        socketTask = task
        isConnected = true
        lastErrorMessage = nil
        task.resume()

        startReceiveLoop(for: task)

        do {
            _ = try await send(.setUpdateInterval(500), timeout: 2.5)
        } catch {
            lastErrorMessage = error.localizedDescription
            disconnect()
            throw error
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil

        socketTask?.cancel(with: .normalClosure, reason: nil)
        socketTask = nil

        if isConnected {
            isConnected = false
        }

        failAllPending(with: CamillaWebSocketError.notConnected)
    }

    @discardableResult
    func send(_ command: CamillaCommand, timeout: TimeInterval = 2.5) async throws -> [String: Any] {
        guard isConnected, let socketTask else {
            throw CamillaWebSocketError.notConnected
        }

        let requestID = UUID()
        let responseKey = command.responseKey
        let payload = try command.encodedMessage()

        let waitForReply = Task<[String: Any], Error> { [weak self] in
            try await withCheckedThrowingContinuation { continuation in
                guard let self else {
                    continuation.resume(throwing: CamillaWebSocketError.notConnected)
                    return
                }

                Task { @MainActor in
                    self.enqueuePending(id: requestID, key: responseKey, continuation: continuation)
                }
            }
        }

        do {
            try await socketTask.send(.string(payload))
        } catch {
            failPendingRequest(id: requestID, key: responseKey, error: error)
            throw error
        }

        do {
            let result = try await withThrowingTaskGroup(of: [String: Any].self) { group in
                group.addTask {
                    try await waitForReply.value
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw CamillaWebSocketError.timeout(responseKey)
                }

                let first = try await group.next() ?? [:]
                group.cancelAll()
                return first
            }

            return result
        } catch {
            waitForReply.cancel()
            failPendingRequest(id: requestID, key: responseKey, error: error)
            throw error
        }
    }

    func refreshState() async throws {
        let volumeReply = try await send(.getVolume)
        let muteReply = try await send(.getMute)

        if let volumeNumber = volumeReply["value"] as? NSNumber {
            currentVolume = volumeNumber.doubleValue
        }

        if let muteBool = muteReply["value"] as? Bool {
            isMuted = muteBool
        } else if let muteNumber = muteReply["value"] as? NSNumber {
            isMuted = muteNumber.boolValue
        }
    }

    func applyProfile(configText: String) async throws {
        _ = try await send(.setConfig(configText), timeout: 5.0)
    }

    func setVolume(_ value: Double) async throws {
        _ = try await send(.setVolume(value))
        currentVolume = value
    }

    @discardableResult
    func toggleMute() async throws -> Bool {
        let reply = try await send(.toggleMute)

        if let value = reply["value"] as? Bool {
            isMuted = value
        } else if let value = reply["value"] as? NSNumber {
            isMuted = value.boolValue
        }

        return isMuted
    }

    private func startReceiveLoop(for task: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    switch message {
                    case let .string(text):
                        self.handleIncomingText(text)
                    case let .data(data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleIncomingText(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    self.handleSocketFailure(error)
                    break
                }
            }
        }
    }

    private func handleIncomingText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let envelope = object as? [String: Any],
              envelope.count == 1,
              let commandKey = envelope.keys.first,
              let body = envelope[commandKey] as? [String: Any]
        else {
            return
        }

        resolvePendingRequest(for: commandKey, body: body)
    }

    private func handleSocketFailure(_ error: Error) {
        isConnected = false
        socketTask = nil
        receiveTask = nil
        lastErrorMessage = error.localizedDescription
        failAllPending(with: error)
    }

    private func enqueuePending(
        id: UUID,
        key: String,
        continuation: CheckedContinuation<[String: Any], Error>
    ) {
        let request = PendingRequest(id: id, continuation: continuation)
        var queue = pending[key] ?? []
        queue.append(request)
        pending[key] = queue
    }

    private func resolvePendingRequest(for key: String, body: [String: Any]) {
        guard var queue = pending[key], !queue.isEmpty else {
            return
        }

        let request = queue.removeFirst()
        if queue.isEmpty {
            pending.removeValue(forKey: key)
        } else {
            pending[key] = queue
        }

        if let result = body["result"] as? String,
           result.caseInsensitiveCompare("Error") == .orderedSame {
            let message = body["value"] as? String ?? "CamillaDSP command failed"
            request.continuation.resume(throwing: CamillaWebSocketError.serverError(message))
            return
        }

        request.continuation.resume(returning: body)
    }

    private func failPendingRequest(id: UUID, key: String, error: Error) {
        guard var queue = pending[key],
              let index = queue.firstIndex(where: { $0.id == id })
        else {
            return
        }

        let request = queue.remove(at: index)
        if queue.isEmpty {
            pending.removeValue(forKey: key)
        } else {
            pending[key] = queue
        }

        request.continuation.resume(throwing: error)
    }

    private func failAllPending(with error: Error) {
        for queue in pending.values {
            for request in queue {
                request.continuation.resume(throwing: error)
            }
        }
        pending.removeAll()
    }
}

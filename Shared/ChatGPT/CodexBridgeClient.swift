//
//  CodexBridgeClient.swift
//  NetNewsWire
//

import Foundation

enum CodexBridgeClientError: LocalizedError {
	case notConnected
	case encodingFailed

	var errorDescription: String? {
		switch self {
		case .notConnected:
			return "尚未连接 CodexBridge。"
		case .encodingFailed:
			return "无法编码发送给 CodexBridge 的消息。"
		}
	}
}

@MainActor final class CodexBridgeClient {

	private var socket: URLSessionWebSocketTask?
	private var receiveTask: Task<Void, Never>?

	var onEvent: (([String: Any]) -> Void)?
	var onDisconnected: ((Error?) -> Void)?

	func connect(configuration: CodexBridgeConfiguration) {
		disconnect()

		var request = URLRequest(url: configuration.webSocketURL)
		request.timeoutInterval = 20
		if let clientID = configuration.cloudflareClientID {
			request.setValue(clientID, forHTTPHeaderField: "CF-Access-Client-Id")
		}
		if let clientSecret = configuration.cloudflareClientSecret {
			request.setValue(clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
		}

		let socket = URLSession.shared.webSocketTask(with: request)
		self.socket = socket
		socket.resume()

		receiveTask = Task { [weak self] in
			await self?.receiveLoop(socket: socket)
		}

		Task { [weak self] in
			do {
				try await self?.send(type: "auth", payload: ["token": configuration.bridgeToken])
			} catch {
				self?.onDisconnected?(error)
			}
		}
	}

	func startSession(projectDirectory: String?) async throws {
		var payload: [String: Any] = [:]
		if let projectDirectory {
			payload["projectDirectory"] = projectDirectory
		}
		try await send(type: "startSession", payload: payload)
	}

	func sendMessage(sessionID: String, text: String) async throws {
		try await send(type: "sendMessage", payload: [
			"sessionId": sessionID,
			"text": text,
			"context": ["screenName": "NetNewsWire Article Analysis"]
		])
	}

	func respondToApproval(sessionID: String, approvalID: String, approved: Bool) async throws {
		try await send(type: "approvalResponse", payload: [
			"sessionId": sessionID,
			"approvalId": approvalID,
			"decision": approved ? "approveOnce" : "deny"
		])
	}

	func interrupt(sessionID: String) async throws {
		try await send(type: "interrupt", payload: ["sessionId": sessionID])
	}

	func closeSession(sessionID: String) async throws {
		try await send(type: "closeSession", payload: ["sessionId": sessionID])
	}

	func disconnect() {
		receiveTask?.cancel()
		receiveTask = nil
		socket?.cancel(with: .normalClosure, reason: nil)
		socket = nil
	}

	private func send(type: String, payload: [String: Any]) async throws {
		guard let socket else {
			throw CodexBridgeClientError.notConnected
		}

		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		let envelope: [String: Any] = [
			"type": type,
			"requestId": UUID().uuidString.lowercased(),
			"timestamp": formatter.string(from: Date()),
			"payload": payload
		]
		let data = try JSONSerialization.data(withJSONObject: envelope)
		guard let text = String(data: data, encoding: .utf8) else {
			throw CodexBridgeClientError.encodingFailed
		}
		try await socket.send(.string(text))
	}

	private func receiveLoop(socket: URLSessionWebSocketTask) async {
		while !Task.isCancelled {
			do {
				let message = try await socket.receive()
				let data: Data
				switch message {
				case .string(let text):
					data = Data(text.utf8)
				case .data(let receivedData):
					data = receivedData
				@unknown default:
					continue
				}

				guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
					continue
				}
				onEvent?(event)
			} catch {
				if !Task.isCancelled {
					onDisconnected?(error)
				}
				break
			}
		}
	}
}

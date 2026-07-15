//
//  MacChatGPTArticleAnalysisView.swift
//  NetNewsWire
//

import SwiftUI
import Articles

private struct CodexBridgeApprovalRequest: Identifiable {
	let id: String
	let sessionID: String
	let summary: String
	let kind: String
	let workingDirectory: String
}

@MainActor private final class MacChatGPTArticleAnalysisModel: ObservableObject {

	@Published var status = "正在连接 CodexBridge"
	@Published var response = ""
	@Published var isRunning = true
	@Published var approvalRequest: CodexBridgeApprovalRequest?

	private let article: Article
	private let configuration: CodexBridgeConfiguration
	private let client = CodexBridgeClient()
	private var sessionID: String?
	private var hasStarted = false
	private var isFinished = false

	init(article: Article, configuration: CodexBridgeConfiguration) {
		self.article = article
		self.configuration = configuration
		client.onEvent = { [weak self] event in
			self?.handle(event)
		}
		client.onDisconnected = { [weak self] error in
			guard let self, !self.isFinished else {
				return
			}
			self.finishWithError(error?.localizedDescription ?? "CodexBridge 连接已断开。")
		}
	}

	func start() {
		guard !hasStarted else {
			return
		}
		hasStarted = true
		client.connect(configuration: configuration)
	}

	func stop() {
		guard let sessionID, !isFinished else {
			return
		}
		Task {
			try? await client.interrupt(sessionID: sessionID)
		}
	}

	func close() {
		terminateSession(interrupt: !isFinished)
	}

	func respond(to request: CodexBridgeApprovalRequest, approved: Bool) {
		Task {
			do {
				try await client.respondToApproval(sessionID: request.sessionID, approvalID: request.id, approved: approved)
			} catch {
				finishWithError(error.localizedDescription)
			}
		}
	}

	private func handle(_ event: [String: Any]) {
		guard let type = event["type"] as? String else {
			return
		}
		let payload = event["payload"] as? [String: Any] ?? [:]

		switch type {
		case "authResult":
			guard payload["success"] as? Bool == true else {
				finishWithError(message(from: payload, fallback: "CodexBridge 认证失败。"))
				return
			}
			status = "正在创建分析会话"
			Task {
				do {
					try await client.startSession(projectDirectory: configuration.projectDirectory)
				} catch {
					finishWithError(error.localizedDescription)
				}
			}

		case "sessionStarted":
			guard let sessionID = payload["sessionId"] as? String else {
				finishWithError("CodexBridge 没有返回 sessionId。")
				return
			}
			self.sessionID = sessionID
			status = "ChatGPT 正在分析"
			Task {
				do {
					try await client.sendMessage(sessionID: sessionID, text: article.chatGPTAnalysisPrompt())
				} catch {
					finishWithError(error.localizedDescription)
				}
			}

		case "messageDelta":
			if let delta = payload["delta"] as? String {
				response.append(delta)
			}

		case "approvalRequested":
			guard let sessionID = payload["sessionId"] as? String,
				  let approvalID = payload["approvalId"] as? String else {
				finishWithError("收到格式不正确的权限请求。")
				return
			}
			approvalRequest = CodexBridgeApprovalRequest(
				id: approvalID,
				sessionID: sessionID,
				summary: payload["summary"] as? String ?? "ChatGPT 请求执行额外操作。",
				kind: payload["kind"] as? String ?? "未知操作",
				workingDirectory: payload["workingDirectory"] as? String ?? configuration.projectDirectory ?? "Bridge 默认目录"
			)

		case "turnCompleted":
			finishSuccessfully()

		case "turnInterrupted":
			finishWithError("分析已停止。")

		case "bridgeError", "codexError", "codexProcessExited":
			finishWithError(message(from: payload, fallback: "ChatGPT 分析失败。"))

		default:
			break
		}
	}

	private func finishSuccessfully() {
		isFinished = true
		isRunning = false
		status = "分析完成"
		closeSession()
	}

	private func finishWithError(_ message: String) {
		isFinished = true
		isRunning = false
		status = message
		if response.isEmpty {
			response = "无法完成新闻解读。请检查 CodexBridge 设置和网络连接。"
		}
		closeSession()
	}

	private func closeSession() {
		guard let sessionID else {
			client.disconnect()
			return
		}
		self.sessionID = nil
		Task {
			try? await client.closeSession(sessionID: sessionID)
			client.disconnect()
		}
	}

	private func terminateSession(interrupt: Bool) {
		client.onEvent = nil
		client.onDisconnected = nil
		guard let sessionID else {
			client.disconnect()
			return
		}
		self.sessionID = nil
		Task {
			if interrupt {
				try? await client.interrupt(sessionID: sessionID)
			}
			try? await client.closeSession(sessionID: sessionID)
			client.disconnect()
		}
	}

	private func message(from payload: [String: Any], fallback: String) -> String {
		payload["message"] as? String ?? payload["error"] as? String ?? fallback
	}
}

struct MacChatGPTArticleAnalysisView: View {

	@StateObject private var model: MacChatGPTArticleAnalysisModel
	let onClose: () -> Void

	init(article: Article, configuration: CodexBridgeConfiguration, onClose: @escaping () -> Void) {
		_model = StateObject(wrappedValue: MacChatGPTArticleAnalysisModel(article: article, configuration: configuration))
		self.onClose = onClose
	}

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 8) {
				if model.isRunning {
					ProgressView()
						.controlSize(.small)
				}
				Text(model.status)
					.font(.callout)
					.foregroundStyle(.secondary)
				Spacer()
				Button("停止", action: model.stop)
					.disabled(!model.isRunning)
				Button("关闭", action: onClose)
					.keyboardShortcut(.cancelAction)
			}
			.padding()

			Divider()

			ScrollView {
				Text(model.response.isEmpty ? "等待 ChatGPT 返回内容。" : model.response)
					.frame(maxWidth: .infinity, alignment: .topLeading)
					.textSelection(.enabled)
					.padding(20)
			}
		}
		.frame(minWidth: 700, minHeight: 560)
		.onAppear(perform: model.start)
		.onDisappear(perform: model.close)
		.alert(item: $model.approvalRequest) { request in
			Alert(
				title: Text("需要权限"),
				message: Text("\(request.summary)\n\n类型：\(request.kind)\n目录：\(request.workingDirectory)"),
				primaryButton: .default(Text("允许一次")) {
					model.respond(to: request, approved: true)
				},
				secondaryButton: .cancel(Text("拒绝")) {
					model.respond(to: request, approved: false)
				}
			)
		}
	}
}

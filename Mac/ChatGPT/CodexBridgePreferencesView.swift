//
//  CodexBridgePreferencesView.swift
//  NetNewsWire
//

import SwiftUI

struct CodexBridgePreferencesView: View {

	@State private var draft = CodexBridgeConfigurationStore.loadDraft()
	@State private var message: String?
	@State private var isError = false

	var onSave: ((CodexBridgeConfiguration) -> Void)?
	var onCancel: (() -> Void)?

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Form {
				TextField("WebSocket URL", text: $draft.webSocketURL, prompt: Text("ws://127.0.0.1:8765/ws"))
				SecureField("Bridge Token", text: $draft.bridgeToken)
				TextField("项目目录", text: $draft.projectDirectory, prompt: Text("留空使用 Bridge 默认值"))

				Section("Cloudflare Access（可选）") {
					SecureField("Client ID", text: $draft.cloudflareClientID)
					SecureField("Client Secret", text: $draft.cloudflareClientSecret)
				}
			}
			.formStyle(.grouped)

			Text("Bridge Token 和 Cloudflare 凭据保存在 Keychain。新闻标题、正文和链接会发送到此 CodexBridge。建议使用专用空目录。")
				.font(.footnote)
				.foregroundStyle(.secondary)

			if let message {
				Text(message)
					.foregroundStyle(isError ? .red : .secondary)
			}

			HStack {
				Spacer()
				if let onCancel {
					Button("取消", action: onCancel)
				}
				Button("保存", action: save)
					.keyboardShortcut(.defaultAction)
			}
		}
		.padding(20)
		.frame(width: 512, height: 390)
	}

	private func save() {
		do {
			let configuration = try CodexBridgeConfigurationStore.save(draft)
			message = "设置已保存。"
			isError = false
			onSave?(configuration)
		} catch {
			message = error.localizedDescription
			isError = true
		}
	}
}

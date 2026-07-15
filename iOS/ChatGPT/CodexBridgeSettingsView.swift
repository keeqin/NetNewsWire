//
//  CodexBridgeSettingsView.swift
//  NetNewsWire
//

import SwiftUI

struct CodexBridgeSettingsView: View {

	@Environment(\.dismiss) private var dismiss
	@State private var draft = CodexBridgeConfigurationStore.loadDraft()
	@State private var errorMessage: String?

	let onSave: (CodexBridgeConfiguration) -> Void

	var body: some View {
		NavigationStack {
			Form {
				Section("CodexBridge") {
					TextField("wss://codex.example.com/ws", text: $draft.webSocketURL)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
					SecureField("Bridge Token", text: $draft.bridgeToken)
					TextField("Mac 项目目录（留空使用 Bridge 默认值）", text: $draft.projectDirectory)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
				}

				Section("Cloudflare Access（可选）") {
					SecureField("Client ID", text: $draft.cloudflareClientID)
					SecureField("Client Secret", text: $draft.cloudflareClientSecret)
				}

				Section {
					Text("Bridge Token 和 Cloudflare 凭据保存在 Keychain。新闻标题、正文和链接会发送到你配置的 CodexBridge，并由 ChatGPT 生成解读。建议为新闻分析配置一个专用空目录。")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}

				if let errorMessage {
					Section {
						Text(errorMessage)
							.foregroundStyle(.red)
					}
				}
			}
			.navigationTitle("ChatGPT 设置")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("取消") {
						dismiss()
					}
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("保存") {
						save()
					}
				}
			}
		}
	}

	private func save() {
		do {
			let configuration = try CodexBridgeConfigurationStore.save(draft)
			onSave(configuration)
		} catch {
			errorMessage = error.localizedDescription
		}
	}
}

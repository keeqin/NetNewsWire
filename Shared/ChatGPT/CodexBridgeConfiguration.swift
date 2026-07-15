//
//  CodexBridgeConfiguration.swift
//  NetNewsWire
//

import Foundation
import Security

struct CodexBridgeConfiguration: Sendable {
	let webSocketURL: URL
	let projectDirectory: String?
	let bridgeToken: String
	let cloudflareClientID: String?
	let cloudflareClientSecret: String?
}

enum CodexBridgeConfigurationError: LocalizedError {
	case invalidURL
	case missingToken
	case incompleteCloudflareCredentials
	case keychainFailure(OSStatus)

	var errorDescription: String? {
		switch self {
		case .invalidURL:
			return "WebSocket 地址必须以 wss:// 或 ws:// 开头。"
		case .missingToken:
			return "请填写 Bridge Token。"
		case .incompleteCloudflareCredentials:
			return "Cloudflare Client ID 和 Client Secret 必须同时填写或同时留空。"
		case .keychainFailure(let status):
			if let message = SecCopyErrorMessageString(status, nil) as String? {
				return "无法访问钥匙串：\(message)（\(status)）。"
			}
			return "无法访问钥匙串（\(status)）。"
		}
	}
}

struct CodexBridgeConfigurationDraft {
	var webSocketURL: String
	var projectDirectory: String
	var bridgeToken: String
	var cloudflareClientID: String
	var cloudflareClientSecret: String
}

enum CodexBridgeConfigurationStore {

	private static let keychainService = "com.ranchero.NetNewsWire.CodexBridge"

	private enum Key {
		static let webSocketURL = "CodexBridgeWebSocketURL"
		static let projectDirectory = "CodexBridgeProjectDirectory"
	}

	private enum SecureKey: String {
		case bridgeToken
		case cloudflareClientID
		case cloudflareClientSecret
	}

	static func loadDraft() -> CodexBridgeConfigurationDraft {
		CodexBridgeConfigurationDraft(
			webSocketURL: UserDefaults.standard.string(forKey: Key.webSocketURL) ?? "",
			projectDirectory: UserDefaults.standard.string(forKey: Key.projectDirectory) ?? "",
			bridgeToken: (try? secureValue(for: .bridgeToken)) ?? "",
			cloudflareClientID: (try? secureValue(for: .cloudflareClientID)) ?? "",
			cloudflareClientSecret: (try? secureValue(for: .cloudflareClientSecret)) ?? ""
		)
	}

	static func loadConfiguration() throws -> CodexBridgeConfiguration {
		try configuration(from: loadDraft())
	}

	static func save(_ draft: CodexBridgeConfigurationDraft) throws -> CodexBridgeConfiguration {
		let configuration = try configuration(from: draft)
		UserDefaults.standard.set(configuration.webSocketURL.absoluteString, forKey: Key.webSocketURL)
		if let projectDirectory = configuration.projectDirectory {
			UserDefaults.standard.set(projectDirectory, forKey: Key.projectDirectory)
		} else {
			UserDefaults.standard.removeObject(forKey: Key.projectDirectory)
		}

		try storeSecureValue(draft.bridgeToken, for: .bridgeToken)
		try storeSecureValue(draft.cloudflareClientID, for: .cloudflareClientID)
		try storeSecureValue(draft.cloudflareClientSecret, for: .cloudflareClientSecret)
		return configuration
	}

	private static func configuration(from draft: CodexBridgeConfigurationDraft) throws -> CodexBridgeConfiguration {
		let urlString = draft.webSocketURL.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), (scheme == "wss" || scheme == "ws"), url.host != nil else {
			throw CodexBridgeConfigurationError.invalidURL
		}

		let bridgeToken = draft.bridgeToken.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !bridgeToken.isEmpty else {
			throw CodexBridgeConfigurationError.missingToken
		}

		let cloudflareClientID = draft.cloudflareClientID.nilIfBlank
		let cloudflareClientSecret = draft.cloudflareClientSecret.nilIfBlank
		guard (cloudflareClientID == nil) == (cloudflareClientSecret == nil) else {
			throw CodexBridgeConfigurationError.incompleteCloudflareCredentials
		}

		return CodexBridgeConfiguration(
			webSocketURL: url,
			projectDirectory: draft.projectDirectory.nilIfBlank,
			bridgeToken: bridgeToken,
			cloudflareClientID: cloudflareClientID,
			cloudflareClientSecret: cloudflareClientSecret
		)
	}

	private static func secureValue(for key: SecureKey) throws -> String {
		var query = baseKeychainQuery(for: key)
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne

		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		if status == errSecItemNotFound {
			return ""
		}
		guard status == errSecSuccess else {
			throw CodexBridgeConfigurationError.keychainFailure(status)
		}
		guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
			throw CodexBridgeConfigurationError.keychainFailure(errSecDecode)
		}
		return value
	}

	private static func storeSecureValue(_ value: String, for key: SecureKey) throws {
		let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmedValue.isEmpty {
			let status = SecItemDelete(baseKeychainQuery(for: key) as CFDictionary)
			guard status == errSecSuccess || status == errSecItemNotFound else {
				throw CodexBridgeConfigurationError.keychainFailure(status)
			}
			return
		}

		guard let data = trimmedValue.data(using: .utf8) else {
			throw CodexBridgeConfigurationError.keychainFailure(errSecParam)
		}
		let query = baseKeychainQuery(for: key)
		let update = [kSecValueData as String: data]
		let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
		if updateStatus == errSecSuccess {
			return
		}
		guard updateStatus == errSecItemNotFound else {
			throw CodexBridgeConfigurationError.keychainFailure(updateStatus)
		}

		var newItem = query
		newItem[kSecValueData as String] = data
		newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
		let addStatus = SecItemAdd(newItem as CFDictionary, nil)
		guard addStatus == errSecSuccess else {
			throw CodexBridgeConfigurationError.keychainFailure(addStatus)
		}
	}

	private static func baseKeychainQuery(for key: SecureKey) -> [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: keychainService,
			kSecAttrAccount as String: key.rawValue
		]
	}
}

private extension String {
	var nilIfBlank: String? {
		let trimmedValue = trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmedValue.isEmpty ? nil : trimmedValue
	}
}

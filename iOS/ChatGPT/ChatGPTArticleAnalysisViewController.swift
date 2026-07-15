//
//  ChatGPTArticleAnalysisViewController.swift
//  NetNewsWire
//

import UIKit
import SwiftUI
import RSCore
import Account
import Articles

@MainActor final class ChatGPTArticleAnalysisViewController: UIViewController {

	private let article: Article
	private var configuration: CodexBridgeConfiguration
	private var client = CodexBridgeClient()
	private let statusLabel = UILabel()
	private let textView = UITextView()
	private let activityIndicator = UIActivityIndicatorView(style: .medium)
	private lazy var stopButton = UIBarButtonItem(title: "停止", style: .plain, target: self, action: #selector(stop))
	private lazy var settingsButton = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain, target: self, action: #selector(showSettings))

	private var sessionID: String?
	private var hasStarted = false
	private var isFinished = false

	init(article: Article, configuration: CodexBridgeConfiguration) {
		self.article = article
		self.configuration = configuration
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) is unavailable")
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = .systemBackground
		title = "ChatGPT 解读"
		navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
		settingsButton.accessibilityLabel = "ChatGPT 设置"
		navigationItem.rightBarButtonItems = [stopButton, settingsButton]

		statusLabel.font = .preferredFont(forTextStyle: .footnote)
		statusLabel.textColor = .secondaryLabel
		statusLabel.text = "正在连接 CodexBridge"
		statusLabel.numberOfLines = 0

		textView.isEditable = false
		textView.alwaysBounceVertical = true
		textView.font = .preferredFont(forTextStyle: .body)
		textView.adjustsFontForContentSizeCategory = true
		textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)

		let statusStack = UIStackView(arrangedSubviews: [activityIndicator, statusLabel])
		statusStack.axis = .horizontal
		statusStack.alignment = .center
		statusStack.spacing = 8
		statusStack.translatesAutoresizingMaskIntoConstraints = false
		textView.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(statusStack)
		view.addSubview(textView)

		NSLayoutConstraint.activate([
			statusStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
			statusStack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
			statusStack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
			textView.topAnchor.constraint(equalTo: statusStack.bottomAnchor, constant: 4),
			textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			textView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
		])

		activityIndicator.startAnimating()
		configureClientCallbacks()
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		guard !hasStarted else {
			return
		}
		hasStarted = true
		client.connect(configuration: configuration)
	}

	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)
		if isBeingDismissed || navigationController?.isBeingDismissed == true {
			terminateSession(interrupt: !isFinished)
		}
	}

	private func configureClientCallbacks() {
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
			statusLabel.text = "正在创建分析会话"
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
			statusLabel.text = "ChatGPT 正在分析"
			Task {
				do {
					try await client.sendMessage(sessionID: sessionID, text: article.chatGPTAnalysisPrompt())
				} catch {
					finishWithError(error.localizedDescription)
				}
			}

		case "messageDelta":
			guard let delta = payload["delta"] as? String else {
				return
			}
			textView.text.append(delta)
			textView.scrollRangeToVisible(NSRange(location: textView.text.utf16.count, length: 0))

		case "approvalRequested":
			showApprovalRequest(payload)

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

	private func showApprovalRequest(_ payload: [String: Any]) {
		guard let sessionID = payload["sessionId"] as? String,
			  let approvalID = payload["approvalId"] as? String else {
			finishWithError("收到格式不正确的权限请求。")
			return
		}
		let summary = payload["summary"] as? String ?? "ChatGPT 请求执行额外操作。"
		let workingDirectory = payload["workingDirectory"] as? String ?? configuration.projectDirectory ?? "Bridge 默认目录"
		let kind = payload["kind"] as? String ?? "未知操作"
		let message = "\(summary)\n\n类型：\(kind)\n目录：\(workingDirectory)"
		let alert = UIAlertController(title: "需要权限", message: message, preferredStyle: .alert)
		alert.addAction(UIAlertAction(title: "拒绝", style: .cancel) { [weak self] _ in
			self?.respondToApproval(sessionID: sessionID, approvalID: approvalID, approved: false)
		})
		alert.addAction(UIAlertAction(title: "允许一次", style: .default) { [weak self] _ in
			self?.respondToApproval(sessionID: sessionID, approvalID: approvalID, approved: true)
		})
		present(alert, animated: true)
	}

	private func respondToApproval(sessionID: String, approvalID: String, approved: Bool) {
		Task {
			do {
				try await client.respondToApproval(sessionID: sessionID, approvalID: approvalID, approved: approved)
			} catch {
				finishWithError(error.localizedDescription)
			}
		}
	}

	private func finishSuccessfully() {
		isFinished = true
		activityIndicator.stopAnimating()
		statusLabel.text = "分析完成"
		stopButton.isEnabled = false
		closeSession()
	}

	private func finishWithError(_ message: String) {
		isFinished = true
		activityIndicator.stopAnimating()
		statusLabel.text = message
		stopButton.isEnabled = false
		if textView.text.isEmpty {
			textView.text = "无法完成新闻解读。请检查 CodexBridge 设置和网络连接。"
		}
		closeSession()
	}

	private func closeSession() {
		guard let sessionID else {
			client.disconnect()
			return
		}
		Task {
			try? await client.closeSession(sessionID: sessionID)
			client.disconnect()
		}
	}

	private func message(from payload: [String: Any], fallback: String) -> String {
		payload["message"] as? String ?? payload["error"] as? String ?? fallback
	}

	@objc private func stop() {
		guard let sessionID, !isFinished else {
			return
		}
		Task {
			try? await client.interrupt(sessionID: sessionID)
		}
	}

	@objc private func showSettings() {
		terminateSession(interrupt: !isFinished)
		isFinished = true
		activityIndicator.stopAnimating()
		stopButton.isEnabled = false
		let settingsView = CodexBridgeSettingsView { [weak self] configuration in
			guard let self else {
				return
			}
			self.dismiss(animated: true) {
				self.restart(with: configuration)
			}
		}
		let controller = UIHostingController(rootView: settingsView)
		controller.modalPresentationStyle = .formSheet
		present(controller, animated: true)
	}

	private func restart(with configuration: CodexBridgeConfiguration) {
		client = CodexBridgeClient()
		configureClientCallbacks()
		self.configuration = configuration
		sessionID = nil
		isFinished = false
		stopButton.isEnabled = true
		textView.text = ""
		statusLabel.text = "正在连接 CodexBridge"
		activityIndicator.startAnimating()
		client.connect(configuration: configuration)
	}

	@objc private func close() {
		dismiss(animated: true)
	}

	private func terminateSession(interrupt: Bool) {
		let client = client
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
}

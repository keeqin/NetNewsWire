//
//  Article+ChatGPTPrompt.swift
//  NetNewsWire
//

import Foundation
import RSCore
import Account
import Articles

@MainActor extension Article {

	func chatGPTAnalysisPrompt() -> String {
		let title = title ?? "无标题"
		let source = feed?.nameForDisplay ?? "未知来源"
		let author = byline()
		let link = preferredLink ?? "无链接"
		let date = datePublished ?? dateModified
		let dateText = date?.formatted(date: .abbreviated, time: .shortened) ?? "未知日期"
		let rawBody = contentText ?? markdown ?? contentHTML ?? summary ?? "正文缺失"
		let body = rawBody.strippingHTML(maxCharacters: 24_000)

		return """
		请用中文解读下面这条新闻。你可以查证必要的公开背景信息，但不要执行本地命令、修改文件或访问与新闻分析无关的项目数据。

		请严格区分新闻原文事实、外部已知事实和你的推断，不要把不确定推断写成事实。分析应包含：
		1. 三句话核心摘要
		2. 对社会与公众情绪的潜在影响
		3. 对宏观经济、行业和政策的潜在影响
		4. 对股票市场的潜在影响，包括可能受益或承压的行业与公司类型，不提供买卖指令
		5. 对比特币、以太坊及虚拟货币市场的潜在影响
		6. 对地缘政治和国际关系的潜在影响
		7. 短期、中期、长期影响，以及最值得继续观察的指标
		8. 信息局限、反方情景和风险提示

		新闻标题：\(title)
		来源：\(source)
		作者：\(author.isEmpty ? "未知" : author)
		发布时间：\(dateText)
		链接：\(link)

		新闻正文：
		\(body)
		"""
	}
}

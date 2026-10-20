//
//  LKMCPSettingsWindowController.swift
//  Lookin
//
//  MCP server 的开关、地址展示、写权限与 invoke 白名单。
//

import Foundation
import AppKit

@objc(LKMCPSettingsWindowController)
final class LKMCPSettingsWindowController: NSWindowController {

    @objc static let shared = LKMCPSettingsWindowController()

    private let enableButton = NSButton(checkboxWithTitle: NSLocalizedString("Enable MCP server", comment: ""),
                                        target: nil, action: nil)
    private let writesButton = NSButton(checkboxWithTitle: NSLocalizedString("Allow MCP writes (modify attributes)", comment: ""),
                                        target: nil, action: nil)
    private let invokeButton = NSButton(checkboxWithTitle: NSLocalizedString("Allow MCP invoke (no-argument selectors)", comment: ""),
                                        target: nil, action: nil)

    private let statusDot = LKStatusDotView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let endpointField = NSTextField(labelWithString: "")
    private let endpointPill = LKPillView()
    private let copyEndpointButton = NSButton(title: NSLocalizedString("Copy", comment: ""), target: nil, action: nil)
    private let allowlistTextView = NSTextView()
    private let allowlistPlaceholder = NSTextField(labelWithString: "reloadData\nbecomeFirstResponder")

    /// 白名单输入的防抖：停笔 0.8 秒后写入偏好（setter 会发通知即时生效）
    private var allowlistApplyWork: DispatchWorkItem?
    private var copiedTitleWork: DispatchWorkItem?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = NSLocalizedString("MCP Server", comment: "")
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildUI()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc func present() {
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])

        let intro = wrappingLabel(
            NSLocalizedString("Expose Lookin's live iOS UI inspection to any MCP-capable agent — "
                + "Claude Code, Codex, Cursor, Windsurf, Gemini CLI — over a local "
                + "Streamable HTTP endpoint that binds to 127.0.0.1 only.", comment: ""))
        intro.textColor = .secondaryLabelColor
        stack.addArrangedSubview(intro)

        // MARK: Endpoint

        let endpoint = section(NSLocalizedString("ENDPOINT", comment: ""), in: stack)

        let statusRow = NSStackView(views: [statusDot, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 7
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 9),
            statusDot.heightAnchor.constraint(equalToConstant: 9),
            statusDot.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
        ])
        endpoint.addArrangedSubview(statusRow)

        endpointField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        endpointField.lineBreakMode = .byTruncatingMiddle
        endpointField.isSelectable = true
        endpointField.translatesAutoresizingMaskIntoConstraints = false
        endpointPill.addSubview(endpointField)
        NSLayoutConstraint.activate([
            endpointField.leadingAnchor.constraint(equalTo: endpointPill.leadingAnchor, constant: 10),
            endpointField.trailingAnchor.constraint(lessThanOrEqualTo: endpointPill.trailingAnchor, constant: -10),
            endpointField.centerYAnchor.constraint(equalTo: endpointPill.centerYAnchor),
            endpointPill.heightAnchor.constraint(equalToConstant: 30),
        ])
        endpointPill.onClick = { [weak self] in self?.copyEndpoint() }
        endpointPill.toolTip = NSLocalizedString("Click to copy", comment: "")

        copyEndpointButton.bezelStyle = .rounded
        copyEndpointButton.controlSize = .small
        copyEndpointButton.target = self
        copyEndpointButton.action = #selector(copyEndpoint)

        let endpointRow = NSStackView(views: [endpointPill, copyEndpointButton])
        endpointRow.orientation = .horizontal
        endpointRow.spacing = 8
        // 胶囊比按钮更不抗拉伸，从而吃掉整行剩余宽度
        endpointPill.setContentHuggingPriority(NSLayoutConstraint.Priority(249), for: .horizontal)
        endpoint.addArrangedSubview(endpointRow)
        stretch(endpointRow, in: endpoint)

        let versions = wrappingLabel(String(
            format: NSLocalizedString("Speaks MCP %@ (server/discover) and %@ (initialize).", comment: ""),
            LKMCPProtocol.modernVersion,
            LKMCPProtocol.legacyVersions.joined(separator: " / ")))
        versions.font = .systemFont(ofSize: 11)
        versions.textColor = .tertiaryLabelColor
        endpoint.addArrangedSubview(versions)

        // MARK: General

        let general = section(NSLocalizedString("GENERAL", comment: ""), in: stack)
        enableButton.target = self
        enableButton.action = #selector(toggleEnabled)
        general.addArrangedSubview(checkboxRow(enableButton,
            subtitle: NSLocalizedString("Serve MCP at the endpoint above. Takes effect immediately; "
                + "if the port is occupied the server walks up to +9.", comment: "")))

        // MARK: Permissions

        let permissions = section(NSLocalizedString("PERMISSIONS", comment: ""), in: stack)

        writesButton.target = self
        writesButton.action = #selector(toggleWrites)
        permissions.addArrangedSubview(checkboxRow(writesButton,
            subtitle: NSLocalizedString("Allow lookin_set_attribute / set_custom_attribute / set_gesture_recognizer_enabled. "
                + "Runtime-only — never modifies your source code.", comment: "")))

        invokeButton.target = self
        invokeButton.action = #selector(toggleInvoke)
        permissions.addArrangedSubview(checkboxRow(invokeButton,
            subtitle: NSLocalizedString("Allow lookin_invoke_selector for no-argument selectors on the allowlist below.", comment: "")))

        let allowlistTitle = NSTextField(labelWithString: NSLocalizedString("Invoke allowlist", comment: ""))
        allowlistTitle.font = .systemFont(ofSize: 12, weight: .medium)
        permissions.addArrangedSubview(allowlistTitle)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 90).isActive = true

        allowlistTextView.delegate = self
        allowlistTextView.isRichText = false
        allowlistTextView.allowsUndo = true
        allowlistTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        allowlistTextView.isVerticallyResizable = true
        allowlistTextView.isHorizontallyResizable = false
        allowlistTextView.autoresizingMask = [.width]
        allowlistTextView.textContainer?.widthTracksTextView = true
        allowlistTextView.textContainerInset = NSSize(width: 4, height: 5)
        scroll.documentView = allowlistTextView

        allowlistPlaceholder.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        allowlistPlaceholder.textColor = .tertiaryLabelColor
        allowlistPlaceholder.maximumNumberOfLines = 0
        allowlistPlaceholder.lineBreakMode = .byWordWrapping
        scroll.contentView.addSubview(allowlistPlaceholder)
        allowlistPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            allowlistPlaceholder.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: 8),
            allowlistPlaceholder.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 8),
        ])

        permissions.addArrangedSubview(scroll)
        stretch(scroll, in: permissions)

        // MARK: Client config

        let client = section(NSLocalizedString("ADD TO CLIENT", comment: ""), in: stack)

        let claude = copyButton("Claude Code", action: #selector(copyClaudeCommand))
        let codex = copyButton("Codex", action: #selector(copyCodexConfig))
        let all = copyButton(NSLocalizedString("All Agents", comment: ""), action: #selector(copyAllAgentsConfig))
        let buttonRow = NSStackView(views: [claude, codex, all])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        client.addArrangedSubview(buttonRow)

        let hint = wrappingLabel(
            NSLocalizedString("Configs are copied to the clipboard — nothing is written to your config files. "
                + "Changes above apply instantly; no restart needed.", comment: ""))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        client.addArrangedSubview(hint)
    }

    /// 分区：小标题 + 垂直内容，整体与外层 stack 同宽
    private func section(_ header: String, in outer: NSStackView) -> NSStackView {
        let headerLabel = NSTextField(labelWithString: header)
        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        section.addArrangedSubview(headerLabel)
        outer.addArrangedSubview(section)
        stretch(section, in: outer)
        return section
    }

    private func stretch(_ view: NSView, in stack: NSStackView) {
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func checkboxRow(_ button: NSButton, subtitle: String) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.addArrangedSubview(button)
        let hint = wrappingLabel(subtitle)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        column.addArrangedSubview(hint)
        // 与 checkbox 标题文字对齐（方框 + 间距约 20pt）
        hint.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 20).isActive = true
        return column
    }

    private func copyButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func wrappingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        return label
    }

    // MARK: - State

    private func refresh() {
        let manager = LKPreferenceManager.main()!
        enableButton.state = manager.mcpEnabled ? .on : .off
        writesButton.state = manager.mcpAllowWrites ? .on : .off
        invokeButton.state = manager.mcpAllowInvoke ? .on : .off
        if allowlistTextView.string != manager.mcpInvokeAllowlistText {
            allowlistTextView.string = manager.mcpInvokeAllowlistText
        }
        allowlistPlaceholder.isHidden = !allowlistTextView.string.isEmpty

        let server = LKMCPServer.shared
        if server.isRunning {
            endpointField.stringValue = server.endpointURL
            statusDot.color = .systemGreen
            statusLabel.stringValue = String(format: NSLocalizedString("Running — listening on 127.0.0.1:%u", comment: ""), Int(server.actualPort))
        } else if manager.mcpEnabled {
            endpointField.stringValue = endpointString()
            statusDot.color = .systemOrange
            statusLabel.stringValue = NSLocalizedString("Not running — the port range may be occupied", comment: "")
        } else {
            endpointField.stringValue = endpointString()
            statusDot.color = .systemGray
            statusLabel.stringValue = NSLocalizedString("Disabled", comment: "")
        }

        writesButton.isEnabled = manager.mcpEnabled
        invokeButton.isEnabled = manager.mcpEnabled
        allowlistTextView.isEditable = manager.mcpEnabled
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        LKPreferenceManager.main()!.mcpEnabled = (enableButton.state == .on)
        refreshSoon()
    }

    @objc private func toggleWrites() {
        LKPreferenceManager.main()!.mcpAllowWrites = (writesButton.state == .on)
    }

    @objc private func toggleInvoke() {
        LKPreferenceManager.main()!.mcpAllowInvoke = (invokeButton.state == .on)
    }

    // MARK: - Copy helpers

    @objc private func copyEndpoint() {
        copyToPasteboard(endpointString(), flash: copyEndpointButton)
    }

    @objc private func copyClaudeCommand() {
        copyToPasteboard("claude mcp add --transport http lookin \(endpointString())")
    }

    @objc private func copyCodexConfig() {
        copyToPasteboard("[mcp_servers.lookin]\nurl = \"\(endpointString())\"")
    }

    @objc private func copyAllAgentsConfig() {
        copyToPasteboard(LKMCPServer.shared.configText())
    }

    private func endpointString() -> String {
        let server = LKMCPServer.shared
        if server.isRunning {
            return server.endpointURL
        }
        return "http://127.0.0.1:\(LKPreferenceManager.main()!.mcpPort)/mcp"
    }

    private func copyToPasteboard(_ text: String, flash button: NSButton? = nil) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        guard let button = button else { return }
        let original = button.title
        button.title = NSLocalizedString("Copied ✓", comment: "")
        copiedTitleWork?.cancel()
        let work = DispatchWorkItem { [weak button] in
            button?.title = original
        }
        copiedTitleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}

// MARK: - Allowlist auto-apply

extension LKMCPSettingsWindowController: NSTextViewDelegate {

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              textView == allowlistTextView else { return }
        allowlistPlaceholder.isHidden = !allowlistTextView.string.isEmpty

        allowlistApplyWork?.cancel()
        let text = allowlistTextView.string
        let work = DispatchWorkItem {
            LKPreferenceManager.main()!.mcpInvokeAllowlistText = text
        }
        allowlistApplyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }
}

// MARK: - Small custom views

/// 运行状态圆点，draw 时取色以跟随深浅色模式
private final class LKStatusDotView: NSView {
    var color: NSColor = .systemGray {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 1, width: bounds.width, height: bounds.height - 2)).fill()
    }
}

/// 端点地址的圆角底衬，整块可点击复制
private final class LKPillView: NSView {
    var onClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

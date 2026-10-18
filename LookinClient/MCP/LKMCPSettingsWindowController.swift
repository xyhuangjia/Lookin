//
//  LKMCPSettingsWindowController.swift
//  Lookin
//
//  MCP server 的开关、端口、写权限与 invoke 白名单。
//

import Foundation
import AppKit

@objc(LKMCPSettingsWindowController)
final class LKMCPSettingsWindowController: NSWindowController {

    @objc static let shared = LKMCPSettingsWindowController()

    private let enableButton = NSButton(checkboxWithTitle: "Enable MCP server",
                                        target: nil, action: nil)
    private let writesButton = NSButton(checkboxWithTitle: "Allow MCP writes (modify attributes)",
                                        target: nil, action: nil)
    private let invokeButton = NSButton(checkboxWithTitle: "Allow MCP invoke (no-argument selectors)",
                                        target: nil, action: nil)
    private let addressLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let allowlistTextView = NSTextView()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = "MCP Server"
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
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
        ])

        let title = NSTextField(labelWithString: "MCP Server")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        stack.addArrangedSubview(title)

        let intro = wrappingLabel(
            "Expose Lookin's live iOS UI inspection to Claude Code and Codex over a local Streamable HTTP endpoint. " +
            "The server binds to 127.0.0.1 only."
        )
        stack.addArrangedSubview(intro)

        enableButton.target = self
        enableButton.action = #selector(toggleEnabled)
        stack.addArrangedSubview(enableButton)

        addressLabel.isSelectable = true
        addressLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        addressLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(addressLabel)

        statusLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(statusLabel)

        stack.addArrangedSubview(separator())

        writesButton.target = self
        writesButton.action = #selector(toggleWrites)
        stack.addArrangedSubview(writesButton)

        invokeButton.target = self
        invokeButton.action = #selector(toggleInvoke)
        stack.addArrangedSubview(invokeButton)

        let allowlistTitle = NSTextField(labelWithString: "Invoke allowlist (one no-argument selector per line)")
        allowlistTitle.font = .systemFont(ofSize: 12, weight: .medium)
        stack.addArrangedSubview(allowlistTitle)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 500).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 90).isActive = true

        allowlistTextView.isRichText = false
        allowlistTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        allowlistTextView.isVerticallyResizable = true
        allowlistTextView.isHorizontallyResizable = false
        allowlistTextView.autoresizingMask = [.width]
        allowlistTextView.textContainer?.widthTracksTextView = true
        allowlistTextView.textContainerInset = NSSize(width: 4, height: 4)
        scroll.documentView = allowlistTextView
        stack.addArrangedSubview(scroll)

        let copyClaude = NSButton(title: "Copy Claude Code Command",
                                  target: self, action: #selector(copyClaudeCommand))
        copyClaude.bezelStyle = .rounded
        let copyCodex = NSButton(title: "Copy Codex Config",
                                 target: self, action: #selector(copyCodexConfig))
        copyCodex.bezelStyle = .rounded
        let apply = NSButton(title: "Apply", target: self, action: #selector(applySettings))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"

        let buttonRow = NSStackView(views: [copyClaude, copyCodex, apply])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        stack.addArrangedSubview(buttonRow)

        let hint = wrappingLabel(
            "Claude Code and Codex both speak Streamable HTTP. " +
            "Writes are runtime-only and never modify your source code."
        )
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
    }

    private func wrappingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 500).isActive = true
        return box
    }

    // MARK: - State

    private func refresh() {
        let manager = LKPreferenceManager.main()!
        enableButton.state = manager.mcpEnabled ? .on : .off
        writesButton.state = manager.mcpAllowWrites ? .on : .off
        invokeButton.state = manager.mcpAllowInvoke ? .on : .off
        allowlistTextView.string = manager.mcpInvokeAllowlistText

        let server = LKMCPServer.shared
        if server.isRunning {
            addressLabel.stringValue = server.endpointURL
            statusLabel.stringValue = "Running — protocol versions 2026-07-28 / 2025-11-25 / 2025-06-18"
        } else if manager.mcpEnabled {
            addressLabel.stringValue = "http://127.0.0.1:\(manager.mcpPort)/mcp"
            statusLabel.stringValue = "Not running. The configured port range may be occupied."
        } else {
            addressLabel.stringValue = "http://127.0.0.1:\(manager.mcpPort)/mcp"
            statusLabel.stringValue = "Disabled"
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

    @objc private func applySettings() {
        let manager = LKPreferenceManager.main()!
        manager.mcpInvokeAllowlistText = allowlistTextView.string
        manager.mcpEnabled = (enableButton.state == .on)
        manager.mcpAllowWrites = (writesButton.state == .on)
        manager.mcpAllowInvoke = (invokeButton.state == .on)
        LKMCPServer.shared.restart()
        refreshSoon()
    }

    // MARK: - Copy helpers

    @objc private func copyClaudeCommand() {
        let command = "claude mcp add --transport http lookin \(endpointString())"
        copyToPasteboard(command)
    }

    @objc private func copyCodexConfig() {
        let toml = """
        [mcp_servers.lookin]
        url = "\(endpointString())"
        """
        copyToPasteboard(toml)
    }

    private func endpointString() -> String {
        let server = LKMCPServer.shared
        if server.isRunning {
            return server.endpointURL
        }
        return "http://127.0.0.1:\(LKPreferenceManager.main()!.mcpPort)/mcp"
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        statusLabel.stringValue = "Copied to clipboard."
        refreshSoon()
    }
}

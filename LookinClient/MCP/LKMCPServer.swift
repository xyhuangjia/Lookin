//
//  LKMCPServer.swift
//  Lookin
//
//  内置 MCP server：绑定 127.0.0.1，单一路径 POST /mcp。
//  同时兼容 MCP 2026-07-28（无状态）与 2025-11-25 / 2025-06-18（initialize 握手）。
//

import Foundation
import Network
import AppKit
import os.lock

// MARK: - Router wiring

/// `LKMCPRouter` 本身不依赖 App 类，便于单元测试；
/// 与真实 service 的连接放在 App target 内。
extension LKMCPRouter {
    static let shared = LKMCPRouter(dependencies: LKMCPRouterDependencies(
        toolDefinitions: { LKMCPToolDefinitions.all },
        callTool: { name, arguments in
            await LKMCPService.shared.callTool(name: name, arguments: arguments)
        },
        serverVersion: {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        }
    ))
}

// MARK: - Server

@objc(LKMCPServer)
final class LKMCPServer: NSObject {

    @objc static let shared = LKMCPServer()

    private let queue = DispatchQueue(label: "lookin.mcp.server")
    private let stateLock = NSLock()

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var statusItem: NSStatusItem?
    private var settingsObserver: NSObjectProtocol?

    private var _isRunning = false
    private var _actualPort: UInt16 = 0

    @objc var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isRunning
    }

    var actualPort: UInt16 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _actualPort
    }

    var endpointURL: String {
        let port = isRunning ? actualPort : UInt16(clamping: LKPreferenceManager.main()!.mcpPort)
        return "http://127.0.0.1:\(port)/mcp"
    }

    private override init() {
        super.init()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.LKMCPSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.startIfEnabled()
        }
    }

    deinit {
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Lifecycle

    @objc func startIfEnabled() {
        guard LKPreferenceManager.main()!.mcpEnabled else {
            stop()
            return
        }
        restart()
    }

    @objc func restart() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.stopLocked()
            guard LKPreferenceManager.main()!.mcpEnabled else {
                self.updateStatusItem()
                return
            }
            let desired = UInt16(LKPreferenceManager.main()!.mcpPort)
            let start = max(desired, 1024)
            let end = min(start + 9, 65535)
            self.tryStart(port: start, endPort: end)
        }
    }

    @objc func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
            self?.updateStatusItem()
        }
    }

    /// App 即将退出时同步清理监听与 handshake 文件
    @objc func stopBeforeTermination() {
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        setState(running: false, port: 0)
        removeHandshakeFile()
    }

    private func tryStart(port: UInt16, endPort: UInt16) {
        guard port <= endPort else {
            NSLog("Lookin MCP: all ports in range are occupied.")
            setState(running: false, port: 0)
            updateStatusItem()
            writeHandshakeFile(error: "port_conflict")
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: port)!
            )
            let newListener = try NWListener(using: parameters)

            newListener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                guard let self = self, let newListener = newListener else { return }
                switch state {
                case .ready:
                    self.listener = newListener
                    let bound = newListener.port?.rawValue ?? port
                    self.setState(running: true, port: bound)
                    self.writeHandshakeFile()
                    self.updateStatusItem()
                    NSLog("Lookin MCP: listening on \(self.endpointURL)")
                case .failed(let error):
                    newListener.cancel()
                    if case .posix(let code) = error, code == .EADDRINUSE, port < endPort {
                        self.tryStart(port: port + 1, endPort: endPort)
                    } else {
                        NSLog("Lookin MCP: failed to start on port \(port): \(error)")
                        self.setState(running: false, port: 0)
                        self.updateStatusItem()
                        self.writeHandshakeFile(error: "\(error)")
                    }
                default:
                    break
                }
            }
            newListener.start(queue: queue)
        } catch {
            NSLog("Lookin MCP: failed to create listener on port \(port): \(error)")
            if port < endPort {
                tryStart(port: port + 1, endPort: endPort)
            } else {
                setState(running: false, port: 0)
                updateStatusItem()
                writeHandshakeFile(error: "\(error)")
            }
        }
    }

    private func stopLocked() {
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        setState(running: false, port: 0)
        removeHandshakeFile()
    }

    private func setState(running: Bool, port: UInt16) {
        stateLock.lock()
        _isRunning = running
        _actualPort = port
        stateLock.unlock()
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func close(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }
            var current = buffer
            if let data = data {
                current.append(data)
            }
            switch LKHTTPParser.parse(current) {
            case .complete(let request):
                self.handle(request, on: connection)
            case .invalid(let status):
                self.send(status: status, body: self.statusBody(status), on: connection)
            case .incomplete:
                if isComplete || error != nil {
                    self.close(connection)
                } else if current.count > LKHTTPParser.maxBufferedSize {
                    self.send(status: 413, body: self.statusBody(413), on: connection)
                } else {
                    self.receive(connection, buffer: current)
                }
            }
        }
    }

    // MARK: - HTTP handling

    private func handle(_ request: LKHTTPRequest, on connection: NWConnection) {
        guard request.method == "POST" else {
            send(status: 405, body: statusBody(405), on: connection)
            return
        }
        guard request.path == "/mcp" else {
            send(status: 404, body: statusBody(404), on: connection)
            return
        }
        guard LKMCPRequestPolicy.allows(origin: request.headers["origin"],
                                        host: request.headers["host"],
                                        port: actualPort) else {
            send(status: 403, body: statusBody(403), on: connection)
            return
        }
        guard let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            send(status: 400, body: statusBody(400), on: connection)
            return
        }

        Task { [weak self] in
            guard let self = self else { return }
            let response = await LKMCPRouter.shared.handle(message, headers: request.headers)
            if let response = response {
                self.send(status: response.status, body: response.body, on: connection)
            } else {
                self.send(status: 202, body: nil, on: connection)
            }
        }
    }

    private func send(status: Int, body: Data?, on connection: NWConnection) {
        var header = "HTTP/1.1 \(status) \(LKHTTPParser.reason(for: status))\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(body?.count ?? 0)\r\n"
        header += "Connection: close\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "\r\n"
        var payload = Data(header.utf8)
        if let body = body {
            payload.append(body)
        }
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.close(connection)
        })
    }

    private func statusBody(_ status: Int) -> Data {
        let json: [String: Any] = ["error": ["status": status, "reason": LKHTTPParser.reason(for: status)]]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
    }

    // MARK: - Handshake file

    private var handshakeURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else {
            return nil
        }
        return support
            .appendingPathComponent("Lookin", isDirectory: true)
            .appendingPathComponent("mcp-handshake.json")
    }

    func writeHandshakeFile(error: String? = nil) {
        guard let url = handshakeURL else { return }
        let manager = LKPreferenceManager.main()!
        let currentPort = isRunning ? actualPort : UInt16(clamping: manager.mcpPort)
        var dict: [String: Any] = [
            "url": endpointURL,
            "port": currentPort,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "serverVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "protocolVersions": ["2026-07-28", "2025-11-25", "2025-06-18"],
            "writesEnabled": manager.mcpAllowWrites,
            "invokeEnabled": manager.mcpAllowInvoke
        ]
        if let target = LKMCPService.shared.statusJSON()["target"] {
            dict["target"] = target
        } else {
            dict["target"] = NSNull()
        }
        if let error = error {
            dict["error"] = error
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: dict,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: url.path)
        } catch {
            NSLog("Lookin MCP: failed to write handshake file: \(error)")
        }
    }

    func removeHandshakeFile() {
        guard let url = handshakeURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Status item

    private func updateStatusItem() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let enabled = LKPreferenceManager.main()!.mcpEnabled
            if self.isRunning || enabled {
                if self.statusItem == nil {
                    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                    let menu = NSMenu()
                    menu.addItem(NSMenuItem(title: "MCP: \(self.endpointURL)", action: nil, keyEquivalent: ""))

                    let copyItem = NSMenuItem(title: "Copy MCP config",
                                              action: #selector(self.copyMCPConfig),
                                              keyEquivalent: "")
                    copyItem.target = self
                    menu.addItem(copyItem)

                    let settingsItem = NSMenuItem(title: "MCP Server Settings…",
                                                  action: #selector(self.openSettings),
                                                  keyEquivalent: "")
                    settingsItem.target = self
                    menu.addItem(settingsItem)

                    menu.addItem(.separator())

                    let quitItem = NSMenuItem(title: "Quit Lookin",
                                              action: #selector(self.quitApp),
                                              keyEquivalent: "q")
                    quitItem.target = self
                    menu.addItem(quitItem)

                    item.menu = menu
                    self.statusItem = item
                }
                if self.isRunning {
                    self.statusItem?.button?.title = "Lookin MCP :\(self.actualPort)"
                    if let first = self.statusItem?.menu?.items.first {
                        first.title = "MCP: \(self.endpointURL)"
                    }
                } else {
                    self.statusItem?.button?.title = "Lookin MCP (stopped)"
                    if let first = self.statusItem?.menu?.items.first {
                        first.title = "MCP server is not running — check the port"
                    }
                }
            } else if let item = self.statusItem {
                NSStatusBar.system.removeStatusItem(item)
                self.statusItem = nil
            }
        }
    }

    @objc private func copyMCPConfig() {
        let text = """
        Claude Code:
          claude mcp add --transport http lookin \(endpointURL)

        Codex (~/.codex/config.toml):
          [mcp_servers.lookin]
          url = "\(endpointURL)"
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc private func openSettings() {
        LKMCPSettingsWindowController.shared.present()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

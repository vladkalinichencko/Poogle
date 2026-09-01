import Foundation

struct MCPServer {
    private let indexer: LibraryIndexer
    private let searchEngine: SearchEngine

    init(indexer: LibraryIndexer, searchEngine: SearchEngine) {
        self.indexer = indexer
        self.searchEngine = searchEngine
    }

    func run() async {
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else {
                write(error: -32700, message: "Parse error", id: NSNull())
                continue
            }
            await handle(request)
        }
    }

    private func handle(_ request: [String: Any]) async {
        let id = request["id"]
        guard let method = request["method"] as? String else {
            if id != nil {
                write(error: -32600, message: "Invalid request", id: id!)
            }
            return
        }

        switch method {
        case "initialize":
            guard let id else { return }
            let params = request["params"] as? [String: Any]
            write(result: [
                "protocolVersion": params?["protocolVersion"] as? String
                    ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "Poogle", "version": "1.0.0"],
                "instructions": "Poogle searches the user's private local paper library. Before the first search_papers call in a task, call sync_library so newly added, moved, or deleted PDFs are reflected. Cite returned file paths when you rely on a result.",
            ], id: id)

        case "notifications/initialized", "notifications/cancelled":
            return

        case "ping":
            guard let id else { return }
            write(result: [:], id: id)

        case "tools/list":
            guard let id else { return }
            write(result: ["tools": [
                [
                    "name": "sync_library",
                    "description": "Synchronize Poogle's saved PDF folder with its local index. Call this once before the first paper search in a task.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [:],
                        "additionalProperties": false,
                    ],
                ],
                [
                    "name": "search_papers",
                    "description": "Search the user's private Poogle library of indexed scientific papers. Use this before internet search for research questions, paper discovery, methods, evidence, or literature review.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "query": [
                                "type": "string",
                                "description": "A plain-language research question or paper search query",
                            ],
                        ],
                        "required": ["query"],
                        "additionalProperties": false,
                    ],
                ],
            ]], id: id)

        case "tools/call":
            guard let id else { return }
            await callTool(request["params"] as? [String: Any], id: id)

        default:
            guard let id else { return }
            write(error: -32601, message: "Method not found", id: id)
        }
    }

    private func callTool(_ params: [String: Any]?, id: Any) async {
        switch params?["name"] as? String {
        case "sync_library":
            await syncLibrary(id: id)
        case "search_papers":
            await searchPapers(params, id: id)
        default:
            write(error: -32602, message: "Unknown tool", id: id)
        }
    }

    private func syncLibrary(id: Any) async {
        guard let folder = LibrarySettings.folder else {
            writeToolError(
                "Choose a PDF folder in the Poogle app before synchronizing.",
                id: id
            )
            return
        }

        do {
            let result = try await indexer.sync(folder: folder)
            writeToolResult([
                "scanned_count": result.scannedCount,
                "indexed_count": result.indexedCount,
                "document_count": result.documentCount,
                "skipped_files": result.skippedFiles,
            ], id: id)
        } catch {
            writeToolError(error.localizedDescription, id: id)
        }
    }

    private func searchPapers(_ params: [String: Any]?, id: Any) async {
        guard let arguments = params?["arguments"] as? [String: Any],
              let query = arguments["query"] as? String,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            write(error: -32602, message: "search_papers requires query", id: id)
            return
        }

        do {
            let results = try await searchEngine.search(query)
            let papers: [[String: Any]] = results.map {
                [
                    "title": $0.title,
                    "path": $0.path,
                    "section": $0.section,
                    "snippet": $0.snippet,
                    "relevance": $0.score,
                ]
            }
            writeToolResult(["results": papers], id: id)
        } catch {
            writeToolError(error.localizedDescription, id: id)
        }
    }

    private func writeToolResult(_ value: Any, id: Any) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            writeToolError("Poogle could not encode the tool result.", id: id)
            return
        }
        write(result: [
            "content": [[
                "type": "text",
                "text": String(decoding: data, as: UTF8.self),
            ]],
        ], id: id)
    }

    private func writeToolError(_ message: String, id: Any) {
        write(result: [
            "content": [["type": "text", "text": message]],
            "isError": true,
        ], id: id)
    }

    private func write(result: Any, id: Any) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func write(error code: Int, message: String, id: Any) {
        write([
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message],
        ])
    }

    private func write(_ response: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: response) else {
            return
        }
        FileHandle.standardOutput.write(data + Data([0x0A]))
    }
}

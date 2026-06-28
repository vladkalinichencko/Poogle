import Foundation

protocol SearchModel: Sendable {
    func embed(query: String) throws -> QueryEmbeddingResponse
    func rerank(
        query: String,
        documents: [RerankDocument]
    ) throws -> [Double]
}

final class EmbeddingWorker: SearchModel, @unchecked Sendable {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private let requestLock = NSLock()
    private let processLock = NSLock()

    func embed(_ fileURL: URL) throws -> EmbeddedDocument {
        requestLock.lock()
        defer { requestLock.unlock() }
        let response: DocumentEmbeddingResponse = try request(
            operation: "embed_file",
            payload: ["path": fileURL.path]
        )
        let document = ParsedDocument(
            url: fileURL,
            title: response.title,
            abstract: response.abstract,
            sections: response.chunks.map {
                ParsedSection(title: $0.heading, text: $0.text)
            }
        )
        return EmbeddedDocument(
            document: document,
            chunks: response.chunks.map {
                EmbeddedChunk(
                    heading: $0.heading,
                    text: $0.text,
                    embedding: $0.embedding
                )
            }
        )
    }

    func embed(query: String) throws -> QueryEmbeddingResponse {
        requestLock.lock()
        defer { requestLock.unlock() }
        let response: QueryEmbeddingResponse = try request(
            operation: "embed_query",
            payload: ["query": query]
        )
        return response
    }

    func rerank(
        query: String,
        documents: [RerankDocument]
    ) throws -> [Double] {
        requestLock.lock()
        defer { requestLock.unlock() }
        let encoded = try documents.map {
            let data = try JSONEncoder().encode($0)
            return try JSONSerialization.jsonObject(with: data)
        }
        let response: RerankResponse = try request(
            operation: "rerank",
            payload: [
                "query": query,
                "documents": encoded,
            ]
        )
        return response.scores
    }

    func stop() {
        processLock.lock()
        defer { processLock.unlock() }
        process?.terminate()
        process = nil
        input = nil
        output = nil
    }

    private func request<Result: Decodable>(
        operation: String,
        payload: [String: Any]
    ) throws -> Result {
        try startIfNeeded()
        var request = payload
        request["operation"] = operation
        let data = try JSONSerialization.data(withJSONObject: request)
        input?.write(data + Data([0x0A]))
        let responseData = try readLine()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response: WorkerResponse<Result>
        do {
            response = try decoder.decode(
                WorkerResponse<Result>.self,
                from: responseData
            )
        } catch {
            let preview = String(
                decoding: responseData.prefix(240),
                as: UTF8.self
            )
            throw EmbeddingWorkerError.failed(
                "Invalid model response: \(preview)"
            )
        }
        if let error = response.error {
            throw EmbeddingWorkerError.failed(error)
        }
        guard let result = response.result else {
            throw EmbeddingWorkerError.invalidResponse
        }
        return result
    }

    private func startIfNeeded() throws {
        processLock.lock()
        defer { processLock.unlock() }
        if process?.isRunning == true {
            return
        }
        guard let script = Bundle.module.url(
            forResource: "embedding_worker",
            withExtension: "py",
            subdirectory: "Resources"
        ) else {
            throw EmbeddingWorkerError.missingScript
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let resources = Bundle.main.resourceURL
        let bundledPython = resources?
            .appending(path: ".venv/bin/python")
        let bundledPythonHome = resources?
            .appending(path: "python-runtime")
        guard let python = bundledPython,
              let pythonHome = bundledPythonHome,
              FileManager.default.isExecutableFile(atPath: python.path) else {
            throw EmbeddingWorkerError.missingPythonRuntime
        }
        process.executableURL = python
        process.arguments = [script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        environment["PYTHONHOME"] = pythonHome.path
        environment["TOKENIZERS_PARALLELISM"] = "false"
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.standardError
        try process.run()
        self.process = process
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
    }

    private func readLine() throws -> Data {
        guard let output else {
            throw EmbeddingWorkerError.invalidResponse
        }
        var data = Data()
        while true {
            guard let byte = try output.read(upToCount: 1), !byte.isEmpty else {
                throw EmbeddingWorkerError.ended
            }
            if byte[0] == 0x0A {
                return data
            }
            data.append(byte)
        }
    }
}

private enum EmbeddingWorkerError: LocalizedError {
    case missingScript
    case missingPythonRuntime
    case invalidResponse
    case ended
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingScript:
            "The bundled embedding worker is missing."
        case .missingPythonRuntime:
            "The bundled Python runtime is missing."
        case .invalidResponse:
            "The embedding worker returned an invalid response."
        case .ended:
            "The embedding worker stopped unexpectedly."
        case let .failed(message):
            message
        }
    }
}

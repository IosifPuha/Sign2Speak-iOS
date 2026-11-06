import Foundation
import LiteRTLM

// UI controls serialize commands. This actor owns the native engine and conversation.
actor GemmaRunner: SentenceGenerator {
    private var engine: Engine?
    private var conversation: Conversation?
    private var activeRequest: UUID?
    private var cancellation: (id: UUID, reason: String)?
    private var loadedBackend = "CPU"
    private var loadedContextTokens = SentenceGenerationPolicy.contextTokens
    private var previousBenchmarkFlag: Bool?

    func load(model: URL, gpu: Bool, cache: URL, contextTokens: Int, profiling: Bool) async throws -> Double {
        guard engine == nil, activeRequest == nil else { throw AppError.invalidState }
        // This app serializes its single engine owner. The SDK flag is global;
        // restore it on failed initialization and after native engine release.
        if profiling {
            ExperimentalFlags.optIntoExperimentalAPIs()
            previousBenchmarkFlag = ExperimentalFlags.enableBenchmark
            ExperimentalFlags.enableBenchmark = true
        }
        var initialized = false
        defer { if !initialized { restoreBenchmarkFlag() } }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let config = try EngineConfig(
            modelPath: model.path,
            backend: gpu ? .gpu : .cpu(),
            maxNumTokens: contextTokens,
            cacheDir: cache.path
        )
        let candidate = Engine(engineConfig: config)
        let start = ProcessInfo.processInfo.systemUptime
        try await candidate.initialize()
        engine = candidate
        loadedBackend = gpu ? "GPU" : "CPU"
        loadedContextTokens = contextTokens
        initialized = true
        return ProcessInfo.processInfo.systemUptime - start
    }

    func generate(id: UUID, promptID: String, glosses: String, promptStyle: SentencePromptStyle,
                  progress: @escaping @Sendable (String) async -> Void) async throws -> GenerationMeasurement {
        guard let engine, activeRequest == nil else { throw AppError.invalidState }
        guard promptStyle == .compact || loadedContextTokens >= SentenceGenerationPolicy.contextTokens else {
            throw AppError.invalidState
        }
        activeRequest = id
        let start = ProcessInfo.processInfo.systemUptime
        var response = ""
        var nativeError: String?
        var textPartCount: Int?
        var failureStage: String?
        var failureKind: String?
        var nativeStatusCode: Int?
        var conversationSetupSeconds: Double?
        var responseSeconds: Double?
        var nativeMetrics: GenerationRuntimeMetrics?
        var stage = "creating conversation"
        defer {
            conversation = nil
            activeRequest = nil
            if cancellation?.id == id { cancellation = nil }
        }

        do {
            let config = ConversationConfig(
                systemMessage: Message(promptStyle.systemInstruction, role: .system),
                samplerConfig: try SamplerConfig(topK: GlossSentencePrompt.topK,
                    topP: GlossSentencePrompt.topP, temperature: GlossSentencePrompt.temperature, seed: 42),
                thinkingConfig: ThinkingConfig(enableThinking: false, thinkingTokenBudget: 0),
                enableSpeculativeDecoding: false
            )
            await progress(stage)
            let setupStart = ProcessInfo.processInfo.systemUptime
            let chat = try await engine.createConversation(with: config)
            conversationSetupSeconds = ProcessInfo.processInfo.systemUptime - setupStart
            conversation = chat

            // Keep task/conversation alive until native work returns, including on Stop.
            // The controller owns the independent watchdog and release barrier.
            if cancellation?.id != id {
                let inputMessage = Message(GlossSentencePrompt.make(glosses: glosses))
                stage = "generating full response"
                await progress(stage)
                // Test the non-streaming API to avoid the observed streaming callback stall.
                // The SDK still uses internal callbacks; this is a workaround to validate on device.
                let responseStart = ProcessInfo.processInfo.systemUptime
                let message = try await chat.sendMessage(inputMessage, maxOutputTokens: SentenceGenerationPolicy.maxOutputTokens)
                responseSeconds = ProcessInfo.processInfo.systemUptime - responseStart
                response = message.toString
                textPartCount = message.contents.reduce(0) { count, content in
                    if case .text = content { return count + 1 }
                    return count
                }
                if previousBenchmarkFlag != nil, let metrics = try? chat.getBenchmarkInfo() {
                    nativeMetrics = GenerationRuntimeMetrics(
                        initializationSeconds: metrics.initTimeInSecond,
                        timeToFirstTokenSeconds: metrics.timeToFirstTokenInSecond,
                        lastPrefillTokenCount: metrics.lastPrefillTokenCount,
                        lastDecodeTokenCount: metrics.lastDecodeTokenCount,
                        lastPrefillTokensPerSecond: metrics.lastPrefillTokensPerSecond,
                        lastDecodeTokensPerSecond: metrics.lastDecodeTokensPerSecond)
                }
            }
        } catch {
            failureStage = stage
            failureKind = "runtime"
            if let sdkError = error as? LiteRTLMError {
                switch sdkError {
                case .engine: failureKind = "engine"
                case .config: failureKind = "configuration"
                case .conversation(let detail):
                    failureKind = "conversation"
                    if case .failedToStartStream(let status, _) = detail { nativeStatusCode = status }
                default: break
                }
            } else if error is CancellationError { failureKind = "cancellation" }
            // Native error strings may echo private input. Conversation diagnostics
            // contain only our fixed stage/category and a numeric SDK status.
            if promptID != "conversation" { nativeError = String(describing: error) }
        }
        await progress("reading conversation token count")
        let tokens = try? conversation?.getTokenCount()
        await progress("releasing conversation")
        let reason = cancellation?.id == id ? cancellation?.reason : nil
        var textDiagnostics = GenerationTextDiagnostics.inspect(glosses: glosses, response: response, textPartCount: textPartCount)
        textDiagnostics.promptRevision = promptStyle.revision
        textDiagnostics.systemInstructionUsed = true
        textDiagnostics.samplerTopK = GlossSentencePrompt.topK
        textDiagnostics.samplerTopP = GlossSentencePrompt.topP
        textDiagnostics.samplerTemperature = GlossSentencePrompt.temperature
        textDiagnostics.configuredContextTokens = loadedContextTokens
        textDiagnostics.resourceRevision = promptStyle == .compact ? "compact-context-trial-v1" : SentenceGenerationPolicy.resourceRevision
        textDiagnostics.systemPromptUTF8Bytes = promptStyle.systemInstruction.utf8.count
        textDiagnostics.systemPromptWordCount = promptStyle.systemInstruction.split(whereSeparator: \.isWhitespace).count
        return GenerationMeasurement(
            backend: loadedBackend,
            promptID: promptID,
            elapsedSeconds: ProcessInfo.processInfo.systemUptime - start,
            firstTextSeconds: nil, // Full-response mode cannot measure first streamed text.
            streamChunks: 0,
            conversationTokens: tokens,
            outcome: reason ?? (failureStage != nil ? "failed" : response.isEmpty ? "empty response" : "completed"),
            response: response,
            nativeError: nativeError,
            textDiagnostics: textDiagnostics,
            failureStage: failureStage, failureKind: failureKind, nativeStatusCode: nativeStatusCode,
            conversationSetupSeconds: conversationSetupSeconds, responseSeconds: responseSeconds,
            nativeMetrics: nativeMetrics
        )
    }

    func cancel(id: UUID, reason: String) throws {
        if cancellation?.id != id { cancellation = (id, reason) }
        if activeRequest == id { try conversation?.cancel() }
    }

    func unload() throws {
        guard activeRequest == nil else { throw AppError.invalidState }
        conversation = nil
        engine = nil
        restoreBenchmarkFlag()
        cancellation = nil
    }

    private func restoreBenchmarkFlag() {
        if let previousBenchmarkFlag { ExperimentalFlags.enableBenchmark = previousBenchmarkFlag }
        previousBenchmarkFlag = nil
    }
}

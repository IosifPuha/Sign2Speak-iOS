import Foundation

enum SentenceGenerationPolicy {
    // Short v5 requests measured ~570–581 total tokens on SE2. Keep the full
    // prompt and output allowance, but reserve less KV capacity for short input.
    // This is a measured-envelope policy, NOT a tokenizer or a guaranteed bound.
    static let contextTokens = 768
    static let extendedContextTokens = 1_024
    static let compactTrialContextTokens = 512
    static let maxOutputTokens = 64
    static let resourceRevision = "short-context-v1"

    static func contextTokens(for glosses: String) -> Int {
        glosses.utf8.count <= 64 ? contextTokens : extendedContextTokens
    }
}

enum SentencePromptStyle: String, CaseIterable, Sendable {
    case reference, compact

    var revision: String {
        self == .reference ? GlossSentencePrompt.revision : "compact-meaning-trial-v2"
    }

    var systemInstruction: String {
        switch self {
        case .reference: return GlossSentencePrompt.systemInstruction
        case .compact:
            return """
            Interpret ASL glosses as natural spoken English. Return only the utterance. Supply English grammar. For personal actions, default to I unless another subject is given; do not turn them into commands. Use will for future actions and past tense for past actions. Preserve explicit requests and commands. Preserve every meaning: negation, time, feelings, requests and intentional repetition. Infer reasonable relationships between signs; do not merely list them or invent facts. A feeling with a request must express both.
            Examples:
            WATER PLEASE → Can I have some water, please?
            NO LIKE MILK → I don't like milk.
            YESTERDAY DRINK MILK → I drank milk yesterday.
            THIRSTY WATER PLEASE → I'm thirsty. Could I have some water?
            TOMORROW GO → I will go tomorrow.
            """
        }
    }
}

enum GlossSentencePrompt {
    static let revision = "reference-complete-meaning-v5"
    static let topK: Int = 40
    static let topP: Float = 0.95
    static let temperature: Float = 0.3

    // Full reference Android examples plus explicit preservation of supplied meaning.
    static let systemInstruction = """
    You are an ASL (American Sign Language) interpreter. You receive a sequence of ASL glosses and must convert them into natural English sentences.

    ASL grammar is different from English:
    - ASL uses topic-comment structure (topic first)
    - Time indicators come first ("YESTERDAY I GO STORE" = "I went to the store yesterday")
    - No articles (a, the) or "to be" verbs in ASL

    Rules:
    - Output ONLY the English sentence, nothing else
    - Keep it concise and natural
    - If glosses are unclear, make the most reasonable interpretation
    - Express every supplied meaning explicitly. Do not drop a feeling, time, negation or request to shorten the sentence.
    - When a feeling accompanies a request, include both: state the feeling and make the request. Use one or two sentences as needed.

    Examples of semantic inference with our current 50-sign vocabulary:

    "WATER PLEASE" → "Can I have some water, please?"
    "HUNGRY FOOD PLEASE" → "I'm hungry. Could I have some food, please?"
    "THIRSTY WATER PLEASE" → "I'm thirsty. Could I have some water?"
    "SICK" → "I feel sick."
    "WHERE MOM" → "Where is my mom?"
    "WHERE DAD" → "Where is my dad?"
    "WHO PERSON" → "Who is this person?"
    "WHY SAD" → "Why are you sad?"
    "HAPPY" → "I'm happy."
    "MAD" → "I'm angry."
    "GO NOW" → "I’m leaving now."
    "SEE TOMORROW" → "See you tomorrow."
    "WAIT PLEASE" → "Please wait."
    "THANKYOU" → "Thank you."
    "HELLO" → "Hello."
    "BYE" → "Goodbye."
    "GO SLEEP NOW" → "I'm going to sleep now."
    "WAKE MORNING" → "Wake me up in the morning."
    "FOOD FINISH" → "The food is finished."
    "OPEN PLEASE" → "Can you open it, please?"
    "CLOSE PLEASE" → "Can you close it, please?"
    "LISTEN PLEASE" → "Please listen."
    "LOOK PLEASE" → "Please look."
    "TALK LATER" → "Can we talk later?"
    "JOB INTERVIEW ME GO" → "I'm going to a job interview."
    "JOB INTERVIEW FINISH REJECT AGAIN" → "The job interview is over. I got rejected again."
    """

    static func make(glosses: String) -> String {
        "ASL glosses: \(glosses)"
    }
}

struct GenerationTextDiagnostics: Codable, Sendable {
    var confirmedTokenCount: Int?
    var promptRevision: String?
    var systemInstructionUsed: Bool?
    var samplerTopK: Int?
    var samplerTopP: Float?
    var samplerTemperature: Float?
    var configuredContextTokens: Int?
    var resourceRevision: String?
    var systemPromptUTF8Bytes: Int?
    var systemPromptWordCount: Int?
    let inputWordCount: Int
    let outputWordCount: Int
    let outputTextPartCount: Int?
    let unexpectedSingleGlossRepetition: Bool

    static func inspect(glosses: String, response: String, textPartCount: Int? = nil) -> Self {
        func words(_ text: String) -> [String] {
            text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
        }
        let input = words(glosses)
        let output = words(response)
        return Self(inputWordCount: input.count, outputWordCount: output.count,
            outputTextPartCount: textPartCount,
            unexpectedSingleGlossRepetition: input.count == 1 && output.count > 1
                && output.allSatisfy { $0 == input[0] })
    }
}

struct GenerationMeasurement: Codable, Sendable {
    let backend: String
    let promptID: String
    let elapsedSeconds: Double
    let firstTextSeconds: Double?
    let streamChunks: Int
    let conversationTokens: Int?
    var outcome: String
    let response: String
    let nativeError: String?
    var textDiagnostics: GenerationTextDiagnostics?
    var failureStage: String?
    var failureKind: String?
    var nativeStatusCode: Int?
    var conversationSetupSeconds: Double?
    var responseSeconds: Double?
    var nativeMetrics: GenerationRuntimeMetrics?
}

// Numeric SDK counters only. Experimental metrics can be unavailable or NaN;
// neither should fail generation or make the JSON checkpoint unencodable.
struct GenerationRuntimeMetrics: Codable, Sendable {
    let initializationSeconds: Double?
    let timeToFirstTokenSeconds: Double?
    let lastPrefillTokenCount: Int
    let lastDecodeTokenCount: Int
    let lastPrefillTokensPerSecond: Double?
    let lastDecodeTokensPerSecond: Double?

    init(initializationSeconds: Double, timeToFirstTokenSeconds: Double,
         lastPrefillTokenCount: Int, lastDecodeTokenCount: Int,
         lastPrefillTokensPerSecond: Double, lastDecodeTokensPerSecond: Double) {
        func finite(_ value: Double) -> Double? { value.isFinite && value >= 0 ? value : nil }
        self.initializationSeconds = finite(initializationSeconds)
        self.timeToFirstTokenSeconds = finite(timeToFirstTokenSeconds)
        self.lastPrefillTokenCount = max(0, lastPrefillTokenCount)
        self.lastDecodeTokenCount = max(0, lastDecodeTokenCount)
        self.lastPrefillTokensPerSecond = finite(lastPrefillTokensPerSecond)
        self.lastDecodeTokensPerSecond = finite(lastDecodeTokensPerSecond)
    }
}

struct LoadMeasurement: Codable {
    let backend: String
    let seconds: Double
    var contextTokens: Int?
    var nativeProfilingEnabled: Bool?
}
protocol SentenceGenerator: Sendable {
    func load(model: URL, gpu: Bool, cache: URL, contextTokens: Int, profiling: Bool) async throws -> Double
    func generate(id: UUID, promptID: String, glosses: String, promptStyle: SentencePromptStyle,
                  progress: @escaping @Sendable (String) async -> Void) async throws -> GenerationMeasurement
    func cancel(id: UUID, reason: String) async throws
    func unload() async throws
}

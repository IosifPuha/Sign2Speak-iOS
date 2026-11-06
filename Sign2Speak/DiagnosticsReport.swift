import Darwin
import Foundation
import os

struct MemoryObservation: Codable {
    let recordedAt: Date
    let reason: String
    let phase: String
    let promptID: String?
    let warningNumber: Int?
    let physicalFootprintBytes: UInt64?
    let availableProcessMemoryBytes: UInt64?
    let thermalState: Int
    let lowPowerMode: Bool
}
struct DiagnosticsReport: Codable {
    var version = 50
    var replyRuns: [ReplyRecognitionMeasurement]? = [] // Metadata only; no recognized text/audio.
    var speechRuns: [SpeechMeasurement]? = [] // Metadata only; no spoken text.
    var sessionID = UUID()
    var startedAt = Date()
    var updatedAt = Date()
    var hardware = hardwareIdentifier()
    var os = ProcessInfo.processInfo.operatingSystemVersionString
    var runtime = "LiteRT-LM 0.18.0"
    var model = ModelManifest.gemma
    var backend = "CPU"
    var contextTokens = SentenceGenerationPolicy.contextTokens
    var maxOutputTokens = SentenceGenerationPolicy.maxOutputTokens
    var thinkingEnabled = false
    var generationTimeoutSeconds = 30
    // Optional additions keep version-1 checkpoints decodable.
    var generationAPI: String? = "sendMessage (full response)"
    var cancellationGraceSeconds: Int? = 10
    var activePromptID: String?
    var buildConfiguration: String? = appBuildConfiguration()
    var devicePhysicalMemoryBytes: UInt64? = ProcessInfo.processInfo.physicalMemory
    var memoryWarningCount: Int? = 0
    var memoryObservations: [MemoryObservation]? = []
    var latestPhysicalFootprintBytes: UInt64?
    var latestAvailableProcessMemoryBytes: UInt64?
    var minimumAvailableProcessMemoryBytes: UInt64?
    var activeCameraID: UUID?
    var activeCameraMeasurement: CameraMeasurement?
    var cameraCaptures: [CameraMeasurement]? = []
    var activeClassifierID: UUID?
    var activeClassifierMeasurement: ClassifierMeasurement?
    var classifierRuns: [ClassifierMeasurement]? = [] // Latest 20; absent in older reports.
    var classifierTimeoutSeconds: Int? = 30
    var running = false
    var phase = "idle"
    var sampleCount = 0
    var failedMemorySamples = 0
    var peakPhysicalFootprintBytes: UInt64 = 0
    var phasePeaksBytes: [String: UInt64] = [:]
    var loads: [LoadMeasurement] = []
    var generations: [GenerationMeasurement] = []
    var events: [String] = []
    var memoryNote = "Sampled process phys_footprint at 5 Hz and lifecycle events, not total device RAM or guaranteed peak. os_proc_available_memory is an advisory per-app allowance, not system free RAM or a guarantee against memory warnings/termination; zero can mean the limit is exceeded or the caller is not an app. Unavailable readings are omitted. Memory observations retain the latest 64 entries; warning count covers all received notifications. Validate GPU/driver accounting and transient peaks with Instruments and jetsam reports. Compilation cache is retained between loads."

    mutating func sample() {
        sampleCount += 1
        latestAvailableProcessMemoryBytes = availableProcessMemory()
        if let available = latestAvailableProcessMemoryBytes {
            minimumAvailableProcessMemoryBytes = min(minimumAvailableProcessMemoryBytes ?? available, available)
        }
        latestPhysicalFootprintBytes = physicalFootprint()
        guard let bytes = latestPhysicalFootprintBytes else {
            failedMemorySamples += 1
            return
        }
        peakPhysicalFootprintBytes = max(peakPhysicalFootprintBytes, bytes)
        phasePeaksBytes[phase] = max(phasePeaksBytes[phase] ?? 0, bytes)
    }

    mutating func observeMemory(reason: String, warningNumber: Int? = nil) {
        sample()
        let observation = MemoryObservation(
            recordedAt: Date(), reason: reason, phase: phase, promptID: activePromptID,
            warningNumber: warningNumber, physicalFootprintBytes: latestPhysicalFootprintBytes,
            availableProcessMemoryBytes: latestAvailableProcessMemoryBytes,
            thermalState: ProcessInfo.processInfo.thermalState.rawValue,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        if memoryObservations == nil { memoryObservations = [] }
        memoryObservations?.append(observation)
        if (memoryObservations?.count ?? 0) > 64 { memoryObservations?.removeFirst() }
    }

    func json(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        if prettyPrinted { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

func appBuildConfiguration() -> String {
    #if DEBUG
    return "Debug"
    #else
    return "Release"
    #endif
}

func availableProcessMemory() -> UInt64? {
    #if os(iOS)
    return UInt64(os_proc_available_memory())
    #else
    // The command-line host checks do not have an iOS app memory allowance.
    return nil
    #endif
}

func hardwareIdentifier() -> String {
    var system = utsname()
    uname(&system)
    return withUnsafeBytes(of: &system.machine) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}

func physicalFootprint() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let capacity = Int(count)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : nil
}

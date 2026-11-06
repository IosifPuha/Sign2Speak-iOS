import Foundation

enum AppError: LocalizedError {
    case invalidModel(String)
    case invalidState

    var errorDescription: String? {
        switch self {
        case .invalidModel(let message): return message
        case .invalidState: return "The runtime is not ready for this operation."
        }
    }
}

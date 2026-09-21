import Foundation

enum ExecutorError: Error, LocalizedError {
    case appNotFound(String)
    case missingSlot(String)
    case controlFailed(String)

    var errorDescription: String? {
        switch self {
        case .appNotFound(let name): return "Could not find app: \(name)"
        case .missingSlot(let what): return "Missing \(what)"
        case .controlFailed(let what): return what
        }
    }
}


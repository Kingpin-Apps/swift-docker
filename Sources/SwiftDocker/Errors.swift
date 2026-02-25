import Foundation

public enum DockerError: Error, CustomStringConvertible, Equatable {
    case invalidBasePath(String?)
    case valueError(String?)
    
    public var description: String {
        switch self {
            case .invalidBasePath(let message):
                return message ?? "Invalid base path."
            case .valueError(let message):
                return message ?? "The value is invalid."
        }
    }
}

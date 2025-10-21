//
//  CallError.swift
//  CicareSdkCall
//
//  Created by Mohammad Annas Al Hariri on 20/10/25.
//
import Foundation

public enum ErrorCode: Int, CustomStringConvertible {
    case microphonePermissionDenied = 101
    case apiUnauthorized = 401
    case internalServerError = 400
    
    public var description: String {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission denied."
        case .apiUnauthorized:
            return "API Unauthorized."
        case .internalServerError:
            return "Internal server error."
        }
    }
}

public enum CallError: LocalizedError {
    case microphonePermissionDenied
    case apiUnauthorized
    /// Internal server error with dynamic code and message from backend.
    case internalServerError(code: Int, message: String)
    
    /// Returns the associated local `ErrorCode` when applicable.
    public var code: ErrorCode? {
        switch self {
        case .microphonePermissionDenied:
            return .microphonePermissionDenied
        case .apiUnauthorized:
            return .apiUnauthorized
        case .internalServerError:
            return nil // handled by dynamic server code
        }
    }
    
    /// Returns a unified error code (local or server).
    public var numericCode: Int {
        switch self {
        case .microphonePermissionDenied:
            return ErrorCode.microphonePermissionDenied.rawValue
        case .apiUnauthorized:
            return ErrorCode.apiUnauthorized.rawValue
        case .internalServerError(let code, _):
            return code
        }
    }
    
    /// Human-readable message for each error case.
    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return ErrorCode.microphonePermissionDenied.description
        case .apiUnauthorized:
            return ErrorCode.apiUnauthorized.description
        case .internalServerError(_, let message):
            return message
        }
    }
}

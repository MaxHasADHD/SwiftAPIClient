//
//  CustomResponseHandlerTests.swift
//  SwiftAPIClient
//
//  Created by Maximilian Litteral on 2/23/26.
//

import Foundation
import Testing
@testable import SwiftAPIClient

// MARK: - Test Custom Error Types

enum TraktError: Error, Equatable {
    case accountLimitExceeded
    case accountLocked
    case vipOnly
    case standard(APIError)
}

struct TraktResponseHandler: ResponseHandler {
    func handleResponse(_ response: URLResponse?) throws {
        guard let response else { return }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unhandled(response)
        }
        
        guard 200...299 ~= httpResponse.statusCode else {
            // Handle Trakt-specific status codes
            switch httpResponse.statusCode {
            case 420:
                throw TraktError.accountLimitExceeded
            case 423:
                throw TraktError.accountLocked
            case 426:
                throw TraktError.vipOnly
            default:
                // Fall back to standard HTTP error handling
                try throwStandardError(for: httpResponse)
            }
            return
        }
    }
}

// MARK: - Tests

@Suite("CustomResponseHandler Tests")
struct CustomResponseHandlerTests {
    
    let handler = TraktResponseHandler()
    
    // MARK: - Success Cases
    
    @Test("Returns successfully for 2xx status codes")
    func successfulResponses() throws {
        let url = URL(string: "https://api.trakt.tv/test")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )
        
        // Should not throw
        try handler.handleResponse(response)
    }
    
    // MARK: - Custom Error Cases
    
    @Test("Throws accountLimitExceeded for 420")
    func accountLimitExceeded() throws {
        let url = URL(string: "https://api.trakt.tv/test")!
        let response = HTTPURLResponse(url: url, statusCode: 420, httpVersion: "HTTP/1.1", headerFields: nil)
        
        #expect(throws: TraktError.accountLimitExceeded) {
            try handler.handleResponse(response)
        }
    }
    
    @Test("Throws accountLocked for 423")
    func accountLocked() throws {
        let url = URL(string: "https://api.trakt.tv/test")!
        let response = HTTPURLResponse(url: url, statusCode: 423, httpVersion: "HTTP/1.1", headerFields: nil)
        
        #expect(throws: TraktError.accountLocked) {
            try handler.handleResponse(response)
        }
    }
    
    @Test("Throws vipOnly for 426")
    func vipOnly() throws {
        let url = URL(string: "https://api.trakt.tv/test")!
        let response = HTTPURLResponse(url: url, statusCode: 426, httpVersion: "HTTP/1.1", headerFields: nil)
        
        #expect(throws: TraktError.vipOnly) {
            try handler.handleResponse(response)
        }
    }
    
    // MARK: - Standard Error Fallback
    
    @Test("Falls back to standard error handling for 401")
    func standardUnauthorized() throws {
        let url = URL(string: "https://api.trakt.tv/test")!
        let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)
        
        #expect(throws: APIError.unauthorized) {
            try handler.handleResponse(response)
        }
    }
    
    @Test("Falls back to standard error handling for 404")
    func standardNotFound() throws {
        let url = URL(string: "https://api.trakt.tv/test")!
        let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)
        
        #expect(throws: APIError.notFound) {
            try handler.handleResponse(response)
        }
    }
    
    @Test("Falls back to standard error handling for 500")
    func standardServerError() throws {
        let url = URL(string: "https://api.trakt.tv/test")!
        let response = HTTPURLResponse(url: url, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)
        
        #expect(throws: APIError.serverError) {
            try handler.handleResponse(response)
        }
    }
    
    // MARK: - Retry Functionality Preserved
    
    @Test("Preserves retry functionality for 429 with retry-after")
    func retryFunctionalityPreserved() throws {
        let url = URL(string: "https://api.trakt.tv/test")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: ["retry-after": "60"]
        )
        
        do {
            try handler.handleResponse(response)
            Issue.record("Expected retry error to be thrown")
        } catch let error as APIError {
            guard case .retry(let delay) = error else {
                Issue.record("Expected .retry error, got \(error)")
                return
            }
            #expect(delay == 60.0)
        }
    }
}

// MARK: - Type Safety Tests

@Suite("Type Safety Tests")
struct TypeSafetyTests {
    
    @Test("Custom error types can be caught directly")
    func typeSafeCatching() {
        let url = URL(string: "https://api.trakt.tv/test")!
        let response = HTTPURLResponse(url: url, statusCode: 420, httpVersion: "HTTP/1.1", headerFields: nil)
        let handler = TraktResponseHandler()
        
        var caughtCorrectError = false
        
        do {
            try handler.handleResponse(response)
        } catch TraktError.accountLimitExceeded {
            caughtCorrectError = true
        } catch {
            Issue.record("Caught wrong error type: \(error)")
        }
        
        #expect(caughtCorrectError)
    }
    
    @Test("Multiple custom error types can be distinguished")
    func multipleErrorTypes() {
        let handler = TraktResponseHandler()
        let url = URL(string: "https://api.trakt.tv/test")!
        
        // Test each custom error
        let testCases: [(statusCode: Int, expectedError: TraktError)] = [
            (420, .accountLimitExceeded),
            (423, .accountLocked),
            (426, .vipOnly)
        ]
        
        for testCase in testCases {
            let response = HTTPURLResponse(
                url: url,
                statusCode: testCase.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
            
            do {
                try handler.handleResponse(response)
                Issue.record("Expected error for status code \(testCase.statusCode)")
            } catch let error as TraktError {
                #expect(error == testCase.expectedError)
            } catch {
                Issue.record("Wrong error type for status code \(testCase.statusCode): \(error)")
            }
        }
    }
    
    @Test("Standard APIError can still be caught alongside custom errors")
    func mixedErrorHandling() {
        let handler = TraktResponseHandler()
        let url = URL(string: "https://api.trakt.tv/test")!
        
        // Custom error
        let customResponse = HTTPURLResponse(url: url, statusCode: 420, httpVersion: "HTTP/1.1", headerFields: nil)
        var caughtCustom = false
        do {
            try handler.handleResponse(customResponse)
        } catch TraktError.accountLimitExceeded {
            caughtCustom = true
        } catch {
            Issue.record("Wrong error for custom: \(error)")
        }
        #expect(caughtCustom)
        
        // Standard error
        let standardResponse = HTTPURLResponse(url: url, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)
        var caughtStandard = false
        do {
            try handler.handleResponse(standardResponse)
        } catch APIError.unauthorized {
            caughtStandard = true
        } catch {
            Issue.record("Wrong error for standard: \(error)")
        }
        #expect(caughtStandard)
    }
}

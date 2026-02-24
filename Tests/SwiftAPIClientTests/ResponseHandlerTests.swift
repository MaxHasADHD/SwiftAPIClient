//
//  ResponseHandlerTests.swift
//  SwiftAPIClient
//
//  Created by Maximilian Litteral on 2/23/26.
//

import Foundation
import Testing
@testable import SwiftAPIClient

@Suite("DefaultResponseHandler Tests")
struct DefaultResponseHandlerTests {
    
    let handler = DefaultResponseHandler()
    
    // MARK: - Success Cases
    
    @Test("Returns successfully for 2xx status codes")
    func successfulResponses() throws {
        for statusCode in 200...299 {
            let url = URL(string: "https://api.example.com/test")!
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
            
            // Should not throw
            try handler.handleResponse(response)
        }
    }
    
    @Test("Returns successfully for nil response")
    func nilResponse() throws {
        // Should not throw
        try handler.handleResponse(nil)
    }
    
    // MARK: - Client Errors (4xx)
    
    @Test("Throws badRequest for 400")
    func badRequest() throws {
        let url = URL(string: "https://api.example.com/test")!
        let response = HTTPURLResponse(url: url, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: nil)
        
        #expect(throws: APIError.badRequest) {
            try handler.handleResponse(response)
        }
    }
    
    @Test("Throws unauthorized for 401")
    func unauthorized() throws {
        let url = URL(string: "https://api.example.com/test")!
        let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)
        
        #expect(throws: APIError.unauthorized) {
            try handler.handleResponse(response)
        }
    }
    
    @Test("Throws forbidden for 403")
    func forbidden() throws {
        let url = URL(string: "https://api.example.com/test")!
        let response = HTTPURLResponse(url: url, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: nil)
        
        #expect(throws: APIError.forbidden) {
            try handler.handleResponse(response)
        }
    }
    
    @Test("Throws notFound for 404")
    func notFound() throws {
        let url = URL(string: "https://api.example.com/test")!
        let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)
        
        #expect(throws: APIError.notFound) {
            try handler.handleResponse(response)
        }
    }
    
    @Test("Throws methodNotAllowed for 405")
    func methodNotAllowed() throws {
        let url = URL(string: "https://api.example.com/test")!
        let response = HTTPURLResponse(url: url, statusCode: 405, httpVersion: "HTTP/1.1", headerFields: nil)
        
        #expect(throws: APIError.methodNotAllowed) {
            try handler.handleResponse(response)
        }
    }
    
    @Test("Throws conflict for 409")
    func conflict() throws {
        let url = URL(string: "https://api.example.com/test")!
        let response = HTTPURLResponse(url: url, statusCode: 409, httpVersion: "HTTP/1.1", headerFields: nil)
        
        #expect(throws: APIError.conflict) {
            try handler.handleResponse(response)
        }
    }
    
    @Test("Throws preconditionFailed for 412")
    func preconditionFailed() throws {
        let url = URL(string: "https://api.example.com/test")!
        let response = HTTPURLResponse(url: url, statusCode: 412, httpVersion: "HTTP/1.1", headerFields: nil)
        
        #expect(throws: APIError.preconditionFailed) {
            try handler.handleResponse(response)
        }
    }
    
    @Test("Throws unprocessableEntity for 422")
    func unprocessableEntity() throws {
        let url = URL(string: "https://api.example.com/test")!
        let response = HTTPURLResponse(url: url, statusCode: 422, httpVersion: "HTTP/1.1", headerFields: nil)
        
        #expect(throws: APIError.unprocessableEntity) {
            try handler.handleResponse(response)
        }
    }
    
    // MARK: - Rate Limiting (429)
    
    @Test("Throws retry with delay for 429 with string retry-after header")
    func rateLimitWithStringRetryAfter() throws {
        let url = URL(string: "https://api.example.com/test")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: ["retry-after": "30"]
        )
        
        do {
            try handler.handleResponse(response)
            Issue.record("Expected retry error to be thrown")
        } catch let error as APIError {
            guard case .retry(let delay) = error else {
                Issue.record("Expected .retry error, got \(error)")
                return
            }
            #expect(delay == 30.0)
        }
    }
    
    @Test("Throws retry with delay for 429 with numeric retry-after header")
    func rateLimitWithNumericRetryAfter() throws {
        let url = URL(string: "https://api.example.com/test")!
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
    
    @Test("Throws rateLimitExceeded for 429 without retry-after header")
    func rateLimitWithoutRetryAfter() throws {
        let url = URL(string: "https://api.example.com/test")!
        let response = HTTPURLResponse(url: url, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: nil)
        
        do {
            try handler.handleResponse(response)
            Issue.record("Expected rateLimitExceeded error to be thrown")
        } catch let error as APIError {
            guard case .rateLimitExceeded = error else {
                Issue.record("Expected .rateLimitExceeded error, got \(error)")
                return
            }
        }
    }
    
    // MARK: - Server Errors (5xx)
    
    @Test("Throws serverError for 500")
    func serverError() throws {
        let url = URL(string: "https://api.example.com/test")!
        let response = HTTPURLResponse(url: url, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)
        
        #expect(throws: APIError.serverError) {
            try handler.handleResponse(response)
        }
    }
    
    @Test("Throws serviceUnavailable for 502, 503, 504")
    func serviceUnavailable() throws {
        for statusCode in [502, 503, 504] {
            let url = URL(string: "https://api.example.com/test")!
            let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)
            
            #expect(throws: APIError.serviceUnavailable) {
                try handler.handleResponse(response)
            }
        }
    }
    
    @Test("Throws serverError for other 5xx codes")
    func otherServerErrors() throws {
        for statusCode in [501, 505, 520, 599] {
            let url = URL(string: "https://api.example.com/test")!
            let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)
            
            #expect(throws: APIError.serverError) {
                try handler.handleResponse(response)
            }
        }
    }
    
    // MARK: - Unhandled Errors
    
    @Test("Throws unhandled for unrecognized status codes")
    func unhandledStatusCodes() throws {
        for statusCode in [418, 451, 600] {
            let url = URL(string: "https://api.example.com/test")!
            let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)
            
            do {
                try handler.handleResponse(response)
                Issue.record("Expected unhandled error for status code \(statusCode)")
            } catch let error as APIError {
                guard case .unhandled = error else {
                    Issue.record("Expected .unhandled error, got \(error)")
                    return
                }
            }
        }
    }
    
    @Test("Throws unhandled for non-HTTP response")
    func nonHTTPResponse() throws {
        let url = URL(string: "https://api.example.com/test")!
        let response = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        
        #expect(throws: APIError.unhandled(response)) {
            try handler.handleResponse(response)
        }
    }
}

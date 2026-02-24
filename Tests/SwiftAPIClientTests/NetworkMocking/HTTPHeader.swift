//
//  HTTPHeader.swift
//  SwiftAPIClient
//
//  Created by Maximilian Litteral on 2/23/26.
//

import Foundation

public enum HTTPHeader {
    case contentType
    case apiKey(String)
    case page(Int)
    case pageCount(Int)
    case retry(TimeInterval)

    public var key: String {
        switch self {
        case .contentType:
            "Content-type"
        case .apiKey:
            "trakt-api-key"
        case .page:
            "X-Pagination-Page"
        case .pageCount:
            "X-Pagination-Page-Count"
        case .retry:
            "retry-after"
        }
    }

    public var value: String {
        switch self {
        case .contentType:
            "application/json"
        case .apiKey(let apiKey):
            apiKey
        case .page(let page):
            page.description
        case .pageCount(let pageCount):
            pageCount.description
        case .retry(let delay):
            delay.description
        }
    }
}


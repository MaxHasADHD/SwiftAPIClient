//
//  DateParser.swift
//  SwiftAPIClient
//

import Foundation

// Internal
internal let calendar = Calendar.current
internal let dateFormatter = DateFormatter()

@Sendable
public func customDateDecodingStrategy(decoder: Decoder) throws -> Date {
    let container = try decoder.singleValueContainer()
    let str = try container.decode(String.self)
    return try Date.dateFromString(str)
}

public extension Date {

    enum DateParserError: Error {
        case failedToParseDateFromString(String)
    }

    // MARK: - Class

    static func dateFromString(_ dateString: String) throws(DateParserError) -> Date {
        // Try various ISO8601 formats using the modern Date.ParseStrategy API
        // This is thread-safe and avoids shared mutable state
        let gmtTimeZone = TimeZone(secondsFromGMT: 0)!
        
        // Format 1: Full ISO8601 with fractional seconds (yyyy-MM-dd'T'HH:mm:ss.SSSZ)
        var strategy = Date.ISO8601FormatStyle(timeZone: gmtTimeZone)
            .year().month().day()
            .time(includingFractionalSeconds: true)
            .timeZone(separator: .omitted)
        if let date = try? Date(dateString, strategy: strategy) {
            return date
        }
        
        // Format 2: ISO8601 without fractional seconds (yyyy-MM-dd'T'HH:mm:ss or with Z)
        strategy = Date.ISO8601FormatStyle(timeZone: gmtTimeZone)
            .year().month().day()
            .time(includingFractionalSeconds: false)
            .timeZone(separator: .omitted)
        if let date = try? Date(dateString, strategy: strategy) {
            return date
        }
        
        // Format 3: Date with time and space separator (yyyy-MM-dd HH:mm:ss ZZZ)
        // For non-standard formats, we still need DateFormatter but create a local instance
        if dateString.count == 23 && dateString.contains(" ") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZ"
            formatter.timeZone = TimeZone(abbreviation: "GMT")
            if let date = formatter.date(from: dateString) {
                return date
            }
        }
        
        // Format 4: Date only (yyyy-MM-dd)
        strategy = Date.ISO8601FormatStyle(timeZone: gmtTimeZone)
            .year().month().day()
        if let date = try? Date(dateString, strategy: strategy) {
            return date
        }
        
        throw .failedToParseDateFromString("String to parse: \(dateString)")
    }

    func UTCDateString() -> String {
        let format = Date.ISO8601FormatStyle()
            .year().month().day()
            .time(includingFractionalSeconds: true)
            .timeZone(separator: .omitted)
        return self.formatted(format)
    }

    func dateString(withFormat format: String) -> String {
        // For custom formats, create a local DateFormatter instance
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        formatter.timeZone = TimeZone(abbreviation: "GMT")
        return formatter.string(from: self)
    }
}



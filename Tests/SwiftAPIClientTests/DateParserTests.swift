//
//  DateParserTests.swift
//  SwiftAPIClient
//

import Testing
import Foundation
@testable import SwiftAPIClient

@Suite("Date Parser Tests")
struct DateParserTests {
    
    // MARK: - ISO8601 Format Tests
    
    @Test("Parses date with fractional seconds and Z timezone")
    func dateWithFractionalSecondsZ() throws {
        let dateString = "2024-03-15T14:30:45.123Z"
        let date = try Date.dateFromString(dateString)
        
        let components = Calendar.current.dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: date
        )
        
        #expect(components.year == 2024)
        #expect(components.month == 3)
        #expect(components.day == 15)
        #expect(components.hour == 14)
        #expect(components.minute == 30)
        #expect(components.second == 45)
        // Note: Fractional seconds precision may vary by platform
        if let nanoseconds = components.nanosecond {
            let milliseconds = nanoseconds / 1_000_000
            #expect(milliseconds == 123)
        }
    }
    
    @Test("Parses date with fractional seconds and offset")
    func dateWithFractionalSecondsOffset() throws {
        let dateString = "2024-03-15T14:30:45.123+0000"
        let date = try Date.dateFromString(dateString)
        
        let components = Calendar.current.dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: date
        )
        
        #expect(components.year == 2024)
        #expect(components.month == 3)
        #expect(components.day == 15)
        #expect(components.hour == 14)
        #expect(components.minute == 30)
        #expect(components.second == 45)
    }
    
    @Test("Parses date without fractional seconds with Z")
    func dateWithoutFractionalSecondsZ() throws {
        let dateString = "2024-03-15T14:30:45Z"
        let date = try Date.dateFromString(dateString)
        
        let components = Calendar.current.dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: date
        )
        
        #expect(components.year == 2024)
        #expect(components.month == 3)
        #expect(components.day == 15)
        #expect(components.hour == 14)
        #expect(components.minute == 30)
        #expect(components.second == 45)
    }
    
    @Test("Parses date without fractional seconds with offset")
    func dateWithoutFractionalSecondsOffset() throws {
        let dateString = "2024-03-15T14:30:45+0000"
        let date = try Date.dateFromString(dateString)
        
        let components = Calendar.current.dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: date
        )
        
        #expect(components.year == 2024)
        #expect(components.month == 3)
        #expect(components.day == 15)
        #expect(components.hour == 14)
        #expect(components.minute == 30)
        #expect(components.second == 45)
    }
    
    @Test("Parses date-only format")
    func dateOnly() throws {
        let dateString = "2024-03-15"
        let date = try Date.dateFromString(dateString)
        
        let components = Calendar.current.dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: date
        )
        
        #expect(components.year == 2024)
        #expect(components.month == 3)
        #expect(components.day == 15)
    }
    
    @Test("Parses date with space separator and timezone")
    func dateWithSpaceSeparator() throws {
        let dateString = "2024-03-15 14:30:45 GMT"
        let date = try Date.dateFromString(dateString)
        
        let components = Calendar.current.dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: date
        )
        
        #expect(components.year == 2024)
        #expect(components.month == 3)
        #expect(components.day == 15)
        #expect(components.hour == 14)
        #expect(components.minute == 30)
        #expect(components.second == 45)
    }
    
    // MARK: - Error Handling Tests
    
    @Test("Throws error for invalid date string")
    func invalidDateString() {
        let dateString = "not-a-date"
        
        #expect(throws: Date.DateParserError.self) {
            try Date.dateFromString(dateString)
        }
    }
    
    @Test("Throws error for malformed ISO8601 date")
    func malformedDate() {
        let dateString = "2024-13-45T25:70:90Z" // Invalid month, day, hour, minute, second
        
        #expect(throws: Date.DateParserError.self) {
            try Date.dateFromString(dateString)
        }
    }
    
    @Test("Throws error for empty string")
    func emptyString() {
        let dateString = ""
        
        #expect(throws: Date.DateParserError.self) {
            try Date.dateFromString(dateString)
        }
    }
    
    // MARK: - Edge Cases
    
    @Test("Parses leap year date")
    func leapYearDate() throws {
        let dateString = "2024-02-29"
        let date = try Date.dateFromString(dateString)
        
        let components = Calendar.current.dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: date
        )
        
        #expect(components.year == 2024)
        #expect(components.month == 2)
        #expect(components.day == 29)
    }
    
    @Test("Parses midnight time")
    func midnightTime() throws {
        let dateString = "2024-03-15T00:00:00Z"
        let date = try Date.dateFromString(dateString)
        
        let components = Calendar.current.dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: date
        )
        
        #expect(components.year == 2024)
        #expect(components.month == 3)
        #expect(components.day == 15)
        #expect(components.hour == 0)
        #expect(components.minute == 0)
        #expect(components.second == 0)
    }
    
    @Test("Parses end of day time")
    func endOfDayTime() throws {
        let dateString = "2024-03-15T23:59:59Z"
        let date = try Date.dateFromString(dateString)
        
        let components = Calendar.current.dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: date
        )
        
        #expect(components.year == 2024)
        #expect(components.month == 3)
        #expect(components.day == 15)
        #expect(components.hour == 23)
        #expect(components.minute == 59)
        #expect(components.second == 59)
    }
    
    // MARK: - Thread Safety Tests
    
    @Test("Handles concurrent date parsing without race conditions")
    func concurrentDateParsing() async throws {
        let dateStrings = [
            "2024-03-15T14:30:45.123Z",
            "2024-06-20T08:15:30Z",
            "2024-12-31",
            "2024-01-01T00:00:00+0000",
            "2024-07-04 12:00:00 GMT"
        ]
        
        try await withThrowingTaskGroup(of: Date.self) { group in
            // Parse 100 dates concurrently
            for _ in 0..<100 {
                for dateString in dateStrings {
                    group.addTask {
                        try Date.dateFromString(dateString)
                    }
                }
            }
            
            // Collect all results to ensure they all succeed
            var parsedDates: [Date] = []
            for try await date in group {
                parsedDates.append(date)
            }
            
            #expect(parsedDates.count == 500)
        }
    }
    
    // MARK: - Date String Formatting Tests
    
    @Test("Formats date to UTC string")
    func utcDateStringFormatting() throws {
        let components = DateComponents(
            calendar: Calendar.current,
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2024,
            month: 3,
            day: 15,
            hour: 14,
            minute: 30,
            second: 45,
            nanosecond: 123_000_000
        )
        
        guard let date = components.date else {
            Issue.record("Failed to create date from components")
            return
        }
        
        let utcString = date.UTCDateString()
        
        // Should contain the date and time
        #expect(utcString.contains("2024"))
        #expect(utcString.contains("03"))
        #expect(utcString.contains("15"))
    }
    
    @Test("Formats date with custom format")
    func customDateFormatting() throws {
        let components = DateComponents(
            calendar: Calendar.current,
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2024,
            month: 3,
            day: 15,
            hour: 14,
            minute: 30,
            second: 45
        )
        
        guard let date = components.date else {
            Issue.record("Failed to create date from components")
            return
        }
        
        let formattedString = date.dateString(withFormat: "yyyy-MM-dd")
        #expect(formattedString == "2024-03-15")
    }
    
    // MARK: - Custom Date Decoding Strategy Tests
    
    @Test("Decodes date using custom decoding strategy")
    func customDecodingStrategy() throws {
        struct TestModel: Codable {
            let createdAt: Date
        }
        
        let json = """
        {
            "createdAt": "2024-03-15T14:30:45.123Z"
        }
        """.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(customDateDecodingStrategy)
        
        let model = try decoder.decode(TestModel.self, from: json)
        
        let components = Calendar.current.dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: model.createdAt
        )
        
        #expect(components.year == 2024)
        #expect(components.month == 3)
        #expect(components.day == 15)
        #expect(components.hour == 14)
        #expect(components.minute == 30)
        #expect(components.second == 45)
    }
    
    @Test("Decodes date-only string using custom decoding strategy")
    func customDecodingStrategyDateOnly() throws {
        struct TestModel: Codable {
            let birthDate: Date
        }
        
        let json = """
        {
            "birthDate": "1990-05-20"
        }
        """.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(customDateDecodingStrategy)
        
        let model = try decoder.decode(TestModel.self, from: json)
        
        let components = Calendar.current.dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: model.birthDate
        )
        
        #expect(components.year == 1990)
        #expect(components.month == 5)
        #expect(components.day == 20)
    }
    
    @Test("Decodes multiple date formats in same JSON")
    func multipleFormatsInJSON() throws {
        struct TestModel: Codable {
            let fullDate: Date
            let dateOnly: Date
            let withSpace: Date
        }
        
        let json = """
        {
            "fullDate": "2024-03-15T14:30:45.123Z",
            "dateOnly": "2024-06-20",
            "withSpace": "2024-12-31 23:59:59 GMT"
        }
        """.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(customDateDecodingStrategy)
        
        let model = try decoder.decode(TestModel.self, from: json)
        
        let fullComponents = Calendar.current.dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: model.fullDate
        )
        #expect(fullComponents.year == 2024)
        #expect(fullComponents.month == 3)
        #expect(fullComponents.day == 15)
        
        let dateOnlyComponents = Calendar.current.dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: model.dateOnly
        )
        #expect(dateOnlyComponents.year == 2024)
        #expect(dateOnlyComponents.month == 6)
        #expect(dateOnlyComponents.day == 20)
        
        let spaceComponents = Calendar.current.dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: model.withSpace
        )
        #expect(spaceComponents.year == 2024)
        #expect(spaceComponents.month == 12)
        #expect(spaceComponents.day == 31)
    }
}

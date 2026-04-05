import Foundation

enum ScheduleUnit {
    case minutes(Int)
    case hours(Int)
    case days(Int)
}

enum ScriptType {
    case service
    case scheduled(ScheduleUnit)
}

struct ScriptEntry {
    let url: URL
    let filename: String
    let displayName: String
    let type: ScriptType
    let logURL: URL

    static let logDirectory: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/log")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let servicesDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/services")
    }()

    init?(url: URL) {
        self.url = url
        self.filename = url.lastPathComponent

        // Check executable
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }

        // Parse schedule suffix
        let name = filename
        if let range = name.range(of: #"\.(\d+)(m|h|d)$"#, options: .regularExpression) {
            let suffix = String(name[range]).dropFirst() // drop the leading dot
            let unitChar = suffix.last!
            guard let value = Int(suffix.dropLast()), value > 0 else { return nil }

            switch unitChar {
            case "m": self.type = .scheduled(.minutes(value))
            case "h": self.type = .scheduled(.hours(value))
            case "d": self.type = .scheduled(.days(value))
            default: return nil
            }
            self.displayName = String(name[name.startIndex..<range.lowerBound])
        } else {
            self.type = .service
            self.displayName = name
        }

        self.logURL = ScriptEntry.logDirectory.appendingPathComponent("\(displayName).log")
    }

    static func scan() -> [ScriptEntry] {
        let dir = servicesDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isExecutableKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.compactMap { ScriptEntry(url: $0) }
    }
}

// MARK: - Schedule calculation

extension ScriptEntry {
    /// Calculate the next fire date for a scheduled task, anchored to midnight.
    static func nextFireDate(for unit: ScheduleUnit, after date: Date = Date()) -> Date {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: date)

        switch unit {
        case .minutes(let interval):
            let secondsSinceMidnight = date.timeIntervalSince(midnight)
            let minutesSinceMidnight = Int(secondsSinceMidnight) / 60
            let nextSlot = ((minutesSinceMidnight / interval) + 1) * interval
            // If we've gone past today, wrap to tomorrow
            if nextSlot >= 24 * 60 {
                let tomorrowMidnight = calendar.date(byAdding: .day, value: 1, to: midnight)!
                return tomorrowMidnight
            }
            return calendar.date(byAdding: .minute, value: nextSlot, to: midnight)!

        case .hours(let interval):
            let hourOfDay = calendar.component(.hour, from: date)
            let nextSlot = ((hourOfDay / interval) + 1) * interval
            if nextSlot >= 24 {
                let tomorrowMidnight = calendar.date(byAdding: .day, value: 1, to: midnight)!
                return tomorrowMidnight
            }
            return calendar.date(byAdding: .hour, value: nextSlot, to: midnight)!

        case .days(let interval):
            let dayOfMonth = calendar.component(.day, from: date)
            // Anchor to 1st of month: run on days where (day-1) % interval == 0
            // i.e., day 1, 1+interval, 1+2*interval, ...
            let slotIndex = (dayOfMonth - 1) / interval
            let currentSlotDay = slotIndex * interval + 1
            let nextSlotDay = currentSlotDay + interval

            // Try the next slot in this month
            let daysUntilNextSlot = nextSlotDay - dayOfMonth
            let nextDate = calendar.date(byAdding: .day, value: daysUntilNextSlot, to: midnight)!
            // If we're still in the same month, use it
            if calendar.component(.month, from: nextDate) == calendar.component(.month, from: date) {
                return nextDate
            }

            // Overflow to 1st of next month
            var comps = calendar.dateComponents([.year, .month], from: date)
            comps.month! += 1
            comps.day = 1
            return calendar.date(from: comps) ?? calendar.date(byAdding: .month, value: 1, to: midnight)!
        }
    }
}

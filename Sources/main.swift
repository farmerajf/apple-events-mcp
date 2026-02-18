import Foundation
import EventKit

// MARK: - MCP Protocol Types

struct MCPRequest: Codable, Sendable {
    let jsonrpc: String
    let id: RequestID?
    let method: String
    let params: Params?

    enum RequestID: Codable, Sendable {
        case string(String)
        case int(Int)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                self = .string(string)
            } else if let int = try? container.decode(Int.self) {
                self = .int(int)
            } else {
                throw DecodingError.typeMismatch(RequestID.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "ID must be string or int"))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let string):
                try container.encode(string)
            case .int(let int):
                try container.encode(int)
            }
        }
    }

    struct Params: Codable, Sendable {
        let name: String?
        let arguments: [String: AnyCodable]?
        let protocolVersion: String?
        let capabilities: [String: AnyCodable]?
        let clientInfo: ClientInfo?

        struct ClientInfo: Codable, Sendable {
            let name: String
            let version: String
        }
    }
}

struct MCPResponse: Codable, Sendable {
    var jsonrpc: String = "2.0"
    let id: MCPRequest.RequestID?
    let result: Result?
    let error: MCPError?

    struct Result: Codable, Sendable {
        let content: [Content]?
        let tools: [Tool]?
        let protocolVersion: String?
        let capabilities: Capabilities?
        let serverInfo: ServerInfo?
        let instructions: String?

        struct Content: Codable, Sendable {
            let type: String
            let text: String
        }

        struct Capabilities: Codable, Sendable {
            let tools: ToolsCapability?

            struct ToolsCapability: Codable, Sendable {
                let listChanged: Bool?
            }
        }

        struct ServerInfo: Codable, Sendable {
            let name: String
            let version: String
        }

        struct Tool: Codable, Sendable {
            let name: String
            let description: String
            let inputSchema: InputSchema

            struct InputSchema: Codable, Sendable {
                let type: String
                let properties: [String: Property]
                let required: [String]?

                struct Property: Codable, Sendable {
                    let type: String
                    let description: String
                }
            }
        }
    }

    struct MCPError: Codable, Sendable {
        let code: Int
        let message: String
    }
}

struct AnyCodable: Codable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            value = dictionary.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}

// MARK: - Reminders Manager

class RemindersManager: @unchecked Sendable {
    private let eventStore = EKEventStore()
    private var hasAccess = false

    func requestAccess() async throws {
        hasAccess = try await eventStore.requestFullAccessToReminders()
        if !hasAccess {
            throw NSError(domain: "RemindersManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Access to Reminders denied"])
        }
    }

    func listReminderLists() -> [[String: Any]] {
        let calendars = eventStore.calendars(for: .reminder)
        return calendars.map { calendar in
            [
                "id": calendar.calendarIdentifier,
                "name": calendar.title
            ]
        }
    }

    func createReminderList(name: String) throws -> String {
        // Create a new calendar for reminders
        let calendar = EKCalendar(for: .reminder, eventStore: eventStore)
        calendar.title = name

        // Find the best source (iCloud, then default, then any available)
        guard let source = findBestSource() else {
            throw NSError(domain: "RemindersManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "No available source for creating reminder list"])
        }

        calendar.source = source

        // Save the calendar
        try eventStore.saveCalendar(calendar, commit: true)

        log("Created reminder list '\(name)' with ID: \(calendar.calendarIdentifier)")
        return calendar.calendarIdentifier
    }

    private func findBestSource() -> EKSource? {
        // Try to find iCloud source first
        if let iCloudSource = eventStore.sources.first(where: { $0.title == "iCloud" }) {
            return iCloudSource
        }

        // Fall back to default calendar's source
        if let defaultSource = eventStore.defaultCalendarForNewReminders()?.source {
            return defaultSource
        }

        // Last resort: use any available source
        return eventStore.sources.first
    }

    func getTodayReminders() -> [[String: Any]] {
        let startTime = Date()
        log("Starting getTodayReminders")

        let calendars = eventStore.calendars(for: .reminder)
        let predicate = eventStore.predicateForReminders(in: calendars)
        var allReminders: [EKReminder] = []
        let semaphore = DispatchSemaphore(value: 0)

        eventStore.fetchReminders(matching: predicate) { reminders in
            if let reminders = reminders {
                allReminders = reminders
            }
            semaphore.signal()
        }

        semaphore.wait()

        let fetchTime = Date().timeIntervalSince(startTime)
        log("Fetched \(allReminders.count) reminders in \(Int(fetchTime * 1000))ms")

        // Get today's date boundaries
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday)!

        // Filter for incomplete reminders that are due today or past due
        let filtered = allReminders.filter { reminder in
            guard !reminder.isCompleted else { return false }
            guard let dueDateComponents = reminder.dueDateComponents,
                  let dueDate = dueDateComponents.date else { return false }

            // Include if due date is today or earlier
            return dueDate < endOfToday
        }

        log("Found \(filtered.count) reminders due today or past due")

        let result = filtered.map { reminder -> [String: Any] in
            var dict: [String: Any] = [
                "id": reminder.calendarItemIdentifier,
                "name": reminder.title ?? "",
                "completed": reminder.isCompleted
            ]

            if let notes = reminder.notes, !notes.isEmpty {
                dict["body"] = notes
            }

            if let dueDate = reminder.dueDateComponents?.date {
                let formatter = ISO8601DateFormatter()
                dict["dueDate"] = formatter.string(from: dueDate)

                // Add indicator for past due
                if dueDate < startOfToday {
                    dict["pastDue"] = true
                }
            }

            if let calendar = reminder.calendar {
                dict["listName"] = calendar.title
            }

            dict["priority"] = reminder.priority

            return dict
        }

        let totalTime = Date().timeIntervalSince(startTime)
        log("Total operation took \(Int(totalTime * 1000))ms")

        return result
    }

    func listReminders(listName: String?, showCompleted: Bool) -> [[String: Any]] {
        let startTime = Date()
        log("Starting listReminders for list: \(listName ?? "all")")

        let calendars: [EKCalendar]
        if let listName = listName {
            calendars = eventStore.calendars(for: .reminder).filter { $0.title == listName }
            if calendars.isEmpty {
                log("List '\(listName)' not found")
                return []
            }
        } else {
            calendars = eventStore.calendars(for: .reminder)
        }

        let predicate = eventStore.predicateForReminders(in: calendars)
        var allReminders: [EKReminder] = []
        let semaphore = DispatchSemaphore(value: 0)

        eventStore.fetchReminders(matching: predicate) { reminders in
            if let reminders = reminders {
                allReminders = reminders
            }
            semaphore.signal()
        }

        semaphore.wait()

        let fetchTime = Date().timeIntervalSince(startTime)
        log("Fetched \(allReminders.count) reminders in \(Int(fetchTime * 1000))ms")

        // Filter by completion status
        let filtered = allReminders.filter { $0.isCompleted == showCompleted }
        log("After filtering: \(filtered.count) reminders (showCompleted=\(showCompleted))")

        let result = filtered.map { reminder -> [String: Any] in
            var dict: [String: Any] = [
                "id": reminder.calendarItemIdentifier,
                "name": reminder.title ?? "",
                "completed": reminder.isCompleted
            ]

            if let notes = reminder.notes, !notes.isEmpty {
                dict["body"] = notes
            }

            if let dueDate = reminder.dueDateComponents?.date {
                let formatter = ISO8601DateFormatter()
                dict["dueDate"] = formatter.string(from: dueDate)
            }

            if let calendar = reminder.calendar {
                dict["listName"] = calendar.title
            }

            dict["priority"] = reminder.priority

            // Note: Tags are not accessible via EventKit API
            // Apple's EventKit framework does not expose the tags feature that exists
            // in the Reminders app. This is a known limitation with no public API solution.

            return dict
        }

        let totalTime = Date().timeIntervalSince(startTime)
        log("Total operation took \(Int(totalTime * 1000))ms")

        return result
    }

    func createReminder(title: String, listName: String, notes: String?, dueDate: String?) throws -> String {
        let calendars = eventStore.calendars(for: .reminder).filter { $0.title == listName }
        guard let calendar = calendars.first else {
            throw NSError(domain: "RemindersManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "List '\(listName)' not found"])
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = calendar
        reminder.title = title

        if let notes = notes {
            reminder.notes = notes
        }

        if let dueDateString = dueDate {
            // Try to parse as ISO8601 first (full datetime)
            let iso8601Formatter = ISO8601DateFormatter()

            if let date = iso8601Formatter.date(from: dueDateString) {
                // Full datetime provided - include time components
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                reminder.dueDateComponents = components
            } else {
                // Try to parse as date-only format (YYYY-MM-DD)
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"
                dateFormatter.timeZone = TimeZone.current

                if let date = dateFormatter.date(from: dueDateString) {
                    // Date only - don't set time components (just year, month, day)
                    var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
                    // Explicitly ensure no time components
                    components.hour = nil
                    components.minute = nil
                    components.second = nil
                    reminder.dueDateComponents = components
                }
            }
        }

        try eventStore.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    func completeReminder(id: String) throws {
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw NSError(domain: "RemindersManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Reminder not found"])
        }

        reminder.isCompleted = true
        try eventStore.save(reminder, commit: true)
    }

    func deleteReminder(id: String) throws {
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw NSError(domain: "RemindersManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "Reminder not found"])
        }

        try eventStore.remove(reminder, commit: true)
    }

    func updateReminder(id: String, title: String?, notes: String?, dueDate: String?, priority: Int?) throws {
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
            throw NSError(domain: "RemindersManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "Reminder not found"])
        }

        if let title = title {
            reminder.title = title
        }

        if let notes = notes {
            reminder.notes = notes
        }

        if let dueDateString = dueDate {
            if dueDateString.isEmpty {
                // Empty string means clear the due date
                reminder.dueDateComponents = nil
            } else {
                // Try to parse as ISO8601 first (full datetime)
                let iso8601Formatter = ISO8601DateFormatter()

                if let date = iso8601Formatter.date(from: dueDateString) {
                    // Full datetime provided - include time components
                    let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                    reminder.dueDateComponents = components
                } else {
                    // Try to parse as date-only format (YYYY-MM-DD)
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "yyyy-MM-dd"
                    dateFormatter.timeZone = TimeZone.current

                    if let date = dateFormatter.date(from: dueDateString) {
                        // Date only - don't set time components (just year, month, day)
                        var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
                        // Explicitly ensure no time components
                        components.hour = nil
                        components.minute = nil
                        components.second = nil
                        reminder.dueDateComponents = components
                    }
                }
            }
        }

        if let priority = priority {
            reminder.priority = priority
        }

        try eventStore.save(reminder, commit: true)
    }
}

// MARK: - Calendar Manager

class CalendarManager: @unchecked Sendable {
    private let eventStore = EKEventStore()
    private var hasAccess = false

    func requestAccess() async throws {
        hasAccess = try await eventStore.requestFullAccessToEvents()
        if !hasAccess {
            throw NSError(domain: "CalendarManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Access to Calendar denied"])
        }
    }

    func listCalendars() -> [[String: Any]] {
        let calendars = eventStore.calendars(for: .event)
        return calendars.map { calendar in
            [
                "id": calendar.calendarIdentifier,
                "name": calendar.title
            ]
        }
    }

    func getTodayEvents() -> [[String: Any]] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
        return getEvents(calendarName: nil, startDate: startOfToday, endDate: endOfToday)
    }

    func getEvents(calendarName: String?, startDate: Date, endDate: Date) -> [[String: Any]] {
        let startTime = Date()
        log("Starting getEvents from \(startDate) to \(endDate)")

        let calendars: [EKCalendar]
        if let calendarName = calendarName {
            calendars = eventStore.calendars(for: .event).filter { $0.title == calendarName }
            if calendars.isEmpty {
                log("Calendar '\(calendarName)' not found")
                return []
            }
        } else {
            calendars = eventStore.calendars(for: .event)
        }

        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        let events = eventStore.events(matching: predicate)

        let fetchTime = Date().timeIntervalSince(startTime)
        log("Fetched \(events.count) events in \(Int(fetchTime * 1000))ms")

        return events.map { formatEvent($0) }
    }

    func createEvent(title: String, calendarName: String?, startDate: Date, endDate: Date, isAllDay: Bool, location: String?, notes: String?, url: String?) throws -> String {
        let calendar: EKCalendar
        if let calendarName = calendarName {
            guard let found = eventStore.calendars(for: .event).first(where: { $0.title == calendarName }) else {
                throw NSError(domain: "CalendarManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Calendar '\(calendarName)' not found"])
            }
            calendar = found
        } else {
            guard let defaultCalendar = eventStore.defaultCalendarForNewEvents else {
                throw NSError(domain: "CalendarManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "No default calendar available"])
            }
            calendar = defaultCalendar
        }

        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.isAllDay = isAllDay

        if let location = location {
            event.location = location
        }
        if let notes = notes {
            event.notes = notes
        }
        if let urlString = url, let url = URL(string: urlString) {
            event.url = url
        }

        try eventStore.save(event, span: .thisEvent, commit: true)
        log("Created event '\(title)' with ID: \(event.eventIdentifier ?? "unknown")")
        return event.eventIdentifier
    }

    func updateEvent(id: String, title: String?, startDate: Date?, endDate: Date?, location: String?, notes: String?, url: String?) throws {
        guard let event = eventStore.event(withIdentifier: id) else {
            throw NSError(domain: "CalendarManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "Event not found"])
        }

        if let title = title {
            event.title = title
        }
        if let startDate = startDate {
            event.startDate = startDate
        }
        if let endDate = endDate {
            event.endDate = endDate
        }
        if let location = location {
            event.location = location
        }
        if let notes = notes {
            event.notes = notes
        }
        if let urlString = url {
            if urlString.isEmpty {
                event.url = nil
            } else {
                event.url = URL(string: urlString)
            }
        }

        try eventStore.save(event, span: .thisEvent, commit: true)
    }

    func deleteEvent(id: String) throws {
        guard let event = eventStore.event(withIdentifier: id) else {
            throw NSError(domain: "CalendarManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "Event not found"])
        }

        try eventStore.remove(event, span: .thisEvent, commit: true)
    }

    private func formatEvent(_ event: EKEvent) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "id": event.eventIdentifier ?? "",
            "title": event.title ?? "",
            "startDate": formatter.string(from: event.startDate),
            "endDate": formatter.string(from: event.endDate),
            "isAllDay": event.isAllDay
        ]

        if let location = event.location, !location.isEmpty {
            dict["location"] = location
        }
        if let notes = event.notes, !notes.isEmpty {
            dict["notes"] = notes
        }
        if let calendar = event.calendar {
            dict["calendarName"] = calendar.title
        }
        if let url = event.url {
            dict["url"] = url.absoluteString
        }

        switch event.status {
        case .confirmed: dict["status"] = "confirmed"
        case .tentative: dict["status"] = "tentative"
        case .canceled: dict["status"] = "canceled"
        default: break
        }

        return dict
    }
}

// MARK: - Date Parsing Helpers

func parseDate(_ string: String) -> Date? {
    // Try ISO8601 first (full datetime)
    let iso8601Formatter = ISO8601DateFormatter()
    if let date = iso8601Formatter.date(from: string) {
        return date
    }

    // Try date-only format (YYYY-MM-DD)
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    dateFormatter.timeZone = TimeZone.current
    return dateFormatter.date(from: string)
}

// MARK: - MCP Server (transport-agnostic)

class MCPServer: @unchecked Sendable {
    let remindersManager = RemindersManager()
    let calendarManager = CalendarManager()

    func requestAccess() async throws {
        try await remindersManager.requestAccess()
        log("Successfully obtained access to Reminders")
        try await calendarManager.requestAccess()
        log("Successfully obtained access to Calendar")
    }

    /// Process a raw JSON-RPC request and return raw JSON response data.
    /// Returns nil for notifications (requests without an id).
    func handleRequest(_ data: Data) -> Data? {
        // Try to decode the request to get the ID for error responses
        var requestId: MCPRequest.RequestID?
        if let partialRequest = try? JSONDecoder().decode(MCPRequest.self, from: data) {
            requestId = partialRequest.id
        }

        // Notifications (no id) don't get a response
        guard requestId != nil else {
            log("Received notification, no response needed")
            return nil
        }

        do {
            let request = try JSONDecoder().decode(MCPRequest.self, from: data)
            let response = try processRequest(request)
            return encodeResponse(response)
        } catch {
            logError("Error processing request: \(error)")
            let errorResponse = MCPResponse(
                id: requestId,
                result: nil,
                error: MCPResponse.MCPError(code: -32603, message: error.localizedDescription)
            )
            return encodeResponse(errorResponse)
        }
    }

    private func encodeResponse(_ response: MCPResponse) -> Data {
        do {
            return try JSONEncoder().encode(response)
        } catch {
            logError("Error encoding response: \(error)")
            return Data(#"{"jsonrpc":"2.0","id":-1,"error":{"code":-32603,"message":"Internal encoding error"}}"#.utf8)
        }
    }

    private func processRequest(_ request: MCPRequest) throws -> MCPResponse {
        switch request.method {
        case "initialize":
            let instructions = """
            This server provides full access to Apple Reminders and Apple Calendar via EventKit.

            REMINDERS (task management):
            - Use list_reminder_lists before creating reminders to see available lists.
            - Use list_today_reminders for a daily overview — it returns incomplete reminders due today or overdue.
            - list_reminders returns incomplete reminders by default. Pass completed: true to see completed ones.
            - create_reminder defaults to the "Reminders" list if no list_name is given.
            - Priority levels: 0 = none, 1–4 = high, 5 = medium, 6–9 = low.
            - Tags are not available via EventKit (Apple limitation).

            CALENDAR EVENTS:
            - Use list_calendars before creating events to see available calendars.
            - Use list_today_events to see today's full schedule across all calendars.
            - list_events requires a start_date and end_date to define the query range.
            - create_event requires title, start_date, and end_date. All other fields (calendar_name, location, notes, url, is_all_day) are optional.
            - create_event uses the system default calendar if no calendar_name is given.
            - Use the url field for video call links (Zoom, Google Meet, etc.).
            - For all-day events, use date-only format and set is_all_day: true.
            - update_event and delete_event operate on a single occurrence of recurring events.

            DATE FORMATS (both reminders and calendar):
            - Full datetime: "2025-11-15T10:00:00Z" (UTC, specific time)
            - Date-only: "2025-11-15" (interpreted in the user's local timezone)

            BEST PRACTICES:
            - Morning planning: call list_today_reminders and list_today_events together for a full daily overview.
            - When the user asks to schedule something, use create_event. When they ask to add a task or todo, use create_reminder.
            - When looking up what's coming, use list_events with a date range (e.g., next 7 days).
            - Always confirm destructive actions (delete_reminder, delete_event) with the user before executing.
            """

            return MCPResponse(
                id: request.id,
                result: MCPResponse.Result(
                    content: nil,
                    tools: nil,
                    protocolVersion: "2024-11-05",
                    capabilities: MCPResponse.Result.Capabilities(
                        tools: MCPResponse.Result.Capabilities.ToolsCapability(listChanged: false)
                    ),
                    serverInfo: MCPResponse.Result.ServerInfo(
                        name: "apple-events",
                        version: "1.0.0"
                    ),
                    instructions: instructions
                ),
                error: nil
            )

        case "tools/list":
            return MCPResponse(
                id: request.id,
                result: MCPResponse.Result(
                    content: nil,
                    tools: getTools(),
                    protocolVersion: nil,
                    capabilities: nil,
                    serverInfo: nil,
                    instructions: nil
                ),
                error: nil
            )

        case "tools/call":
            guard let params = request.params,
                  let toolName = params.name else {
                throw NSError(domain: "MCPServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Missing tool name"])
            }

            // Handle tool execution errors gracefully and return them in the result content
            let resultText: String
            do {
                resultText = try callTool(toolName, arguments: params.arguments ?? [:])
            } catch {
                // Return tool errors as content rather than JSON-RPC errors
                // This provides better error messages to the user
                let errorDetail: String
                if let nsError = error as NSError? {
                    errorDetail = nsError.localizedDescription
                } else {
                    errorDetail = error.localizedDescription
                }

                let errorResult = [
                    "success": false,
                    "error": errorDetail
                ] as [String: Any]
                resultText = try toJSON(errorResult)
            }

            return MCPResponse(
                id: request.id,
                result: MCPResponse.Result(
                    content: [MCPResponse.Result.Content(type: "text", text: resultText)],
                    tools: nil,
                    protocolVersion: nil,
                    capabilities: nil,
                    serverInfo: nil,
                    instructions: nil
                ),
                error: nil
            )

        default:
            throw NSError(domain: "MCPServer", code: 404, userInfo: [NSLocalizedDescriptionKey: "Unknown method: \(request.method)"])
        }
    }

    private func getTools() -> [MCPResponse.Result.Tool] {
        return [
            MCPResponse.Result.Tool(
                name: "list_reminder_lists",
                description: "Get all reminder lists from Apple Reminders",
                inputSchema: MCPResponse.Result.Tool.InputSchema(
                    type: "object",
                    properties: [:],
                    required: nil
                )
            ),
            MCPResponse.Result.Tool(
                name: "create_reminder_list",
                description: "Create a new reminder list in Apple Reminders",
                inputSchema: MCPResponse.Result.Tool.InputSchema(
                    type: "object",
                    properties: [
                        "name": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "Name of the new reminder list"
                        )
                    ],
                    required: ["name"]
                )
            ),
            MCPResponse.Result.Tool(
                name: "list_today_reminders",
                description: "Get all incomplete reminders that are due today or past due. This is useful for seeing what needs to be done today.",
                inputSchema: MCPResponse.Result.Tool.InputSchema(
                    type: "object",
                    properties: [:],
                    required: nil
                )
            ),
            MCPResponse.Result.Tool(
                name: "list_reminders",
                description: "Get reminders from a specific list or all lists. By default, only returns incomplete reminders.",
                inputSchema: MCPResponse.Result.Tool.InputSchema(
                    type: "object",
                    properties: [
                        "list_name": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "Name of the reminder list (optional, if not provided returns all reminders)"
                        ),
                        "completed": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "boolean",
                            description: "Filter by completion status (optional, defaults to false to show only incomplete reminders)"
                        )
                    ],
                    required: nil
                )
            ),
            MCPResponse.Result.Tool(
                name: "create_reminder",
                description: "Create a new reminder in Apple Reminders",
                inputSchema: MCPResponse.Result.Tool.InputSchema(
                    type: "object",
                    properties: [
                        "title": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "Title of the reminder"
                        ),
                        "list_name": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "Name of the list to add the reminder to (defaults to 'Reminders')"
                        ),
                        "notes": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "Additional notes for the reminder (optional)"
                        ),
                        "due_date": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "Due date in ISO 8601 format (e.g., '2025-11-15T10:00:00Z') or date-only format (e.g., '2025-11-15') (optional)"
                        )
                    ],
                    required: ["title"]
                )
            ),
            MCPResponse.Result.Tool(
                name: "complete_reminder",
                description: "Mark a reminder as completed",
                inputSchema: MCPResponse.Result.Tool.InputSchema(
                    type: "object",
                    properties: [
                        "reminder_id": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "ID of the reminder to complete"
                        )
                    ],
                    required: ["reminder_id"]
                )
            ),
            MCPResponse.Result.Tool(
                name: "delete_reminder",
                description: "Delete a reminder",
                inputSchema: MCPResponse.Result.Tool.InputSchema(
                    type: "object",
                    properties: [
                        "reminder_id": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "ID of the reminder to delete"
                        )
                    ],
                    required: ["reminder_id"]
                )
            ),
            MCPResponse.Result.Tool(
                name: "update_reminder",
                description: "Update an existing reminder's properties (title, notes, due date, or priority)",
                inputSchema: MCPResponse.Result.Tool.InputSchema(
                    type: "object",
                    properties: [
                        "reminder_id": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "ID of the reminder to update"
                        ),
                        "title": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "New title for the reminder (optional)"
                        ),
                        "notes": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "New notes for the reminder (optional)"
                        ),
                        "due_date": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "New due date in ISO 8601 format (e.g., '2025-11-15T10:00:00Z'), date-only format (e.g., '2025-11-15'), or empty string to clear (optional)"
                        ),
                        "priority": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "New priority level 0-9, where 0=none, 1-4=high, 5=medium, 6-9=low (optional)"
                        )
                    ],
                    required: ["reminder_id"]
                )
            ),

            // Calendar tools
            MCPResponse.Result.Tool(
                name: "list_calendars",
                description: "Get all event calendars from Apple Calendar",
                inputSchema: MCPResponse.Result.Tool.InputSchema(
                    type: "object",
                    properties: [:],
                    required: nil
                )
            ),
            MCPResponse.Result.Tool(
                name: "list_today_events",
                description: "Get all calendar events for today. Useful for seeing your schedule.",
                inputSchema: MCPResponse.Result.Tool.InputSchema(
                    type: "object",
                    properties: [:],
                    required: nil
                )
            ),
            MCPResponse.Result.Tool(
                name: "list_events",
                description: "Get calendar events in a date range, optionally filtered by calendar name.",
                inputSchema: MCPResponse.Result.Tool.InputSchema(
                    type: "object",
                    properties: [
                        "calendar_name": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "Name of the calendar to filter by (optional, if not provided returns events from all calendars)"
                        ),
                        "start_date": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "Start of date range in ISO 8601 format (e.g., '2025-11-15T00:00:00Z') or date-only (e.g., '2025-11-15')"
                        ),
                        "end_date": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "End of date range in ISO 8601 format (e.g., '2025-11-16T00:00:00Z') or date-only (e.g., '2025-11-16')"
                        )
                    ],
                    required: ["start_date", "end_date"]
                )
            ),
            MCPResponse.Result.Tool(
                name: "create_event",
                description: "Create a new event in Apple Calendar",
                inputSchema: MCPResponse.Result.Tool.InputSchema(
                    type: "object",
                    properties: [
                        "title": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "Title of the event"
                        ),
                        "calendar_name": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "Name of the calendar to add the event to (optional, uses default calendar)"
                        ),
                        "start_date": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "Start date/time in ISO 8601 format (e.g., '2025-11-15T10:00:00Z') or date-only for all-day events (e.g., '2025-11-15')"
                        ),
                        "end_date": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "End date/time in ISO 8601 format (e.g., '2025-11-15T11:00:00Z') or date-only for all-day events (e.g., '2025-11-16')"
                        ),
                        "is_all_day": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "boolean",
                            description: "Whether this is an all-day event (optional, defaults to false)"
                        ),
                        "location": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "Location of the event (optional)"
                        ),
                        "notes": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "Additional notes for the event (optional)"
                        ),
                        "url": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "URL associated with the event, e.g., a video call link (optional)"
                        )
                    ],
                    required: ["title", "start_date", "end_date"]
                )
            ),
            MCPResponse.Result.Tool(
                name: "update_event",
                description: "Update an existing calendar event's properties",
                inputSchema: MCPResponse.Result.Tool.InputSchema(
                    type: "object",
                    properties: [
                        "event_id": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "ID of the event to update"
                        ),
                        "title": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "New title for the event (optional)"
                        ),
                        "start_date": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "New start date/time in ISO 8601 format (optional)"
                        ),
                        "end_date": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "New end date/time in ISO 8601 format (optional)"
                        ),
                        "location": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "New location (optional)"
                        ),
                        "notes": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "New notes (optional)"
                        ),
                        "url": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "New URL, or empty string to clear (optional)"
                        )
                    ],
                    required: ["event_id"]
                )
            ),
            MCPResponse.Result.Tool(
                name: "delete_event",
                description: "Delete a calendar event",
                inputSchema: MCPResponse.Result.Tool.InputSchema(
                    type: "object",
                    properties: [
                        "event_id": MCPResponse.Result.Tool.InputSchema.Property(
                            type: "string",
                            description: "ID of the event to delete"
                        )
                    ],
                    required: ["event_id"]
                )
            )
        ]
    }

    private func callTool(_ name: String, arguments: [String: AnyCodable]) throws -> String {
        switch name {
        case "list_reminder_lists":
            let lists = remindersManager.listReminderLists()
            let result = ["lists": lists, "count": lists.count] as [String : Any]
            return try toJSON(result)

        case "create_reminder_list":
            guard let name = arguments["name"]?.value as? String else {
                throw NSError(domain: "MCPServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Missing name"])
            }

            let id = try remindersManager.createReminderList(name: name)
            let result = ["success": true, "list_id": id, "name": name] as [String : Any]
            return try toJSON(result)

        case "list_today_reminders":
            let reminders = remindersManager.getTodayReminders()
            let result = ["reminders": reminders, "count": reminders.count] as [String : Any]
            return try toJSON(result)

        case "list_reminders":
            let listName = arguments["list_name"]?.value as? String
            let showCompleted = arguments["completed"]?.value as? Bool ?? false

            let reminders = remindersManager.listReminders(listName: listName, showCompleted: showCompleted)
            let result = ["reminders": reminders, "count": reminders.count] as [String : Any]
            return try toJSON(result)

        case "create_reminder":
            guard let title = arguments["title"]?.value as? String else {
                throw NSError(domain: "MCPServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Missing title"])
            }

            let listName = arguments["list_name"]?.value as? String ?? "Reminders"
            let notes = arguments["notes"]?.value as? String
            let dueDate = arguments["due_date"]?.value as? String

            let id = try remindersManager.createReminder(title: title, listName: listName, notes: notes, dueDate: dueDate)
            let result = ["success": true, "reminder_id": id, "title": title] as [String : Any]
            return try toJSON(result)

        case "complete_reminder":
            guard let id = arguments["reminder_id"]?.value as? String else {
                throw NSError(domain: "MCPServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Missing reminder_id"])
            }

            try remindersManager.completeReminder(id: id)
            let result = ["success": true, "reminder_id": id] as [String : Any]
            return try toJSON(result)

        case "delete_reminder":
            guard let id = arguments["reminder_id"]?.value as? String else {
                throw NSError(domain: "MCPServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Missing reminder_id"])
            }

            try remindersManager.deleteReminder(id: id)
            let result = ["success": true, "reminder_id": id] as [String : Any]
            return try toJSON(result)

        case "update_reminder":
            guard let id = arguments["reminder_id"]?.value as? String else {
                throw NSError(domain: "MCPServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Missing reminder_id"])
            }

            let title = arguments["title"]?.value as? String
            let notes = arguments["notes"]?.value as? String
            let dueDate = arguments["due_date"]?.value as? String
            let priorityValue = arguments["priority"]?.value
            var priority: Int? = nil

            if let priorityString = priorityValue as? String, let priorityInt = Int(priorityString) {
                priority = priorityInt
            } else if let priorityInt = priorityValue as? Int {
                priority = priorityInt
            }

            try remindersManager.updateReminder(id: id, title: title, notes: notes, dueDate: dueDate, priority: priority)
            let result = ["success": true, "reminder_id": id] as [String : Any]
            return try toJSON(result)

        // Calendar tools
        case "list_calendars":
            let calendars = calendarManager.listCalendars()
            let result = ["calendars": calendars, "count": calendars.count] as [String : Any]
            return try toJSON(result)

        case "list_today_events":
            let events = calendarManager.getTodayEvents()
            let result = ["events": events, "count": events.count] as [String : Any]
            return try toJSON(result)

        case "list_events":
            guard let startDateStr = arguments["start_date"]?.value as? String,
                  let endDateStr = arguments["end_date"]?.value as? String else {
                throw NSError(domain: "MCPServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Missing start_date or end_date"])
            }

            guard let startDate = parseDate(startDateStr) else {
                throw NSError(domain: "MCPServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid start_date format"])
            }
            guard let endDate = parseDate(endDateStr) else {
                throw NSError(domain: "MCPServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid end_date format"])
            }

            let calendarName = arguments["calendar_name"]?.value as? String
            let events = calendarManager.getEvents(calendarName: calendarName, startDate: startDate, endDate: endDate)
            let result = ["events": events, "count": events.count] as [String : Any]
            return try toJSON(result)

        case "create_event":
            guard let title = arguments["title"]?.value as? String else {
                throw NSError(domain: "MCPServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Missing title"])
            }
            guard let startDateStr = arguments["start_date"]?.value as? String,
                  let startDate = parseDate(startDateStr) else {
                throw NSError(domain: "MCPServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Missing or invalid start_date"])
            }
            guard let endDateStr = arguments["end_date"]?.value as? String,
                  let endDate = parseDate(endDateStr) else {
                throw NSError(domain: "MCPServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Missing or invalid end_date"])
            }

            let calendarName = arguments["calendar_name"]?.value as? String
            let isAllDay = arguments["is_all_day"]?.value as? Bool ?? false
            let location = arguments["location"]?.value as? String
            let notes = arguments["notes"]?.value as? String
            let url = arguments["url"]?.value as? String

            let id = try calendarManager.createEvent(title: title, calendarName: calendarName, startDate: startDate, endDate: endDate, isAllDay: isAllDay, location: location, notes: notes, url: url)
            let result = ["success": true, "event_id": id, "title": title] as [String : Any]
            return try toJSON(result)

        case "update_event":
            guard let id = arguments["event_id"]?.value as? String else {
                throw NSError(domain: "MCPServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Missing event_id"])
            }

            let title = arguments["title"]?.value as? String
            let startDate = (arguments["start_date"]?.value as? String).flatMap { parseDate($0) }
            let endDate = (arguments["end_date"]?.value as? String).flatMap { parseDate($0) }
            let location = arguments["location"]?.value as? String
            let notes = arguments["notes"]?.value as? String
            let url = arguments["url"]?.value as? String

            try calendarManager.updateEvent(id: id, title: title, startDate: startDate, endDate: endDate, location: location, notes: notes, url: url)
            let result = ["success": true, "event_id": id] as [String : Any]
            return try toJSON(result)

        case "delete_event":
            guard let id = arguments["event_id"]?.value as? String else {
                throw NSError(domain: "MCPServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Missing event_id"])
            }

            try calendarManager.deleteEvent(id: id)
            let result = ["success": true, "event_id": id] as [String : Any]
            return try toJSON(result)

        default:
            throw NSError(domain: "MCPServer", code: 404, userInfo: [NSLocalizedDescriptionKey: "Unknown tool: \(name)"])
        }
    }

    private func toJSON(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: .prettyPrinted)
        guard let string = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "MCPServer", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to convert to JSON string"])
        }
        return string
    }
}

// MARK: - Stdio Transport

struct StdioTransport: Sendable {
    let server: MCPServer

    func run() {
        log("Apple Reminders MCP Server running on stdio")

        while let line = readLine() {
            guard let data = line.data(using: .utf8) else { continue }
            guard let responseData = server.handleRequest(data) else { continue }
            if let jsonString = String(data: responseData, encoding: .utf8) {
                print(jsonString)
                fflush(stdout)
            }
        }
    }
}

// MARK: - Logging

func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    fputs("[\(timestamp)] \(message)\n", stderr)
    fflush(stderr)
}

func logError(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    fputs("[\(timestamp)] ERROR: \(message)\n", stderr)
    fflush(stderr)
}

// MARK: - Main

let server = MCPServer()

do {
    try await server.requestAccess()
} catch {
    logError("Failed to get access to Reminders: \(error)")
    exit(1)
}

let args = CommandLine.arguments
if args.contains("--http") {
    do {
        let config = try Config.load()
        let transport = HTTPTransport(server: server, port: UInt16(config.port), apiKey: config.apiKey)
        try await transport.run()
    } catch {
        logError("Failed to start HTTP server: \(error)")
        exit(1)
    }
} else {
    let transport = StdioTransport(server: server)
    transport.run()
}

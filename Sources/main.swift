import Foundation
import EventKit

// MARK: - MCP Protocol Types

struct MCPRequest: Codable {
    let jsonrpc: String
    let id: RequestID
    let method: String
    let params: Params?

    enum RequestID: Codable {
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

    struct Params: Codable {
        let name: String?
        let arguments: [String: AnyCodable]?
        let protocolVersion: String?
        let capabilities: [String: AnyCodable]?
        let clientInfo: ClientInfo?

        struct ClientInfo: Codable {
            let name: String
            let version: String
        }
    }
}

struct MCPResponse: Codable {
    let jsonrpc: String = "2.0"
    let id: MCPRequest.RequestID
    let result: Result?
    let error: MCPError?

    struct Result: Codable {
        let content: [Content]?
        let tools: [Tool]?
        let protocolVersion: String?
        let capabilities: Capabilities?
        let serverInfo: ServerInfo?
        let instructions: String?

        struct Content: Codable {
            let type: String
            let text: String
        }

        struct Capabilities: Codable {
            let tools: ToolsCapability?

            struct ToolsCapability: Codable {
                let listChanged: Bool?
            }
        }

        struct ServerInfo: Codable {
            let name: String
            let version: String
        }

        struct Tool: Codable {
            let name: String
            let description: String
            let inputSchema: InputSchema

            struct InputSchema: Codable {
                let type: String
                let properties: [String: Property]
                let required: [String]?

                struct Property: Codable {
                    let type: String
                    let description: String
                }
            }
        }
    }

    struct MCPError: Codable {
        let code: Int
        let message: String
    }
}

struct AnyCodable: Codable {
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

class RemindersManager {
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

// MARK: - MCP Server

class MCPServer {
    private let remindersManager = RemindersManager()

    func start() async {
        do {
            try await remindersManager.requestAccess()
            log("Successfully obtained access to Reminders")
        } catch {
            logError("Failed to get access to Reminders: \(error)")
            exit(1)
        }

        log("Apple Reminders MCP Server running on stdio")

        while let line = readLine() {
            handleRequest(line)
        }
    }

    private func handleRequest(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }

        // Try to decode the request to get the ID for error responses
        var requestId: MCPRequest.RequestID?
        if let partialRequest = try? JSONDecoder().decode(MCPRequest.self, from: data) {
            requestId = partialRequest.id
        }

        do {
            let request = try JSONDecoder().decode(MCPRequest.self, from: data)
            let response = try processRequest(request)
            sendResponse(response)
        } catch {
            logError("Error processing request: \(error)")
            // Send error response back to client
            sendErrorResponse(id: requestId ?? .int(-1), code: -32603, message: error.localizedDescription)
        }
    }

    private func sendErrorResponse(id: MCPRequest.RequestID, code: Int, message: String) {
        let errorResponse = MCPResponse(
            id: id,
            result: nil,
            error: MCPResponse.MCPError(code: code, message: message)
        )
        sendResponse(errorResponse)
    }

    private func processRequest(_ request: MCPRequest) throws -> MCPResponse {
        switch request.method {
        case "initialize":
            let instructions = """
            This server provides comprehensive access to Apple Reminders for both reminders AND task management.

            Apple Reminders is a full-featured task management system, not just for simple reminders. Use it for:
            - Tasks and todo items (with or without due dates)
            - Project management (create separate lists for different projects)
            - Daily task planning and scheduling
            - Recurring tasks and deadlines
            - Priority-based task organization

            USAGE BEST PRACTICES:
            1. Use list_today_reminders to get an overview of what's due today or overdue
            2. Create separate lists for different contexts (Work, Personal, Projects, Shopping, etc.)
            3. Use list_reminder_lists to see existing lists before creating new ones
            4. Dates can be provided in two formats:
               - Full datetime: "2025-11-15T10:00:00Z" (with specific time)
               - Date-only: "2025-11-15" (no specific time, all-day reminder)
            5. Priority levels: 0=none, 1-4=high, 5=medium, 6-9=low
            6. Tags and categories are not available via the API (EventKit limitation)

            SUGGESTED WORKFLOWS:
            - Morning planning: Use list_today_reminders to review what's due
            - Task capture: Create reminders quickly without due dates, organize later
            - Project setup: Create a new list for each project, then add tasks
            - Weekly review: List all incomplete reminders across all lists
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
                        name: "apple-reminders",
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

        default:
            throw NSError(domain: "MCPServer", code: 404, userInfo: [NSLocalizedDescriptionKey: "Unknown tool: \(name)"])
        }
    }

    private func sendResponse(_ response: MCPResponse) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(response)
            if let jsonString = String(data: data, encoding: .utf8) {
                print(jsonString)
                fflush(stdout)
            }
        } catch {
            logError("Error encoding response: \(error)")
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

@main
struct AppleRemindersMCP {
    static func main() async {
        let server = MCPServer()
        await server.start()
    }
}

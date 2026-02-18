import Foundation
import FlyingFox

struct HTTPTransport: Sendable {
    let server: MCPServer
    let port: UInt16
    let apiKey: String

    func run() async throws {
        let httpServer = HTTPServer(port: port)

        // Health endpoint (unprotected)
        await httpServer.appendRoute("GET /health") { _ in
            HTTPResponse(
                statusCode: .ok,
                headers: [.contentType: "application/json"],
                body: Data(#"{"status":"ok"}"#.utf8)
            )
        }

        // MCP Streamable HTTP endpoint (API key protected)
        await httpServer.appendRoute("POST /*") { request in
            // Extract API key from path: /:apiKey/mcp
            let path = request.path
            let components = path.split(separator: "/")

            guard components.count == 2,
                  components[1] == "mcp" else {
                return HTTPResponse(
                    statusCode: .notFound,
                    headers: [.contentType: "application/json"],
                    body: Data(#"{"error":"Not found"}"#.utf8)
                )
            }

            let providedKey = String(components[0])

            // Validate API key
            guard providedKey == apiKey else {
                return HTTPResponse(
                    statusCode: .unauthorized,
                    headers: [.contentType: "application/json"],
                    body: Data(#"{"error":"Unauthorized"}"#.utf8)
                )
            }

            // Validate Content-Type
            let contentType = request.headers[HTTPHeader("Content-Type")]
            guard let ct = contentType, ct.contains("application/json") else {
                return HTTPResponse(
                    statusCode: .init(415, phrase: "Unsupported Media Type"),
                    headers: [.contentType: "application/json"],
                    body: Data(#"{"error":"Content-Type must be application/json"}"#.utf8)
                )
            }

            // Read request body
            let requestData = try await request.bodyData
            guard !requestData.isEmpty else {
                return HTTPResponse(
                    statusCode: .badRequest,
                    headers: [.contentType: "application/json"],
                    body: Data(#"{"jsonrpc":"2.0","id":-1,"error":{"code":-32700,"message":"Empty request body"}}"#.utf8)
                )
            }

            // Process through MCP server
            guard let responseData = server.handleRequest(requestData) else {
                // Notification — no response body needed
                return HTTPResponse(statusCode: .accepted)
            }

            return HTTPResponse(
                statusCode: .ok,
                headers: [.contentType: "application/json"],
                body: responseData
            )
        }

        log("Apple Reminders MCP Server running on http://localhost:\(port)/\(apiKey)/mcp")
        log("Health check: http://localhost:\(port)/health")

        try await httpServer.run()
    }
}

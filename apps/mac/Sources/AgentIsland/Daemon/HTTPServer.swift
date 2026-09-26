import CryptoKit
import Foundation
import Network

/// One HTTP request, as much as the daemon needs.
struct HTTPRequest {
  var method: String
  var path: String
  var query: [String: String]
  /// Lowercased names.
  var headers: [String: String]
  var body: Data

  func header(_ name: String) -> String? { headers[name.lowercased()] }

}

struct HTTPResponse {
  var status: Int
  var body: Data = Data()
  var contentType = "application/json; charset=utf-8"

  static func json(_ status: Int, _ data: Data) -> HTTPResponse { HTTPResponse(status: status, body: data) }

  static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
    HTTPResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data())
  }

  /// An empty 204: the hook contract (Claude reads any 2xx JSON as a decision).
  static let empty = HTTPResponse(status: 204)

  static let reasons = [200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 500: "Internal Server Error"]
}

/// A WebSocket the daemon streams to.
final class WebSocketPeer {
  fileprivate let connection: NWConnection
  var onClose: () -> Void = {}
  private var buffer = Data()
  private var closed = false

  fileprivate init(connection: NWConnection) {
    self.connection = connection
  }

  /// Sends one text frame (servers never mask).
  func send(_ text: Data) {
    guard !closed else { return }
    connection.send(content: Self.frame(opcode: 0x1, payload: text), completion: .contentProcessed { [weak self] error in
      guard error != nil else { return }
      MainActor.assumeIsolated { self?.close() }
    })
  }

  static func frame(opcode: UInt8, payload: Data) -> Data {
    var header = Data([0x80 | opcode])
    switch payload.count {
    case ..<126: header.append(UInt8(payload.count))
    case ..<65536:
      header.append(126)
      header.append(contentsOf: [UInt8(payload.count >> 8 & 0xFF), UInt8(payload.count & 0xFF)])
    default:
      header.append(127)
      header.append(contentsOf: (0..<8).reversed().map { UInt8(UInt64(payload.count) >> (UInt64($0) * 8) & 0xFF) })
    }
    return header + payload
  }

  fileprivate func start() {
    receive()
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
      MainActor.assumeIsolated {
        guard let self else { return }
        if let data { self.buffer.append(data) }
        self.readFrames()
        if complete || error != nil { self.close() } else if !self.closed { self.receive() }
      }
    }
  }

  /// Client frames: masked. Close ends it; ping gets a pong; the rest is ignored.
  private func readFrames() {
    while buffer.count >= 2 {
      let bytes = [UInt8](buffer.prefix(14))
      let opcode = bytes[0] & 0x0F
      let masked = bytes[1] & 0x80 != 0
      var length = Int(bytes[1] & 0x7F)
      var index = 2
      if length == 126 {
        guard bytes.count >= 4 else { return }
        length = Int(bytes[2]) << 8 | Int(bytes[3])
        index = 4
      } else if length == 127 {
        guard bytes.count >= 10 else { return }
        length = (2..<10).reduce(0) { $0 << 8 | Int(bytes[$1]) }
        index = 10
      }
      let total = index + (masked ? 4 : 0) + length
      guard buffer.count >= total else { return }
      var payload = Data(buffer[buffer.startIndex + index + (masked ? 4 : 0) ..< buffer.startIndex + total])
      if masked {
        let key = [UInt8](buffer[buffer.startIndex + index ..< buffer.startIndex + index + 4])
        payload = Data(payload.enumerated().map { $0.element ^ key[$0.offset % 4] })
      }
      buffer.removeFirst(total)
      switch opcode {
      case 0x8:
        connection.send(content: Self.frame(opcode: 0x8, payload: Data()), completion: .idempotent)
        close()
        return
      case 0x9:
        connection.send(content: Self.frame(opcode: 0xA, payload: payload), completion: .idempotent)
      default:
        break
      }
    }
  }

  func close() {
    guard !closed else { return }
    closed = true
    connection.cancel()
    onClose()
  }
}

/// A minimal HTTP/1.1 server with WebSocket upgrade, loopback only. One
/// request per connection (Connection: close), which is all hooks and curl need.
final class HTTPServer {
  typealias Handler = (HTTPRequest) async -> HTTPResponse
  typealias Upgrade = (HTTPRequest, WebSocketPeer) -> Void

  private let listener: NWListener
  private let handler: Handler
  private let upgrade: Upgrade
  var onReady: () -> Void = {}
  var onFailure: (Error) -> Void = { _ in }

  /// Anything bigger isn't a hook payload.
  static let maxBody = 8 * 1024 * 1024

  init(port: UInt16, handler: @escaping Handler, upgrade: @escaping Upgrade) throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    parameters.allowLocalEndpointReuse = true
    listener = try NWListener(using: parameters)
    self.handler = handler
    self.upgrade = upgrade
  }

  func start() {
    listener.stateUpdateHandler = { [weak self] state in
      MainActor.assumeIsolated {
        switch state {
        case .ready: self?.onReady()
        case let .failed(error): self?.onFailure(error)
        default: break
        }
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      MainActor.assumeIsolated { self?.accept(connection) }
    }
    listener.start(queue: .main)
  }

  func stop() { listener.cancel() }

  private func accept(_ connection: NWConnection) {
    connection.start(queue: .main)
    read(connection, buffer: Data())
  }

  private func read(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
      MainActor.assumeIsolated {
        guard let self else { return }
        var buffer = buffer
        if let data { buffer.append(data) }
        switch Self.parse(buffer) {
        case let .complete(request): self.respond(to: request, on: connection)
        case .tooLarge: self.write(HTTPResponse.json(413, ["error": "too large"]), to: connection)
        case .malformed: self.write(HTTPResponse.json(400, ["error": "malformed request"]), to: connection)
        case .incomplete:
          if complete || error != nil { connection.cancel() } else { self.read(connection, buffer: buffer) }
        }
      }
    }
  }

  private enum Parse {
    case complete(HTTPRequest), incomplete, malformed, tooLarge
  }

  private static func parse(_ buffer: Data) -> Parse {
    guard let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
      return buffer.count > 64 * 1024 ? .malformed : .incomplete
    }
    let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
    let parts = head.first?.split(separator: " ") ?? []
    guard parts.count >= 2 else { return .malformed }
    var headers: [String: String] = [:]
    for line in head.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    let length = Int(headers["content-length"] ?? "0") ?? 0
    guard length <= maxBody else { return .tooLarge }
    let bodyStart = end.upperBound
    guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return .incomplete }
    let target = String(parts[1])
    let components = URLComponents(string: "http://localhost" + target)
    var query: [String: String] = [:]
    for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
    return .complete(HTTPRequest(
      method: String(parts[0]).uppercased(),
      path: components?.percentEncodedPath.removingPercentEncoding ?? target,
      query: query,
      headers: headers,
      body: Data(buffer[bodyStart ..< bodyStart + length])
    ))
  }

  private func respond(to request: HTTPRequest, on connection: NWConnection) {
    if request.header("upgrade")?.lowercased() == "websocket", let key = request.header("sec-websocket-key") {
      let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
      let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
      connection.send(content: Data(head.utf8), completion: .idempotent)
      let peer = WebSocketPeer(connection: connection)
      peer.start()
      upgrade(request, peer)
      return
    }
    Task {
      let response = await handler(request)
      write(response, to: connection)
    }
  }

  private func write(_ response: HTTPResponse, to connection: NWConnection) {
    var head = "HTTP/1.1 \(response.status) \(HTTPResponse.reasons[response.status] ?? "OK")\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
    if !response.body.isEmpty { head += "Content-Type: \(response.contentType)\r\n" }
    head += "\r\n"
    connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
  }
}


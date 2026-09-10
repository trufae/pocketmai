import CMaiPluginABI
import Darwin
import Foundation
import MaiPluginSDK

private let fixtureKind = "native-fixture"

private nonisolated(unsafe) let fixtureManifestCString: UnsafeMutablePointer<CChar>? = {
  let manifest = NativePluginManifest(
    plugin: NativePluginIdentity(
      id: "org.mai.fixture-native",
      displayName: "Native fixture plugin",
      version: "1.0.0",
      capabilities: ["chat-provider", "agent-tool", "ocr-provider", "mcp-tool-source"]),
    extensions: [
      "chat-provider": [
        NativePluginExtension(
          kind: fixtureKind,
          metadata: ["capabilities": .integer(3)])
      ],
      "agent-tool": [NativePluginExtension(kind: fixtureKind)],
      "ocr-provider": [NativePluginExtension(kind: fixtureKind)],
      "mcp-tool-source": [NativePluginExtension(kind: fixtureKind)],
    ])
  let data = try! JSONEncoder().encode(manifest)
  return strdup(String(decoding: data, as: UTF8.self))
}()

private nonisolated(unsafe) let fixtureAPIPointer: UnsafeMutablePointer<mai_plugin_api_v1> = {
  let pointer = UnsafeMutablePointer<mai_plugin_api_v1>.allocate(capacity: 1)
  pointer.initialize(
    to: mai_plugin_api_v1(
      abi_version: UInt32(MAI_PLUGIN_ABI_VERSION),
      manifest_json: UnsafePointer(fixtureManifestCString),
      plugin_context: nil,
      start: fixtureStart,
      cancel: fixtureCancel,
      destroy: fixtureDestroy))
  return pointer
}()

@_cdecl("mai_plugin_entry_v1")
public func maiFixturePluginEntry() -> UnsafePointer<mai_plugin_api_v1>? {
  UnsafePointer(fixtureAPIPointer)
}

private func fixtureStart(
  _ pluginContext: UnsafeMutableRawPointer?,
  _ requestJSON: UnsafePointer<CChar>?,
  _ callbackContext: UnsafeMutableRawPointer?,
  _ emit: mai_plugin_emit_v1?,
  _ complete: mai_plugin_complete_v1?
) -> UInt64 {
  guard let requestJSON else {
    finish(
      .init(error: .init(code: "invalid-request", message: "Missing request JSON.")),
      callbackContext: callbackContext,
      complete: complete)
    return 1
  }
  do {
    let request = try JSONDecoder().decode(
      NativePluginRequest.self,
      from: Data(String(cString: requestJSON).utf8))
    let result = try handle(request, callbackContext: callbackContext, emit: emit)
    finish(.init(result: result), callbackContext: callbackContext, complete: complete)
  } catch {
    finish(
      .init(error: .init(code: "fixture-error", message: error.localizedDescription)),
      callbackContext: callbackContext,
      complete: complete)
  }
  return 1
}

private func fixtureCancel(
  _ pluginContext: UnsafeMutableRawPointer?,
  _ operationID: UInt64
) {}

private func fixtureDestroy(_ pluginContext: UnsafeMutableRawPointer?) {}

private func handle(
  _ request: NativePluginRequest,
  callbackContext: UnsafeMutableRawPointer?,
  emit: mai_plugin_emit_v1?
) throws -> PluginJSONValue {
  switch request.operation {
  case NativePluginOperation.providerModels:
    return .array([
      .object([
        "id": .string("native-hello"),
        "displayName": .string("Native Hello"),
        "capabilities": .integer(0),
      ])
    ])
  case NativePluginOperation.providerComplete:
    let payload = try requiredPayload(request)
    if let result = providerToolResult(payload) {
      return providerResponse(text: "native tool result: \(result)")
    }
    let input = providerInputText(payload)
    if input.hasPrefix("tool:") || input.hasPrefix("mcp:") {
      let separator = input.firstIndex(of: ":")!
      let value = input[input.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      let name = input.hasPrefix("mcp:") ? "native-mcp::echo" : "native_echo"
      return .object([
        "message": .object([
          "id": .string(UUID().uuidString),
          "role": .string("assistant"),
          "content": .array([
            .object([
              "toolCall": .object([
                "_0": .object([
                  "id": .string("fixture-call"),
                  "name": .string(name),
                  "arguments": .object(["text": .string(value)]),
                ])
              ])
            ])
          ]),
        ]),
        "stopReason": .string("toolCall"),
      ])
    }
    let text = "native: \(input)"
    if payload.objectValue?["stream"] == .bool(true) {
      send(
        event: .object(["textDelta": .object(["_0": .string(text)])]),
        callbackContext: callbackContext,
        emit: emit)
    }
    return providerResponse(text: text)
  case NativePluginOperation.toolList:
    return .array([
      toolDefinition(
        name: "native_echo",
        description: "Echo text through the native fixture plugin.",
        schema: .object([
          "type": .string("object"),
          "properties": .object(["text": .object(["type": .string("string")])]),
          "required": .array([.string("text")]),
        ]))
    ])
  case NativePluginOperation.toolGroups:
    return try PluginWireCodec.value([
      NativeToolGroupDefinition(
        id: "native",
        displayName: "Native fixture",
        description: "Fixture native tools.",
        toolNames: ["native_echo"],
        options: [
          NativeToolGroupOptionDefinition(
            id: "prefix",
            label: "Echo prefix")
        ])
    ])
  case NativePluginOperation.toolCall:
    let arguments = try callArguments(request)
    return toolOutput(text: arguments.objectValue?["text"]?.stringValue ?? "")
  case NativePluginOperation.ocrRecognize:
    let ocr = try requiredPayload(request).objectValue
    let filename = ocr?["filename"]?.stringValue ?? "image"
    let dataSize = ocr?["imageData"]?.stringValue.flatMap { Data(base64Encoded: $0) }?.count ?? 0
    return .object(["markdown": .string("# Native OCR\n\n\(filename) (\(dataSize) bytes)")])
  case NativePluginOperation.mcpConnect:
    return .object([
      "serverID": .string("native-mcp"),
      "serverName": .string("Native fixture MCP"),
      "protocolVersion": .string("fixture-v1"),
      "tools": .array([
        toolDefinition(name: "native-mcp::echo", description: "Fixture MCP echo")
      ]),
      "resources": .array([]),
    ])
  case NativePluginOperation.mcpCall:
    let arguments = try callArguments(request)
    return toolOutput(text: arguments.objectValue?["text"]?.stringValue ?? "native MCP")
  case NativePluginOperation.mcpClose:
    return .null
  default:
    throw NativePluginFailure(
      code: "unsupported-operation",
      message: "Unsupported operation '\(request.operation)'.")
  }
}

private func requiredPayload(_ request: NativePluginRequest) throws -> PluginJSONValue {
  guard let payload = request.payload else {
    throw NativePluginFailure(code: "missing-payload", message: "The request payload is missing.")
  }
  return payload
}

private func providerInputText(_ payload: PluginJSONValue) -> String {
  let messages = payload.objectValue?["messages"]?.arrayValue ?? []
  let content = messages.last?.objectValue?["content"]?.arrayValue ?? []
  return content.compactMap { part in
    part.objectValue?["text"]?.objectValue?["_0"]?.stringValue
  }.joined(separator: "\n")
}

private func providerToolResult(_ payload: PluginJSONValue) -> String? {
  let messages = payload.objectValue?["messages"]?.arrayValue ?? []
  for message in messages.reversed() {
    let content = message.objectValue?["content"]?.arrayValue ?? []
    for part in content {
      let result = part.objectValue?["toolResult"]?.objectValue?["_0"]?.objectValue
      let resultContent = result?["content"]?.arrayValue ?? []
      if let text = resultContent.compactMap({ item in
        item.objectValue?["text"]?.objectValue?["_0"]?.stringValue
      }).first {
        return text
      }
    }
  }
  return nil
}

private func providerResponse(text: String) -> PluginJSONValue {
  .object([
    "message": .object([
      "id": .string(UUID().uuidString),
      "role": .string("assistant"),
      "content": .array([.object(["text": .object(["_0": .string(text)])])]),
    ]),
    "stopReason": .string("stop"),
  ])
}

private func callArguments(_ request: NativePluginRequest) throws -> PluginJSONValue {
  try requiredPayload(request).objectValue?["arguments"] ?? .object([:])
}

private func toolDefinition(
  name: String,
  description: String,
  schema: PluginJSONValue = .object(["type": .string("object")])
) -> PluginJSONValue {
  .object([
    "name": .string(name),
    "description": .string(description),
    "inputSchema": schema,
    "annotations": .object([
      "readOnly": .bool(true),
      "destructive": .bool(false),
      "idempotent": .bool(true),
      "openWorld": .bool(false),
      "approval": .string("automatic"),
    ]),
  ])
}

private func toolOutput(text: String) -> PluginJSONValue {
  .object([
    "content": .array([.object(["text": .object(["_0": .string(text)])])]),
    "isError": .bool(false),
  ])
}

private func send(
  event: PluginJSONValue,
  callbackContext: UnsafeMutableRawPointer?,
  emit: mai_plugin_emit_v1?
) {
  guard let emit, let data = try? JSONEncoder().encode(event) else { return }
  String(decoding: data, as: UTF8.self).withCString {
    emit(callbackContext, $0)
  }
}

private func finish(
  _ response: NativePluginResponse,
  callbackContext: UnsafeMutableRawPointer?,
  complete: mai_plugin_complete_v1?
) {
  guard let complete else { return }
  let data =
    (try? JSONEncoder().encode(response))
    ?? Data(
      "{\"error\":{\"code\":\"encoding-error\",\"message\":\"Could not encode response.\"}}"
        .utf8)
  String(decoding: data, as: UTF8.self).withCString {
    complete(callbackContext, $0)
  }
}

import Foundation

/// Reduces a large tool catalog to two stable tools. Hosts remain responsible
/// for executing the concrete call returned by `resolveCall`.
public enum ToolProxy {
  public static let listName = "list-tools"
  public static let callName = "call-tool"

  /// How many matches `listTools` describes with their arguments; the rest
  /// are named in one line each, so a broad search costs a screen, not the
  /// whole catalog.
  public static let detailedMatches = 6

  /// The two proxy tools, named for the catalog they stand in for. A model
  /// that only sees "list-tools" and "call-tool" does not know it can read
  /// files or run commands, and declines the task instead of looking.
  public static func definitions(for catalog: [ToolDefinition]) -> [ToolDefinition] {
    let names = catalog.map(\.name).sorted().joined(separator: ", ")
    let enabled = names.isEmpty ? "" : " Enabled tools: \(names)."
    return [
      ToolDefinition(
        name: listName,
        description:
          "Describe enabled tools and their arguments, searched by capability, tool name, or argument name.\(enabled)",
        parameters: [
          ToolParameterDef(
            name: "keywords",
            type: "string",
            description: "Space-separated task, tool, capability, or argument keywords.",
            required: true)
        ],
        annotations: ToolAnnotations(
          readOnly: true, idempotent: true, openWorld: false, approval: .automatic)),
      ToolDefinition(
        name: callName,
        description:
          "Call one enabled tool by exact name with JSON arguments. Use list-tools first when its arguments are not known.",
        parameters: [
          ToolParameterDef(
            name: "name",
            type: "string",
            description: "Exact tool name from the enabled tools.",
            required: true),
          ToolParameterDef(
            name: "arguments",
            type: "object",
            description: "JSON object with arguments for the selected tool. Use {} when none.",
            required: true),
        ],
        annotations: ToolAnnotations(approval: .automatic)),
    ]
  }

  /// The proxy tools without a catalog to name.
  public static var definitions: [ToolDefinition] { definitions(for: []) }

  public static func listTools(
    arguments: [String: AgentToolArgumentValue],
    definitions: [ToolDefinition]
  ) -> String {
    let keywords =
      arguments["keywords"]?.stringValue ?? arguments["query"]?.stringValue
      ?? arguments["filter"]?.stringValue ?? ""
    let terms = keywords.lowercased().split { $0.isWhitespace || $0 == "," }.map(String.init)
    // A term found in the name outweighs one found somewhere in the text, so
    // "read" ranks files_read above every tool whose description mentions reading.
    let matches = definitions.compactMap { definition -> (ToolDefinition, Int)? in
      guard !terms.isEmpty else { return (definition, 0) }
      let name = definition.name.lowercased()
      let searchable = searchableText(for: definition)
      let score = terms.count(where: name.contains) * 2 + terms.count(where: searchable.contains)
      return score > 0 ? (definition, score) : nil
    }.sorted {
      $0.1 == $1.1 ? $0.0.name < $1.0.name : $0.1 > $1.1
    }

    guard !matches.isEmpty else {
      let suffix =
        keywords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "" : " matching '\(keywords)'"
      return "No enabled tools\(suffix). Try broader keywords."
    }
    var lines = matches.prefix(detailedMatches).map { summary(for: $0.0) }
    let rest = matches.dropFirst(detailedMatches)
    if !rest.isEmpty {
      lines.append("Also matching, named only: " + rest.map(\.0.name).joined(separator: ", ") + ".")
      lines.append("Search again with a tool's name to see its arguments.")
    }
    return lines.joined(separator: "\n")
  }

  public static func resolveCall(
    arguments: [String: AgentToolArgumentValue],
    definitions: [ToolDefinition]
  ) -> (call: ParsedToolCall?, error: String?) {
    let requestedName =
      arguments["name"]?.stringValue ?? arguments["tool_name"]?.stringValue
      ?? arguments["tool"]?.stringValue ?? ""
    let resolver = AgentToolNameResolver(tools: definitions)
    guard let canonicalName = resolver.canonicalName(for: requestedName) else {
      return (
        nil,
        "Error: unknown tool '\(requestedName)'. Call \(listName) first with relevant keywords."
      )
    }
    guard let definition = definitions.first(where: { $0.name == canonicalName }) else {
      return (nil, "Error: unknown tool '\(requestedName)'.")
    }
    let normalized = AgentTooling.normalizeArguments(
      argumentObject(from: arguments["arguments"]),
      for: definition)
    return (
      ParsedToolCall(
        name: canonicalName,
        arguments: [:],
        argumentValues: normalized,
        rawBlock: ""),
      nil
    )
  }

  private static func searchableText(for definition: ToolDefinition) -> String {
    ([definition.name, definition.description]
      + definition.parameters.flatMap { [$0.name, $0.type, $0.description] })
      .joined(separator: " ")
      .lowercased()
  }

  private static func summary(for definition: ToolDefinition) -> String {
    let arguments =
      definition.parameters.isEmpty
      ? "no arguments"
      : definition.parameters.map { parameter in
        let required = parameter.required ? "required" : "optional"
        let detail = parameter.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(parameter.name) (\(parameter.type), \(required))"
          + (detail.isEmpty ? "" : " - \(detail)")
      }.joined(separator: "; ")
    return "- \(definition.name): \(definition.description) Arguments: \(arguments)."
  }

  private static func argumentObject(
    from value: AgentToolArgumentValue?
  ) -> [String: AgentToolArgumentValue] {
    if let object = value?.objectValue { return object }
    guard let string = value?.stringValue,
      let data = string.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
    else { return [:] }
    return decoded.objectValue ?? [:]
  }
}

import Foundation

/// Turns the small, common LaTex subset used in chat replies into readable
/// terminal text. Terminals do not have a maths layout engine, but hiding the
/// delimiters and presentation commands is markedly easier to read than raw
/// source such as `$$\\text{rate} = \\frac{a}{b}$$`.
enum MarkdownMath {
  /// Returns nil when the input is not a complete inline or display formula.
  static func render(delimited source: String) -> String? {
    let chars = Array(source)
    guard chars.first == "$" else { return nil }
    let delimiterLength = chars.dropFirst().first == "$" ? 2 : 1
    guard chars.count >= delimiterLength * 2,
      Array(chars.prefix(delimiterLength)).allSatisfy({ $0 == "$" }),
      Array(chars.suffix(delimiterLength)).allSatisfy({ $0 == "$" })
    else { return nil }
    let body = String(chars.dropFirst(delimiterLength).dropLast(delimiterLength))
    return render(body: body)
  }

  private static func render(body: String) -> String {
    let chars = Array(body)
    var index = 0
    var output = ""
    while index < chars.count {
      if chars[index] == "\\" {
        let commandStart = index
        index += 1
        let nameStart = index
        while index < chars.count, chars[index].isLetter { index += 1 }
        let name = String(chars[nameStart..<index])
        if name.isEmpty {
          if index < chars.count {
            output.append(chars[index])
            index += 1
          } else {
            output.append("\\")
          }
          continue
        }
        if name == "frac", let numerator = bracedGroup(chars, at: index) {
          index = numerator.end
          if let denominator = bracedGroup(chars, at: index) {
            index = denominator.end
            output += "\(render(body: numerator.value)) / \(render(body: denominator.value))"
            continue
          }
          output += "\\frac{\(render(body: numerator.value))}"
          continue
        }
        if ["text", "textrm", "mathrm", "operatorname"].contains(name),
          let group = bracedGroup(chars, at: index)
        {
          output += render(body: group.value)
          index = group.end
          continue
        }
        if ["left", "right"].contains(name) { continue }
        if let replacement = commands[name] {
          output += replacement
        } else {
          // Keep unfamiliar commands legible without the LaTex escape noise.
          output += name
        }
        if index == commandStart + 1 { index += 1 }
      } else if chars[index] == "{" || chars[index] == "}" {
        index += 1
      } else if chars[index] == "~" {
        output.append(" ")
        index += 1
      } else {
        output.append(chars[index])
        index += 1
      }
    }
    return output.replacingOccurrences(of: "  ", with: " ")
  }

  private static func bracedGroup(_ chars: [Character], at start: Int) -> (value: String, end: Int)? {
    var index = start
    while index < chars.count, chars[index].isWhitespace { index += 1 }
    guard index < chars.count, chars[index] == "{" else { return nil }
    let contentStart = index + 1
    var depth = 1
    index += 1
    while index < chars.count {
      if chars[index] == "{" { depth += 1 }
      if chars[index] == "}" {
        depth -= 1
        if depth == 0 { return (String(chars[contentStart..<index]), index + 1) }
      }
      index += 1
    }
    return nil
  }

  private static let commands: [String: String] = [
    "times": "×", "cdot": "·", "div": "÷", "pm": "±", "mp": "∓",
    "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔",
    "ge": "≥", "geq": "≥", "le": "≤", "leq": "≤", "neq": "≠",
    "approx": "≈", "infty": "∞", "sum": "Σ", "prod": "Π",
    "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
    "theta": "θ", "lambda": "λ", "mu": "μ", "pi": "π", "sigma": "σ",
    "phi": "φ", "omega": "ω", "ldots": "…", "quad": " ", "qquad": " ",
  ]
}

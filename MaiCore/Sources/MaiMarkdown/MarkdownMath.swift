import Foundation

/// Turns the LaTeX subset that chat replies use into readable terminal text.
/// Terminals have no maths layout engine, but replacing each command with its
/// Unicode symbol, raising `x^2` to `x²`, and hiding the delimiters and
/// presentation commands is markedly easier to read than raw source such as
/// `$$\\text{rate} = \\frac{a}{b}$$`.
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

  /// Renders LaTeX source without delimiters.
  static func render(body: String) -> String {
    var renderer = Renderer(chars: Array(body))
    var text = renderer.run()
    while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
    return text
  }

  private struct Renderer {
    let chars: [Character]
    var index = 0
    var output = ""

    init(chars: [Character]) { self.chars = chars }

    mutating func run() -> String {
      while index < chars.count {
        let char = chars[index]
        switch char {
        case "\\":
          command()
        case "^", "_":
          script(char)
        case "{", "}":
          index += 1
        case "~", "&":
          // A non-breaking space, or an alignment tab inside an environment.
          output.append(" ")
          index += 1
        default:
          output.append(char)
          index += 1
        }
      }
      return output
    }

    private mutating func command() {
      index += 1
      guard index < chars.count else {
        output.append("\\")
        return
      }
      let nameStart = index
      while index < chars.count, chars[index].isLetter { index += 1 }
      let name = String(chars[nameStart..<index])
      if name.isEmpty {
        let symbol = chars[index]
        index += 1
        switch symbol {
        case ",", ":", ";", " ", "\\": output.append(" ")
        case "!": break
        case "|": output.append("‖")
        default: output.append(symbol)  // \% \& \# \_ \$ \{ \}
        }
        return
      }
      switch name {
      case "frac", "dfrac", "tfrac", "cfrac":
        guard let numerator = argument() else {
          output += name
          return
        }
        guard let denominator = argument() else {
          output += rendered(numerator)
          return
        }
        output += "\(rendered(numerator)) / \(rendered(denominator))"
      case "binom", "dbinom", "tbinom":
        guard let top = argument(), let bottom = argument() else {
          output += name
          return
        }
        output += "C(\(rendered(top)), \(rendered(bottom)))"
      case "sqrt":
        let degree = optionalArgument().map(rendered)
        guard let radicand = argument().map(rendered) else {
          output += "√"
          return
        }
        if let degree { output += MarkdownMath.map(degree, with: superscripts) ?? degree }
        output += "√" + (isWord(radicand) ? radicand : "(\(radicand))")
      case "mathbb":
        guard let letters = argument().map(rendered) else {
          output += name
          return
        }
        output += String(letters.map { doubleStruck[$0] ?? $0 })
      case "boxed", "fbox":
        guard let content = argument().map(rendered) else {
          output += name
          return
        }
        output += "[\(content)]"
      case "operatorname":
        skipSpaces()
        if index < chars.count, chars[index] == "*" { index += 1 }
        output += argument().map(rendered) ?? name
      case "not":
        negation()
      case "begin", "end", "phantom", "hphantom", "vphantom", "label", "tag":
        _ = argument()
      case "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr",
        "biggl", "biggr", "Biggl", "Biggr", "bigm", "Bigm":
        skipSpaces()
        if index < chars.count, chars[index] == "." { index += 1 }
      default:
        if let mark = accents[name] {
          guard let base = argument().map(rendered) else {
            output += name
            return
          }
          output += base.count == 1 ? base + mark : base
        } else if unwrapped.contains(name) {
          output += argument().map(rendered) ?? name
        } else if ignored.contains(name) {
          return
        } else {
          // Function names such as \sin and \lim, and any unfamiliar command,
          // stay legible without the escape noise.
          if closers.contains(name) {
            while output.last?.isWhitespace == true { output.removeLast() }
          }
          output += symbols[name] ?? name
          // TeX swallows the space after a command; that matters for the
          // symbols that bind to what follows, as in `\forall x` or `\neg p`.
          if prefixes.contains(name) {
            let resume = index
            skipSpaces()
            // A following command such as `\nabla \cdot F` keeps its space.
            if index < chars.count, chars[index] == "\\" { index = resume }
          }
        }
      }
    }

    /// `^` and `_`: Unicode super- and subscripts when every character has
    /// one and the argument is short enough to stay readable, otherwise the
    /// marker followed by the argument, parenthesized if it is not one word.
    private mutating func script(_ marker: Character) {
      index += 1
      guard let raw = argument() else { return output.append(marker) }
      let text = rendered(raw)
      if marker == "^", text == "∘" { return output.append("°") }
      if text.count == 1, let only = text.first, !only.isLetter, !only.isNumber {
        output += text
        return  // x^*, f^\prime, A^\dagger
      }
      let compact = text.filter { !$0.isWhitespace }
      let table = marker == "^" ? superscripts : subscripts
      if compact.filter(\.isLetter).count <= 2, let mapped = MarkdownMath.map(compact, with: table)
      {
        output += mapped
        return
      }
      output += String(marker) + (text.count <= 1 || isWord(text) ? text : "(\(text))")
    }

    private mutating func negation() {
      skipSpaces()
      guard index < chars.count else { return output.append("¬") }
      switch chars[index] {
      case "=":
        index += 1
        return output.append("≠")
      case "<":
        index += 1
        return output.append("≮")
      case ">":
        index += 1
        return output.append("≯")
      case "\\":
        let saved = index
        if let token = argument(), token.hasPrefix("\\") {
          let name = String(token.dropFirst())
          if let negated = negations[name] {
            output += negated
            return
          }
          if let symbol = symbols[name] {
            output += symbol + "\u{0338}"
            return
          }
        }
        index = saved
      default: break
      }
      output.append("¬")
    }

    private func rendered(_ source: String) -> String { MarkdownMath.render(body: source) }

    private func isWord(_ text: String) -> Bool {
      !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber }
    }

    private mutating func skipSpaces() {
      while index < chars.count, chars[index].isWhitespace { index += 1 }
    }

    /// The next argument as LaTeX source: a braced group, one command, or one
    /// character, as TeX itself takes it (`\frac12` is a half).
    private mutating func argument() -> String? {
      skipSpaces()
      guard index < chars.count else { return nil }
      if chars[index] == "{" { return bracedGroup() }
      if chars[index] == "\\" {
        var end = index + 1
        if end < chars.count, chars[end].isLetter {
          while end < chars.count, chars[end].isLetter { end += 1 }
        } else if end < chars.count {
          end += 1
        }
        defer { index = end }
        return String(chars[index..<end])
      }
      defer { index += 1 }
      return String(chars[index])
    }

    /// A `[degree]` after `\sqrt`.
    private mutating func optionalArgument() -> String? {
      skipSpaces()
      guard index < chars.count, chars[index] == "[" else { return nil }
      guard let close = chars[(index + 1)...].firstIndex(of: "]") else { return nil }
      defer { index = close + 1 }
      return String(chars[(index + 1)..<close])
    }

    /// The content of the `{...}` group at the cursor; an unbalanced group
    /// runs to the end of the formula.
    private mutating func bracedGroup() -> String {
      let contentStart = index + 1
      var depth = 1
      var cursor = contentStart
      while cursor < chars.count {
        if chars[cursor] == "\\" {
          cursor += 2
          continue
        }
        if chars[cursor] == "{" { depth += 1 }
        if chars[cursor] == "}" {
          depth -= 1
          if depth == 0 {
            index = cursor + 1
            return String(chars[contentStart..<cursor])
          }
        }
        cursor += 1
      }
      index = chars.count
      return String(chars[contentStart...])
    }
  }

  private static func map(_ text: String, with table: [Character: Character]) -> String? {
    var mapped = ""
    for char in text {
      guard let replacement = table[char] else { return nil }
      mapped.append(replacement)
    }
    return mapped
  }

  /// Commands whose argument is shown as it is: fonts and emphasis a terminal
  /// cannot render, and decorations too wide for a combining mark.
  private static let unwrapped: Set<String> = [
    "text", "textrm", "textbf", "textit", "texttt", "textsf", "textnormal", "mbox", "hbox",
    "emph", "mathrm", "mathbf", "mathit", "mathsf", "mathtt", "mathcal", "mathscr", "mathfrak",
    "boldsymbol", "bm", "pmb", "underbrace", "overbrace", "underset", "overset", "stackrel",
    "cancel", "bcancel", "xcancel", "color", "textcolor", "substack", "smash",
  ]

  /// Symbols that bind to the next token, so no space follows them.
  private static let prefixes: Set<String> = [
    "neg", "lnot", "forall", "exists", "nexists", "partial", "nabla", "langle", "lfloor",
    "lceil", "lvert", "lVert",
  ]

  /// Closing delimiters, which close up against what precedes them.
  private static let closers: Set<String> = ["rangle", "rfloor", "rceil", "rvert", "rVert"]

  /// Presentation commands without a terminal equivalent.
  private static let ignored: Set<String> = [
    "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle", "limits", "nolimits",
    "nonumber", "notag", "mathstrut", "rm", "bf", "it", "cal", "sf", "tt", "small", "large",
    "Large", "LARGE", "huge", "Huge", "tiny", "scriptsize", "footnotesize", "normalsize",
    "allowbreak", "relax", "strut", "noindent",
  ]

  /// Accents become combining marks on a one-character base.
  private static let accents: [String: String] = [
    "hat": "\u{0302}", "widehat": "\u{0302}", "bar": "\u{0304}", "overline": "\u{0305}",
    "vec": "\u{20D7}", "overrightarrow": "\u{20D7}", "overleftarrow": "\u{20D6}",
    "tilde": "\u{0303}", "widetilde": "\u{0303}", "dot": "\u{0307}", "ddot": "\u{0308}",
    "dddot": "\u{20DB}", "check": "\u{030C}", "breve": "\u{0306}", "acute": "\u{0301}",
    "grave": "\u{0300}", "underline": "\u{0332}", "mathring": "\u{030A}",
  ]

  private static let doubleStruck: [Character: Character] = [
    "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "R": "ℝ", "C": "ℂ", "P": "ℙ", "H": "ℍ",
  ]

  private static let superscripts: [Character: Character] = [
    "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸",
    "9": "⁹", "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
    "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ", "h": "ʰ", "i": "ⁱ",
    "j": "ʲ", "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ",
    "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ",
    "A": "ᴬ", "B": "ᴮ", "D": "ᴰ", "E": "ᴱ", "G": "ᴳ", "H": "ᴴ", "I": "ᴵ", "J": "ᴶ", "K": "ᴷ",
    "L": "ᴸ", "M": "ᴹ", "N": "ᴺ", "O": "ᴼ", "P": "ᴾ", "R": "ᴿ", "T": "ᵀ", "U": "ᵁ", "V": "ⱽ",
    "W": "ᵂ", "β": "ᵝ", "γ": "ᵞ", "δ": "ᵟ", "φ": "ᵠ", "χ": "ᵡ", "θ": "ᶿ",
  ]

  private static let subscripts: [Character: Character] = [
    "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈",
    "9": "₉", "+": "₊", "-": "₋", "−": "₋", "=": "₌", "(": "₍", ")": "₎",
    "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ",
    "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
    "β": "ᵦ", "γ": "ᵧ", "ρ": "ᵨ", "φ": "ᵩ", "χ": "ᵪ",
  ]

  /// `\not` before a relation that has its own negated symbol.
  private static let negations: [String: String] = [
    "in": "∉", "ni": "∌", "subset": "⊄", "supset": "⊅", "subseteq": "⊈", "supseteq": "⊉",
    "equiv": "≢", "sim": "≁", "simeq": "≄", "cong": "≇", "approx": "≉",
    "le": "≰", "leq": "≰", "ge": "≱", "geq": "≱", "prec": "⊀", "succ": "⊁",
    "exists": "∄", "mid": "∤", "parallel": "∦", "vdash": "⊬", "models": "⊭",
    "rightarrow": "↛", "to": "↛", "leftarrow": "↚", "Rightarrow": "⇏", "Leftarrow": "⇍",
    "Leftrightarrow": "⇎", "leftrightarrow": "↮",
  ]

  private static let symbols: [String: String] = [
    // Arrows
    "rightarrow": "→", "to": "→", "leftarrow": "←", "gets": "←", "leftrightarrow": "↔",
    "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔", "implies": "⇒",
    "impliedby": "⇐", "iff": "⇔", "mapsto": "↦", "longmapsto": "⟼", "longrightarrow": "⟶",
    "longleftarrow": "⟵", "longleftrightarrow": "⟷", "Longrightarrow": "⟹",
    "Longleftarrow": "⟸", "Longleftrightarrow": "⟺", "uparrow": "↑", "downarrow": "↓",
    "updownarrow": "↕", "Uparrow": "⇑", "Downarrow": "⇓", "Updownarrow": "⇕",
    "nearrow": "↗", "searrow": "↘", "swarrow": "↙", "nwarrow": "↖", "hookrightarrow": "↪",
    "hookleftarrow": "↩", "rightharpoonup": "⇀", "rightharpoondown": "⇁",
    "leftharpoonup": "↼", "leftharpoondown": "↽", "rightleftharpoons": "⇌",
    "leftrightarrows": "⇆", "rightleftarrows": "⇄", "rightrightarrows": "⇉",
    "leftleftarrows": "⇇", "twoheadrightarrow": "↠", "twoheadleftarrow": "↞",
    "rightsquigarrow": "⇝", "leadsto": "⇝", "circlearrowleft": "↺", "circlearrowright": "↻",
    "curvearrowleft": "↶", "curvearrowright": "↷",
    // Relations
    "ge": "≥", "geq": "≥", "geqslant": "⩾", "le": "≤", "leq": "≤", "leqslant": "⩽",
    "ne": "≠", "neq": "≠", "equiv": "≡", "approx": "≈", "sim": "∼", "simeq": "≃",
    "cong": "≅", "propto": "∝", "ll": "≪", "gg": "≫", "lll": "⋘", "ggg": "⋙",
    "prec": "≺", "succ": "≻", "preceq": "⪯", "succeq": "⪰", "doteq": "≐", "asymp": "≍",
    "models": "⊨", "vdash": "⊢", "dashv": "⊣", "Vdash": "⊩", "vDash": "⊨", "perp": "⊥",
    "parallel": "∥", "nparallel": "∦", "mid": "∣", "nmid": "∤", "subset": "⊂",
    "supset": "⊃", "subseteq": "⊆", "supseteq": "⊇", "subsetneq": "⊊", "supsetneq": "⊋",
    "nsubseteq": "⊈", "nsupseteq": "⊉", "in": "∈", "notin": "∉", "ni": "∋", "owns": "∋",
    "sqsubset": "⊏", "sqsupset": "⊐", "sqsubseteq": "⊑", "sqsupseteq": "⊒", "bowtie": "⋈",
    "triangleleft": "◁", "triangleright": "▷", "trianglelefteq": "⊴", "trianglerighteq": "⊵",
    "lesssim": "≲", "gtrsim": "≳", "lessgtr": "≶", "gtrless": "≷", "lesseqgtr": "⋚",
    "gtreqless": "⋛", "nless": "≮", "ngtr": "≯", "nleq": "≰", "ngeq": "≱", "nsim": "≁",
    "ncong": "≇", "nequiv": "≢", "napprox": "≉", "lt": "<", "gt": ">", "colon": ":",
    // Binary operators
    "times": "×", "cdot": "·", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗", "star": "⋆",
    "circ": "∘", "bullet": "•", "oplus": "⊕", "ominus": "⊖", "otimes": "⊗", "oslash": "⊘",
    "odot": "⊙", "cup": "∪", "cap": "∩", "bigcup": "⋃", "bigcap": "⋂", "sqcup": "⊔",
    "sqcap": "⊓", "setminus": "∖", "smallsetminus": "∖", "wedge": "∧", "vee": "∨",
    "land": "∧", "lor": "∨", "lnot": "¬", "neg": "¬", "bigwedge": "⋀", "bigvee": "⋁",
    "uplus": "⊎", "amalg": "⨿", "wr": "≀", "diamond": "⋄", "dagger": "†", "ddagger": "‡",
    "bigoplus": "⨁", "bigotimes": "⨂", "bigodot": "⨀", "biguplus": "⨄", "bigsqcup": "⨆",
    "sum": "Σ", "prod": "Π", "coprod": "∐", "int": "∫", "iint": "∬", "iiint": "∭",
    "oint": "∮", "oiint": "∯", "partial": "∂", "nabla": "∇", "surd": "√",
    // Logic and sets
    "forall": "∀", "exists": "∃", "nexists": "∄", "emptyset": "∅", "varnothing": "∅",
    "top": "⊤", "bot": "⊥", "therefore": "∴", "because": "∵", "infty": "∞",
    "aleph": "ℵ", "beth": "ℶ", "gimel": "ℷ", "complement": "∁",
    // Dots
    "ldots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱", "dots": "…", "dotsc": "…",
    "dotsb": "⋯", "dotsm": "⋯", "dotsi": "⋯", "iddots": "⋰",
    // Delimiters
    "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
    "lbrace": "{", "rbrace": "}", "lbrack": "[", "rbrack": "]", "vert": "|", "Vert": "‖",
    "lvert": "|", "rvert": "|", "lVert": "‖", "rVert": "‖", "backslash": "\\",
    "llcorner": "⌞", "lrcorner": "⌟", "ulcorner": "⌜", "urcorner": "⌝",
    // Miscellany
    "angle": "∠", "measuredangle": "∡", "sphericalangle": "∢", "triangle": "△",
    "square": "□", "Box": "□", "blacksquare": "■", "Diamond": "◇", "lozenge": "◊",
    "blacktriangle": "▲", "blacktriangledown": "▼", "diamondsuit": "♢", "heartsuit": "♡",
    "clubsuit": "♣", "spadesuit": "♠", "degree": "°", "prime": "′", "dprime": "″",
    "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ", "wp": "℘", "mho": "℧", "imath": "ı",
    "jmath": "ȷ", "pounds": "£", "euro": "€", "yen": "¥", "S": "§", "P": "¶",
    "copyright": "©", "checkmark": "✓", "maltese": "✠", "flat": "♭", "natural": "♮",
    "sharp": "♯", "bigstar": "★", "textasciitilde": "~",
    "textbackslash": "\\", "textbar": "|", "textless": "<", "textgreater": ">",
    "ldotp": ".", "cdotp": "·", "quad": " ", "qquad": " ", "thinspace": " ",
    "enspace": " ", "space": " ", "negthinspace": "", "medspace": " ", "thickspace": " ",
    // Greek
    "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
    "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι",
    "kappa": "κ", "varkappa": "ϰ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
    "omicron": "ο", "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ",
    "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "φ", "chi": "χ",
    "psi": "ψ", "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
    "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
  ]
}

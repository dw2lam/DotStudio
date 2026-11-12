//  GLSLTranslator.swift — Shadertoy-style GLSL → Metal (the `shadertoy` engine, kind glsl-source).
//
//  The engine's compat header (ShadertoyCompat.h) covers what a header can: the vecN / matN types,
//  GLSL's mod / atan(y, x) / inversesqrt / dFdx / lessThan / inverse …, and Shadertoy's uniforms
//  as macros over a struct `_st`. This rewriter does the rest, token by token, keeping every
//  newline where it was — the output has the user's line count, so a compile error's line is the
//  user's line:
//    • every function the package defines gets a hidden first parameter, `thread const
//      DSShadertoy& _st`, and every call to one passes `_st` (Metal has no globals: this is how
//      iTime reaches a helper function);
//    • `out` / `inout` parameters become `thread T&`, `in` is dropped;
//    • `const` globals become `constant` (Metal's program-scope constants); other globals,
//      `uniform`s and texture channels are reported (no equivalent);
//    • `T[N](a, b)` array constructors → `{a, b}`; `Struct(a, b)` → `Struct{a, b}`;
//      `mat2(a, b, c, d)` (scalars) → `float2x2(float2(a, b), float2(c, d))` (also mat3 / mat4);
//      `vec3(x)` with one argument → `ds_vec3(x)` (GLSL truncates a longer vector, Metal doesn't);
//    • `precision` statements, precision qualifiers, `#version` and `#extension` are dropped;
//    • identifiers that are keywords in Metal but not GLSL (half, kernel, device, thread, …) are
//      renamed `_u_<name>`.
//  Function-like macros are rewritten the same way (their bodies usually call package functions).

import Foundation

enum GLSLTranslator {
    /// Rewrites `source` to Metal that compiles after the shadertoy engine's compat header. Keeps
    /// the line count, so compile errors map 1:1 to the user's lines.
    static func translate(_ source: String, file: String) -> (source: String, diagnostics: [Diagnostic]) {
        var t = Translation(source: source, file: file)
        t.run()
        return (t.output(), t.diagnostics)
    }

    // MARK: Tokens

    enum Kind { case ident, number, punct, space, comment }

    struct Token {
        var kind: Kind
        var text: String
        var line: Int
        var col: Int
        /// 0 = code; each preprocessor line its own segment (rewrites never cross segments).
        var segment: Int
    }

    static func tokenize(_ source: String) -> [Token] {
        let s = Array(source.unicodeScalars)
        var out: [Token] = []
        var i = 0, line = 1, col = 1
        var lineStart = true           // only whitespace since the last newline
        var segment = 0, ppCount = 0
        func isIdentStart(_ c: Unicode.Scalar) -> Bool { c == "_" || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") }
        func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }
        func isIdent(_ c: Unicode.Scalar) -> Bool { isIdentStart(c) || isDigit(c) }
        while i < s.count {
            let c = s[i]
            let start = i, l0 = line, c0 = col
            var kind: Kind = .punct
            func advance(_ n: Int = 1) {
                for _ in 0..<n where i < s.count {
                    if s[i] == "\n" { line += 1; col = 1 } else { col += 1 }
                    i += 1
                }
            }
            if c == "\n" {
                advance()
                kind = .space
                if segment != 0 { segment = 0 }            // a preprocessor line ends
                lineStart = true
            } else if c == " " || c == "\t" || c == "\r" || c == "\u{0C}" {
                advance(); kind = .space
                while i < s.count, s[i] == " " || s[i] == "\t" || s[i] == "\r" { advance() }
            } else if c == "\\", i + 1 < s.count, s[i + 1] == "\n" {
                advance(2); kind = .space                  // a line continuation: the segment goes on
            } else if c == "/", i + 1 < s.count, s[i + 1] == "/" {
                while i < s.count, s[i] != "\n" { advance() }
                kind = .comment
            } else if c == "/", i + 1 < s.count, s[i + 1] == "*" {
                advance(2)
                while i < s.count, !(s[i] == "*" && i + 1 < s.count && s[i + 1] == "/") { advance() }
                advance(2)
                kind = .comment
            } else if isIdentStart(c) {
                while i < s.count, isIdent(s[i]) { advance() }
                kind = .ident
            } else if isDigit(c) || (c == "." && i + 1 < s.count && isDigit(s[i + 1])) {
                while i < s.count {
                    let d = s[i]
                    if isIdent(d) || d == "." { advance() }
                    else if (d == "+" || d == "-"), i > start, s[i - 1] == "e" || s[i - 1] == "E",
                            !(s[start] == "0" && start + 1 < s.count && (s[start + 1] == "x" || s[start + 1] == "X")) { advance() }
                    else { break }
                }
                kind = .number
            } else {
                if c == "#" && lineStart { ppCount += 1; segment = ppCount }
                advance()
                kind = .punct
            }
            if kind != .space && kind != .comment { lineStart = false }
            if kind == .space && s[start..<i].contains("\n") && !(s[start] == "\\") { lineStart = true }
            var text = ""
            text.unicodeScalars.append(contentsOf: s[start..<i])
            out.append(Token(kind: kind, text: text, line: l0, col: c0, segment: kind == .space && text.contains("\n") && text.first != "\\" ? 0 : segment))
        }
        return out
    }

    // MARK: The rewrite

    static let precisionWords: Set<String> = ["highp", "mediump", "lowp"]
    static let scalarTypes: Set<String> = ["float", "int", "uint", "bool", "void"]
    static let vectorTypes: Set<String> = ["vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4", "uvec2", "uvec3", "uvec4",
                                           "bvec2", "bvec3", "bvec4"]
    static let matrixDims: [String: (cols: Int, rows: Int)] = [
        "mat2": (2, 2), "mat3": (3, 3), "mat4": (4, 4), "mat2x2": (2, 2), "mat3x3": (3, 3), "mat4x4": (4, 4),
        "mat2x3": (2, 3), "mat2x4": (2, 4), "mat3x2": (3, 2), "mat3x4": (3, 4), "mat4x2": (4, 2), "mat4x3": (4, 3)]
    /// Keywords / reserved words in Metal (C++14) that a GLSL program may use as a name.
    static let metalReserved: Set<String> = [
        "half", "constant", "device", "thread", "threadgroup", "threadgroup_imageblock", "kernel", "vertex",
        "fragment", "sampler", "visible", "stitchable", "ray_data", "object_data", "char", "short", "long", "signed",
        "unsigned", "double", "class", "namespace", "template", "typename", "this", "new", "delete", "operator",
        "private", "protected", "public", "using", "auto", "union", "enum", "goto", "register", "static", "extern",
        "friend", "virtual", "mutable", "explicit", "export", "sizeof", "typedef", "volatile", "alignas", "alignof",
        "decltype", "nullptr", "catch", "try", "throw", "typeid", "constexpr", "static_assert", "noexcept",
        "thread_local", "wchar_t", "char16_t", "char32_t", "asm", "dynamic_cast", "static_cast", "const_cast",
        "reinterpret_cast", "size_t", "ptrdiff_t", "uchar", "ushort", "ulong", "half2", "half3", "half4",
        "inline", "and_eq", "or_eq", "xor_eq", "bitand", "bitor", "compl", "not_eq", "xor", "and", "or"]
    static let channelWords: Set<String> = ["texture", "texelFetch", "textureLod", "textureGrad", "textureSize",
                                            "textureProj", "textureOffset", "texelFetchOffset", "iChannel0", "iChannel1",
                                            "iChannel2", "iChannel3", "iChannelResolution", "iChannelTime",
                                            "sampler2D", "samplerCube", "sampler3D"]

    struct Translation {
        let file: String
        var toks: [Token]
        var out: [String]
        var pre: [String]
        var post: [String]
        var diagnostics: [Diagnostic] = []
        /// Significant tokens (no space / comments), in order.
        var sig: [Int] = []
        /// Matching bracket per token index (for ( [ { and their closers), within a segment.
        var match: [Int: Int] = [:]
        var userFuncs = Set<String>()
        var structs = Set<String>()
        var defNames = Set<Int>()          // token indices of function names at their definition
        var reportedChannel = false

        init(source: String, file: String) {
            self.file = file
            toks = GLSLTranslator.tokenize(source)
            out = toks.map(\.text)
            pre = Array(repeating: "", count: toks.count)
            post = Array(repeating: "", count: toks.count)
        }

        func output() -> String {
            var s = ""
            for i in toks.indices { s += pre[i]; s += out[i]; s += post[i] }
            return s
        }

        mutating func diag(_ i: Int, _ msg: String, _ sev: Diagnostic.Severity = .error) {
            let t = i < toks.count ? toks[i] : Token(kind: .space, text: "", line: 1, col: 1, segment: 0)
            let d = Diagnostic(line: t.line, column: t.col, message: msg, severity: sev, file: file)
            if !diagnostics.contains(d) { diagnostics.append(d) }
        }

        /// Blanks a token's text (its newlines stay, so lines never move).
        mutating func blank(_ i: Int) {
            out[i] = toks[i].kind == .comment ? String(toks[i].text.filter { $0 == "\n" }) : ""
        }

        /// Position in `sig` of token index i.
        func sigPos(_ i: Int) -> Int? {
            var lo = 0, hi = sig.count - 1
            while lo <= hi {
                let m = (lo + hi) / 2
                if sig[m] == i { return m }
                if sig[m] < i { lo = m + 1 } else { hi = m - 1 }
            }
            return nil
        }
        /// The next significant token after sig position k in the same segment.
        func nextSig(_ k: Int) -> Int? {
            guard k + 1 < sig.count, toks[sig[k + 1]].segment == toks[sig[k]].segment else { return nil }
            return k + 1
        }
        func prevSig(_ k: Int) -> Int? {
            guard k > 0, toks[sig[k - 1]].segment == toks[sig[k]].segment else { return nil }
            return k - 1
        }
        func text(_ k: Int?) -> String? { k.map { toks[sig[$0]].text } }

        mutating func run() {
            // Directives first: drop #version / #extension lines.
            var i = 0
            while i < toks.count {
                if toks[i].text == "#", toks[i].segment != 0 {
                    var j = i + 1
                    while j < toks.count, toks[j].kind == .space, toks[j].segment != 0 { j += 1 }
                    if j < toks.count, toks[j].segment == toks[i].segment, toks[j].text == "version" || toks[j].text == "extension" {
                        var k = i
                        while k < toks.count, toks[k].segment == toks[i].segment { if toks[k].kind != .space { blank(k) }; k += 1 }
                        i = k; continue
                    }
                }
                i += 1
            }
            sig = toks.indices.filter { toks[$0].kind != .space && toks[$0].kind != .comment && !out[$0].isEmpty }
            matchBrackets()
            structure()
            swizzleCompound()
            expressions()
            if !userFuncs.contains("mainImage") {
                diagnostics.append(Diagnostic(line: 1, column: 1, message: "no mainImage(out vec4 fragColor, in vec2 fragCoord): a Shadertoy scene draws in mainImage", severity: .error, file: file))
            }
        }

        mutating func matchBrackets() {
            var stacks: [Int: [Int]] = [:]
            for i in sig {
                let seg = toks[i].segment
                switch toks[i].text {
                case "(", "[", "{": stacks[seg, default: []].append(i)
                case ")", "]", "}":
                    if let o = stacks[seg]?.popLast() { match[o] = i; match[i] = o }
                    else if seg == 0 { diag(i, "unbalanced \(toks[i].text)") }
                default: break
                }
            }
            if let o = stacks[0]?.last { diag(o, "unclosed \(toks[o].text)") }
        }

        func isType(_ s: String) -> Bool {
            scalarTypes.contains(s) || vectorTypes.contains(s) || matrixDims[s] != nil || structs.contains(s)
        }

        /// Top-level declarations: structs, functions (definitions and prototypes), globals.
        mutating func structure() {
            let code = sig.indices.filter { toks[sig[$0]].segment == 0 }
            var pos: [Int: Int] = [:]                // token index → position in `code`
            for (n, k) in code.enumerated() { pos[sig[k]] = n }
            var p = 0
            while p < code.count {
                let k = code[p]
                let i = sig[k]
                let w = toks[i].text
                // the end of this top-level statement (a ; at depth 0, or a function body's })
                func skipTo(_ terminator: String) -> Int {
                    var q = p
                    while q < code.count {
                        let ti = sig[code[q]]
                        if toks[ti].text == terminator { return q }
                        if ["(", "[", "{"].contains(toks[ti].text), let m = match[ti], let mp = pos[m] { q = mp + 1; continue }
                        q += 1
                    }
                    return code.count - 1
                }
                if w == ";" { p += 1; continue }
                if w == "precision" {
                    let e = skipTo(";")
                    for q in p...e { blank(sig[code[q]]) }
                    p = e + 1; continue
                }
                if w == "struct" {
                    if p + 1 < code.count { structs.insert(toks[sig[code[p + 1]]].text) }
                    let e = skipTo(";")
                    // `struct S { … } s;` declares a global too
                    if e > p, let close = (p..<e).last(where: { toks[sig[code[$0]]].text == "}" }), close + 1 < e {
                        diag(sig[code[close + 1]], "global variables aren't supported (Metal has no mutable globals): declare it inside mainImage")
                    }
                    p = e + 1; continue
                }
                if ["uniform", "in", "out", "varying", "attribute", "buffer", "shared"].contains(w) {
                    diag(i, "`\(w)` globals aren't supported: Shadertoy's uniforms (iTime, iResolution, …) are already there; other inputs have no DotStudio equivalent")
                    let e = skipTo(";")
                    p = e + 1; continue
                }
                // qualifiers, then a type, then a name
                var q = p
                var isConst = false
                while q < code.count, ["const", "highp", "mediump", "lowp", "invariant", "flat", "smooth"].contains(toks[sig[code[q]]].text) {
                    if toks[sig[code[q]]].text == "const" { isConst = true }
                    q += 1
                }
                guard q + 1 < code.count else { p = q + 1; continue }
                let typeIdx = sig[code[q]]
                var nameQ = q + 1
                // `float[3] x = …` (type-first array) — keep scanning past the brackets
                if toks[sig[code[nameQ]]].text == "[", let m = match[sig[code[nameQ]]], let mp = pos[m] {
                    nameQ = mp + 1
                }
                guard nameQ + 1 < code.count, toks[typeIdx].kind == .ident, toks[sig[code[nameQ]]].kind == .ident else {
                    let e = skipTo(";"); p = e + 1; continue
                }
                let nameIdx = sig[code[nameQ]]
                let after = toks[sig[code[nameQ + 1]]].text
                if after == "(" && !isConst {
                    // a function: definition or prototype
                    let open = sig[code[nameQ + 1]]
                    userFuncs.insert(toks[nameIdx].text)
                    defNames.insert(nameIdx)
                    rewriteParams(open: open)
                    guard let close = match[open], let cp = pos[close] else { p = code.count; continue }
                    if cp + 1 < code.count, toks[sig[code[cp + 1]]].text == "{", let bodyEnd = match[sig[code[cp + 1]]],
                       let bp = pos[bodyEnd] {
                        p = bp + 1
                    } else {
                        p = cp + 2
                    }
                    continue
                }
                if isConst {
                    // a program-scope constant
                    for qq in p..<q where toks[sig[code[qq]]].text == "const" { out[sig[code[qq]]] = "constant" }
                    let e = skipTo(";"); p = e + 1; continue
                }
                if isType(toks[typeIdx].text) || after == "=" || after == ";" || after == "," || after == "[" {
                    diag(nameIdx, "global variable `\(toks[nameIdx].text)` isn't supported (Metal has no mutable globals): make it `const`, a #define, or declare it inside mainImage and pass it to the functions that need it")
                }
                let e = skipTo(";"); p = e + 1
            }
        }

        /// `(in vec2 p, out float d, inout vec3 c)` → `(thread const DSShadertoy& _st, vec2 p, thread float& d, thread vec3& c)`.
        mutating func rewriteParams(open: Int) {
            guard let close = match[open], let ko = sigPos(open), let kc = sigPos(close) else { return }
            let inner = (ko + 1)..<kc
            let onlyVoid = inner.count == 1 && toks[sig[inner.lowerBound]].text == "void"
            if inner.isEmpty || onlyVoid {
                if onlyVoid { blank(sig[inner.lowerBound]) }
                post[open] += "thread const DSShadertoy& _st"
                return
            }
            post[open] += "thread const DSShadertoy& _st, "
            // split into parameters at top-level commas
            var params: [[Int]] = [[]]
            var depth = 0
            for k in inner {
                let s = toks[sig[k]].text
                if s == "(" || s == "[" { depth += 1 }
                if s == ")" || s == "]" { depth -= 1 }
                if s == "," && depth == 0 { params.append([]); continue }
                params[params.count - 1].append(k)
            }
            for prm in params {
                var byRef = false
                var typeK: Int?
                for k in prm {
                    let i = sig[k], s = toks[i].text
                    if s == "in" || precisionWords.contains(s) { blank(i); continue }
                    if s == "out" || s == "inout" { out[i] = "thread"; byRef = true; continue }
                    if s == "const" { continue }
                    if typeK == nil { typeK = k }
                }
                if byRef, let t = typeK {
                    post[sig[t]] += "&"
                    if prm.contains(where: { toks[sig[$0]].text == "[" }) {
                        diag(sig[t], "out / inout array parameters aren't supported")
                    }
                }
            }
        }

        /// `p.xz *= rot(a);` → `p.xz = p.xz * (rot(a));`: Metal can't bind a swizzle to the
        /// reference an overloaded compound operator (matrix × vector) takes.
        mutating func swizzleCompound() {
            func isSwizzle(_ s: String) -> Bool {
                s.count >= 2 && s.count <= 4 && (s.allSatisfy { "xyzw".contains($0) } || s.allSatisfy { "rgba".contains($0) })
            }
            for k in sig.indices {
                let i = sig[k]
                guard toks[i].kind == .ident, isSwizzle(toks[i].text), let pd = prevSig(k), text(pd) == ".",
                      let op = nextSig(k), ["*", "/", "+", "-"].contains(text(op) ?? ""),
                      let eq = nextSig(op), text(eq) == "=", sig[eq] == sig[op] + 1,
                      let first = nextSig(eq), text(first) != "=" else { continue }
                // the lvalue: ident(.ident | [ … ])* ending at the swizzle
                var ls = pd
                while let b = prevSig(ls) {
                    let bt = toks[sig[b]]
                    if bt.kind == .ident, let bb = prevSig(b), text(bb) == "." { ls = bb; continue }
                    if bt.kind == .ident { ls = b; break }
                    if bt.text == "]", let o = match[sig[b]], let ko = sigPos(o), let before = prevSig(ko), toks[sig[before]].kind == .ident {
                        ls = before
                        if let dot = prevSig(before), text(dot) == "." { ls = dot; continue }
                        break
                    }
                    break
                }
                guard toks[sig[ls]].kind == .ident else { continue }
                // the right-hand side: up to ; , or an unmatched ) at depth 0
                var last = first
                var depth = 0
                var q: Int? = first
                while let qq = q {
                    let s = text(qq)!
                    if s == "(" || s == "[" || s == "{" { depth += 1 }
                    if s == ")" || s == "]" || s == "}" { if depth == 0 { break }; depth -= 1 }
                    if depth == 0 && (s == ";" || s == ",") { break }
                    last = qq
                    q = nextSig(qq)
                }
                var lv = ""
                for kk in ls...k {
                    let tx = toks[sig[kk]].text
                    lv += metalReserved.contains(tx) ? "_u_" + tx : tx
                }
                out[sig[op]] = "= " + lv + " " + toks[sig[op]].text
                blank(sig[eq])
                pre[sig[first]] = "(" + pre[sig[first]]
                post[sig[last]] += ")"
            }
        }

        /// Top-level argument count of the call whose `(` is token `open`.
        func argCount(open: Int) -> (count: Int, commas: [Int]) {
            guard let close = match[open], let ko = sigPos(open), let kc = sigPos(close) else { return (0, []) }
            if kc == ko + 1 { return (0, []) }
            var depth = 0
            var commas: [Int] = []
            for k in (ko + 1)..<kc {
                let s = toks[sig[k]].text
                if s == "(" || s == "[" || s == "{" { depth += 1 }
                if s == ")" || s == "]" || s == "}" { depth -= 1 }
                if s == "," && depth == 0 { commas.append(sig[k]) }
            }
            return (commas.count + 1, commas)
        }

        mutating func expressions() {
            var reported = Set<String>()
            for k in sig.indices {
                let i = sig[k]
                guard toks[i].kind == .ident else { continue }
                let w = toks[i].text
                let next = nextSig(k)
                let nextText = text(next)
                let prevText = text(prevSig(k))
                // a #define's own name is never rewritten
                if toks[i].segment != 0, let p2 = prevSig(k), text(p2) == "define" { continue }
                if precisionWords.contains(w) { blank(i); continue }
                if channelWords.contains(w) {
                    if !reported.contains(w) {
                        reported.insert(w)
                        diag(i, "`\(w)`: texture channels (iChannel0…3) aren't available in DotStudio — generate the image procedurally instead")
                    }
                    continue
                }
                if w == "gl_FragCoord" || w == "gl_FragColor" {
                    diag(i, "\(w): write a Shadertoy-style mainImage(out vec4 fragColor, in vec2 fragCoord)")
                    continue
                }
                if metalReserved.contains(w) { out[i] = "_u_" + w }
                guard let n = next, let open = Optional(sig[n]) else { continue }
                // calls to the package's own functions pass the uniforms
                if nextText == "(", userFuncs.contains(w), !defNames.contains(i), prevText != "." {
                    let empty = text(nextSig(n)) == ")"
                    post[open] += empty ? "_st" : "_st, "
                    continue
                }
                // Struct(a, b) → Struct{a, b}
                if nextText == "(", structs.contains(w), prevText != ".", let close = match[open] {
                    out[open] = "{"; out[close] = "}"
                    continue
                }
                // T[N](a, b) → {a, b}
                if nextText == "[", isType(w), let rb = match[open], let kr = sigPos(rb), let after = nextSig(kr),
                   text(after) == "(", let close = match[sig[after]] {
                    blank(i)
                    if let ko = sigPos(open) { for kk in ko...kr { blank(sig[kk]) } }
                    out[sig[after]] = "{"; out[close] = "}"
                    continue
                }
                if nextText == "(", let dims = matrixDims[w], let close = match[open] {
                    let (count, commas) = argCount(open: open)
                    if count == dims.cols * dims.rows && dims.rows > 1 {
                        // scalars → one column vector per `rows` scalars
                        let colType = "float\(dims.rows)"
                        out[i] = "float\(dims.cols)x\(dims.rows)"
                        out[open] = "(" + colType + "("
                        for (ci, c) in commas.enumerated() where ci % dims.rows == dims.rows - 1 { out[c] = "), " + colType + "(" }
                        out[close] = "))"
                    } else if count != 1 && count != dims.cols {
                        diag(i, "\(w)(…) with \(count) arguments: use \(dims.cols) column vectors or \(dims.cols * dims.rows) scalars", .warning)
                    }
                    continue
                }
                if nextText == "(", ["vec2", "vec3", "vec4"].contains(w), prevText != ".", argCount(open: open).count == 1 {
                    out[i] = "ds_" + w
                    continue
                }
            }
        }
    }
}

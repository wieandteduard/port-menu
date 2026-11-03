import Foundation

/// 判断一个进程的 cwd 属于仓库里的哪个 workspace 包，以及它该怎么显示。
///
/// 为什么需要兜底：本机的 monorepo（`gc-2026` / `gc-2026-09` / `gc-2026-10`）大多
/// **没有** workspace 清单，只有 `packages/*` 目录约定 + 包内 `package.json`。
/// 所以规则分两层：
///
/// 1. 仓库声明了清单 → **只认清单**（声明本身就是一个否决权：没被声明的目录不算包）；
/// 2. 没有清单 → 目录约定：cwd 之下第一层含 manifest 的目录（深度 ≥ 2、≤ 4、不含排除段）。
///
/// 两种情况都不命中就返回 nil，调用方回退到仓库名——回退必须是显式的。
enum WorkspaceResolver {
    static let manifestNames = ["package.json", "Cargo.toml", "go.mod"]

    static let excludedSegments: Set<String> = [
        "node_modules", ".git", "build", "dist", "target", "_build",
        "vendor", ".next", "out", "coverage",
    ]

    /// 相对仓库根的最浅/最深层数：`packages/x` 是 2 层，再深基本都是源码子目录。
    static let minDepth = 2
    static let maxDepth = 4

    // MARK: - 判定

    /// - Parameters:
    ///   - patterns: 仓库声明的 workspace pattern；`nil` 或空表示没有清单，走目录约定。
    /// - Returns: 包目录相对仓库根的路径，如 `packages/c3-disco-droids`；不是包则 nil。
    static func packagePath(cwd: String, repoRoot: String, patterns: [String]?) -> String? {
        let root = trimmingTrailingSlash(repoRoot)
        let dir = trimmingTrailingSlash(cwd)
        guard dir != root, dir.hasPrefix(root + "/") else { return nil }

        let segments = dir.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        guard !segments.isEmpty,
              !segments.contains(where: { excludedSegments.contains($0.lowercased()) })
        else { return nil }

        if let patterns, !patterns.isEmpty {
            return deepestDeclaredMatch(segments: segments, patterns: patterns)
        }
        return deepestDirectoryWithManifest(segments: segments, root: root)
    }

    private static func deepestDeclaredMatch(segments: [String], patterns: [String]) -> String? {
        // 声明层不受 minDepth 限制：清单把包直接写在仓库根下是合法的
        // （例如 pnpm 项目里 `- codex-cli` 这种深度 1 的条目）。
        guard !segments.isEmpty else { return nil }
        // "!" 前缀是排除项（pnpm 的 `!pattern` 与 Cargo 的 `exclude` 共用这个编码）。
        let positives = patterns.filter { !$0.hasPrefix("!") }
        let negatives = patterns.filter { $0.hasPrefix("!") }

        // 最长匹配前缀：嵌套包取最具体的那层。
        for depth in stride(from: segments.count, through: 1, by: -1) {
            let candidate = segments[0..<depth].joined(separator: "/")
            guard positives.contains(where: { matches(pattern: $0, path: candidate) }) else { continue }
            guard !negatives.contains(where: { matches(pattern: $0, path: candidate) }) else { return nil }
            return candidate
        }
        return nil
    }

    private static func deepestDirectoryWithManifest(segments: [String], root: String) -> String? {
        let upper = min(segments.count, maxDepth)
        guard upper >= minDepth else { return nil }
        for depth in stride(from: upper, through: minDepth, by: -1) {
            let candidate = segments[0..<depth].joined(separator: "/")
            let directory = root + "/" + candidate
            for manifest in manifestNames
            where FileManager.default.fileExists(atPath: directory + "/" + manifest) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - 显示

    /// 所有包共享的直接父目录（如 `packages/`）；不共享或层数不一致时返回 nil。
    ///
    /// 省掉它是有实际收益的：`gc-2026-10 › packages/c2-boxing-fighter-super-punch`
    /// 在 340pt 的弹窗里宽 346pt 必然截断，去掉 `packages/` 后 283pt 放得下。
    static func elisionPrefix(for paths: [String]) -> String? {
        guard !paths.isEmpty else { return nil }
        var parents: [String] = []
        for path in paths {
            guard let slash = path.lastIndex(of: "/") else { return nil }
            parents.append(String(path[path.startIndex..<slash]))
        }
        guard let first = parents.first, !first.isEmpty,
              parents.allSatisfy({ $0 == first })
        else { return nil }
        return first + "/"
    }

    // MARK: - Glob 匹配（单路径，不枚举文件系统）

    /// `*` 只吃一层，`**` 吃任意层；字面段大小写不敏感。
    static func matches(pattern: String, path: String) -> Bool {
        let patternSegments = normalizingPattern(pattern).split(separator: "/").map(String.init)
        let pathSegments = path.split(separator: "/").map(String.init)
        return matches(patternSegments, 0, pathSegments, 0)
    }

    private static func matches(
        _ pattern: [String], _ patternIndex: Int,
        _ path: [String], _ pathIndex: Int
    ) -> Bool {
        if patternIndex == pattern.count { return pathIndex == path.count }
        let token = pattern[patternIndex]

        if token == "**" {
            if patternIndex == pattern.count - 1 { return true }
            var skip = pathIndex
            while skip <= path.count {
                if matches(pattern, patternIndex + 1, path, skip) { return true }
                skip += 1
            }
            return false
        }

        guard pathIndex < path.count else { return false }
        if token == "*" || token.caseInsensitiveCompare(path[pathIndex]) == .orderedSame {
            return matches(pattern, patternIndex + 1, path, pathIndex + 1)
        }
        return false
    }

    private static func normalizingPattern(_ pattern: String) -> String {
        var value = pattern.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("!") { value.removeFirst() }
        if value.hasPrefix("./") { value.removeFirst(2) }
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func trimmingTrailingSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    // MARK: - 清单读取（带 mtime 缓存）

    /// 仓库声明的 workspace pattern；没有任何清单时返回 nil。
    ///
    /// 按 **mtime** 失效：改清单不用等 TTL，也不用每次扫描重读。
    static func patterns(atRepoRoot root: URL) -> [String]? {
        let path = root.path()
        let stamp = manifestStamp(atRepoRoot: root)
        if let cached = cache.lookup(path: path, stamp: stamp) { return cached }
        let parsed = parsePatterns(atRepoRoot: root)
        cache.store(parsed, stamp: stamp, path: path)
        return parsed
    }

    private static func parsePatterns(atRepoRoot root: URL) -> [String]? {
        // pnpm 的 YAML 优先于 package.json 的 workspaces（两者都在时 pnpm 只读 YAML）。
        if let yaml = read(root.appending(path: "pnpm-workspace.yaml")),
           let list = pnpmPatterns(yaml), !list.isEmpty {
            return list
        }
        if let json = read(root.appending(path: "package.json")),
           let list = npmPatterns(json), !list.isEmpty {
            return list
        }
        if let toml = read(root.appending(path: "Cargo.toml")),
           let list = cargoMembers(toml), !list.isEmpty {
            return list
        }
        if let work = read(root.appending(path: "go.work")),
           let list = goWorkUse(work), !list.isEmpty {
            return list
        }
        return nil
    }

    private static func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private static func manifestStamp(atRepoRoot root: URL) -> Date {
        let candidates = ["pnpm-workspace.yaml", "package.json", "Cargo.toml", "go.work"]
        var latest = Date.distantPast
        for name in candidates {
            let url = root.appending(path: name)
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate else { continue }
            latest = max(latest, modified)
        }
        return latest
    }

    // MARK: - 各生态清单的最简解析

    /// `pnpm-workspace.yaml` 里 `packages:` 的列表项。只处理列表形式，够用。
    static func pnpmPatterns(_ yaml: String) -> [String]? {
        var result: [String] = []
        var insidePackages = false
        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if !insidePackages {
                if line.hasPrefix("packages:") {
                    let inline = line.dropFirst("packages:".count).trimmingCharacters(in: .whitespaces)
                    if inline.hasPrefix("[") {
                        return inline
                            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                            .split(separator: ",")
                            .map { unquoting($0.trimmingCharacters(in: .whitespaces)) }
                            .filter { !$0.isEmpty }
                    }
                    insidePackages = true
                }
                continue
            }

            if line.hasPrefix("- ") {
                let value = unquoting(line.dropFirst(2).trimmingCharacters(in: .whitespaces))
                // 保留 `!pattern`：它是排除项，交给 deepestDeclaredMatch 处理。
                if !value.isEmpty { result.append(value) }
            } else if !line.hasPrefix("#") {
                insidePackages = false
            }
        }
        return result.isEmpty ? nil : result
    }

    /// `package.json` 的 `workspaces`：数组形式，或 Yarn 1 的 `{ packages: [...] }`。
    static func npmPatterns(_ json: String) -> [String]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workspaces = object["workspaces"]
        else { return nil }

        if let list = workspaces as? [String] { return list.isEmpty ? nil : list }
        if let dictionary = workspaces as? [String: Any],
           let list = dictionary["packages"] as? [String], !list.isEmpty {
            return list
        }
        return nil
    }

    /// `Cargo.toml` 的 `[workspace] members`（正向）与 `exclude`（编码成 `!pattern`）。
    static func cargoMembers(_ toml: String) -> [String]? {
        guard let workspaceRange = toml.range(of: "[workspace]") else { return nil }
        let body = toml[workspaceRange.upperBound...]

        let members = quotedArray(after: "members", in: body) ?? []
        let excludes = quotedArray(after: "exclude", in: body) ?? []
        guard !members.isEmpty else { return nil }
        return members + excludes.map { "!" + $0 }
    }

    /// 取 `key = [ ... ]` 里的字符串数组，支持单行与多行。
    private static func quotedArray(after key: String, in text: Substring) -> [String]? {
        guard let keyRange = text.range(of: key) else { return nil }
        let afterKey = text[keyRange.upperBound...]
        guard let open = afterKey.firstIndex(of: "[") else { return nil }

        var collected = "\""
        var depth = 0
        for character in afterKey[open...] {
            if character == "[" { depth += 1 }
            if character == "]" {
                depth -= 1
                if depth == 0 { collected.append("\""); break }
            }
            collected.append(character)
        }

        let quoted = collected.split(separator: "\"").enumerated()
            .filter { $0.offset % 2 == 1 }
            .map { String($0.element) }
        return quoted.isEmpty ? nil : quoted
    }

    /// `go.work` 的 `use` 指令：单值或块形式。
    static func goWorkUse(_ work: String) -> [String]? {
        var result: [String] = []
        var insideBlock = false
        for rawLine in work.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") { continue }

            if line == "use (" { insideBlock = true; continue }
            if insideBlock, line == ")" { insideBlock = false; continue }

            if insideBlock {
                line = unquoting(line)
                if !line.isEmpty { result.append(line) }
                continue
            }
            if line.hasPrefix("use ") {
                line = unquoting(line.dropFirst(4).trimmingCharacters(in: .whitespaces))
                if !line.isEmpty { result.append(line) }
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func unquoting(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        for quote in ["\"", "'"] where text.hasPrefix(quote) && text.hasSuffix(quote) && text.count >= 2 {
            text = String(text.dropFirst().dropLast())
            break
        }
        return text
    }

    // MARK: - 缓存

    private static let cache = PatternCache()

    final class PatternCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: (patterns: [String]?, stamp: Date)] = [:]

        func lookup(path: String, stamp: Date) -> [String]?? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = storage[path], entry.stamp == stamp else { return nil }
            return .some(entry.patterns)
        }

        func store(_ patterns: [String]?, stamp: Date, path: String) {
            lock.lock()
            defer { lock.unlock() }
            if storage.count > 64 { storage.removeAll() }
            storage[path] = (patterns, stamp)
        }
    }
}

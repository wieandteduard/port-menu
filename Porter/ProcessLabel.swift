import Foundation

/// 无 git 根的进程该叫什么。
///
/// 这类行以前退回"cwd 的目录名"或"进程名"，两者都不说明"这是什么在跑"：
///
/// - cwd 是 `~/Github` 时显示 `Github`——那是个装仓库的容器，看不出跑的是 `dsh`；
/// - Raycast 的后台进程把进程标题改成了 `Raycast Backend`，而 `lsof` 的 COMMAND
///   列只给内核里的 `node`，于是那行就叫 `node`，没有任何信息。
///
/// 所以无 git 根时统一取**命令身份**作主行：解释器（node/python…）就往下钻到它跑的
/// 脚本或包里，非解释器就用程序名；目录位置交给副行显示，不再冒充项目名。
enum ProcessLabel {
    static let interpreterNames: Set<String> = [
        "node", "bun", "deno", "npx", "tsx", "ts-node",
        "python", "python2", "python3", "php", "ruby", "perl", "java",
    ]

    /// 由 `ps -o command=`（整条命令行）与 `lsof` 的 COMMAND 列推出一个可读名字。
    static func label(command: String, processName: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return processName }

        let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let executableToken = tokens.first else { return processName }
        let executableName = (executableToken as NSString).lastPathComponent.lowercased()

        // 进程自己改了标题：命令行第一个词既不是路径，也和 lsof 的 COMMAND 对不上。
        // 例：COMMAND=node，command="Raycast Backend"。
        if !executableToken.contains("/"), !namesMatch(executableName, processName) {
            return trimmed
        }

        guard interpreterNames.contains(strippingVersionSuffix(executableName)) else {
            return executableName.isEmpty ? processName : executableName
        }

        return scriptLabel(from: Array(tokens.dropFirst())) ?? executableName
    }

    /// 打包器/脚手架的通用入口名不携带身份信息：`node dist/main.js` 推出 `main`，
    /// 和没说一样。这类名字不当作"身份"使用。
    static let genericEntryNames: Set<String> = [
        "main", "index", "bin", "dist", "start", "run", "src", "lib",
    ]

    static func isGenericEntryName(_ name: String) -> Bool {
        genericEntryNames.contains(name.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// 无 git 根时给副行用的目录位置；家目录下显示成 `~/…`。
    /// 返回空串表示"这里没什么好说的"（根目录、家目录本身、没有 cwd）。
    static func directoryTail(cwd: String?) -> String {
        guard var path = cwd, !path.isEmpty else { return "" }
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == "/" { return "" }

        // HOME 可能带尾斜杠（测试进程里就是这样），两边都要归一化再比。
        var home = FileManager.default.homeDirectoryForCurrentUser.path()
        if home.count > 1, home.hasSuffix("/") { home.removeLast() }
        if path == home { return "" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - 细节

    /// `python3` / `python3.14` / `node` → `python` / `node`。
    private static func strippingVersionSuffix(_ name: String) -> String {
        var result = name
        while let last = result.last, last.isNumber || last == "." {
            result.removeLast()
        }
        return result.isEmpty ? name : result
    }

    /// `COMMAND` 列会被截断到 9 个字符，所以只要求前缀关系。
    private static func namesMatch(_ executable: String, _ processName: String) -> Bool {
        let comm = processName.lowercased()
        guard !comm.isEmpty else { return false }
        return executable.hasPrefix(comm) || comm.hasPrefix(executable)
    }

    /// 从解释器后面的参数里找出"跑的是什么"。
    private static func scriptLabel(from arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]

            // `python3 -m http.server` → http.server
            if argument == "-m", index + 1 < arguments.count {
                return arguments[index + 1]
            }
            if argument.hasPrefix("-") {
                index += 1
                continue
            }
            return scriptName(fromPath: argument)
        }
        return nil
    }

    /// 脚本 → 名字。优先读包元数据（`bin` 键 → 包名），读不到才回退路径推导。
    private static func scriptName(fromPath path: String) -> String {
        if let identity = PackageIdentity.name(forScript: path) { return identity }
        return pathOnlyName(fromPath: path)
    }

    private static func pathOnlyName(fromPath path: String) -> String {
        // pnpm dlx / npx 的缓存路径里包名在 node_modules 之后：
        // …/node_modules/@deepseek-ai/dsh/lib/bin.js → dsh
        if let range = path.range(of: "node_modules/", options: .backwards) {
            let remainder = path[range.upperBound...]
            let segments = remainder.split(separator: "/").map(String.init)
            if let first = segments.first {
                if first.hasPrefix("@"), segments.count >= 2 {
                    // 作用域包：@scope/name → name
                    let name = segments[1]
                    if !name.isEmpty, !name.hasSuffix(".js"), !name.hasSuffix(".mjs") {
                        return name
                    }
                    return strippingExtension(segments.last ?? first)
                }
                if first != ".bin", first != "..", first != "." {
                    return strippingExtension(first)
                }
            }
        }

        let base = (path as NSString).lastPathComponent
        return strippingExtension(base)
    }

    private static func strippingExtension(_ name: String) -> String {
        for suffix in [".js", ".mjs", ".cjs", ".ts", ".mts", ".cts", ".py", ".rb", ".php"] {
            if name.hasSuffix(suffix) { return String(name.dropLast(suffix.count)) }
        }
        return name
    }
}

// MARK: - 包元数据

/// 从脚本路径回溯到它所属的 npm 包，给出这个名字。
///
/// 为什么不是纯路径推导：真实机器上 `@heigame2020/xyx-cli` 的入口是 `main.js`，
/// 路径推导只能得到 `main`——毫无作用。包元数据能给出 `xyx`（`bin` 键，就是用户敲的命令）
/// 或 `@heigame2020/xyx-cli`（包名）。
///
/// 只认 `node_modules` 里的包（用户决定）：脚本在自己项目里跑时，
/// 项目身份已经由仓库名/包路径承担，这里回答的是"跑的是哪个第三方 CLI"。
enum PackageIdentity {
    struct Manifest {
        let name: String?
        /// `bin` 字段；字符串形式没有键名，只用来判断"这是个可执行包"。
        let binaries: [String: String]
    }

    static func name(forScript scriptPath: String) -> String? {
        let resolved = URL(filePath: scriptPath).resolvingSymlinksInPath().path()
        let insideNodeModules = resolved.contains("/node_modules/")

        guard let packageDirectory = nearestPackageDirectory(from: resolved),
              let manifest = manifest(at: packageDirectory)
        else { return nil }

        let relative = relativePath(of: resolved, in: packageDirectory)
        if let key = binKey(in: manifest, matching: relative) { return key }

        // 包里（`node_modules`）的脚本退一步用包名；
        // 但**项目自己的**脚本只认 bin 命中：否则一个 Rust 二进制会捞到上层
        // JS 项目的名字，比不显示更误导。
        return insideNodeModules ? manifest.name : nil
    }

    // MARK: 细节

    /// 从脚本往上找最近的 `package.json`。
    ///
    /// `node_modules` 里的脚本一路走到包根；项目自己的脚本最多上溯 `maxAncestors` 层，
    /// 免得一路走到家目录去捞一个无关的 `package.json`。
    private static func nearestPackageDirectory(from path: String) -> String? {
        let insideNodeModules = path.contains("/node_modules/")
        var directory = (path as NSString).deletingLastPathComponent
        var levels = 0

        while directory.count > 1 {
            if insideNodeModules {
                guard directory.contains("/node_modules/") || directory.hasSuffix("/node_modules") else {
                    return nil
                }
            } else {
                levels += 1
                guard levels <= maxAncestors else { return nil }
            }
            if FileManager.default.fileExists(atPath: directory + "/package.json") {
                return directory
            }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// `node_modules` 外的上溯上限：`…/xyx-cli/dist/main.js` 只需要 2 层。
    private static let maxAncestors = 5

    private static func relativePath(of file: String, in directory: String) -> String {
        guard file.hasPrefix(directory + "/") else { return (file as NSString).lastPathComponent }
        return String(file.dropFirst(directory.count + 1))
    }

    /// `bin` 值形如 `./bin/tsc`、`bin/tsc`、`./cli.js`，都要归一化后再比。
    private static func binKey(in manifest: Manifest, matching relativePath: String) -> String? {
        let target = normalizingBinaryPath(relativePath)
        for (key, value) in manifest.binaries where normalizingBinaryPath(value) == target {
            return key
        }
        return nil
    }

    private static func normalizingBinaryPath(_ value: String) -> String {
        var path = value.trimmingCharacters(in: .whitespaces)
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func manifest(at directory: String) -> Manifest? {
        let path = directory + "/package.json"
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date
        else { return nil }

        if let cached = cache.lookup(path: path, stamp: modified) { return cached }

        let loaded = parseManifest(at: path)
        cache.store(loaded, stamp: modified, path: path)
        return loaded
    }

    private static func parseManifest(at path: String) -> Manifest? {
        guard let data = try? Data(contentsOf: URL(filePath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let name = object["name"] as? String
        var binaries: [String: String] = [:]
        if let dictionary = object["bin"] as? [String: String] {
            binaries = dictionary
        }
        // 字符串形式的 bin 没有键名，保留为空表：落到包名。
        guard name != nil || !binaries.isEmpty else { return nil }
        return Manifest(name: name, binaries: binaries)
    }

    private static let cache = ManifestCache()

    /// 按 `package.json` 的 mtime 失效：装了新版本立刻生效。
    final class ManifestCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: (manifest: Manifest?, stamp: Date)] = [:]

        func lookup(path: String, stamp: Date) -> Manifest?? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = storage[path], entry.stamp == stamp else { return nil }
            return .some(entry.manifest)
        }

        func store(_ manifest: Manifest?, stamp: Date, path: String) {
            lock.lock()
            defer { lock.unlock() }
            if storage.count > 256 { storage.removeAll() }
            storage[path] = (manifest, stamp)
        }
    }
}

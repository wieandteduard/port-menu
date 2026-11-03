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

    private static func scriptName(fromPath path: String) -> String {
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

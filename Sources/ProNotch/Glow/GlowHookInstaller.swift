import Foundation

/// 把「完成提醒」接入 / 移出 Claude / Codex / VS Code。三者机制不同：
/// - Claude Code：原生 Stop 钩子（`~/.claude/settings.json`），追加一条 `open pronotch://`。
/// - Codex：完成事件只走 `config.toml` 的 `notify`（单程序）。我们装一个转发脚本——
///   先等待原有的 `notify` 跑完，再 `open pronotch://` 点亮光晕（保留 computer-use
///   等下游不被打断）。原 `notify` 以 base64 存进脚本头部，卸载时据此还原。
/// - VS Code：提供独立的 `vscode-notify.sh` 完成提醒入口；传入命令时会先等待命令退出再提醒，
///   或用 `--done` 在真正完成点显式提醒。裸调用不提醒，避免任务刚启动就误报完成。
///
/// 安全策略：写前备份 `.pronotch.bak`；Claude 只动我们自己追加的那条、Codex 只动 `notify`
/// 一行；全部可还原。
enum GlowHookInstaller {

    // MARK: - 对外接口（按来源分流）

    static func isVSCodeHostAvailable() -> Bool {
        let fm = FileManager.default
        let paths = [
            "/Applications/Visual Studio Code.app",
            NSHomeDirectory() + "/Applications/Visual Studio Code.app",
            "/Applications/Visual Studio Code - Insiders.app",
            NSHomeDirectory() + "/Applications/Visual Studio Code - Insiders.app",
            "/Applications/VSCodium.app",
            NSHomeDirectory() + "/Applications/VSCodium.app",
            "/Applications/Cursor.app",
            NSHomeDirectory() + "/Applications/Cursor.app",
            "/Applications/Windsurf.app",
            NSHomeDirectory() + "/Applications/Windsurf.app",
        ]
        return paths.contains { fm.fileExists(atPath: $0) }
    }

    static func isInstalled(_ source: GlowSource) -> Bool {
        switch source {
        case .claude: return isClaudeInstalled()
        case .codex:  return isCodexInstalled()
        case .vscode: return isVSCodeInstalled()
        }
    }

    @discardableResult
    static func setInstalled(_ source: GlowSource, _ on: Bool) -> Bool {
        switch source {
        case .claude: return setClaudeInstalled(on)
        case .codex:  return setCodexInstalled(on)
        case .vscode: return setVSCodeInstalled(on)
        }
    }

    /// 升级迁移：仅把「已接入」的来源刷新到当前脚本格式，不改变接入与否
    static func migrateIfInstalled(_ source: GlowSource) {
        guard isInstalled(source) else { return }
        setInstalled(source, true)
    }

    /// 清除早期版本（43640d8）写进 ~/.codex/hooks.json 的 pronotch Stop 钩子孤儿。
    /// 现在 Codex 完成提醒走 config.toml 的 notify，这条孤儿会让每次完成多发一个「无 host」
    /// 信号——表现为：终端在前台时光晕仍亮、且只能靠激活 Codex 桌面 App 才能熄灭。
    @discardableResult
    static func cleanCodexHooksOrphan() -> Bool {
        let p = codexHooksPath
        guard let data = FileManager.default.contents(atPath: p),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any],
              var stop = hooks["Stop"] as? [[String: Any]] else { return false }
        let before = stop.count
        stop.removeAll { entry in
            (entry["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("pronotch://done") == true
            } == true
        }
        guard stop.count != before else { return false }   // 无孤儿则不动文件
        backup(p)
        if stop.isEmpty { hooks.removeValue(forKey: "Stop") } else { hooks["Stop"] = stop }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              (try? out.write(to: URL(fileURLWithPath: p))) != nil else { return false }
        return true
    }

    /// hook 脚本格式版本：升级时 +1，启动迁移据此把旧脚本刷新到新格式
    private static let scriptFormat = 8

    /// 沿进程链向上找到「Agent 实际所在的 GUI App」bundle id。优先识别 VS Code / Cursor /
    /// Windsurf 这类编辑器宿主；终端 / IDE / 桌面 App 通用，找不到回空。
    private static let hostDetectSnippet = """
    bundle_id_for_app() {
      /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null
    }

    known_vscode_host() {
      local app bid
      for app in \
        "/Applications/Visual Studio Code.app" \
        "$HOME/Applications/Visual Studio Code.app" \
        "/Applications/Visual Studio Code - Insiders.app" \
        "$HOME/Applications/Visual Studio Code - Insiders.app" \
        "/Applications/VSCodium.app" \
        "$HOME/Applications/VSCodium.app" \
        "/Applications/Cursor.app" \
        "$HOME/Applications/Cursor.app" \
        "/Applications/Windsurf.app" \
        "$HOME/Applications/Windsurf.app"
      do
        [ -d "$app" ] || continue
        bid=$(bundle_id_for_app "$app")
        [ -n "$bid" ] && { printf '%s' "$bid"; return; }
      done
    }

    detect_host() {
      local pid=$PPID ppid path app bid
      for _ in $(seq 1 25); do
        [ "$pid" -le 1 ] && break
        read -r ppid path < <(ps -o ppid=,comm= -p "$pid" 2>/dev/null)
        [ -z "$ppid" ] && break
        case "$path" in
          */Applications/*.app/Contents/*|"$HOME"/Applications/*.app/Contents/*)
            app="${path%%.app/Contents/*}.app"
            bid=$(bundle_id_for_app "$app")
            [ -n "$bid" ] && { printf '%s' "$bid"; return; } ;;
        esac
        pid=$ppid
      done
      # VS Code 集成终端通常会带 TERM_PROGRAM=vscode；某些 shell / pty 链拿不到
      # /Applications/*.app 父进程时，用它兜底到本机安装的编辑器主 App。
      if [ "${TERM_PROGRAM:-}" = "vscode" ] || [ -n "${VSCODE_IPC_HOOK_CLI:-}${VSCODE_GIT_ASKPASS_NODE:-}${VSCODE_CWD:-}" ]; then
        bid=$(known_vscode_host)
        [ -n "$bid" ] && { printf '%s' "$bid"; return; }
      fi
    }
    """

    /// 脚本是否已是当前格式（含 host 探测）：据脚本头的 PRONOTCH_FMT 标记判断
    private static func scriptIsCurrent(_ path: String) -> Bool {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return s.contains("PRONOTCH_FMT=\(scriptFormat)")
    }

    private static func backup(_ path: String) {
        if let cur = FileManager.default.contents(atPath: path) {
            try? cur.write(to: URL(fileURLWithPath: path + ".pronotch.bak"))
        }
    }

    // MARK: - Claude Code（~/.claude/settings.json 的 Stop 钩子）

    private static let claudePath = ("~/.claude/settings.json" as NSString).expandingTildeInPath

    /// Claude 转发脚本：探测宿主 App + open -g 点亮（放应用支持目录，跨重装稳定）
    private static var claudeScript: String {
        NSHomeDirectory() + "/Library/Application Support/ProNotch/claude-notify.sh"
    }
    private static var claudeCommand: String { "\"\(claudeScript)\"" }

    /// 旧版（内联 open pronotch://）或新版（指向脚本）都算「我们的」——卸载/迁移时一并处理
    private static func entryIsOurs(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]])?.contains {
            let c = ($0["command"] as? String) ?? ""
            return c.contains("pronotch://done") || c.contains("claude-notify.sh")
        } == true
    }
    /// 仅新版（command 指向我们的脚本）
    private static func entryIsCurrentClaude(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]])?.contains {
            ($0["command"] as? String)?.contains("claude-notify.sh") == true
        } == true
    }

    /// 生成 Claude 转发脚本（内容幂等）
    @discardableResult
    private static func writeClaudeScript() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (claudeScript as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        let script = """
        #!/bin/bash
        # ProNotch · Claude 完成提醒（自动生成，勿手改）· PRONOTCH_FMT=\(scriptFormat)
        \(hostDetectSnippet)
        host=$(detect_host)
        url="pronotch://done?source=claude"
        [ -n "$host" ] && url="$url&host=$host"
        open -g "$url"
        """
        guard (try? script.write(toFile: claudeScript, atomically: true, encoding: .utf8)) != nil else { return false }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudeScript)
        return true
    }

    private static func isClaudeInstalled() -> Bool {
        guard let data = FileManager.default.contents(atPath: claudePath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let stop = hooks["Stop"] as? [[String: Any]] else { return false }
        return stop.contains(where: entryIsOurs)
    }

    @discardableResult
    private static func setClaudeInstalled(_ on: Bool) -> Bool {
        let p = claudePath
        let fm = FileManager.default
        guard fm.fileExists(atPath: (p as NSString).deletingLastPathComponent) else { return false }

        var root: [String: Any] = [:]
        if let data = fm.contents(atPath: p) {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            root = obj
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var stop = hooks["Stop"] as? [[String: Any]] ?? []
        let oursEntries = stop.filter(entryIsOurs)

        if on {
            // 已是当前格式（脚本最新 + 仅一条指向脚本的 Stop 条目）→ 幂等跳过
            if scriptIsCurrent(claudeScript), oursEntries.count == 1, entryIsCurrentClaude(oursEntries[0]) {
                return true
            }
            guard writeClaudeScript() else { return false }
            stop.removeAll(where: entryIsOurs)   // 清掉旧内联 / 重复条目，再装新版
            stop.append(["hooks": [["type": "command", "command": claudeCommand]]])
        } else {
            if oursEntries.isEmpty { return true }
            stop.removeAll(where: entryIsOurs)
            try? fm.removeItem(atPath: claudeScript)
        }

        backup(p)
        if stop.isEmpty { hooks.removeValue(forKey: "Stop") } else { hooks["Stop"] = stop }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }

        guard let out = try? JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              (try? out.write(to: URL(fileURLWithPath: p))) != nil else { return false }
        return true
    }

    // MARK: - VS Code（独立完成提醒入口）

    private static let vscodeInstalledKey = "glowVSCodeInstalled"

    private static var vscodeScript: String {
        NSHomeDirectory() + "/Library/Application Support/ProNotch/vscode-notify.sh"
    }

    private static func isVSCodeInstalled() -> Bool {
        UserDefaults.standard.bool(forKey: vscodeInstalledKey)
            && FileManager.default.fileExists(atPath: vscodeScript)
    }

    @discardableResult
    private static func setVSCodeInstalled(_ on: Bool) -> Bool {
        let fm = FileManager.default
        if on {
            guard isVSCodeHostAvailable(), writeVSCodeScript() else { return false }
            UserDefaults.standard.set(true, forKey: vscodeInstalledKey)
            return true
        } else {
            try? fm.removeItem(atPath: vscodeScript)
            UserDefaults.standard.set(false, forKey: vscodeInstalledKey)
            return true
        }
    }

    @discardableResult
    private static func writeVSCodeScript() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (vscodeScript as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        let script = """
        #!/bin/bash
        # ProNotch · VS Code 完成提醒（自动生成，勿手改）· PRONOTCH_FMT=\(scriptFormat)
        # 用法：
        #   vscode-notify.sh --done          # 当前调用点即视为已完成
        #   vscode-notify.sh -- npm test     # 先等待命令退出，再提醒，并保留退出码
        #   vscode-notify.sh --shell "npm test"  # 用 shell 执行一整段命令，完成后提醒
        \(hostDetectSnippet)
        status=0
        should_notify=1
        case "${1:-}" in
          --done)
            shift
            if [ "$#" -gt 0 ]; then
              echo "ProNotch: --done does not take a command; use '-- <command>' to wait." >&2
              exit 64
            fi
            ;;
          --shell)
            shift
            if [ "$#" -eq 0 ]; then
              echo "ProNotch: --shell needs a command string." >&2
              exit 64
            fi
            /bin/bash -lc "$*"
            status=$?
            ;;
          --)
            shift
            if [ "$#" -eq 0 ]; then
              echo "ProNotch: no command after --; skip VS Code completion reminder." >&2
              exit 0
            fi
            "$@"
            status=$?
            ;;
          "")
            echo "ProNotch: no command passed; use '-- <command>' to wait, or '--done' at the real completion point." >&2
            should_notify=0
            ;;
          *)
            "$@"
            status=$?
            ;;
        esac
        if [ "$should_notify" != "1" ]; then
          exit "$status"
        fi
        host=$(detect_host)
        url="pronotch://done?source=vscode"
        [ -n "$host" ] && url="$url&host=$host"
        open -g "$url"
        exit "$status"
        """
        guard (try? script.write(toFile: vscodeScript, atomically: true, encoding: .utf8)) != nil else {
            return false
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vscodeScript)
        return true
    }

    // MARK: - Codex（config.toml 的 notify 转发器）

    private static let codexConfig = ("~/.codex/config.toml" as NSString).expandingTildeInPath
    private static let codexHooksPath = ("~/.codex/hooks.json" as NSString).expandingTildeInPath

    /// 转发脚本路径：放应用支持目录，跨重装稳定
    private static var codexScript: String {
        NSHomeDirectory() + "/Library/Application Support/ProNotch/codex-notify.sh"
    }
    /// 脚本文件名，用于在 notify 串里识别「是否引用了我们」——文件名不含斜杠，
    /// 无论路径在 TOML 里是否被转义（computer-use 套壳时会 JSON 转义斜杠）都能匹配。
    private static var codexScriptMarker: String { (codexScript as NSString).lastPathComponent }

    private static func isCodexInstalled() -> Bool {
        guard let toml = try? String(contentsOfFile: codexConfig, encoding: .utf8),
              let arr = notifyArray(in: toml) else { return false }
        // notify 链中引用了我们的转发脚本（直接指向，或被 computer-use 等套在外层），且脚本在 → 已接入。
        // 旧版只认「首元素 = 脚本」，被套壳就误判「未接入」→ 重新勾选时酿成自引用死循环（光晕狂闪）。
        return arr.contains(codexScriptMarker) && FileManager.default.fileExists(atPath: codexScript)
    }

    @discardableResult
    private static func setCodexInstalled(_ on: Bool) -> Bool {
        let fm = FileManager.default
        // 没装 Codex（config.toml 所在目录不存在）就无法接入
        guard fm.fileExists(atPath: (codexConfig as NSString).deletingLastPathComponent) else { return false }
        let toml = (try? String(contentsOfFile: codexConfig, encoding: .utf8)) ?? ""

        let arr = notifyArray(in: toml)
        let directlyOurs = arr?.hasPrefix("[\"\(codexScript)\"") == true   // notify 首元素就是我们的脚本
        let inChain = arr?.contains(codexScriptMarker) == true             // 链中引用了我们（含被外层套壳）

        if on {
            if inChain {
                // 直接指向时，previous 取脚本自己记录的原值。绝不把「含我们自己的当前链」抓来当 previous，
                // 否则调用回自己 → 无限循环（这正是闪烁 bug 的根源）。脚本缺失或格式过期才重写。
                if !directlyOurs {
                    // computer-use 等后装的 notify 可能把 ProNotch 塞进 --previous-notify，
                    // 这会让光晕先亮、外层程序后收尾。迁移成 ProNotch 外层转发后，
                    // 我们可以先等待外层 notify 跑完，再点亮。
                    let migrated = notifyArrayRemovingForwarder(arr)
                    guard migrated.parsed, writeForwarder(previous: migrated.previous) else { return false }
                    backup(codexConfig)
                    let newToml = upsertNotifyLine(toml, value: "[\"\(codexScript)\"]")
                    return (try? newToml.write(toFile: codexConfig, atomically: true, encoding: .utf8)) != nil
                }
                if !fm.fileExists(atPath: codexScript) || !scriptIsCurrent(codexScript) {
                    return writeForwarder(previous: readPreviousFromForwarder())
                }
                return true
            }
            // 全新接入：当前 notify（不含我们）整体作为 previous 透传
            guard writeForwarder(previous: arr) else { return false }
            backup(codexConfig)
            let newToml = upsertNotifyLine(toml, value: "[\"\(codexScript)\"]")
            return (try? newToml.write(toFile: codexConfig, atomically: true, encoding: .utf8)) != nil
        } else {
            if !inChain { return true }
            if directlyOurs {
                // notify 直接是我们：还原原 notify（或删整条）+ 删脚本
                backup(codexConfig)
                let prev = readPreviousFromForwarder()
                let newToml = (prev?.isEmpty == false) ? upsertNotifyLine(toml, value: prev!) : removeNotifyLine(toml)
                let ok = (try? newToml.write(toFile: codexConfig, atomically: true, encoding: .utf8)) != nil
                if ok { try? fm.removeItem(atPath: codexScript) }
                return ok
            }
            // 被外层套壳：notify 归上游（computer-use 等）管，不动它；只删我们的脚本即可
            // （上游转发到缺失脚本无害，不会再点亮光晕）。
            try? fm.removeItem(atPath: codexScript)
            return true
        }
    }

    // MARK: - Codex TOML 辅助（只处理顶层单行 notify，Codex 实际就是单行）

    private static let notifyRegex = #"^\s*notify\s*="#

    /// 顶层 notify 行（行首 `notify =`）
    private static func notifyLine(in toml: String) -> String? {
        toml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .first { $0.range(of: notifyRegex, options: .regularExpression) != nil }
    }

    /// notify 等号右侧的数组串 `[...]`（原样），无则 nil
    private static func notifyArray(in toml: String) -> String? {
        guard let line = notifyLine(in: toml), let eq = line.firstIndex(of: "=") else { return nil }
        let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        return val.isEmpty ? nil : val
    }

    /// 删除顶层 notify 行（恢复「无 notify」原状）
    private static func removeNotifyLine(_ toml: String) -> String {
        toml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { $0.range(of: notifyRegex, options: .regularExpression) == nil }
            .joined(separator: "\n")
    }

    /// 替换或新增顶层 notify 行
    private static func upsertNotifyLine(_ toml: String, value: String) -> String {
        var lines = toml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLine = "notify = \(value)"
        if let i = lines.firstIndex(where: { $0.range(of: notifyRegex, options: .regularExpression) != nil }) {
            lines[i] = newLine
        } else {
            // 插到第一个 [section] 之前（顶层区），没有 section 就插到末尾
            let at = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
            lines.insert(newLine, at: at)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 转发脚本生成 / 解析

    /// 生成转发脚本：等待 previous 跑完 + 点亮光晕；原 notify 以 base64 存进脚本头供还原
    private static func writeForwarder(previous: String?) -> Bool {
        // 根部兜底防自引用死循环：previous 绝不能（间接）引用本脚本，否则 exec 回自己 → 无限循环。
        // 被 computer-use 套壳后原 notify 链里就含我们，这里统一剥掉，任何调用路径都断得了环。
        let previous = (previous?.contains(codexScriptMarker) == true) ? nil : previous
        let fm = FileManager.default
        let dir = (codexScript as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let prevB64 = previous?.data(using: .utf8)?.base64EncodedString() ?? ""
        let forwardBlock = forwardRunBlock(previous: previous)
        let script = """
        #!/bin/bash
        # ProNotch · Codex 完成提醒转发器（自动生成，勿手改）· PRONOTCH_FMT=\(scriptFormat)
        # 还原：把 ~/.codex/config.toml 的 notify 改回下面 base64 的解码值，再删除本文件。
        # PRONOTCH_PREV_B64=\(prevB64)
        \(hostDetectSnippet)
        find_transcript() {
          local thread_id="$1" db path
          case "$thread_id" in
            ""|*[!0-9A-Fa-f-]*) return 1 ;;
          esac

          # Desktop / IDE 会把 thread-id 对应的 rollout 路径记在 state_*.sqlite。
          # 遍历是为了兼容状态库将来升级版本号；找不到时再回退到 sessions 目录。
          for db in "$HOME"/.codex/state_*.sqlite; do
            [ -f "$db" ] || continue
            path=$(/usr/bin/sqlite3 "$db" \
              "SELECT rollout_path FROM threads WHERE id='$thread_id' LIMIT 1;" 2>/dev/null)
            [ -f "$path" ] && { printf '%s' "$path"; return 0; }
          done
          path=$(/usr/bin/find "$HOME/.codex/sessions" -type f \
            -name "*$thread_id*.jsonl" -print -quit 2>/dev/null)
          [ -f "$path" ] && { printf '%s' "$path"; return 0; }
          return 1
        }

        is_final_codex_answer() {
          local thread_id transcript last_line attempt
          thread_id=$(printf '%s' "$payload" | \
            /usr/bin/plutil -extract thread-id raw -o - -- - 2>/dev/null)
          transcript=$(find_transcript "$thread_id") || return 1

          # notify 偶尔会比最后一行落盘略早，短暂重试后再判定。
          # Codex Desktop/IDE 将过程更新标成 commentary，真正交付标成
          # final_answer；只允许后者点亮，避免仍在思考或自动续跑时误报。
          for attempt in 1 2 3 4 5; do
            last_line=$(/usr/bin/grep -E \
              '"type":"response_item".*"type":"message".*"role":"assistant"' \
              "$transcript" 2>/dev/null | /usr/bin/tail -n 1)
            case "$last_line" in
              *'"phase":"final_answer"'*|*'"phase":"final"'*) return 0 ;;
            esac
            /bin/sleep 0.12
          done
          return 1
        }

        any_codex_turn_running() {
          local db transcript last_task
          for db in "$HOME"/.codex/state_*.sqlite; do
            [ -f "$db" ] || continue
            while IFS= read -r transcript; do
              [ -f "$transcript" ] || continue
              # rollout 是 JSONL；从文件末尾反查最近一次任务边界，避免扫描整份长会话。
              last_task=$(/usr/bin/tail -r "$transcript" 2>/dev/null | \
                /usr/bin/grep -m 1 -E \
                '"type":"event_msg".*"type":"task_(started|complete)"')
              case "$last_task" in
                *'"type":"task_started"'*) return 0 ;;
              esac
            done < <(/usr/bin/sqlite3 "$db" \
              "SELECT rollout_path FROM threads
               WHERE updated_at_ms >= (strftime('%s','now') - 86400) * 1000;" \
              2>/dev/null)
          done
          return 1
        }

        all_codex_turns_finished() {
          local attempt
          # 给当前 turn 的 task_complete 事件一点落盘时间；若另一个任务确实还在跑，
          # 本次完成信号保持静默，最后结束的那个任务会再次触发 notify。
          for attempt in 1 2 3 4 5; do
            any_codex_turn_running || return 0
            /bin/sleep 0.12
          done
          return 1
        }

        payload="$1"
        should_notify=0
        case "$payload" in
          *agent-turn-complete*)
            # 跳过 Codex Desktop 自动生成会话标题的内部任务——它在你刚发消息时就完成，会让光晕「一开始就亮」
            case "$payload" in
              *"Generate a concise UI title"*) : ;;
              *) should_notify=1 ;;
            esac ;;
        esac
        \(forwardBlock)
        if [ "$should_notify" = "1" ] && \
           is_final_codex_answer && all_codex_turns_finished; then
          host=$(detect_host)
          url="pronotch://done?source=codex"
          [ -n "$host" ] && url="$url&host=$host"
          open -g "$url"
        fi
        """
        guard (try? script.write(toFile: codexScript, atomically: true, encoding: .utf8)) != nil else { return false }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexScript)
        return true
    }

    /// 透传块：把原 notify 数组解析成 bash 参数并等待返回；无 previous 则空操作
    private static func forwardRunBlock(previous: String?) -> String {
        guard let previous, let elems = parseTomlStringArray(previous), !elems.isEmpty else {
            return "# 原本无 notify，到此结束"
        }
        let quoted = elems.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        return "\(quoted) \"$payload\" || true"
    }

    /// 从当前 notify 链中去掉 ProNotch 自己，得到可安全保存为 previous 的原链。
    private static func notifyArrayRemovingForwarder(_ notify: String?) -> (previous: String?, parsed: Bool) {
        guard let notify, let elems = parseTomlStringArray(notify), !elems.isEmpty else {
            return (nil, false)
        }
        var cleaned: [String] = []
        var i = 0
        while i < elems.count {
            if i + 1 < elems.count,
               elems[i] == "--previous-notify",
               elems[i + 1].contains(codexScriptMarker) {
                i += 2
                continue
            }
            if elems[i].contains(codexScriptMarker) {
                i += 1
                continue
            }
            cleaned.append(elems[i])
            i += 1
        }
        return (cleaned.isEmpty ? nil : tomlStringArray(cleaned), true)
    }

    /// 从脚本头 `# PRONOTCH_PREV_B64=` 取回原 notify 数组串
    private static func readPreviousFromForwarder() -> String? {
        guard let script = try? String(contentsOfFile: codexScript, encoding: .utf8) else { return nil }
        for line in script.split(separator: "\n") {
            if let r = line.range(of: "# PRONOTCH_PREV_B64=") {
                let b64 = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if b64.isEmpty { return nil }
                return Data(base64Encoded: b64).flatMap { String(data: $0, encoding: .utf8) }
            }
        }
        return nil
    }

    /// 解析 TOML 字符串数组 `["a","b",...]` → [String]（处理 \" \\ \/ \n \t 常见转义）
    private static func parseTomlStringArray(_ s: String) -> [String]? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), t.hasSuffix("]") else { return nil }
        let inner = Array(t.dropFirst().dropLast())
        var result: [String] = []
        var i = 0
        while i < inner.count {
            while i < inner.count, inner[i] != "\"" { i += 1 }   // 找开引号
            guard i < inner.count else { break }
            i += 1
            var elem = ""
            while i < inner.count, inner[i] != "\"" {
                if inner[i] == "\\", i + 1 < inner.count {
                    switch inner[i + 1] {
                    case "\"": elem.append("\"")
                    case "\\": elem.append("\\")
                    case "/":  elem.append("/")
                    case "n":  elem.append("\n")
                    case "t":  elem.append("\t")
                    default:   elem.append(inner[i + 1])
                    }
                    i += 2
                } else {
                    elem.append(inner[i]); i += 1
                }
            }
            i += 1   // 跳过闭引号
            result.append(elem)
        }
        return result
    }

    private static func tomlStringArray(_ elems: [String]) -> String {
        let quoted = elems.map { elem in
            let escaped = elem
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\t", with: "\\t")
            return "\"\(escaped)\""
        }
        return "[\(quoted.joined(separator: ", "))]"
    }
}

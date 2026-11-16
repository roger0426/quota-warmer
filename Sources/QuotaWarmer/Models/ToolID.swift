import Foundation

enum ToolID: String, CaseIterable, Identifiable, Codable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex:  return "Codex CLI"
        }
    }

    /// Short, brand-only name for in-app screen labels.
    var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        }
    }

    var icon: String {
        switch self {
        case .claude: return "bolt.circle.fill"
        case .codex:  return "terminal.fill"
        }
    }

    /// Template image asset for the provider glyph.
    var glyphAssetName: String {
        switch self {
        case .claude: return "ClaudeCode"
        case .codex:  return "Codex"
        }
    }

    var accentColor: String {
        switch self {
        case .claude: return "orange"
        case .codex:  return "purple"
        }
    }

    /// Claude: `haiku` is the CLI alias for the cheapest current model (Claude
    /// Haiku 4.5, $1/$5 per MTok as of 2026-09-30) and follows future Haiku
    /// releases. Measured 2026-09-30 on CLI 2.1.285: without isolation the
    /// default system prompt (user CLAUDE.md, MCP tool schemas, skills, plugins)
    /// made a single `hi` write ~51K cache tokens plus ~190 thinking tokens;
    /// `--safe-mode`/`--strict-mcp-config`, a one-line system prompt, disabled
    /// thinking and `--effort low` bring it to ~400 input / 5 output tokens.
    /// All of these flags are per-run only — nothing is written to settings.
    ///
    /// The models actually used come from the tool's model catalog
    /// (`ModelCatalogStore.warmupModels`); these are the built-in defaults.
    var warmupCommand: String { warmupCommand(model: defaultWarmupModel) }

    /// Run only when the primary command is rejected for an unknown option or
    /// feature flag (a CLI without the isolation flags). Still pinned to a cheap
    /// model, so the fallback can never land on the user's default (e.g. Opus).
    var fallbackWarmupCommand: String? { legacyWarmupCommand(model: defaultWarmupModel) }

    /// Claude: the CLI alias for the cheapest tier. Codex: measured cheapest
    /// per warm-up on a ChatGPT account (2026-09-30: ~15K prompt tokens vs
    /// ~35K for gpt-6-luna, which is cheaper per token).
    var defaultWarmupModel: String {
        switch self {
        case .claude: return "haiku"
        case .codex:  return "gpt-5.6-luna"
        }
    }

    /// Codex features switched off for a warm-up. `hooks` matters most:
    /// `--ignore-user-config` skips `config.toml` but not `~/.codex/hooks.json`,
    /// so without it the user's global hooks run on every warm-up. The rest only
    /// add tool descriptions a one-word reply never uses. Measured 2026-11-14 on
    /// codex-cli 0.166.0 (gpt-5.6-luna, one `hi`): 15,202 input tokens with the
    /// plain command, 12,657 with these off, 9,110 with a one-line
    /// `model_instructions_file` as well. An unknown name makes the CLI exit
    /// before any request ("Unknown feature flag"), which
    /// `legacyWarmupCommand` covers.
    static let codexWarmupDisabledFeatures = [
        "hooks", "apps", "browser_use", "browser_use_external", "browser_use_full_cdp_access",
        "computer_use", "image_generation", "plugins", "remote_plugin", "plugin_discovery_prefetch",
        "multi_agent", "goals", "sleep_tool", "view_image", "skill_search", "tool_suggest",
        "in_app_browser", "worktrees", "skill_mcp_dependency_install", "shell_tool", "unified_exec"
    ]

    /// `model` must pass `ModelCatalog.isSafeWarmupModel`: it is interpolated
    /// into a `zsh -lc` command line. `instructionsFile` (Codex only) is an
    /// absolute path to a short file that replaces Codex's built-in system
    /// prompt; a path with a quote or backslash is ignored.
    func warmupCommand(model: String, instructionsFile: String? = nil) -> String {
        switch self {
        case .claude:
            return "claude --model \(model) --effort low --settings '{\"alwaysThinkingEnabled\":false}' --safe-mode --strict-mcp-config --system-prompt 'Reply with one word.' --no-session-persistence --max-turns 1 --tools '' --output-format json -p 'hi'"
        case .codex:
            var instructions = ""
            if let path = instructionsFile, path.hasPrefix("/"),
               !path.contains("'"), !path.contains("\""), !path.contains("\\") {
                instructions = " -c 'model_instructions_file=\"\(path)\"'"
            }
            let disabled = Self.codexWarmupDisabledFeatures.map { " --disable \($0)" }.joined()
            return "codex exec --model \(model) -c model_reasoning_effort=\"low\"\(instructions) --skip-git-repo-check --ephemeral --ignore-user-config --ignore-rules\(disabled) 'hi'"
        }
    }

    /// Makes the Claude CLI refresh its expired access token without a model
    /// call: non-interactive `/usage` is a local command. The invalid model is
    /// the guard: a CLI that doesn't know `/usage` sends it as a prompt, and the
    /// API rejects the model before any quota is spent or a window opens.
    /// `--safe-mode` keeps the user's hooks, plugins and CLAUDE.md out of this
    /// background run (checked 2026-11-15 on CLI 2.1.322: `/usage` still works).
    static let claudeTokenRefreshModel = "quotawarmer-no-model"
    static let claudeTokenRefreshCommand =
        "claude --model \(claudeTokenRefreshModel) --safe-mode --strict-mcp-config --no-session-persistence --max-turns 1 --tools '' -p '/usage'"

    func legacyWarmupCommand(model: String) -> String? {
        switch self {
        // None in this fork: a run without `--safe-mode` loads the user's
        // CLAUDE.md, hooks, plugins and MCP tool schemas (~51K tokens for one
        // `hi`), so a CLI that rejects the flag fails visibly instead.
        case .claude: return nil
        // Same pinned model, without the feature switches: for a Codex CLI
        // that no longer knows one of `codexWarmupDisabledFeatures`.
        case .codex:  return "codex exec --model \(model) -c model_reasoning_effort=\"low\" --skip-git-repo-check --ephemeral --ignore-user-config --ignore-rules 'hi'"
        }
    }

    var logDirectoryURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude:
            return home.appendingPathComponent(".claude/projects")
        case .codex:
            return home.appendingPathComponent(".codex/sessions")
        }
    }

    /// A warm-up that used more tokens than this means the isolation flags no
    /// longer keep context out. Measured 2026-11-15: Claude ~930 (CLI 2.1.322),
    /// Codex ~9,100, or ~15,200 on the fallback command (codex-cli 0.166.0).
    var warmupTokenAlertThreshold: Int {
        switch self {
        case .claude: return 5_000
        case .codex:  return 20_000
        }
    }

    /// Rolling quota window duration. Claude Code is always 5 h server-side;
    /// the setting lets the user adjust if Anthropic ever changes this.
    var windowDuration: TimeInterval {
        AppSettings.shared.windowDuration
    }

    /// Weekly quota window length (7 days). Used by the in-app pace marker to
    /// show how much of the weekly window's *time* remains versus quota.
    var weeklyWindowDuration: TimeInterval { 7 * 24 * 3600 }
}

/// How QuotaWarmer treats a tool. Monitoring (read-only visibility) is the
/// safe default; automatic warm-up is an explicit opt-in on top of it.
///
/// - `.off`      — not watched at all.
/// - `.monitor`  — polls quota and shows status/alerts, but never sends anything.
/// - `.autoWarm` — monitors *and* auto-claims a fresh window.
enum ToolMode: String, CaseIterable, Codable {
    case off
    case monitor
    case autoWarm

    /// Short label for compact controls.
    var label: String {
        switch self {
        case .off:      return String(localized: "Off")
        case .monitor:  return String(localized: "Monitor")
        case .autoWarm: return String(localized: "Auto-warm")
        }
    }

    /// Descriptive label for the dropdown menu items.
    var menuLabel: String {
        switch self {
        case .off:      return String(localized: "Off — don't watch")
        case .monitor:  return String(localized: "Monitor only — watch quota")
        case .autoWarm: return String(localized: "Auto-warm — claim windows")
        }
    }

    /// Next mode when cycling the control: Off → Monitor → Auto-warm → Off.
    var next: ToolMode {
        switch self {
        case .off:      return .monitor
        case .monitor:  return .autoWarm
        case .autoWarm: return .off
        }
    }
}

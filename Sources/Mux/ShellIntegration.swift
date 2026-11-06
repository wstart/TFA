import Foundation

/// Streaming byte-level parser for shell-integration OSC sequences in raw pane output:
/// `ESC ] <code> ; <payload> (BEL | ESC \)`.
///
/// Recognized codes (emitted by `~/.tfa/shell-integration.sh`):
///   `133;A`        — shell is showing a prompt (idle)           (FinalTerm / iTerm2 convention)
///   `133;C`        — a command starts executing (busy)
///   `133;D;<exit>` — the command finished with that exit code
///   `7770;<text>`  — TFA-private: the command line about to run (zsh preexec passes it)
///
/// A per-byte state machine, so sequences split across `%output` chunks parse correctly with no
/// lookback buffer. Any other OSC code is consumed to its terminator and ignored — matching the
/// introducer generically also means a title sequence can never alias into our marks.
struct ShellIntegrationScanner {
    enum Event: Equatable {
        case prompt                // 133;A — at prompt
        case commandStart          // 133;C — command began
        case commandEnd(Int?)      // 133;D — command finished (exit code when parseable)
        case commandText(String)   // 7770  — the command line (trimmed, capped)
    }

    private enum State { case idle, esc, code, payload }
    private var state: State = .idle
    private var code = 0
    private var codeDigits = 0
    private var payload: [UInt8] = []
    private var sawESC = false // inside payload: saw ESC (possible ST `ESC \`)

    /// Payload cap — command lines are capped shell-side too; this is the hard parser bound.
    private static let maxPayload = 256

    mutating func scan(_ data: Data) -> [Event] {
        var out: [Event] = []
        for b in data {
            switch state {
            case .idle:
                if b == 0x1B { state = .esc }
            case .esc:
                if b == 0x5D { state = .code; code = 0; codeDigits = 0 }        // ESC ]
                else { state = (b == 0x1B) ? .esc : .idle }
            case .code:
                if b >= 0x30, b <= 0x39, codeDigits < 6 {
                    code = code * 10 + Int(b - 0x30); codeDigits += 1
                } else if b == 0x3B, codeDigits > 0 {                            // `;` → payload
                    state = .payload; payload = []; sawESC = false
                } else {
                    state = (b == 0x1B) ? .esc : .idle                            // not `code;` — bail
                }
            case .payload:
                if sawESC {
                    if b == 0x5C, let e = Self.event(code, payload) { out.append(e) } // ESC \ = ST
                    reset(); if b == 0x1B { state = .esc }
                    continue
                }
                if b == 0x07 {                                                   // BEL terminator
                    if let e = Self.event(code, payload) { out.append(e) }
                    reset()
                    continue
                }
                if b == 0x1B { sawESC = true; continue }
                if payload.count < Self.maxPayload { payload.append(b) }         // cap; still scans on
            }
        }
        return out
    }

    private mutating func reset() {
        state = .idle; payload = []; sawESC = false; code = 0; codeDigits = 0
    }

    private static func event(_ code: Int, _ payload: [UInt8]) -> Event? {
        switch code {
        case 133:
            let s = String(decoding: payload, as: UTF8.self)
            let segs = s.split(separator: ";", omittingEmptySubsequences: false)
            switch segs.first.map(String.init) {
            case "A": return .prompt
            case "C": return .commandStart
            case "D": return .commandEnd(segs.count > 1 ? Int(segs[1]) : nil)
            default:  return nil // B (prompt end) and unknown marks are irrelevant to TFA
            }
        case 7770:
            let text = String(decoding: payload, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .commandText(text)
        default:
            return nil // some other OSC (title, hyperlink, …) — consumed, ignored
        }
    }
}

/// A shell's integration-reported phase. `.unknown` = the shell has no integration installed (or
/// hasn't emitted a mark yet) — consumers must fall back to the activity heuristic.
enum ShellPhase: Equatable {
    case unknown
    case atPrompt
    case running(since: Date)
}

/// The OSC 133 shell-integration snippet (zsh + bash) TFA reads its precise busy/idle signal and
/// exit codes from. Emits `C` when a command starts, `D;<exit>` when it finishes, `A` at each prompt,
/// and the TFA-private `7770` command text. Written to `~/.tfa/shell-integration.sh` at launch;
/// SOURCING it from ~/.zshrc stays opt-in (设置 → 安装 Shell 集成).
enum ShellIntegrationScript {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".tfa/shell-integration.sh")

    /// Write the script if missing or different; returns whether a write happened.
    @discardableResult
    static func install(to url: URL = defaultURL) -> Bool {
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == script { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    static let script = #"""
# TFA shell integration — OSC 133 marks (FinalTerm convention) so TFA knows precisely when this
# shell is at a prompt, when a command starts, and each command's exit code.
# Generated by TFA; safe to source multiple times; harmless outside TFA (iTerm2 etc. understand it).
[ -n "$__TFA_SHELL_INTEGRATION" ] && return
__TFA_SHELL_INTEGRATION=1

if [ -n "$ZSH_VERSION" ]; then
  # 7770 is TFA-private: the command line about to run (capped, newlines flattened) — TFA's
  # per-terminal「过程记录」pairs it with the next D mark. Other terminals ignore unknown OSCs.
  __tfa_preexec() { local __c="${1[1,160]}"; __c="${__c//$'\n'/ }"; printf '\033]133;C\007\033]7770;%s\007' "$__c"; }
  __tfa_precmd()  { local __ec=$?; printf '\033]133;D;%s\007\033]133;A\007' "$__ec"; }
  autoload -Uz add-zsh-hook
  add-zsh-hook preexec __tfa_preexec
  add-zsh-hook precmd  __tfa_precmd
elif [ -n "$BASH_VERSION" ]; then
  # bash has no reliable preexec without a DEBUG-trap dance — prompt marks (D + A) alone still give
  # TFA the at-prompt signal and exit codes; "running" falls back to the activity heuristic.
  __tfa_prompt() { local __ec=$?; printf '\033]133;D;%s\007\033]133;A\007' "$__ec"; }
  case ";$PROMPT_COMMAND;" in
    *";__tfa_prompt;"*) ;;
    *) PROMPT_COMMAND="__tfa_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
  esac
fi
"""#
}

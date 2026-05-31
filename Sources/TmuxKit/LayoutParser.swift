import Foundation

/// Geometry of one pane within a window, in character cells.
public struct PaneGeometry: Equatable, Sendable {
    public let id: TmuxPaneID
    public let left: Int
    public let top: Int
    public let width: Int
    public let height: Int
}

/// Parses tmux `window_layout` strings into per-pane rectangles.
///
/// Grammar (docs/tmux-control-protocol.md §8):
///   layout = CSUM "," cell
///   cell   = WxH,X,Y [ ",paneid" | "{" cell ("," cell)* "}" | "[" cell ("," cell)* "]" ]
/// `{}` splits left→right, `[]` splits top→bottom. Leaf cells end in the pane id integer.
public enum LayoutParser {
    public static func parse(_ layout: String) -> [PaneGeometry] {
        // Drop the 4-hex-digit checksum + comma.
        guard let comma = layout.firstIndex(of: ",") else { return [] }
        let body = Array(layout[layout.index(after: comma)...])
        var i = 0
        var out: [PaneGeometry] = []
        parseCell(body, &i, &out)
        return out
    }

    private static func parseCell(_ c: [Character], _ i: inout Int, _ out: inout [PaneGeometry]) {
        let w = readInt(c, &i)
        skip(c, &i, "x")
        let h = readInt(c, &i)
        skip(c, &i, ",")
        let x = readInt(c, &i)
        skip(c, &i, ",")
        let y = readInt(c, &i)

        guard i < c.count else { return }
        if c[i] == "{" || c[i] == "[" {
            let close: Character = c[i] == "{" ? "}" : "]"
            i += 1 // consume opener
            while true {
                parseCell(c, &i, &out)
                if i < c.count, c[i] == "," { i += 1; continue }
                break
            }
            if i < c.count, c[i] == close { i += 1 } // consume closer
        } else if c[i] == "," {
            i += 1 // consume comma before pane id
            let pid = readInt(c, &i)
            out.append(PaneGeometry(id: "%\(pid)", left: x, top: y, width: w, height: h))
        }
    }

    private static func readInt(_ c: [Character], _ i: inout Int) -> Int {
        var n = 0
        var any = false
        while i < c.count, let d = c[i].wholeNumberValue, c[i].isNumber {
            n = n * 10 + d
            i += 1
            any = true
        }
        return any ? n : 0
    }

    private static func skip(_ c: [Character], _ i: inout Int, _ ch: Character) {
        if i < c.count, c[i] == ch { i += 1 }
    }
}

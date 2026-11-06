import SwiftUI
import SuperagentCore

// 工单阶段的视觉语言：沿用 DESIGN.md §6 的状态色——等人 = 琥珀（失败 / 送达失败 = 砖红），
// 工作中 = 墨色，排队 / 空闲 / 已结束 = 石灰；颜色只表达「需要你看」。

extension Stage {
    var tint: Color {
        switch self {
        case .person(.failed), .person(.delivery): return Theme.Status.error
        case .person: return Theme.Status.attention
        case .working(let queued): return queued ? Theme.Status.neutral : Theme.Status.active
        case .idle: return Theme.Status.neutral
        case .ended(.done): return Theme.Status.positive
        case .ended: return Theme.Status.neutral
        }
    }

    var symbol: String {
        switch self {
        case .person(.answer): return "questionmark.bubble"
        case .person(.review): return "checkmark.seal"
        case .person(.blocked): return "hand.raised"
        case .person(.failed): return "xmark.octagon"
        case .person(.delivery): return "exclamationmark.triangle"
        case .person(.stalled): return "pause.circle"
        case .working(let queued): return queued ? "clock" : "hammer"
        case .idle: return "moon.zzz"
        case .ended(.done): return "checkmark.circle"
        case .ended: return "minus.circle"
        }
    }
}

/// 人对一个工单要写的话：打回意见 / 回答问题 / 补充。
enum TicketFeedbackKind: String, Identifiable {
    case reject, answer, add
    var id: String { rawValue }

    var title: String {
        switch self {
        case .reject: return "打回"
        case .answer: return "回答"
        case .add: return "补充"
        }
    }

    /// 这个阶段默认该写哪种话。
    static func `default`(for stage: Stage) -> TicketFeedbackKind {
        switch stage {
        case .person(.review): return .reject
        case .person(.answer): return .answer
        default: return .add
        }
    }
}

/// 待人写的跟进（工单 + 哪种），驱动 `TicketFeedbackSheet`。
struct TicketFeedbackRequest: Identifiable, Equatable {
    let ticketID: Int64
    let kind: TicketFeedbackKind
    var id: String { "\(ticketID)-\(kind.rawValue)" }
}

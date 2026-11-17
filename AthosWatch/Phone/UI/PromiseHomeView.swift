import AVFoundation
import SwiftUI

/// 首页：我答应了什么。
///
/// 排序原则不是「最近的放前面」，而是「我最容易搞砸的放前面」：
/// 待确认的（还没进待办）→ 接下来要交的（按截止时间）→ 已完成。
struct PromiseHomeView: View {

    @EnvironmentObject private var store: PromiseStore
    @State private var audioMessage: String?
    @State private var player: AVAudioPlayer?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    WeekSummaryBar(review: store.review)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                }

                if !store.pending.isEmpty {
                    Section {
                        ForEach(store.pending) { commitment in
                            PromiseRow(commitment: commitment)
                        }
                    } header: {
                        SectionHeader(
                            title: "待你确认",
                            detail: "没点头之前不会变成待办"
                        )
                    }
                }

                Section {
                    if store.mine.isEmpty {
                        EmptyHint(
                            text: "还没有确认过的承诺。\n对方说的、你含糊答应的，都会先落在上面那一组。"
                        )
                    } else {
                        ForEach(store.mine) { commitment in
                            PromiseRow(commitment: commitment)
                        }
                    }
                } header: {
                    SectionHeader(title: "接下来", detail: "按截止时间排")
                }

                if !store.finished.isEmpty {
                    Section {
                        ForEach(store.finished) { commitment in
                            PromiseRow(commitment: commitment)
                        }
                    } header: {
                        SectionHeader(title: "已经结束", detail: nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.page)
            .navigationTitle("我答应了什么")
            .navigationBarTitleDisplayMode(.large)
            .alert("这段原话没有音频", isPresented: Binding(
                get: { audioMessage != nil },
                set: { if !$0 { audioMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { audioMessage = nil }
            } message: {
                Text(audioMessage ?? "")
            }
        }
    }
}

// MARK: - 本周概览

struct WeekSummaryBar: View {
    let review: WeeklyReview

    var body: some View {
        HStack(spacing: 0) {
            metric("本周承诺", "\(review.metrics.created)", Theme.accent)
            divider
            metric("没定时间", "\(review.metrics.createdWithoutDue)", Theme.pending)
            divider
            metric("后来改期", "\(review.metrics.rescheduledFromNoDue)", Theme.rescheduled)
        }
        .padding(.vertical, 14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(width: 1, height: 26)
    }

    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 单条承诺

struct PromiseRow: View {
    let commitment: Commitment

    @EnvironmentObject private var store: PromiseStore
    @State private var showAudioHint = false

    private var isExpanded: Bool { store.expandedIDs.contains(commitment.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            metaRow
            if isExpanded {
                timeline
            }
            if commitment.status == .needsConfirmation {
                actions
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { store.toggleExpanded(commitment.id) }
        .alert("这段原话没有音频文件", isPresented: $showAudioHint) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("演示数据只有文本。真机上这段会播放手表当时录下的那句话，并高亮它前后的上下文。")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(store.title(for: commitment))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(commitment.status == .done ? .secondary : .primary)
                .strikethrough(commitment.status == .done)
                .lineLimit(isExpanded ? 4 : 2)

            Spacer(minLength: 4)

            if commitment.wasRescheduled {
                Badge(text: "改期 \(commitment.rescheduleCount)", color: Theme.rescheduled)
            }
            if !commitment.promisor.isMe {
                Badge(text: "对方提的", color: Theme.done)
            }
            if let state = store.reminderState[commitment.id] {
                Badge(text: state, color: state.contains("已写入") ? .green : .red)
            }
        }
    }

    private var metaRow: some View {
        HStack(spacing: 10) {
            if let due = commitment.due {
                Label {
                    Text(DueText.relative(due))
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(due < Date() && commitment.status == .active ? Color.red : Color.secondary)
            } else {
                Label("没定时间", systemImage: "questionmark.circle")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.pending)
            }

            if let promisee = commitment.promisee {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("给 \(promisee)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack(spacing: 3) {
                ForEach(0..<min(commitment.revisions.count, 4), id: \.self) { _ in
                    Circle().fill(Theme.accent.opacity(0.35)).frame(width: 4, height: 4)
                }
                Text("\(commitment.revisions.count) 句原话")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(store.utterances(for: commitment).enumerated()), id: \.element.id) { index, utterance in
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(index == 0 ? Theme.accent : Theme.rescheduled)
                            .frame(width: 7, height: 7)
                            .padding(.top, 5)
                        if index < store.utterances(for: commitment).count - 1 {
                            Rectangle()
                                .fill(Color(.separator))
                                .frame(width: 1)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    .frame(width: 7)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(DueText.stamp(utterance.recordedAt))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(utterance.speaker.displayName)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 0)
                            Button {
                                showAudioHint = true
                            } label: {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 17))
                                    .foregroundStyle(Theme.accent.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                        }
                        Text("「\(utterance.text)」")
                            .font(.footnote)
                            .foregroundStyle(.primary)
                    }
                    .padding(.bottom, 10)
                }
            }

            if let last = commitment.revisions.max(by: { $0.at < $1.at }),
               case .dueChanged(let from, let to) = last.change {
                Text("日期从 \(from.map(DueText.absolute) ?? "未定") 改成 \(to.map(DueText.absolute) ?? "未定")，仍是同一条。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 15)
            }
        }
        .padding(.top, 4)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                store.confirm(commitment)
            } label: {
                Label("确认", systemImage: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)

            Button {
                store.dismiss(commitment)
            } label: {
                Text("不是承诺")
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
        }
        .padding(.top, 2)
    }
}

// MARK: - 小组件

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}

struct SectionHeader: View {
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .textCase(nil)
    }
}

struct EmptyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.vertical, 10)
    }
}

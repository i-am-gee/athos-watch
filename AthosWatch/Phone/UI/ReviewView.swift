import SwiftUI

/// 周复盘。目标不是好看，是让人看见一个能改的习惯。
///
/// 每个数字都必须能回到原话——所以底部永远挂着「这周的原话」，
/// 点一条就能看到当时是怎么说的。
struct ReviewView: View {

    @EnvironmentObject private var store: PromiseStore

    private var review: WeeklyReview { store.review }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headlineCard
                    metricGrid
                    if let advice = review.advice {
                        adviceCard(advice)
                    }
                    transcriptSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.page)
            .navigationTitle("本周复盘")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var headlineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(weekRange)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Text(review.headline)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var weekRange: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        let end = review.weekEnd.addingTimeInterval(-1)
        return "\(formatter.string(from: review.weekStart)) — \(formatter.string(from: end))"
    }

    private var metricGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            MetricTile(
                title: "答应时没定时间",
                value: "\(review.metrics.createdWithoutDue)",
                caption: review.metrics.created == 0 ? "本周没有承诺" : "占本周 \(Int(review.metrics.noDueRate * 100))%",
                color: Theme.pending
            )
            MetricTile(
                title: "后来改期",
                value: "\(review.metrics.rescheduledFromNoDue)",
                caption: review.metrics.createdWithoutDue == 0
                    ? "没有可比数据"
                    : "没定时间的 \(review.metrics.createdWithoutDue) 条里，\(Int(review.metrics.churnAfterNoDue * 100))% 改过",
                color: Theme.rescheduled
            )
            MetricTile(
                title: "还等你确认",
                value: "\(review.metrics.awaitingConfirmation)",
                caption: "没点头就不进待办",
                color: Theme.accent
            )
            MetricTile(
                title: "对方在等你回应",
                value: "\(review.metrics.awaitingMyReply)",
                caption: "这些不是你答应的",
                color: Theme.done
            )
        }
    }

    private func adviceCard(_ advice: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.pending)
                .padding(.top, 2)
            Text(advice)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.pending.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "这周的原话", detail: "每个数字都能点回来说过的某一句")

            let lines = store.ledger.utterances
                .filter { $0.recordedAt >= review.weekStart && $0.recordedAt < review.weekEnd }
                .sorted { $0.recordedAt > $1.recordedAt }

            if lines.isEmpty {
                EmptyHint(text: "这一周还没有录音。")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, utterance in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(DueText.stamp(utterance.recordedAt))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                Text("「\(utterance.text)」")
                                    .font(.footnote)
                                    .foregroundStyle(.primary)
                            }
                            Spacer(minLength: 0)
                            Text(utterance.speaker.displayName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 9)

                        if index < lines.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 14)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let caption: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

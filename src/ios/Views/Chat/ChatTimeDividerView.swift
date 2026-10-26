import SwiftUI

/// [10-20 醒醒] 时间胶囊。微信那样：居中一小颗，说明这一段跟上一段隔了多久。
///
/// 文案由 `CollectionViewMessageListV3.timeDividerText` 现算——每次 cell 配置
/// 都重算，所以滚回去看的时候「3 分钟前」会自动变成「2 小时前」，不需要
/// 起定时器。
struct ChatTimeDividerView: View {
    let date: Date

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Text(CollectionViewMessageListV3.timeDividerText(for: date))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(MinisTheme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(MinisTheme.mutedSurface.opacity(0.75))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(MinisTheme.border.opacity(0.35), lineWidth: 0.5)
                )
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(CollectionViewMessageListV3.timeDividerText(for: date)))
    }
}

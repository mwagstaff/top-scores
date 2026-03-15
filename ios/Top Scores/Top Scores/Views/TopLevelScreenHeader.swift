import SwiftUI

struct TopLevelScreenHeader<Icon: View, Accessory: View, Detail: View>: View {
    let screenTitle: String
    private let icon: () -> Icon
    private let accessory: () -> Accessory
    private let detail: () -> Detail

    init(
        screenTitle: String,
        @ViewBuilder icon: @escaping () -> Icon,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
        @ViewBuilder detail: @escaping () -> Detail = { EmptyView() }
    ) {
        self.screenTitle = screenTitle
        self.icon = icon
        self.accessory = accessory
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))

                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)

                    icon()
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 30, height: 30)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Top Scores")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text(screenTitle)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                accessory()
            }

            detail()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }
}

import SwiftUI

struct ResponsePlaceholder: View {
    let icon: AppIcon
    let title: String
    var hint: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(icon: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(BrandColor.icon)
                .frame(width: 42, height: 42)
                .background(BrandColor.icon.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                if let hint {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 320)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

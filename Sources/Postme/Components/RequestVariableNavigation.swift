import SwiftUI

struct RequestVariableNavigation: Equatable {
    let variable: MissingRequestVariable
    let id = UUID()
}

private struct RequestVariableNavigationKey: EnvironmentKey {
    static let defaultValue: RequestVariableNavigation? = nil
}

extension EnvironmentValues {
    var requestVariableNavigation: RequestVariableNavigation? {
        get { self[RequestVariableNavigationKey.self] }
        set { self[RequestVariableNavigationKey.self] = newValue }
    }
}

extension View {
    func requestVariableField(_ field: RequestVariableField?) -> some View {
        modifier(RequestVariableFieldHighlight(field: field))
    }
}

private struct RequestVariableFieldHighlight: ViewModifier {
    @Environment(\.requestVariableNavigation) private var navigation
    let field: RequestVariableField?

    func body(content: Content) -> some View {
        let highlighted = field != nil && navigation?.variable.field == field
        content.overlay {
            if highlighted {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(BrandColor.icon, lineWidth: 1.5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

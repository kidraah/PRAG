import SwiftUI

/// Frames of named controls in the shelf's coordinate space, collected only in demo mode.
struct DemoAnchorKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Tags a control so the demo director can drive its cursor to it. No-op outside demo mode.
    @ViewBuilder
    func demoAnchor(_ id: String) -> some View {
        if AppEnv.isDemo {
            background(GeometryReader { g in
                Color.clear.preference(key: DemoAnchorKey.self, value: [id: g.frame(in: .named(ShelfSpace.name))])
            })
        } else {
            self
        }
    }
}

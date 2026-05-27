import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            DeviceListView()
        }
        .overlay(alignment: .top) {
            ToastOverlay()
        }
    }
}

#Preview {
    RootView().environment(AppModel())
}

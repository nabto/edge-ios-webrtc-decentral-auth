import SwiftUI
import Observation

struct Toast: Identifiable, Equatable {
    enum Style { case success, info, warning, error }
    let id = UUID()
    let title: String
    let message: String?
    let style: Style
}

@Observable
@MainActor
final class Toaster {
    private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?

    func show(_ toast: Toast, duration: TimeInterval = 3.0) {
        current = toast
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }

    func success(_ title: String, message: String? = nil) {
        show(Toast(title: title, message: message, style: .success))
    }

    func error(_ title: String, message: String? = nil) {
        show(Toast(title: title, message: message, style: .error))
    }

    func warning(_ title: String, message: String? = nil) {
        show(Toast(title: title, message: message, style: .warning))
    }

    func info(_ title: String, message: String? = nil) {
        show(Toast(title: title, message: message, style: .info))
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

struct ToastOverlay: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let toast = app.toaster.current {
            ToastView(toast: toast)
                .padding(.horizontal)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(duration: 0.25), value: toast.id)
        }
    }
}

private struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.white)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                if let message = toast.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(radius: 6, y: 2)
    }

    private var icon: String {
        switch toast.style {
        case .success: return "checkmark.circle.fill"
        case .info:    return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }

    private var background: Color {
        switch toast.style {
        case .success: return .green
        case .info:    return .blue
        case .warning: return .orange
        case .error:   return .red
        }
    }
}

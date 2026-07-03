import SwiftUI

struct UpdateCheckAlertView: View {
    let title: String
    let message: String?
    let linkDestination: URL
    let onOK: () -> Void

    private var height: CGFloat {
        message == nil ? 292 : 336
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(red: 0.78, green: 0.78, blue: 0.76).opacity(0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )

            VStack(spacing: 18) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 54, weight: .regular))
                    .foregroundColor(.black)
                    .frame(width: 72, height: 72)

                VStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.black.opacity(0.88))
                        .multilineTextAlignment(.center)

                    if let message {
                        Text(message)
                            .font(.system(size: 13))
                            .foregroundColor(.black.opacity(0.62))
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                    }

                    Link(destination: linkDestination) {
                        Text(UpdateChecker.repositoryDisplay)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.blue)
                            .underline()
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .center)

                Button(action: onOK) {
                    Text("好")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 232, height: 42)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(Color.accentColor)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 26)
        }
        .frame(width: 380, height: height)
    }
}

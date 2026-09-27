import SwiftUI

/// Six digits, entered once. The host turns them into a cookie, so this screen
/// is not seen again on this device unless the code is rotated.
struct PairingView: View {
    let hostName: String
    let wasWrong: Bool
    var onSubmit: (String) -> Void
    var onCancel: () -> Void

    @State private var code = ""

    var body: some View {
        VStack(spacing: 20) {
            Text(hostName).font(.title2).bold()
            Text(wasWrong
                 ? "That code was not right. Check the ExtraPad menu on your Mac."
                 : "Enter the six-digit code from the ExtraPad menu on your Mac.")
                .multilineTextAlignment(.center)
                .foregroundColor(wasWrong ? .red : .secondary)
                .padding(.horizontal, 40)

            TextField("000000", text: $code)
                .keyboardType(.numberPad)
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
                .padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary))
                .onChange(of: code) { value in
                    code = String(value.filter(\.isNumber).prefix(6))
                    if code.count == 6 { onSubmit(code) }
                }

            Button("Connect") { onSubmit(code) }
                .buttonStyle(.borderedProminent)
                .disabled(code.count != 6)

            Button("Back", action: onCancel)
                .padding(.top, 4)
        }
        .padding()
    }
}

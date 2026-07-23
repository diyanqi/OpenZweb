import SwiftUI
import AppKit

/// Six discrete digit cells for OTP / SMS codes.
struct OTPInputView: View {
    @Binding var code: String
    var length: Int = 6
    var shakeToken: Int = 0
    var isError: Bool = false
    var onComplete: ((String) -> Void)?

    @FocusState private var focused: Bool
    @State private var fieldText: String = ""
    @State private var shakeOffset: CGFloat = 0

    var body: some View {
        ZStack {
            // Hidden field captures typing / paste
            TextField("", text: $fieldText)
                .textFieldStyle(.plain)
                .focused($focused)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .onChange(of: fieldText) { _, newValue in
                    let digits = newValue.filter(\.isNumber)
                    let clipped = String(digits.prefix(length))
                    if clipped != fieldText { fieldText = clipped }
                    code = clipped
                    if clipped.count == length {
                        onComplete?(clipped)
                    }
                }
                .onAppear {
                    fieldText = code.filter(\.isNumber)
                    focused = true
                }
                .onChange(of: code) { _, newValue in
                    let digits = String(newValue.filter(\.isNumber).prefix(length))
                    if digits != fieldText { fieldText = digits }
                }

            HStack(spacing: 10) {
                ForEach(0..<length, id: \.self) { index in
                    let char = character(at: index)
                    let isActive = focused && index == min(code.count, length - 1)
                    Text(char.isEmpty ? "·" : char)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(char.isEmpty ? Color.secondary.opacity(0.35) : Color.primary)
                        .frame(width: 42, height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    isError
                                        ? Color.red.opacity(0.85)
                                        : (isActive ? Color.accentColor : Color.secondary.opacity(0.25)),
                                    lineWidth: (isActive || isError) ? 2 : 1
                                )
                        )
                }
            }
            .offset(x: shakeOffset)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
        }
        .onAppear { focused = true }
        .onChange(of: shakeToken) { _, _ in
            guard shakeToken > 0 else { return }
            Task { @MainActor in
                focused = true
                let deltas: [CGFloat] = [0, -12, 12, -10, 10, -6, 6, -3, 3, 0]
                for delta in deltas {
                    withAnimation(.linear(duration: 0.04)) {
                        shakeOffset = delta
                    }
                    try? await Task.sleep(nanoseconds: 40_000_000)
                }
                shakeOffset = 0
            }
        }
    }

    private func character(at index: Int) -> String {
        guard index < code.count else { return "" }
        let i = code.index(code.startIndex, offsetBy: index)
        return String(code[i])
    }
}

struct SMSOTPSheet: View {
    @EnvironmentObject private var engine: ConnectEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "ellipsis.message.fill")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)

            Text("短信验证码")
                .font(.title2.weight(.semibold))
            Text("请输入发送到绑定手机的 6 位验证码")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            OTPInputView(
                code: $engine.smsCode,
                length: 6,
                shakeToken: engine.smsShakeToken,
                isError: engine.smsError != nil
            ) { _ in
                engine.submitSMS()
            }
            .padding(.top, 4)

            if engine.smsAllowsSkipSecondary {
                Toggle("跳过以后的短信验证", isOn: $engine.skipSecondaryAuth)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .help("与 EZ4Connect 相同：验证码前加 $，请求跳过后续二次短信。服务端不一定允许。")
            }

            if let smsError = engine.smsError {
                VStack(spacing: 4) {
                    Text(smsError)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                    Text("输入框会抖动提示错误，请重新输入 6 位验证码后提交")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 12) {
                Button("取消") {
                    engine.disconnect()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("提交") {
                    engine.submitSMS()
                }
                .buttonStyle(.borderedProminent)
                .disabled(engine.smsCode.count < 6)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(28)
        .frame(width: 380)
        .animation(.easeOut(duration: 0.2), value: engine.smsError)
    }
}

import SwiftUI
import AppKit

/// Six discrete digit cells for OTP / SMS codes.
struct OTPInputView: View {
    @Binding var code: String
    var length: Int = 6
    var shakeToken: Int = 0
    var isError: Bool = false
    /// When true, digits stay visible but typing is locked (verifying).
    var isLocked: Bool = false
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
                .disabled(isLocked)
                .onChange(of: fieldText) { _, newValue in
                    guard !isLocked else { return }
                    let digits = newValue.filter(\.isNumber)
                    let clipped = String(digits.prefix(length))
                    if clipped != fieldText { fieldText = clipped }
                    if clipped != code { code = clipped }
                    if clipped.count == length {
                        onComplete?(clipped)
                    }
                }
                .onChange(of: code) { _, newValue in
                    let digits = String(newValue.filter(\.isNumber).prefix(length))
                    if digits != fieldText { fieldText = digits }
                }
                .onChange(of: isLocked) { _, locked in
                    if locked {
                        focused = false
                    } else if !isError {
                        focused = true
                    }
                }

            HStack(spacing: 10) {
                ForEach(0..<length, id: \.self) { index in
                    let char = character(at: index)
                    let isActive = focused && !isLocked && index == min(code.count, length - 1)
                    Text(char.isEmpty ? "·" : char)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(
                            isLocked
                                ? Color.secondary
                                : (char.isEmpty ? Color.secondary.opacity(0.35) : Color.primary)
                        )
                        .frame(width: 42, height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(isLocked ? 0.7 : 1))
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
            .onTapGesture {
                guard !isLocked else { return }
                focused = true
            }
        }
        .onAppear {
            if !isLocked { focused = true }
        }
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

            Text(L10n.t("sms.title"))
                .font(.title2.weight(.semibold))
            Text(L10n.t("sms.hint"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            OTPInputView(
                code: $engine.smsCode,
                length: 6,
                shakeToken: engine.smsShakeToken,
                isError: engine.smsError != nil,
                isLocked: engine.isSubmittingSMS
            ) { _ in
                engine.submitSMS()
            }
            .padding(.top, 4)

            if engine.isSubmittingSMS {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.t("sms.verifying"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }

            if engine.smsAllowsSkipSecondary {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(L10n.t("sms.skip_secondary"), isOn: $engine.skipSecondaryAuth)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                        .disabled(engine.isSubmittingSMS)
                    Text(L10n.t("sms.skip_secondary_hint"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 320, alignment: .leading)
            }

            if let smsError = engine.smsError {
                VStack(spacing: 4) {
                    Text(smsError)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                    Text(L10n.t("sms.reenter"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 12) {
                Button(L10n.t("common.cancel")) {
                    engine.disconnect()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(engine.isSubmittingSMS)

                Button(L10n.t("common.submit")) {
                    engine.submitSMS()
                }
                .buttonStyle(.borderedProminent)
                .disabled(engine.smsCode.count < 6 || engine.isSubmittingSMS)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(28)
        .frame(width: 380)
        .animation(.easeOut(duration: 0.2), value: engine.smsError)
        .animation(.easeOut(duration: 0.2), value: engine.isSubmittingSMS)
    }
}

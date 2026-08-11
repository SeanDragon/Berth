import SwiftUI

/// keyboard-interactive 质询(堡垒机 MFA):按服务器给的提示逐项输入,
/// echo=false 的用安全输入框。回车提交,Esc 取消(取消 = 认证中止)。
struct KeyboardInteractivePromptSheet: View {
    let prompt: KeyboardInteractivePrompt
    let session: TerminalSession

    @State private var answers: [String]
    @FocusState private var focusedField: Int?

    init(prompt: KeyboardInteractivePrompt, session: TerminalSession) {
        self.prompt = prompt
        self.session = session
        _answers = State(initialValue: Array(repeating: "", count: prompt.challenge.prompts.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                Text(prompt.challenge.title.isEmpty
                    ? String(localized: "服务器请求交互式认证")
                    : prompt.challenge.title)
                    .font(.title3.bold())
            }

            Text("\(PrivacyMode.shared.maskHost(in: session.spec.label, hostname: session.spec.hostname)) 要求补充认证信息(如 MFA 动态验证码)。")
                .font(.callout)
                .foregroundStyle(.secondary)

            if !prompt.challenge.instruction.isEmpty {
                Text(prompt.challenge.instruction)
                    .font(.callout)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(prompt.challenge.prompts.enumerated()), id: \.offset) { index, item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.text)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        if item.echo {
                            TextField("", text: $answers[index])
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: index)
                        } else {
                            SecureField("", text: $answers[index])
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: index)
                        }
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))

            HStack {
                Button("取消连接") {
                    session.resolveKeyboardInteractivePrompt(answers: nil)
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("提交") {
                    session.resolveKeyboardInteractivePrompt(answers: answers)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled()
        .onAppear { focusedField = 0 }
    }
}

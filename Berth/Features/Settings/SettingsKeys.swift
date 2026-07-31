import Foundation

/// @AppStorage / UserDefaults 键名统一定义
enum SettingsKeys {
    static let terminalFontSize = "terminal.fontSize"
    static let confirmBeforeClosingTab = "terminal.confirmBeforeClosingTab"
    static let autoReconnect = "session.autoReconnect"
    static let terminalTheme = "terminal.theme"
    static let cursorShape = "terminal.cursorShape"
    static let cursorBlink = "terminal.cursorBlink"
    static let requireTouchIDForKeys = "security.requireTouchIDForKeys"
    static let pasteProtection = "terminal.pasteProtection"
    static let notifyLongCommand = "session.notifyLongCommand"
    static let restoreSessions = "session.restoreOnLaunch"
    static let copyOnSelect = "terminal.copyOnSelect"
    static let middleClickPaste = "terminal.middleClickPaste"
    static let restoreWorkingDir = "session.restoreWorkingDir"
    /// 界面语言:system / zh-Hans / en(写 AppleLanguages 覆盖,重启生效)
    static let appLanguage = "app.language"
    /// 菜单栏常驻图标
    static let menuBarExtra = "app.menuBarExtra"
    /// 侧栏主机可达性探测(TCP 测活,默认关)
    static let probeReachability = "app.probeReachability"
    /// 演示模式:主机列表隐藏真实主机,显示内置示例(录屏/截图防泄漏)
    static let demoMode = "app.demoMode"
    /// AI 助手:模型名(空 = 默认 claude-opus-5)
    static let aiModel = "ai.model"
    /// AI 助手:API 地址(空 = https://api.anthropic.com;兼容自建中转)
    static let aiBaseURL = "ai.baseURL"
    /// AI 助手:自动执行 AI 建议的命令(危险命令与生产主机仍需确认,默认关)
    static let aiAutoRunCommands = "ai.autoRunCommands"
    /// AI 助手:请求格式(anthropic / openAI 兼容)
    static let aiAPIFormat = "ai.apiFormat"
}

import AppKit
import Foundation
import Observation
import SwiftData
import SwiftUI

/// Arc 式工作空间(自 Termite 移植):主机的分组容器,严格归属制——实体复用
/// HostGroup(随 CloudKit 同步)。未分组主机与所属空间已删除的主机自动归入第一个
/// 空间(主机永远不会凭空消失);没有任何工作空间时侧边栏保持扁平列表,功能零打扰。
/// 本 store 只管本机态:选中空间、跟手横扫进度、ssh_config 镜像主机的本地归属映射。
@MainActor
@Observable
final class SpaceStore {
    static let shared = SpaceStore()

    /// 空间 id 列表(SidebarView 从 @Query 同步进来,顺序即 strip 顺序)
    private(set) var spaceIDs: [UUID] = []
    private(set) var selectedID: UUID?

    /// ssh_config 镜像主机不入库,归属存本机(hostID 按 alias 决定性派生,跨启动稳定)
    private var mirrorAssignments: [UUID: UUID] = [:]

    private static let selectedKey = "sidebar.selectedSpace"
    private static let mirrorKey = "sidebar.mirrorHostSpaces"

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.selectedKey) {
            selectedID = UUID(uuidString: raw)
        }
        if let stored = UserDefaults.standard.dictionary(forKey: Self.mirrorKey) as? [String: String] {
            for (host, space) in stored {
                if let hostID = UUID(uuidString: host), let spaceID = UUID(uuidString: space) {
                    mirrorAssignments[hostID] = spaceID
                }
            }
        }
    }

    /// SidebarView 把 @Query 的分组列表喂进来;选中已失效时回落第一个
    func syncSpaces(_ ids: [UUID]) {
        guard ids != spaceIDs else { return }
        spaceIDs = ids
        if let selectedID, ids.contains(selectedID) { return }
        selectedID = ids.first
    }

    var selectedIndex: Int {
        selectedID.flatMap { spaceIDs.firstIndex(of: $0) } ?? 0
    }

    /// 主机的有效归属:归属无效(nil / 空间已删)回落到第一个空间。
    /// 镜像主机查本地映射,托管主机看 group 关系
    func effectiveSpaceID(of host: Host) -> UUID? {
        let assigned = host.source == .sshConfig ? mirrorAssignments[host.id] : host.group?.id
        return assigned.flatMap { spaceIDs.contains($0) ? $0 : nil } ?? spaceIDs.first
    }

    /// 镜像主机「移到工作空间」:写本地映射(不碰 ~/.ssh/config)
    func assignMirrorHost(_ hostID: UUID, to spaceID: UUID?) {
        mirrorAssignments[hostID] = spaceID
        let stored = mirrorAssignments.reduce(into: [String: String]()) {
            $0[$1.key.uuidString] = $1.value.uuidString
        }
        UserDefaults.standard.set(stored, forKey: Self.mirrorKey)
    }

    /// 最近一次切换的进场方向(空间名的水平推入动画):向后切=新内容从右侧推入
    private(set) var slideEdge: Edge = .trailing

    func select(_ id: UUID) {
        if let from = spaceIDs.firstIndex(of: selectedID ?? id),
           let to = spaceIDs.firstIndex(of: id) {
            slideEdge = to >= from ? .trailing : .leading
        }
        selectedID = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.selectedKey)
    }

    /// 相邻切换:到首尾即止,不循环
    func selectAdjacent(_ delta: Int) {
        guard spaceIDs.count > 1 else { return }
        let target = selectedIndex + delta
        guard spaceIDs.indices.contains(target) else { return }
        select(spaceIDs[target])
    }

    // MARK: - 跟手横扫(移植自 Termite,机制注释见彼处)

    /// 切换进度 −1…1(负=下一个空间正在进场,正=上一个)。
    /// 侧边栏据此做 shared-axis 转场:内容只平移几十点,靠透明度完成交接
    private(set) var dragProgress: CGFloat = 0

    /// 一次切换需要的手指行程:半个侧边栏宽,再给个下限免得窄侧边栏太灵敏
    private func swipeSpan(width: CGFloat) -> CGFloat {
        max(90, width * 0.5)
    }

    /// 手指移动:首尾之外的方向加阻尼(橡皮筋)
    func dragChanged(_ translation: CGFloat, width: CGFloat) {
        guard spaceIDs.count > 1 else { return }
        let index = selectedIndex
        var progress = translation / swipeSpan(width: width)
        if (progress > 0 && index == 0) || (progress < 0 && index == spaceIDs.count - 1) {
            progress *= 0.25
        }
        dragProgress = max(-1, min(1, progress))
    }

    /// 松手:按手指速度把进度投影出去,过半就完成切换,否则退回
    func dragEnded(velocity: CGFloat, width: CGFloat) {
        guard dragProgress != 0 else { return }
        let span = swipeSpan(width: width)
        let progressVelocity = velocity / span
        let projected = dragProgress + progressVelocity * 0.13
        let delta = dragProgress > 0 ? -1 : 1
        let canMove = spaceIDs.indices.contains(selectedIndex + delta)
        let committed = abs(projected) > 0.5 && canMove

        let target: CGFloat = committed ? (dragProgress > 0 ? 1 : -1) : 0
        let distance = target - dragProgress
        let initialVelocity = distance == 0 ? 0 : max(-24, min(24, progressVelocity / distance))
        let animation = Animation.interpolatingSpring(duration: 0.32, bounce: 0.08,
                                                      initialVelocity: initialVelocity)

        guard committed else {
            withAnimation(animation) { dragProgress = 0 }
            return
        }
        // 进度推到 ±1 时进场页已严丝合缝,此刻换选中并把进度归零,画面前后完全一致
        let targetID = spaceIDs[selectedIndex + delta]
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            dragProgress = target
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.select(targetID)
                self.dragProgress = 0
            }
        }
    }

    /// 手势被打断(切窗口等):无条件退回
    func dragCancelled() {
        guard dragProgress != 0 else { return }
        withAnimation(.interpolatingSpring(duration: 0.28, bounce: 0.08)) { dragProgress = 0 }
    }
}

/// 工作空间取名弹框:新建 / 重命名共用。实体是 HostGroup,直接进 SwiftData(随 CloudKit 同步)
@MainActor
enum SpacePrompt {
    /// 单行输入框——多行 cell 会把文字顶到上缘且长占位换行,单行才垂直居中、超长滚动
    private static func nameField() -> NSTextField {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        return field
    }

    static func create(in context: ModelContext) {
        let alert = NSAlert()
        alert.messageText = String(localized: "新建工作空间")
        alert.informativeText = String(localized: "主机只在所属工作空间显示;新空间从空白开始,现有主机留在原空间。")
        let field = nameField()
        field.placeholderString = String(localized: "工作空间名称,如:工作 / 个人")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "创建"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let maxOrder = (try? context.fetch(FetchDescriptor<HostGroup>()))?.map(\.sortOrder).max() ?? 0
        let group = HostGroup(name: name, sortOrder: maxOrder + 1)
        context.insert(group)
        try? context.save()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            SpaceStore.shared.select(group.id)
        }
    }

    static func rename(_ group: HostGroup, in context: ModelContext) {
        let alert = NSAlert()
        alert.messageText = String(localized: "重命名工作空间")
        let field = nameField()
        field.stringValue = group.name
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "确定"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        group.name = name
        try? context.save()
    }
}

/// 触控板横扫切换工作空间(Arc 手势,自 Termite 移植):本地监视器捕获落在侧边栏上的
/// 横向滚动,累计位移实时喂给 SpaceStore——画面跟手,松手才判定换档还是弹回。
/// 轴锁定在手势开头一次性判定并锁死整段,纵向滚动(主机列表)不受影响。
struct SpaceSwipeCatcher: NSViewRepresentable {
    final class CatcherView: NSView {
        private var monitor: Any?
        private var accumX: CGFloat = 0
        private var accumY: CGFloat = 0
        private var tracking = false
        private var swallowsMomentum = false
        private var velocityX: CGFloat = 0
        private var lastTimestamp: TimeInterval = 0
        private var settleTimer: Timer?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
                settleTimer?.invalidate()
                settleTimer = nil
                if tracking {
                    tracking = false
                    SpaceStore.shared.dragCancelled()
                }
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    self?.route(event) ?? event
                }
            }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func route(_ event: NSEvent) -> NSEvent? {
            // 收尾事件抢在窗口归属校验之前:抬手那一记 ended 未必带着本窗口,
            // 被挡掉手势就永远收不了尾,strip 会卡死在两个空间之间
            if tracking, event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                finishGesture()
                return nil
            }
            guard event.window === window else { return event }

            if event.momentumPhase != [] {
                // 手指已离开,换档与否在松手那一刻就定了;惯性不再推进位移
                return swallowsMomentum ? nil : event
            }
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                finishGesture()
                accumX = 0
                accumY = 0
                velocityX = 0
                lastTimestamp = event.timestamp
                swallowsMomentum = false
                return event
            }
            // 手指按住不动会发 stationary:不是松手,只是推后看门狗计时
            if event.phase.contains(.stationary) {
                if tracking {
                    velocityX = 0
                    lastTimestamp = event.timestamp
                    scheduleSettle()
                    return nil
                }
                return event
            }
            if event.phase.contains(.changed) {
                accumX += event.scrollingDeltaX
                accumY += event.scrollingDeltaY
                if !tracking {
                    guard shouldLockHorizontal(event) else { return event }
                    swallowsMomentum = true
                    tracking = true
                }
                updateVelocity(event)
                // 自然滚动:指尖右扫(deltaX 正)= 内容右移,上一个空间从左侧进
                SpaceStore.shared.dragChanged(accumX, width: bounds.width)
                scheduleSettle()
                return nil
            }
            return event
        }

        /// 速度按真实事件间隔算成 pt/s 再平滑(逐帧 delta 与刷新率绑死,不能直接当速度)
        private func updateVelocity(_ event: NSEvent) {
            let dt = event.timestamp - lastTimestamp
            lastTimestamp = event.timestamp
            guard dt > 0.0001, dt < 0.1 else { return }
            let instant = event.scrollingDeltaX / CGFloat(dt)
            velocityX = velocityX * 0.5 + instant * 0.5
        }

        /// 手势收尾的唯一出口:结束事件与看门狗都走这里,保证只吸附一次
        private func finishGesture() {
            settleTimer?.invalidate()
            settleTimer = nil
            guard tracking else { return }
            tracking = false
            SpaceStore.shared.dragEnded(velocity: velocityX, width: bounds.width)
        }

        /// 看门狗纯兜底:「停在两个空间中间」是绝不能出现的状态,而结束事件的
        /// phase 语义并非所有输入设备都一致。拖拽/菜单会挂起常规模式定时器,必须 .common
        private func scheduleSettle() {
            settleTimer?.invalidate()
            let timer = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishGesture() }
            }
            RunLoop.main.add(timer, forMode: .common)
            settleTimer = timer
        }

        /// 轴锁定:指针在侧边栏内、有多个空间、且手势起步阶段横向明显压过纵向
        private func shouldLockHorizontal(_ event: NSEvent) -> Bool {
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point),
                  SpaceStore.shared.spaceIDs.count > 1,
                  abs(accumY) < 12,
                  abs(event.scrollingDeltaX) > 0.5,
                  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5 else { return false }
            return true
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            settleTimer?.invalidate()
        }
    }

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ nsView: CatcherView, context: Context) {}
}

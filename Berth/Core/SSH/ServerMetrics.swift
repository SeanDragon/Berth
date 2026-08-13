import Foundation

/// 仪表盘用的一次资源采样。
///
/// 与 inspector 的 `ServerInfo` 的分工:`ServerInfo` 取的是给人看的成品字符串
/// (「2364/7200 MB」),仪表盘要算 CPU 占用和网络速率,必须拿**原始累计计数器**
/// 自己跨次求差,所以这里存裸数值,派生值统一由 `ServerMetricsReading` 计算。
struct ServerMetricsSample: Equatable, Sendable {
    /// 本地采样时刻。速率一律按本地时钟求差 —— 服务器时钟漂移/跳变不该算进带宽里
    var takenAt = Date()

    var hostname = ""
    var os = ""
    var kernel = ""
    var cpuCount = 0
    /// 1/5/15 分钟负载
    var load: [Double] = []
    var uptimeSeconds: Double?

    /// /proc/stat 的累计 jiffies(总量与空闲量),跨两次采样求差得 CPU 占用
    var cpuTotalTicks: Double?
    var cpuIdleTicks: Double?
    /// 拿不到计数器时的直接占用率(macOS 的 top 只给百分比)
    var cpuPercentDirect: Double?

    var memTotalKB: Double?
    var memAvailableKB: Double?
    var swapTotalKB: Double?
    var swapFreeKB: Double?

    /// 累计收发字节(排除 lo 与容器虚拟网卡),跨两次采样求差得速率
    var netRxBytes: Double?
    var netTxBytes: Double?

    var processes: Int?
    /// CPU 温度(摄氏),仅在能读到 thermal zone 时有值
    var temperatureC: Double?
    var disks: [DiskUsage] = []

    /// 至少解析出一项有意义的数据(否则视为采集失败,别用空卡片糊弄)
    var isUsable: Bool {
        memTotalKB != nil || cpuTotalTicks != nil || cpuPercentDirect != nil
            || !load.isEmpty || !disks.isEmpty
    }

    struct DiskUsage: Equatable, Sendable, Identifiable {
        let mount: String
        let usedKB: Double
        let totalKB: Double

        var id: String { mount }
        var fraction: Double {
            guard totalKB > 0 else { return 0 }
            return min(max(usedKB / totalKB, 0), 1)
        }
    }

    // MARK: - 解析

    init() {}

    /// 解析采集脚本输出的 key=value 行。无法识别的行忽略(服务器五花八门,宁缺毋滥)。
    init(parsing text: String, takenAt: Date = Date()) {
        self.takenAt = takenAt
        for line in text.components(separatedBy: .newlines) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            let number = Double(value)
            switch key {
            case "HOSTNAME": hostname = value
            case "OS": os = value
            case "KERNEL": kernel = value
            case "CPUS": cpuCount = Int(value) ?? 0
            case "LOAD": load = value.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            case "UPTIME": uptimeSeconds = number
            case "CPUTOTAL": cpuTotalTicks = number
            case "CPUIDLE": cpuIdleTicks = number
            case "CPUPCT": cpuPercentDirect = number.map { min(max($0, 0), 100) }
            case "MEMTOTAL": memTotalKB = number
            case "MEMAVAIL": memAvailableKB = number
            case "SWAPTOTAL": swapTotalKB = number
            case "SWAPFREE": swapFreeKB = number
            case "NETRX": netRxBytes = number
            case "NETTX": netTxBytes = number
            case "PROCS": processes = Int(value)
            case "TEMPMC": temperatureC = number.map { $0 / 1000 }
            case "DISK":
                // <挂载点>|<已用 KB>|<总量 KB>
                let parts = value.components(separatedBy: "|")
                guard parts.count == 3, let used = Double(parts[1]), let total = Double(parts[2]), total > 0 else { continue }
                disks.append(DiskUsage(mount: parts[0], usedKB: used, totalKB: total))
            default: continue
            }
        }
    }
}

/// 采集脚本的命名空间(脚本本身与解析结果分开:脚本要跟着服务器差异演进,样本结构不必)
enum ServerMetrics {
    /// 一次采集只跑一条脚本、只取一次快照(CPU/网络的瞬时值由 app 跨次求差得到)。
    /// 约束:保证 exit 0、不写 stderr —— 否则 Citadel 的 executeCommand 会抛错。
    /// Linux 走 /proc;macOS/BSD 走 sysctl/vm_stat/netstat 兜底,取不到的字段直接不输出,
    /// UI 侧按缺项降级显示,不猜、不填 0。
    static let collectionScript = #"""
    printf 'HOSTNAME=%s\n' "$(hostname 2>/dev/null)"
    printf 'KERNEL=%s\n' "$(uname -sr 2>/dev/null)"

    if [ -r /proc/stat ]; then
        printf 'OS=%s\n' "$(. /etc/os-release 2>/dev/null; printf '%s' "$PRETTY_NAME")"
        printf 'CPUS=%s\n' "$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
        printf 'LOAD=%s\n' "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
        printf 'UPTIME=%s\n' "$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
        printf 'PROCS=%s\n' "$(ls -1 /proc 2>/dev/null | grep -c '^[0-9][0-9]*$')"

        awk '/^cpu /{t=0; for (i=2; i<=NF; i++) t+=$i; print "CPUTOTAL=" t; print "CPUIDLE=" ($5+$6); exit}' /proc/stat 2>/dev/null

        awk '
            /^MemTotal:/{mt=$2}
            /^MemAvailable:/{ma=$2; hasma=1}
            /^MemFree:/{mf=$2}
            /^Buffers:/{bu=$2}
            /^Cached:/{ca=$2}
            /^SwapTotal:/{st=$2}
            /^SwapFree:/{sf=$2}
            END{
                if (mt) print "MEMTOTAL=" mt
                if (hasma) print "MEMAVAIL=" ma; else if (mt) print "MEMAVAIL=" (mf+bu+ca)
                if (st) { print "SWAPTOTAL=" st; print "SWAPFREE=" sf+0 }
            }' /proc/meminfo 2>/dev/null

        # 只统计物理/上联网卡:回环与容器虚拟网卡会把同一份流量重复计一遍
        awk 'NR>2 {
                sub(/^ +/, "");
                split($0, p, ":");
                ifc=p[1];
                if (ifc ~ /^(lo|docker|veth|br-|virbr|cni|flannel|tun|tap)/) next;
                split(p[2], f, " ");
                rx+=f[1]; tx+=f[9];
            }
            END { if (rx+tx > 0) { print "NETRX=" rx; print "NETTX=" tx } }' /proc/net/dev 2>/dev/null

        for zone in /sys/class/thermal/thermal_zone*; do
            [ -r "$zone/temp" ] || continue
            case "$(cat "$zone/type" 2>/dev/null)" in
                *cpu*|*x86_pkg*|*coretemp*|*soc*|*package*)
                    printf 'TEMPMC=%s\n' "$(cat "$zone/temp" 2>/dev/null)"
                    break
                    ;;
            esac
        done
    else
        printf 'OS=%s\n' "$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)"
        printf 'CPUS=%s\n' "$(sysctl -n hw.ncpu 2>/dev/null)"
        printf 'LOAD=%s\n' "$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | sed 's/^ *//;s/ *$//')"
        printf 'PROCS=%s\n' "$(ps -A 2>/dev/null | awk 'END{print NR-1}')"

        # 注意别贪婪匹配到后面的 usec:形如 "{ sec = 1786400000, usec = 123456 } ..."
        boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ *sec = \([0-9][0-9]*\).*/\1/p')
        [ -n "$boot" ] && printf 'UPTIME=%s\n' "$(( $(date +%s) - boot ))"

        top -l 1 -n 0 2>/dev/null | awk '/CPU usage/{
            for (i=1; i<=NF; i++) if ($i == "idle") {
                idle=$(i-1); sub(/%/, "", idle); printf "CPUPCT=%.1f\n", 100-idle; exit
            }
        }'

        pagesize=$(vm_stat 2>/dev/null | sed -n 's/.*page size of \([0-9]*\) bytes.*/\1/p')
        [ -z "$pagesize" ] && pagesize=4096
        memsize=$(sysctl -n hw.memsize 2>/dev/null)
        [ -n "$memsize" ] && printf 'MEMTOTAL=%s\n' "$((memsize / 1024))"
        vm_stat 2>/dev/null | awk -v ps="$pagesize" '
            /Pages free/{gsub(/\./, "", $NF); f=$NF}
            /Pages inactive/{gsub(/\./, "", $NF); i=$NF}
            /Pages speculative/{gsub(/\./, "", $NF); s=$NF}
            END{ if (f+i+s > 0) printf "MEMAVAIL=%d\n", (f+i+s) * ps / 1024 }'

        netstat -ib 2>/dev/null | awk '
            $1 !~ /^(lo|Name)/ && $3 ~ /^<Link/ { rx+=$7; tx+=$10 }
            END { if (rx+tx > 0) { print "NETRX=" rx; print "NETTX=" tx } }'
    fi

    # 真实文件系统的容量,最多 6 个挂载点。排掉伪文件系统(tmpfs/overlay)与
    # macOS 的系统辅助卷(VM/Preboot/Update…)—— 它们和根卷共用容器,列出来只是噪声
    df -kP 2>/dev/null | awk '
        NR>1 && $1 !~ /^(tmpfs|devtmpfs|udev|none|shm|map|devfs)$/ && $2+0 > 0 &&
        ($1 != "overlay" || $6 == "/") &&
        $6 !~ /^\/System\/Volumes\/(VM|Preboot|Update|xarts|iSCPreboot|Hardware)/ &&
        $6 !~ /^\/(dev|proc|sys|run|snap)/ && $6 !~ /^\/var\/lib\/docker/ {
            # 同一个文件系统被 bind-mount 多次时只留第一个挂载点,别把一块盘数三遍
            key = $1 "|" $2 "|" $3;
            if (seen[key]++) next;
            print "DISK=" $6 "|" $3 "|" $2
        }' | head -6

    exit 0
    """#
}

/// 一次采样 + 上一次采样 → 可直接上屏的展示值。
/// CPU 占用与网络速率必须靠两次采样求差,所以首次采集这两项为 nil(UI 显示「—」)。
struct ServerMetricsReading: Equatable, Sendable {
    var takenAt: Date
    var hostname: String
    var os: String
    var kernel: String
    var cpuCount: Int
    var load: [Double]
    var uptimeSeconds: Double?
    var processes: Int?
    var temperatureC: Double?

    /// 0...1
    var cpuFraction: Double?
    var memUsedKB: Double?
    var memTotalKB: Double?
    var swapUsedKB: Double?
    var swapTotalKB: Double?
    /// bytes/s
    var netRxRate: Double?
    var netTxRate: Double?
    var disks: [ServerMetricsSample.DiskUsage]

    var memFraction: Double? {
        guard let used = memUsedKB, let total = memTotalKB, total > 0 else { return nil }
        return min(max(used / total, 0), 1)
    }

    var swapFraction: Double? {
        guard let used = swapUsedKB, let total = swapTotalKB, total > 0 else { return nil }
        return min(max(used / total, 0), 1)
    }

    /// 主盘:优先根分区,否则容量最大的那个
    var primaryDisk: ServerMetricsSample.DiskUsage? {
        disks.first { $0.mount == "/" } ?? disks.max { $0.totalKB < $1.totalKB }
    }

    /// 负载相对核数(> 1 表示排队)
    var loadFraction: Double? {
        guard let load1 = load.first, cpuCount > 0 else { return nil }
        return load1 / Double(cpuCount)
    }

    init(sample: ServerMetricsSample, previous: ServerMetricsSample? = nil) {
        takenAt = sample.takenAt
        hostname = sample.hostname
        os = sample.os
        kernel = sample.kernel
        cpuCount = sample.cpuCount
        load = sample.load
        uptimeSeconds = sample.uptimeSeconds
        processes = sample.processes
        temperatureC = sample.temperatureC
        disks = sample.disks

        memTotalKB = sample.memTotalKB
        if let total = sample.memTotalKB, let available = sample.memAvailableKB {
            memUsedKB = max(total - available, 0)
        }
        swapTotalKB = sample.swapTotalKB
        if let total = sample.swapTotalKB, let free = sample.swapFreeKB {
            swapUsedKB = max(total - free, 0)
        }

        // 采样间隔:同一台机器两次采集的本地时刻差。<0.5s 的差分噪声太大,直接不算
        let interval = previous.map { sample.takenAt.timeIntervalSince($0.takenAt) } ?? 0

        if let direct = sample.cpuPercentDirect {
            cpuFraction = direct / 100
        } else if let previous, interval >= 0.5,
                  let total = sample.cpuTotalTicks, let idle = sample.cpuIdleTicks,
                  let prevTotal = previous.cpuTotalTicks, let prevIdle = previous.cpuIdleTicks {
            let totalDelta = total - prevTotal
            let idleDelta = idle - prevIdle
            // 计数器回绕或服务器重启 → 差值为负,这一轮不出数
            if totalDelta > 0, idleDelta >= 0 {
                cpuFraction = min(max(1 - idleDelta / totalDelta, 0), 1)
            }
        }

        if let previous, interval >= 0.5 {
            netRxRate = Self.rate(sample.netRxBytes, previous.netRxBytes, interval: interval)
            netTxRate = Self.rate(sample.netTxBytes, previous.netTxBytes, interval: interval)
        }
    }

    private static func rate(_ current: Double?, _ previous: Double?, interval: TimeInterval) -> Double? {
        guard let current, let previous, current >= previous else { return nil }
        return (current - previous) / interval
    }
}

// MARK: - 展示格式化

enum MetricFormat {
    /// 速率:B/s → 合适量级
    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let value = bytesPerSecond else { return "—" }
        return byteCount(value) + "/s"
    }

    /// KB(1024 进制)→ 人话容量
    static func kilobytes(_ kb: Double?) -> String {
        guard let kb else { return "—" }
        return byteCount(kb * 1024)
    }

    static func byteCount(_ bytes: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = max(bytes, 0)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        // 大单位给一位小数,B/KB 没必要
        let precise = unit >= 2 && value < 100
        return String(format: precise ? "%.1f %@" : "%.0f %@", value, units[unit])
    }

    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// 运行时长:天/小时/分钟,只取两级
    static func uptime(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        let total = Int(seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return String(localized: "\(days) 天 \(hours) 小时") }
        if hours > 0 { return String(localized: "\(hours) 小时 \(minutes) 分") }
        return String(localized: "\(minutes) 分钟")
    }

    static func load(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "—" }
        return values.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: "  ")
    }

    static func temperature(_ celsius: Double?) -> String? {
        guard let celsius, celsius > 0, celsius < 150 else { return nil }
        return String(format: "%.0f°C", celsius)
    }
}

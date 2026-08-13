import XCTest
@testable import Berth

/// 仪表盘采集:key=value 解析、跨样本求 CPU 占用与网络速率、格式化。
final class ServerMetricsTests: XCTestCase {

    /// 真机(Alpine 容器)上采到的一份完整输出
    private let linuxOutput = """
    HOSTNAME=web-1
    KERNEL=Linux 6.8.0-45-generic
    OS=Ubuntu 22.04.4 LTS
    CPUS=4
    LOAD=0.42 0.55 0.60
    UPTIME=864000.31
    PROCS=214
    CPUTOTAL=20393011
    CPUIDLE=20329004
    MEMTOTAL=8039128
    MEMAVAIL=3016420
    SWAPTOTAL=2097148
    SWAPFREE=2000000
    NETRX=1656000
    NETTX=126000
    TEMPMC=48500
    DISK=/|10364084|60725657
    DISK=/data|500|1000
    """

    func testParsesLinuxOutput() {
        let sample = ServerMetricsSample(parsing: linuxOutput)
        XCTAssertEqual(sample.hostname, "web-1")
        XCTAssertEqual(sample.os, "Ubuntu 22.04.4 LTS")
        XCTAssertEqual(sample.cpuCount, 4)
        XCTAssertEqual(sample.load, [0.42, 0.55, 0.60])
        XCTAssertEqual(sample.uptimeSeconds ?? 0, 864000.31, accuracy: 0.01)
        XCTAssertEqual(sample.processes, 214)
        XCTAssertEqual(sample.cpuTotalTicks, 20393011)
        XCTAssertEqual(sample.temperatureC ?? 0, 48.5, accuracy: 0.001)
        XCTAssertEqual(sample.disks.count, 2)
        XCTAssertEqual(sample.disks.first?.mount, "/")
        XCTAssertTrue(sample.isUsable)
    }

    func testEmptyOutputIsNotUsable() {
        XCTAssertFalse(ServerMetricsSample(parsing: "").isUsable)
        // 只有主机名说明脚本跑了但什么也没采到 —— 不能拿来充数据
        XCTAssertFalse(ServerMetricsSample(parsing: "HOSTNAME=box\nKERNEL=Linux 5.0\n").isUsable)
    }

    func testIgnoresGarbageLines() {
        let sample = ServerMetricsSample(parsing: """
        bash: nproc: command not found
        MEMTOTAL=1024
        MEMAVAIL=
        DISK=/|broken|1000
        """)
        XCTAssertEqual(sample.memTotalKB, 1024)
        XCTAssertNil(sample.memAvailableKB)
        XCTAssertTrue(sample.disks.isEmpty)
    }

    // MARK: - 派生值

    func testFirstReadingHasNoRates() {
        let reading = ServerMetricsReading(sample: ServerMetricsSample(parsing: linuxOutput))
        // CPU 占用与网络速率都要两次采样才算得出来,首轮必须是「没有」而不是 0
        XCTAssertNil(reading.cpuFraction)
        XCTAssertNil(reading.netRxRate)
        XCTAssertNil(reading.netTxRate)
        // 内存/磁盘是瞬时量,首轮就该有
        XCTAssertEqual(reading.memFraction ?? 0, 1 - 3016420.0 / 8039128.0, accuracy: 0.0001)
        XCTAssertEqual(reading.primaryDisk?.mount, "/")
    }

    func testCPUAndNetworkRatesFromTwoSamples() {
        let start = Date()
        let first = ServerMetricsSample(parsing: linuxOutput, takenAt: start)
        // 5 秒后:总量 +1000 tick,其中 750 是空闲 → 占用 25%
        let second = ServerMetricsSample(parsing: """
        CPUTOTAL=20394011
        CPUIDLE=20329754
        NETRX=1666000
        NETTX=131000
        MEMTOTAL=8039128
        MEMAVAIL=3016420
        """, takenAt: start.addingTimeInterval(5))

        let reading = ServerMetricsReading(sample: second, previous: first)
        XCTAssertEqual(reading.cpuFraction ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(reading.netRxRate ?? 0, 2000, accuracy: 0.001)
        XCTAssertEqual(reading.netTxRate ?? 0, 1000, accuracy: 0.001)
    }

    func testCounterResetProducesNoRate() {
        let start = Date()
        let first = ServerMetricsSample(parsing: linuxOutput, takenAt: start)
        // 服务器重启:累计计数器归零,差值为负 —— 宁可不出数,也别画一根负速率
        let second = ServerMetricsSample(parsing: """
        CPUTOTAL=500
        CPUIDLE=400
        NETRX=10
        NETTX=5
        MEMTOTAL=8039128
        MEMAVAIL=7000000
        """, takenAt: start.addingTimeInterval(5))

        let reading = ServerMetricsReading(sample: second, previous: first)
        XCTAssertNil(reading.cpuFraction)
        XCTAssertNil(reading.netRxRate)
    }

    func testDarwinDirectCPUPercent() {
        let sample = ServerMetricsSample(parsing: """
        OS=macOS 15.0
        CPUPCT=15.1
        MEMTOTAL=16777216
        MEMAVAIL=8388608
        """)
        // macOS 只给百分比,没有计数器:首轮就该有 CPU 值
        let reading = ServerMetricsReading(sample: sample)
        XCTAssertEqual(reading.cpuFraction ?? 0, 0.151, accuracy: 0.0001)
        XCTAssertEqual(reading.memFraction ?? 0, 0.5, accuracy: 0.0001)
    }

    func testPrimaryDiskPrefersRootThenLargest() {
        let root = ServerMetricsSample(parsing: "DISK=/data|1|100\nDISK=/|2|50")
        XCTAssertEqual(ServerMetricsReading(sample: root).primaryDisk?.mount, "/")

        let noRoot = ServerMetricsSample(parsing: "DISK=/data|1|100\nDISK=/mnt|2|500")
        XCTAssertEqual(ServerMetricsReading(sample: noRoot).primaryDisk?.mount, "/mnt")
    }

    func testLoadFractionUsesCoreCount() {
        let sample = ServerMetricsSample(parsing: "CPUS=4\nLOAD=2.0 1.0 1.0\nMEMTOTAL=100\nMEMAVAIL=50")
        XCTAssertEqual(ServerMetricsReading(sample: sample).loadFraction ?? 0, 0.5, accuracy: 0.0001)
    }

    // MARK: - 格式化

    func testByteFormatting() {
        XCTAssertEqual(MetricFormat.byteCount(512), "512 B")
        XCTAssertEqual(MetricFormat.byteCount(1024 * 1024 * 2.5), "2.5 MB")
        XCTAssertEqual(MetricFormat.kilobytes(nil), "—")
        XCTAssertEqual(MetricFormat.rate(nil), "—")
        // B/KB 量级给整数就够,MB 起才带一位小数
        XCTAssertEqual(MetricFormat.rate(1024), "1 KB/s")
        XCTAssertEqual(MetricFormat.rate(1024 * 1024 * 3.5), "3.5 MB/s")
    }

    func testPercentAndTemperature() {
        XCTAssertEqual(MetricFormat.percent(0.336), "34%")
        XCTAssertEqual(MetricFormat.percent(nil), "—")
        XCTAssertEqual(MetricFormat.temperature(48.5), "48°C")
        // 传感器读数离谱时不显示,别在卡片上写「0°C」或「3200°C」
        XCTAssertNil(MetricFormat.temperature(0))
        XCTAssertNil(MetricFormat.temperature(3200))
    }

    /// 采集脚本的硬性约束:必须以 exit 0 结束,否则 Citadel 的 executeCommand 会抛错
    func testCollectionScriptEndsWithExitZero() {
        XCTAssertTrue(ServerMetrics.collectionScript.contains("exit 0"))
        XCTAssertFalse(ServerMetrics.collectionScript.contains("\r"))
    }
}

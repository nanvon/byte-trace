import Foundation
import XCTest

@testable import ByteTraceCore

/// `UsageStore` 的单个 sqlite3 连接会被主线程（落库、查询）与后台队列
/// （保留策略的 purge / VACUUM）同时使用。`apply` 与 `purgeBuckets` 都是
/// `BEGIN IMMEDIATE … COMMIT` 的多语句事务，没有互斥就会撞上
/// "cannot start a transaction within a transaction"。
final class UsageStoreConcurrencyTests: XCTestCase {
    func testConcurrentApplyAndPurgeDoNotNestTransactions() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("byte-trace-concurrency-\(UUID().uuidString).sqlite3")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }

        let store = try UsageStore(databaseURL: url)
        let iterations = 60
        let errors = ErrorBox()

        let group = DispatchGroup()
        let writeQueue = DispatchQueue(label: "test.write")
        let purgeQueue = DispatchQueue(label: "test.purge")

        writeQueue.async(group: group) {
            for index in 0..<iterations {
                let sampledAt = Date(timeIntervalSince1970: 1_754_000_000 + Double(index * 60))
                do {
                    try store.apply(
                        [
                            DailyUsageAggregate(
                                day: "2025-08-01",
                                appKey: "bundle:test.app",
                                displayName: "Test",
                                category: .userApp,
                                bundleID: "test.app",
                                bundlePath: nil,
                                executablePath: nil,
                                firstSeenAt: sampledAt,
                                lastSeenAt: sampledAt,
                                downloadBytes: 10,
                                uploadBytes: 20,
                                sampleCount: 1
                            )
                        ],
                        bucketAggregates: [
                            UsageBucketAggregate(
                                bucketStart: sampledAt,
                                appKey: "bundle:test.app",
                                displayName: "Test",
                                category: .userApp,
                                bundleID: "test.app",
                                bundlePath: nil,
                                executablePath: nil,
                                firstSeenAt: sampledAt,
                                lastSeenAt: sampledAt,
                                downloadBytes: 10,
                                uploadBytes: 20,
                                sampleCount: 1
                            )
                        ]
                    )
                } catch {
                    errors.append("apply: \(error)")
                }
            }
        }

        purgeQueue.async(group: group) {
            for _ in 0..<iterations {
                do {
                    _ = try store.purgeBuckets(before: Date(timeIntervalSince1970: 1_754_000_000))
                    _ = try store.purgeCollectorEvents(before: Date(timeIntervalSince1970: 1_754_000_000))
                    _ = try store.dailyUsage(for: "2025-08-01")
                } catch {
                    errors.append("purge: \(error)")
                }
            }
        }

        let outcome = group.wait(timeout: .now() + 60)
        XCTAssertEqual(outcome, .success, "并发读写超时")
        XCTAssertEqual(errors.messages, [], "并发访问不应产生数据库错误")

        // 落库确实生效，而不是被静默吞掉。
        let records = try store.dailyUsage(for: "2025-08-01")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.downloadBytes, Int64(10 * iterations))
        XCTAssertEqual(records.first?.uploadBytes, Int64(20 * iterations))
    }

    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ message: String) {
            lock.lock()
            storage.append(message)
            lock.unlock()
        }

        var messages: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}

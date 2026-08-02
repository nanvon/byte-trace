import Foundation
import NetworkExtension
import OSLog

final class FilterDataProvider: NEFilterDataProvider {
    private let flowRecords = FlowRecordStore()
    private let logger = Logger(
        subsystem: "com.nanvon.ByteTrace.NetworkExtensionLab.FilterProvider",
        category: "flow"
    )

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        logger.info("Filter Data Provider started in pass-through mode")
        completionHandler(nil)
    }

    override func stopFilter(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        logger.info("Filter Data Provider stopped: \(String(describing: reason), privacy: .public)")
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        let metadata = metadata(for: flow)
        flowRecords.begin(
            FlowRecord(
                flowID: flow.identifier,
                startedAt: Date(),
                metadata: metadata
            )
        )

        let verdict = NEFilterNewFlowVerdict.allow()
        verdict.shouldReport = true
        // 只需要 flow close report；第一版不打开周期性统计，避免重复计数。
        return verdict
    }

    override func handle(_ report: NEFilterReport) {
        guard report.event == .flowClosed, let flow = report.flow else {
            return
        }

        guard let record = flowRecords.close(
            flowID: flow.identifier,
            at: Date(),
            bytesInbound: UInt64(report.bytesInboundCount),
            bytesOutbound: UInt64(report.bytesOutboundCount)
        ) else {
            logger.debug("Ignoring close report without an open record")
            return
        }

        let flowID = record.flowID.uuidString
        let visibility = record.metadata.visibility.rawValue
        let inboundBytes = record.bytesInbound
        let outboundBytes = record.bytesOutbound
        logger.info("Flow closed id=\(flowID, privacy: .public)")
        logger.info("Flow visibility=\(visibility, privacy: .public)")
        logger.info("Flow bytes inbound=\(inboundBytes, privacy: .public)")
        logger.info("Flow bytes outbound=\(outboundBytes, privacy: .public)")
    }

    override func handleInboundData(
        from flow: NEFilterFlow,
        readBytesStartOffset offset: Int,
        readBytes: Data
    ) -> NEFilterDataVerdict {
        NEFilterDataVerdict.allow()
    }

    override func handleOutboundData(
        from flow: NEFilterFlow,
        readBytesStartOffset offset: Int,
        readBytes: Data
    ) -> NEFilterDataVerdict {
        NEFilterDataVerdict.allow()
    }

    override func handleInboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict {
        NEFilterDataVerdict.allow()
    }

    override func handleOutboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict {
        NEFilterDataVerdict.allow()
    }

    private func metadata(for flow: NEFilterFlow) -> FlowRecordMetadata {
        let sourceAppAuditToken = flow.sourceAppAuditToken?.base64EncodedString()
        let sourceProcessAuditToken = flow.sourceProcessAuditToken?.base64EncodedString()
        let remoteHostname = (flow as? NEFilterSocketFlow)?.remoteHostname
        let url = flow.url?.absoluteString

        let direction: FlowRecordDirection
        switch String(describing: flow.direction) {
        case "inbound":
            direction = .inbound
        case "outbound":
            direction = .outbound
        default:
            direction = .unknown
        }

        return FlowRecordMetadata(
            sourceAppAuditTokenBase64: sourceAppAuditToken,
            sourceProcessAuditTokenBase64: sourceProcessAuditToken,
            resolvedBundleIdentifier: nil,
            remoteHostname: remoteHostname,
            remoteEndpoint: nil,
            url: url,
            direction: direction
        )
    }
}

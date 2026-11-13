import Foundation

public enum DomainName {
    private static let multiLabelSuffixes: Set<String> = [
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
        "com.hk", "com.tw", "com.sg", "com.au", "net.au", "org.au",
        "co.uk", "org.uk", "ac.uk", "gov.uk", "co.jp", "ne.jp", "or.jp", "ac.jp",
        "co.kr", "or.kr", "co.in", "com.br", "com.mx", "co.nz", "co.za", "com.tr"
    ]

    /// 取统计所用的主域名。多段公共后缀按内置表处理。
    public static func registrable(_ host: String) -> String? {
        var name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty, name.utf8.count <= 253, !name.contains(":") else { return nil }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 &&
                label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }) else { return nil }
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) { return nil }
        let suffix = labels.suffix(2).joined(separator: ".")
        return multiLabelSuffixes.contains(suffix) ? labels.suffix(3).joined(separator: ".") : suffix
    }
}

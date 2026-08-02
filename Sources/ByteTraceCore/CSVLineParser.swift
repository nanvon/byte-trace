import Foundation

enum CSVLineParser {
    static func parse(_ line: String) -> [String] {
        var fields: [String] = []
        var field = String()
        var isQuoted = false
        var scalarIndex = line.unicodeScalars.startIndex

        while scalarIndex < line.unicodeScalars.endIndex {
            let scalar = line.unicodeScalars[scalarIndex]

            if scalar == "\"" {
                let nextIndex = line.unicodeScalars.index(after: scalarIndex)
                if isQuoted, nextIndex < line.unicodeScalars.endIndex,
                   line.unicodeScalars[nextIndex] == "\"" {
                    field.append("\"")
                    scalarIndex = line.unicodeScalars.index(after: nextIndex)
                    continue
                }
                isQuoted.toggle()
            } else if scalar == "," && !isQuoted {
                fields.append(field)
                field.removeAll(keepingCapacity: true)
            } else {
                field.unicodeScalars.append(scalar)
            }

            scalarIndex = line.unicodeScalars.index(after: scalarIndex)
        }

        fields.append(field)
        return fields
    }
}

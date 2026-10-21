import Foundation

/// 与 Raycast 版 utils/transfer.ts 兼容的 JSON 导入导出
enum Transfer {
    /// 沿用 Raycast 版 Prompt Stash 的格式标识，两边导出的文件可以互相导入
    static let schema = "prompt-stash-export"
    static let version = 1

    struct ExportFile: Codable {
        var schema: String
        var version: Int
        var exportedAt: String
        var count: Int
        var prompts: [Prompt]

        enum CodingKeys: String, CodingKey {
            case schema = "$schema"
            case version, exportedAt, count, prompts
        }
    }

    enum ImportStrategy {
        case skip, replace, duplicate
    }

    struct ImportResult: Equatable {
        var added = 0
        var replaced = 0
        var skipped = 0
    }

    struct TransferError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: JSON coding（日期格式与 JS 的 Date.toJSON 一致：2025-01-01T00:00:00.000Z）

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            if let s = try? c.decode(String.self) {
                if let date = fractional.date(from: s) ?? plain.date(from: s) { return date }
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "无法解析日期 \(s)")
            }
            let n = try c.decode(Double.self)
            return Date(timeIntervalSince1970: n > 100_000_000_000 ? n / 1000 : n)
        }
        return d
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(fractional.string(from: date))
        }
        return e
    }

    // MARK: Export

    static func buildExport(_ prompts: [Prompt]) throws -> Data {
        let file = ExportFile(
            schema: schema,
            version: version,
            exportedAt: fractional.string(from: Date()),
            count: prompts.count,
            prompts: prompts
        )
        return try encoder().encode(file)
    }

    // MARK: Import

    /// 解析导出文件；同时接受 Raycast LocalStorage 里的「裸数组」旧格式
    static func parse(_ data: Data) throws -> [Prompt] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TransferError(message: L("文件不是合法的 JSON", "File is not valid JSON"))
        }

        let items: [Any]
        if let array = root as? [Any] {
            items = array
        } else if let obj = root as? [String: Any] {
            guard obj["$schema"] as? String == schema else {
                throw TransferError(message: L("不是 Prompt Slash / Prompt Stash 导出文件", "Not a Prompt Slash / Prompt Stash export file"))
            }
            guard let v = obj["version"] as? Int, v <= version else {
                let v = obj["version"].map { "\($0)" } ?? "?"
                throw TransferError(message: L("不支持的导出版本：\(v)", "Unsupported export version: \(v)"))
            }
            guard let prompts = obj["prompts"] as? [Any] else {
                throw TransferError(message: L("导出文件缺少 prompts 数组", "Export file is missing the prompts array"))
            }
            items = prompts
        } else {
            throw TransferError(message: L("导出文件结构无效", "Invalid export file structure"))
        }

        let dec = decoder()
        var seen = Set<String>()
        var result: [Prompt] = []
        for item in items {
            guard JSONSerialization.isValidJSONObject(item),
                  let itemData = try? JSONSerialization.data(withJSONObject: item),
                  let prompt = try? dec.decode(Prompt.self, from: itemData),
                  !seen.contains(prompt.id)
            else { continue }
            seen.insert(prompt.id)
            result.append(prompt)
        }
        if result.isEmpty {
            throw TransferError(message: L("导出文件中没有有效的提示词", "Export file does not contain any valid prompts"))
        }
        return result
    }

    static func merge(existing: [Prompt], imported: [Prompt], strategy: ImportStrategy) -> ([Prompt], ImportResult) {
        var merged = existing
        var result = ImportResult()
        let existingIDs = Set(existing.map(\.id))
        let base = Int64(Date().timeIntervalSince1970 * 1000)

        for (i, prompt) in imported.enumerated() {
            if existingIDs.contains(prompt.id) {
                switch strategy {
                case .replace:
                    if let idx = merged.firstIndex(where: { $0.id == prompt.id }) {
                        merged[idx] = prompt
                    }
                    result.replaced += 1
                case .duplicate:
                    var copy = prompt
                    copy.id = "\(base)-\(i)"
                    merged.append(copy)
                    result.added += 1
                case .skip:
                    result.skipped += 1
                }
            } else {
                merged.append(prompt)
                result.added += 1
            }
        }
        return (merged, result)
    }
}

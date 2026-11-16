import Foundation

/// The OpenCode Go allowance, as the gateway reports it for the owner's key: a five-hour rolling
/// window, a week and a month, each a percentage of what the plan includes, whether it is exhausted,
/// and when it starts again. The endpoint is the one the OpenCode Console itself reads.
struct ZenUsage: Sendable, Equatable {
    struct Meter: Sendable, Equatable {
        /// 0…100 of the window's allowance used.
        var percent: Double
        /// The plan refuses requests in this window until it resets.
        var limited: Bool
        var resetsAt: Date?
    }

    var rolling: Meter?
    var weekly: Meter?
    var monthly: Meter?

    /// A window is at least a label, a meter and a reset line.
    struct Window: Sendable, Equatable, Identifiable {
        var id: String { title }
        var title: String
        var meter: Meter
    }

    var windows: [Window] {
        [rolling.map { Window(title: "5 小时", meter: $0) },
         weekly.map { Window(title: "每周", meter: $0) },
         monthly.map { Window(title: "每月", meter: $0) }].compactMap { $0 }
    }

    /// Reads the allowance with the owner's key: `GET /zen/go/v1/usage` answers
    /// `{"usage":{"rolling":{"status":"ok","percent":12.5,"resetsAt":"2026-11-16T20:00:00Z"}, …}}`.
    static func fetch(key: String) async throws -> ZenUsage {
        guard let url = URL(string: "\(ModelProvider.huishangBaseURL)/usage") else { throw ZenUsageError.unreachable }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        for (name, value) in HuishangClient.headers(key: key, session: "poki-usage") {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ZenUsageError.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ZenUsageError.http(status) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ZenUsageError.shape
        }
        let usage = (object["usage"] as? [String: Any]) ?? object
        let result = ZenUsage(rolling: meter(usage["rolling"]), weekly: meter(usage["weekly"]), monthly: meter(usage["monthly"]))
        guard result.rolling != nil || result.weekly != nil || result.monthly != nil else { throw ZenUsageError.shape }
        return result
    }

    private static func meter(_ value: Any?) -> Meter? {
        guard let object = value as? [String: Any] else { return nil }
        let percent: Double
        if let number = object["percent"] as? Double {
            percent = number
        } else if let number = object["percent"] as? Int {
            percent = Double(number)
        } else if let used = object["used"] as? Double, let limit = object["limit"] as? Double, limit > 0 {
            percent = used / limit * 100
        } else {
            percent = 0
        }
        let status = (object["status"] as? String) ?? ""
        var resetsAt: Date?
        if let text = object["resetsAt"] as? String {
            resetsAt = iso(text)
        } else if let milliseconds = object["resetsAt"] as? Double {
            resetsAt = Date(timeIntervalSince1970: milliseconds / 1000)
        }
        return Meter(percent: min(max(percent, 0), 100), limited: status == "rate-limited", resetsAt: resetsAt)
    }

    /// The gateway sends an ISO 8601 time, with or without a fraction of a second.
    private static func iso(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

/// Why the allowance could not be read, worded for the owner.
enum ZenUsageError: LocalizedError, Equatable {
    case http(Int)
    case shape
    case unreachable

    var errorDescription: String? {
        switch self {
        case .http(401), .http(403):
            return "这个密钥读不到额度：额度属于 OpenCode Console 里的工作区（Go 订阅或按量额度）。"
        case .http(let status):
            return "读取额度时网关返回了 \(status)。"
        case .shape:
            return "网关的额度格式和预期不一样。"
        case .unreachable:
            return "连不上网关，检查一下网络或代理。"
        }
    }
}

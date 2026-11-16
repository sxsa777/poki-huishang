import Foundation
import PokiCore

/// OpenCode Zen (opencode.ai/zen/go/v1) over plain HTTPS with the owner's key, in the chat completions
/// form the gateway translates for every model it lists.
///
/// The gateway serves paid models and an OpenCode Go plan to coding agents, and reads a client by its
/// user agent and by the conversation id in `x-opencode-session` (a request without it is refused
/// before it reaches a model). Poki sends its own agent name and build, one id per conversation, and
/// the same shape of step an agent sends: instructions, tools and their answers.
@MainActor
final class HuishangClient: ModelClient {
    let key: String
    let model: String
    /// The conversation at the gateway: the same for every step of one chat, so the gateway can route
    /// and cache it.
    let session: String
    /// The conversation in the chat API's form: what the model sent goes back unchanged.
    private var messages: [[String: Any]] = []

    static let base = URL(string: "https://opencode.ai/zen/go/v1")!

    /// The client's name and build, as the gateway asks a client to identify itself: a coding agent's
    /// own user agent, not an SDK's or a browser's.
    static var agent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "poki-agent/\(version) (iPhone; Poki)"
    }

    /// What every request carries: the key, that user agent, and the conversation's id.
    static func headers(key: String, session: String) -> [String: String] {
        ["authorization": "Bearer \(key)", "user-agent": agent, "x-opencode-session": session, "accept": "application/json"]
    }

    init(key: String, model: String, session: String) {
        self.key = key
        self.model = model
        self.session = session
    }

    var signature: String { "huishang/\(model)/\(session)" }

    func say(_ text: String) {
        messages.append(["role": "user", "content": text])
    }

    func answer(_ call: ToolCall, _ result: PokiCore.ToolAnswer) {
        messages.append(["role": "tool", "tool_call_id": call.id, "content": result.text])
        // The screen the tool took, in the turn after it: a tool result's own pictures are not part of
        // the chat API, and a user turn's are what every model behind the gateway reads.
        if let jpeg = result.jpeg {
            messages.append(["role": "user", "content": [
                ["type": "text", "text": "The screen the tool just read:"],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]],
            ]])
        }
    }

    func forgetUnansweredQuestion() {
        if messages.last?["role"] as? String == "user", messages.last?["content"] is String { messages.removeLast() }
    }

    func next(instructions: String, tools: [ToolSpec]) async throws -> ModelTurn {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": instructions]] + messages,
            "max_tokens": 16000,
            "stream": false,
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema]] }
            body["tool_choice"] = "auto"
        }
        let (status, json, data) = try await postJSON(Self.base.appending(path: "chat/completions"),
                                                     headers: Self.headers(key: key, session: session), body: body,
                                                     key: key, provider: "OpenCode Zen")
        guard (200..<300).contains(status), let json,
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw ModelFailure(errorDescription: Self.words(status: status, json: json, data: data, key: key))
        }
        messages.append(message)
        var texts: [String] = []
        if let text = message["content"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { texts.append(trimmed) }
        } else if let parts = message["content"] as? [[String: Any]] {
            for part in parts where part["type"] as? String == "text" {
                if let text = (part["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { texts.append(text) }
            }
        }
        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { call -> ToolCall? in
            guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
            let arguments = (function["arguments"] as? String)
                ?? (function["arguments"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }).map { String(decoding: $0, as: UTF8.self) }
                ?? "{}"
            return ToolCall(id: call["id"] as? String ?? "", name: name, arguments: arguments)
        }
        let ending: ModelTurn.Ending = switch choice["finish_reason"] as? String {
        case "tool_calls", "function_call": .tools
        case "length": .cutOff
        case "content_filter": .refused
        default: calls.isEmpty ? .done : .tools
        }
        return ModelTurn(texts: texts, calls: calls, ending: ending)
    }

    /// The gateway's answer, worded for the owner, with the key replaced wherever it repeats it. A
    /// gateway that asks for the session header gets a word of its own: without it nothing reaches a
    /// model, and the owner would otherwise read a bare 400.
    private static func words(status: Int, json: [String: Any]?, data: Data, key: String) -> String {
        let text = apiErrorText(json, data, key: key)
        if text.localizedCaseInsensitiveContains("MissingSessionID") || text.contains("x-opencode-session") {
            return "网关拒绝了这次请求：缺少 x-opencode-session。请重新选一次模型再试；若仍出现，把这条错误发给我。"
        }
        return switch status {
        case 401, 403: "会上数的羊没有接受这个密钥。到 设置 › 模型 里检查一下。"
        case 402: "这个密钥没有余额了。到 OpenCode Console 检查账单。"
        case 404: "这个密钥用不了 \(ModelKeys.selectedModelName)。换一个模型试试。"
        case 429: "网关说这个密钥触发了速率限制，过一分钟再试。"
        default: "会上数的羊返回了 \(status)，\(text)"
        }
    }
}

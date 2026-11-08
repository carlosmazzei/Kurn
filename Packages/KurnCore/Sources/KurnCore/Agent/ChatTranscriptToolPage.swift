import AgentHarness
import Foundation

/// Lossless passage pagination. A partial passage continues at the same passage offset
/// with a scalar offset; advancing to the next passage would lose its unread suffix.
enum ChatTranscriptToolPage {
    struct InvalidOffset: Error {}

    static func output(_ page: ChatTranscriptPage, offset: Int, textOffset: Int,
                       maxBytes: Int = ChatSourceTools.maxOutputBytes) throws -> AgentToolOutput {
        var body = "transcript:\n"
        var nextPassage = offset
        var nextText = 0
        var available = 0
        var returned = 0
        for (index, passage) in page.passages.enumerated() {
            let scalars = passage.text.unicodeScalars
            let start = index == 0 ? textOffset : 0
            guard start <= scalars.count else { throw InvalidOffset() }
            available += scalars.count - start
            let heading = "meeting \(passage.meetingID.uuidString):\n"
                + "\(ChatSourceToolText.timestamp(passage.timestamp)) \(ChatSourceToolText.field(passage.speaker, limit: 100)): "
            let room = maxBytes - body.utf8.count - heading.utf8.count - 200
            if room <= 0 { break }
            var chunk = String.UnicodeScalarView()
            var bytes = 0
            for scalar in scalars.dropFirst(start).prefix(max(0, 8_000 - returned)) {
                let size = scalar.utf8.count
                guard bytes + size <= room else { break }
                chunk.append(scalar)
                bytes += size
            }
            guard !chunk.isEmpty || start == scalars.count else { break }
            body += heading + String(chunk) + "\n"
            returned += chunk.count
            if start + chunk.count < scalars.count {
                nextText = start + chunk.count
                break
            }
            nextPassage += 1
            if returned >= 8_000 { break }
        }
        let more = nextText > 0 || nextPassage < page.total
        guard !more || nextPassage > offset || nextText > textOffset else { throw InvalidOffset() }
        let continuation = more ? "next offset: \(nextPassage); textOffset: \(nextText)" : "end"
        body += "page: \(continuation); total passages: \(page.total)"
        return AgentToolOutput(content: body, summary: "Read \(returned) characters",
                               metrics: [.availableScalars: available, .returnedScalars: returned, .hasMore: more ? 1 : 0])
    }
}

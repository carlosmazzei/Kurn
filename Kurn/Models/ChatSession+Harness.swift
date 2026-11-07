import Foundation
import KurnCore

extension ChatSession {
    func harnessSnapshot() throws -> (scope: ChatSourceScope?, artifacts: [ChatDocumentArtifact]) {
        var scope: ChatSourceScope?
        var artifacts: [ChatDocumentArtifact] = []
        if let scopeData {
            guard let decoded = JSONStorage.decodeAuthoritative(ChatSourceScope.self, from: scopeData).decodedValue else {
                throw AppError.apiError(statusCode: 0, message: "Invalid saved chat scope.")
            }
            scope = decoded
        }
        if let artifactsData {
            guard let decoded = JSONStorage.decodeAuthoritative([ChatDocumentArtifact].self, from: artifactsData).decodedValue else {
                throw AppError.apiError(statusCode: 0, message: "Invalid saved chat artifacts.")
            }
            artifacts = decoded
        }
        return (scope, artifacts)
    }
}

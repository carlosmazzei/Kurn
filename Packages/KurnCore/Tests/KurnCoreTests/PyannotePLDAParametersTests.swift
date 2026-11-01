import Foundation
import Testing
@testable import KurnCore

struct PyannotePLDAParametersTests {
    @Test func decodesThePublishedPsiFieldAsLittleEndianFloat32WithoutChangingValues() throws {
        let values = (0..<128).map { Float($0) * 0.25 }
        let decoded = try PyannotePLDAParameters.decodePsi(PLDATestJSON.data(values: values))
        #expect(decoded == values.map(Double.init))
        #expect(decoded.count == PyannotePLDAParameters.dimension)
    }

    @Test func rejectsMalformedJSONAndMissingOrWrongFields() throws {
        for document in ["invalid", "[]", "{}", "{\"tensors\":{}}", "{\"tensors\":{\"psi\":{}}}",
                         "{\"tensors\":{\"psi\":{\"data_base64\":42}}}"] {
            #expect(throws: PyannotePLDAParameters.Failure.invalidDocument) {
                try PyannotePLDAParameters.decodePsi(Data(document.utf8))
            }
        }
    }

    @Test func rejectsInvalidBase64AndIncorrectFloatCounts() throws {
        for base64 in ["%%%", "", Data(repeating: 0, count: 511).base64EncodedString(),
                       Data(repeating: 0, count: 513).base64EncodedString()] {
            let json = try PLDATestJSON.data(base64: base64)
            #expect(throws: PyannotePLDAParameters.Failure.invalidTensor) {
                try PyannotePLDAParameters.decodePsi(json)
            }
        }
        for count in [127, 129] {
            let json = try PLDATestJSON.data(values: [Float](repeating: 1, count: count))
            #expect(throws: PyannotePLDAParameters.Failure.invalidTensor) {
                try PyannotePLDAParameters.decodePsi(json)
            }
        }
    }

    @Test func refusesNonFiniteValuesInsteadOfInventingReplacementParameters() throws {
        for value: Float in [.nan, .infinity, -.infinity] {
            var values = [Float](repeating: 0.5, count: 128)
            values[27] = value
            let json = try PLDATestJSON.data(values: values)
            #expect(throws: PyannotePLDAParameters.Failure.nonFiniteValue) {
                try PyannotePLDAParameters.decodePsi(json)
            }
        }
    }
}

enum PLDATestJSON {
    static func data(values: [Float] = [Float](repeating: 0.5, count: 128)) throws -> Data {
        var bytes = Data()
        for value in values {
            var littleEndian = value.bitPattern.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
        }
        return try data(base64: bytes.base64EncodedString())
    }

    static func data(base64: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tensors": ["psi": ["data_base64": base64]]])
    }
}

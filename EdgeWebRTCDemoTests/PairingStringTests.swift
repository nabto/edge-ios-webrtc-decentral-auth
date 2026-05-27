import Testing
@testable import EdgeWebRTCDemo

@Suite("parsePairingString")
struct PairingStringTests {

    // MARK: - Happy paths

    @Test("Parses the user's 5-element string with fingerprint and no username")
    func realWorldFiveElementsWithFingerprint() throws {
        let raw = "p=pr-3ggk9wja,d=de-xn3vb3rr,pwd=HkfHYoxtCpTb,sct=QtfgwYkjnnm5,fp=2f121d67bc70a5b4c5684b38aa868b82f314742d71a67b5f6a84f31fcd1da9b6"

        let details = try parsePairingString(raw)

        #expect(details.productId == "pr-3ggk9wja")
        #expect(details.deviceId == "de-xn3vb3rr")
        #expect(details.password == "HkfHYoxtCpTb")
        #expect(details.sct == "QtfgwYkjnnm5")
        #expect(details.username == nil)
        #expect(details.deviceFingerprint == "2f121d67bc70a5b4c5684b38aa868b82f314742d71a67b5f6a84f31fcd1da9b6")
    }

    @Test("Parses the 6-element string with u= and fp=")
    func realWorldSixElementsWithUsernameAndFingerprint() throws {
        let raw = "p=pr-3ggk9wja,d=de-xn3vb3rr,u=admin,pwd=Ete7VhbuEYbr,sct=DKYFc9ufHYwH,fp=2f121d67bc70a5b4c5684b38aa868b82f314742d71a67b5f6a84f31fcd1da9b6"

        let details = try parsePairingString(raw)

        #expect(details.productId == "pr-3ggk9wja")
        #expect(details.deviceId == "de-xn3vb3rr")
        #expect(details.username == "admin")
        #expect(details.password == "Ete7VhbuEYbr")
        #expect(details.sct == "DKYFc9ufHYwH")
        #expect(details.deviceFingerprint == "2f121d67bc70a5b4c5684b38aa868b82f314742d71a67b5f6a84f31fcd1da9b6")
    }

    @Test("Parses minimal p,d-only string")
    func minimalProductAndDevice() throws {
        let details = try parsePairingString("p=pr-abc,d=de-xyz")
        #expect(details.productId == "pr-abc")
        #expect(details.deviceId == "de-xyz")
        #expect(details.password == nil)
        #expect(details.sct == nil)
        #expect(details.username == nil)
        #expect(details.deviceFingerprint == nil)
    }

    @Test(
        "Accepts all three separators",
        arguments: [
            "p=pr-a,d=de-b,pwd=secret",
            "p=pr-a;d=de-b;pwd=secret",
            "p=pr-a:d=de-b:pwd=secret",
        ]
    )
    func separators(raw: String) throws {
        let details = try parsePairingString(raw)
        #expect(details.productId == "pr-a")
        #expect(details.deviceId == "de-b")
        #expect(details.password == "secret")
    }

    @Test("Trims whitespace around each element")
    func whitespaceBetweenElements() throws {
        let raw = " p=pr-a , d=de-b , pwd=secret "
        let details = try parsePairingString(raw)
        #expect(details.productId == "pr-a")
        #expect(details.deviceId == "de-b")
        #expect(details.password == "secret")
    }

    @Test("Skips empty elements (trailing comma)")
    func skipsEmptyElements() throws {
        let details = try parsePairingString("p=pr-a,d=de-b,,pwd=secret,")
        #expect(details.productId == "pr-a")
        #expect(details.deviceId == "de-b")
        #expect(details.password == "secret")
    }

    @Test("Value containing '=' is preserved (only first '=' is the separator)")
    func equalsInValue() throws {
        let details = try parsePairingString("p=pr-a,d=de-b,pwd=abc=def=ghi")
        #expect(details.password == "abc=def=ghi")
    }

    // MARK: - Error paths

    @Test("Empty string throws .empty")
    func emptyString() {
        #expect(throws: PairingStringError.self) { try parsePairingString("") }
    }

    @Test("Whitespace-only string throws .empty")
    func whitespaceOnly() {
        #expect(throws: PairingStringError.self) { try parsePairingString("   ") }
    }

    @Test("Missing '=' throws .missingEquals")
    func missingEquals() {
        #expect(throws: PairingStringError.self) {
            try parsePairingString("p=pr-a,nokey,d=de-b")
        }
    }

    @Test("Unknown key throws .unknownElement")
    func unknownKey() {
        #expect(throws: PairingStringError.self) {
            try parsePairingString("p=pr-a,d=de-b,xyz=bad")
        }
    }

    @Test("Missing p throws .missingRequiredField")
    func missingProduct() {
        #expect(throws: PairingStringError.self) {
            try parsePairingString("d=de-b,pwd=secret")
        }
    }

    @Test("Missing d throws .missingRequiredField")
    func missingDevice() {
        #expect(throws: PairingStringError.self) {
            try parsePairingString("p=pr-a,pwd=secret")
        }
    }
}

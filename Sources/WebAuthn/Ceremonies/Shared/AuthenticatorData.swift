//===----------------------------------------------------------------------===//
//
// This source file is part of the WebAuthn Swift open source project
//
// Copyright (c) 2022 the WebAuthn Swift project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of WebAuthn Swift project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import Crypto
import SwiftCBOR

/// Data created and/ or used by the authenticator during authentication/ registration.
/// The data contains, for example, whether a user was present or verified.
struct AuthenticatorData: Equatable {
    let relyingPartyIDHash: [UInt8]
    let flags: AuthenticatorFlags
    let counter: UInt32
    /// For attestation signatures this value will be set. For assertion signatures not.
    let attestedData: AttestedCredentialData?
    let extData: [UInt8]?
}

extension AuthenticatorData {
    init(bytes: Data) throws {
        let minAuthDataLength = 37
        guard bytes.count >= minAuthDataLength else {
            throw WebAuthnError.authDataTooShort
        }

        let relyingPartyIDHash = Array(bytes[..<32])
        let flags = AuthenticatorFlags(bytes[32])
        let counter: UInt32 = Data(bytes[33..<37]).toInteger(endian: .big)

        var remainingCount = bytes.count - minAuthDataLength

        var attestedCredentialData: AttestedCredentialData?
        // For attestation signatures, the authenticator MUST set the AT flag and include the attestedCredentialData.
        if flags.attestedCredentialData {
            let minAttestedAuthLength = 55
            guard bytes.count > minAttestedAuthLength else {
                throw WebAuthnError.attestedCredentialDataMissing
            }
            let (data, length) = try Self.parseAttestedData(bytes)
            attestedCredentialData = data
            remainingCount -= length
        // For assertion signatures, the AT flag MUST NOT be set and the attestedCredentialData MUST NOT be included.
        } else {
            if !flags.extensionDataIncluded && bytes.count != minAuthDataLength {
                throw WebAuthnError.attestedCredentialFlagNotSet
            }
        }

        var extensionData: [UInt8]?
        if flags.extensionDataIncluded {
            guard remainingCount != 0 else {
                throw WebAuthnError.extensionDataMissing
            }
            extensionData = Array(bytes[(bytes.count - remainingCount)...])
            remainingCount -= extensionData!.count
        }

        guard remainingCount == 0 else {
            throw WebAuthnError.leftOverBytesInAuthenticatorData
        }

        self.relyingPartyIDHash = relyingPartyIDHash
        self.flags = flags
        self.counter = counter
        self.attestedData = attestedCredentialData
        self.extData = extensionData

    }

    /// Returns: Attested credentials data and the length
    private static func parseAttestedData(_ data: Data) throws -> (AttestedCredentialData, Int) {
        // We've parsed the first 37 bytes so far, the next bytes now should be the attested credential data
        // See https://w3c.github.io/webauthn/#sctn-attested-credential-data
        let aaguidLength = 16
        let aaguid = data[37..<(37 + aaguidLength)]  // To byte at index 52

        let idLengthBytes = data[53..<55]  // Length is 2 bytes
        let idLengthData = Data(idLengthBytes)
        let idLength: UInt16 = idLengthData.toInteger(endian: .big)
        let credentialIDEndIndex = Int(idLength) + 55

        guard data.count >= credentialIDEndIndex else {
            throw WebAuthnError.credentialIDTooShort
        }
        let credentialID = data[55..<credentialIDEndIndex]

        /// **credentialPublicKey** (variable): The credential public key encoded in COSE_Key format, as defined in Section 7 of [RFC9052], using the CTAP2 canonical CBOR encoding form.
        /// Assuming valid CBOR, verify the public key's length by decoding the next CBOR item.
        let inputStream = ByteInputStream(data[credentialIDEndIndex...])
        let decoder = CBORDecoder(stream: inputStream)
        _ = try decoder.decodeItem()
        let publicKeyBytes = data[credentialIDEndIndex..<(data.count - inputStream.remainingBytes)]

        let data = AttestedCredentialData(
            aaguid: Array(aaguid),
            credentialID: Array(credentialID),
            publicKey: Array(publicKeyBytes)
        )

        // 2 is the bytes storing the size of the credential ID
        let length = data.aaguid.count + 2 + data.credentialID.count + data.publicKey.count

        return (data, length)
    }
}

/// A helper type to determine how many bytes were consumed when decoding CBOR items.
class ByteInputStream: CBORInputStream {
    private var slice : ArraySlice<UInt8>
    
    init(_ slice: Data) {
        self.slice = Array(slice)[...]
    }
    
    /// The remaining bytes in the original data buffer.
    var remainingBytes: Int { slice.count }
    
    func popByte() throws -> UInt8 {
        if slice.count < 1 { throw CBORError.unfinishedSequence }
        return slice.removeFirst()
    }
    
    func popBytes(_ n: Int) throws -> ArraySlice<UInt8> {
        if slice.count < n { throw CBORError.unfinishedSequence }
        let result = slice.prefix(n)
        slice = slice.dropFirst(n)
        return result
    }
}

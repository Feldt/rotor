import CommonCrypto
import Foundation

/// macOS Chromium / Electron safeStorage ("OSCrypt v10") decryption. The app stores
/// `oauth:tokenCacheV2` as a `v10`-prefixed blob encrypted with a key derived from the
/// "Claude Safe Storage" Keychain password. We only ever decrypt, never encrypt, in the app.
///
/// Scheme (Chromium OSCryptImpl, macOS): PBKDF2-HMAC-SHA1(password, "saltysalt", 1003, 16 bytes)
/// → AES-128-CBC, IV = 16 spaces, PKCS7, after stripping the 3-byte "v10" prefix.
public enum OSCrypt {
    public static let salt = "saltysalt"
    public static let iterations: UInt32 = 1003
    public static let keyLength = 16
    public static let prefix = "v10"
    static let iv = [UInt8](repeating: 0x20, count: 16)  // 16 spaces

    public enum Failure: Error, Equatable { case notEncrypted, badKey, decryptFailed }

    /// PBKDF2-HMAC-SHA1. `password` is the Keychain secret bytes; never logged.
    public static func deriveKey(password: Data) -> Data {
        var key = [UInt8](repeating: 0, count: keyLength)
        let saltBytes = Array(salt.utf8)
        _ = password.withUnsafeBytes { pw in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 pw.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                                 saltBytes, saltBytes.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), iterations,
                                 &key, keyLength)
        }
        return Data(key)
    }

    /// Encrypt, used only by tests (synthetic data). Produces a `v10` blob like the app's.
    public static func encrypt(_ plaintext: Data, key: Data) throws -> Data {
        let out = try crypt(operation: CCOperation(kCCEncrypt), input: [UInt8](plaintext), key: key)
        return Data(prefix.utf8) + Data(out)
    }

    /// Strip the `v10` prefix and AES-128-CBC decrypt.
    public static func decrypt(_ blob: Data, key: Data) throws -> Data {
        guard blob.count > 3, String(decoding: blob.prefix(3), as: UTF8.self) == prefix else {
            throw Failure.notEncrypted
        }
        guard key.count == keyLength else { throw Failure.badKey }
        let out = try crypt(operation: CCOperation(kCCDecrypt), input: [UInt8](blob.dropFirst(3)), key: key)
        return Data(out)
    }

    /// Convenience: derive the key from `password` and decrypt a base64 or raw blob string.
    public static func decryptBlobString(_ s: String, password: Data) throws -> Data {
        let blob = Data(base64Encoded: s) ?? Data(s.utf8)
        return try decrypt(blob, key: deriveKey(password: password))
    }

    static func crypt(operation: CCOperation, input: [UInt8], key: Data) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = key.withUnsafeBytes { k in
            CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    k.baseAddress, key.count, iv, input, input.count, &out, out.count, &moved)
        }
        guard status == kCCSuccess else { throw Failure.decryptFailed }
        return Array(out.prefix(moved))
    }
}

/// The "Claude Safe Storage" Keychain secret. `SecItemCopyMatching` triggers the system prompt
/// once; "Always Allow" makes it silent until the app is re-signed. The value is never logged.
public enum KeychainError: Error, Equatable {
    /// No "Claude Safe Storage" item.
    case missing
    /// The user denied access, or the read failed (OSStatus, not a secret).
    case denied(OSStatus)
}

public protocol SafeStoragePassword: Sendable {
    func password() throws -> Data
}

public struct KeychainPassword: SafeStoragePassword {
    public let service: String
    public init(service: String = "Claude Safe Storage") { self.service = service }

    public func password() throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        query.removeAll()
        if status == errSecItemNotFound { throw KeychainError.missing }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError.denied(status) }
        return data
    }
}

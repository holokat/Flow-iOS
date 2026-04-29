import Foundation

struct EditableProfileFields: Equatable, Sendable {
    var avatarURLString: String
    var bannerURLString: String
    var displayName: String
    var handle: String
    var about: String
    var website: String
    var nip05: String
    var lightningAddress: String

    init(
        avatarURLString: String = "",
        bannerURLString: String = "",
        displayName: String = "",
        handle: String = "",
        about: String = "",
        website: String = "",
        nip05: String = "",
        lightningAddress: String = ""
    ) {
        self.avatarURLString = avatarURLString
        self.bannerURLString = bannerURLString
        self.displayName = displayName
        self.handle = handle
        self.about = about
        self.website = website
        self.nip05 = nip05
        self.lightningAddress = lightningAddress
    }

    init(profile: NostrProfile?) {
        self.avatarURLString = profile?.picture?.trimmed ?? ""
        self.bannerURLString = profile?.banner?.trimmed ?? ""
        self.displayName = profile?.displayName?.trimmed ?? profile?.name?.trimmed ?? ""
        self.handle = profile?.name?.trimmed ?? ""
        self.about = profile?.about?.trimmed ?? ""
        self.website = profile?.website?.trimmed ?? ""
        self.nip05 = profile?.nip05?.trimmed ?? ""
        self.lightningAddress = profile?.lightningAddress?.trimmed ?? ""
    }
}

enum EditableProfileFieldsError: LocalizedError {
    case invalidNostrAddress
    case invalidLightningAddress

    var errorDescription: String? {
        switch self {
        case .invalidNostrAddress:
            return "Enter a valid NIP-05 address or leave it blank."
        case .invalidLightningAddress:
            return "Enter a valid lightning address/LNURL or leave it blank."
        }
    }
}

enum ProfileMetadataEditing {
    static func mergedContent(fields: EditableProfileFields, baseJSON: [String: Any]) throws -> String {
        let normalizedDisplayName = fields.displayName.trimmed
        let normalizedHandle = normalizeHandle(fields.handle)
        let normalizedLightning = normalizeLightningAddress(fields.lightningAddress)
        let normalizedNip05 = fields.nip05.trimmed
        let normalizedAvatarURL = fields.avatarURLString.trimmed
        let normalizedBannerURL = fields.bannerURLString.trimmed

        if !normalizedNip05.isEmpty, !isEmail(normalizedNip05) {
            throw EditableProfileFieldsError.invalidNostrAddress
        }

        if !normalizedLightning.isEmpty, !isEmail(normalizedLightning), !isLNURL(normalizedLightning) {
            throw EditableProfileFieldsError.invalidLightningAddress
        }

        var updated = baseJSON
        updated["display_name"] = normalizedDisplayName
        updated["displayName"] = normalizedDisplayName
        if normalizedHandle.isEmpty {
            updated.removeValue(forKey: "name")
        } else {
            updated["name"] = normalizedHandle
        }
        updated["about"] = fields.about.trimmed
        updated["website"] = fields.website.trimmed
        updated["nip05"] = normalizedNip05
        if normalizedAvatarURL.isEmpty {
            updated.removeValue(forKey: "picture")
        } else {
            updated["picture"] = normalizedAvatarURL
        }
        if normalizedBannerURL.isEmpty {
            updated.removeValue(forKey: "banner")
        } else {
            updated["banner"] = normalizedBannerURL
        }

        updated.removeValue(forKey: "gallery")
        updated.removeValue(forKey: "lud16")
        updated.removeValue(forKey: "lud06")

        if isEmail(normalizedLightning) {
            updated["lud16"] = normalizedLightning
        } else if isLNURL(normalizedLightning) {
            updated["lud06"] = normalizedLightning
        }

        let data = try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys])
        guard let content = String(data: data, encoding: .utf8) else {
            throw RelayClientError.publishRejected("Malformed profile metadata")
        }
        return content
    }

    static func normalizeLightningAddress(_ value: String?) -> String {
        guard let value else { return "" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let prefix = "lightning:"
        if trimmed.lowercased().hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    static func normalizeHandle(_ value: String?) -> String {
        guard let value else { return "" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.hasPrefix("@") {
            return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    static func isEmail(_ value: String) -> Bool {
        value.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
    }

    static func isLNURL(_ value: String) -> Bool {
        value.range(of: #"^lnurl[0-9a-z]+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func normalizedWebsiteURL(from value: String?) -> URL? {
        guard let trimmed = value?.trimmed, !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(trimmed)")
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        return string
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

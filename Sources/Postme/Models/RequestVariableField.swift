import Foundation

enum RequestVariableField: Hashable {
    enum Table: Hashable {
        case headers, query, path, form, files, cookies
    }

    enum Column: Hashable {
        case name, value
    }

    case url, body, rawContentType, binaryContentType, binaryPath
    case bearerToken, username, password, apiKeyName, apiKeyValue
    case row(Table, UUID, Column)

    var section: RequestSection? {
        switch self {
        case .url: return nil
        case .body, .rawContentType, .binaryContentType, .binaryPath, .row(.form, _, _), .row(.files, _, _): return .body
        case .bearerToken, .username, .password, .apiKeyName, .apiKeyValue: return .auth
        case .row(.headers, _, _): return .headers
        case .row(.query, _, _), .row(.path, _, _): return .params
        case .row(.cookies, _, _): return .cookies
        }
    }

    var scrollAnchor: RequestVariableField {
        if case .row(let table, let id, _) = self { return .row(table, id, .name) }
        return self
    }
}

struct MissingRequestVariable: Hashable {
    let name: String
    let field: RequestVariableField
}

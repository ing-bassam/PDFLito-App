import UIKit

/// One line of text found by the on-device text recognition.
struct RecognizedLine: Hashable {
    var text: String
    /// Normalized bounding box (0…1), origin bottom-left like Vision and PDF.
    var box: CGRect
    var confidence: Float
}

enum QualityVerdict: Equatable {
    case good
    case littleText
    case blurry
    case unreadable
    case tooDark

    var isAcceptable: Bool {
        self == .good || self == .littleText
    }

    var title: String {
        switch self {
        case .good: return "Gut lesbar"
        case .littleText: return "Wenig Text"
        case .blurry: return "Unscharf"
        case .unreadable: return "Schwer lesbar"
        case .tooDark: return "Zu dunkel"
        }
    }

    var detail: String {
        switch self {
        case .good: return "Die Seite ist scharf und gut lesbar."
        case .littleText: return "Die Seite ist scharf, enthält aber kaum Text."
        case .blurry: return "Die Seite ist verwackelt oder unscharf. Bitte mit ruhiger Hand neu scannen."
        case .unreadable: return "Der Text ist kaum lesbar. Bitte bei besserem Licht neu scannen."
        case .tooDark: return "Die Seite ist zu dunkel. Bitte bei mehr Licht neu scannen."
        }
    }

    var symbol: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .littleText: return "checkmark.circle"
        case .blurry, .unreadable, .tooDark: return "exclamationmark.triangle.fill"
        }
    }
}

struct PageAnalysis {
    var lines: [RecognizedLine]
    /// Edge sharpness (higher is sharper); nil when the page has too few edges to judge.
    var sharpness: Double?
    var brightness: Double
    var characterCount: Int
    var meanConfidence: Double
    var verdict: QualityVerdict
}

struct ScanPage: Identifiable {
    let id = UUID()
    /// JPEG copy of the camera image, upright and limited in size.
    let imageData: Data
    let thumbnail: UIImage
    var analysis: PageAnalysis?
    /// The user chose to keep a page that failed the quality check.
    var keepAnyway = false

    var isRejected: Bool {
        guard let analysis else { return false }
        return !analysis.verdict.isAcceptable && !keepAnyway
    }

    var isIncluded: Bool {
        analysis != nil && !isRejected
    }
}

enum ScanError: LocalizedError {
    case nothingToSave
    case noFolder
    case folderUnavailable

    var errorDescription: String? {
        switch self {
        case .nothingToSave: return "Es gibt keine gut lesbare Seite zum Speichern."
        case .noFolder: return "Bitte zuerst in den Einstellungen einen Ordner wählen."
        case .folderUnavailable: return "Der gewählte Ordner ist nicht erreichbar. Bitte in den Einstellungen neu wählen."
        }
    }
}

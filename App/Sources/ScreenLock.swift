import CoreGraphics
import Foundation

/// Companion must not auto-start a recording on a locked Mac.
enum ScreenLock {
    static var isLocked: Bool {
        guard let cf = CGSessionCopyCurrentDictionary() else { return false }
        let dict = cf as NSDictionary
        if let number = dict["CGSSessionScreenIsLocked"] as? NSNumber {
            return number.boolValue
        }
        if let flag = dict["CGSSessionScreenIsLocked"] as? Bool {
            return flag
        }
        return false
    }
}

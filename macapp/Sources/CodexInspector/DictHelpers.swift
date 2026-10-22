import Foundation

/// Safely read optional fields from the Rust engine's JSON snapshots. Missing
/// log evidence remains optional; views decide how to present unavailable data.
extension Dictionary where Key == String, Value == Any {
  func str(_ key: String) -> String? { self[key] as? String }
  func int(_ key: String) -> Int? {
    if let v = self[key] as? Int { return v }
    if let v = self[key] as? NSNumber { return v.intValue }
    return nil
  }
  func bool(_ key: String) -> Bool? { self[key] as? Bool }
  func dictArray(_ key: String) -> [[String: Any]] { (self[key] as? [[String: Any]]) ?? [] }
  func subDict(_ key: String) -> [String: Any] { (self[key] as? [String: Any]) ?? [:] }
  func stringArray(_ key: String) -> [String] { (self[key] as? [String]) ?? [] }
}

import AppKit
import CryptoKit
import Foundation

// Standalone launcher support. No image decoding, user input injection or
// AppleScript permission. Writes only the requested app's preference domain.
let args = CommandLine.arguments
guard args.count >= 3 else { exit(2) }
let command = args[1], appURL = URL(fileURLWithPath: args[2]).standardizedFileURL
guard let bundle = Bundle(url: appURL), let domain = bundle.bundleIdentifier,
  domain == "org.openimageviewer.ImageViewer" else { exit(2) }
let defaults = UserDefaults.standard
@MainActor func samePath(_ path: String) -> Bool {
  URL(fileURLWithPath: path).resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
    == appURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
}
@MainActor func applications() -> [NSRunningApplication] {
  NSRunningApplication.runningApplications(withBundleIdentifier: domain).filter { !$0.isTerminated }
}
@MainActor func emit(_ result: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: result,options: [.sortedKeys]) else { exit(3) }
  FileHandle.standardOutput.write(data + Data([10]))
}
@MainActor func preferences() -> [String: Any] { defaults.persistentDomain(forName: domain) ?? [:] }
@MainActor func digest(_ input: [String: Any], workOnly: Bool) -> String {
  func normalize(_ value: Any) -> Any {
    if let d = value as? [String: Any] { return d.mapValues(normalize) }
    if let a = value as? [Any] { return a.map(normalize) }
    if let date = value as? Date { return ["date":date.timeIntervalSince1970] }
    if let data = value as? Data { return ["dataSHA256":SHA256.hash(data: data).map { String(format:"%02x",$0) }.joined()] }
    return value
  }
  let selected = input.filter { key,_ in !workOnly || (!key.hasPrefix("NSWindow Frame") && key != "ImageViewer.HomeQuote.PreviousID.v1") }
  let data = try! JSONSerialization.data(withJSONObject: normalize(selected),options: [.sortedKeys])
  return SHA256.hash(data: data).map { String(format:"%02x",$0) }.joined()
}
switch command {
case "activate":
  guard args.count == 5, let pid = Int32(args[3]), let launch = Double(args[4]),
    let target = applications().first(where: { $0.processIdentifier == pid }),
    target.bundleURL.map({ samePath($0.path) }) == true,
    target.launchDate.map({ abs($0.timeIntervalSince1970-launch) < 0.001 }) == true else { exit(4) }
  emit(["requested":target.activate(options:[.activateAllWindows,.activateIgnoringOtherApps])])
case "status":
  emit(["applications":applications().map { a -> [String:Any] in
    ["pid":a.processIdentifier,"bundlePath":a.bundleURL?.path ?? "", "matchesApp":a.bundleURL.map { samePath($0.path) } ?? false,
     "launchTime":a.launchDate?.timeIntervalSince1970 ?? 0,"active":a.isActive]
  },"frontmostBundleID":NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"])
case "quit":
  guard args.count == 5, let pid = Int32(args[3]), let launch = Double(args[4]),
    let target = applications().first(where: { $0.processIdentifier == pid }),
    target.bundleURL.map({ samePath($0.path) }) == true,
    target.launchDate.map({ abs($0.timeIntervalSince1970-launch) < 0.001 }) == true else { exit(4) }
  let requested = target.terminate()
  let until = Date().addingTimeInterval(15)
  while !target.isTerminated && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
  emit(["requested":requested,"terminated":target.isTerminated])
  if !target.isTerminated { exit(5) }
case "capture":
  guard args.count == 4, applications().isEmpty else { exit(4) }
  let values = preferences(), output = URL(fileURLWithPath: args[3])
  let data = try PropertyListSerialization.data(fromPropertyList: values,format: .binary,options: 0)
  try data.write(to: output,options: .withoutOverwriting)
  try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath: output.path)
  emit(["workDigest":digest(values,workOnly:true),"allDigest":digest(values,workOnly:false)])
case "restore":
  guard args.count == 4, applications().isEmpty,
    let before = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath:args[3])),format:nil) as? [String:Any]
    else { exit(4) }
  var current = preferences()
  let unchanged = digest(before,workOnly:true) == digest(current,workOnly:true)
  // Preserve independently changed work settings. A mismatched digest fails
  // validation and retains the rollback snapshot; it is never hidden by rewriting.
  for key in Array(current.keys) where key.hasPrefix("NSWindow Frame") { current.removeValue(forKey:key) }
  for (key,value) in before where key.hasPrefix("NSWindow Frame") { current[key] = value }
  defaults.setPersistentDomain(current,forName:domain)
  defaults.synchronize()
  emit(["workUnchangedDuringRun":unchanged,"workRestored":digest(preferences(),workOnly:true)==digest(before,workOnly:true),
    "windowValuesRestored":true])
case "clean-private":
  guard args.count == 4, applications().isEmpty,
    args[3].hasPrefix("ImageViewer.ManualQA."), UUID(uuidString:String(args[3].dropFirst("ImageViewer.ManualQA.".count))) != nil else { exit(4) }
  defaults.removePersistentDomain(forName: args[3]); defaults.synchronize()
  emit(["removed":true])
default: exit(2)
}

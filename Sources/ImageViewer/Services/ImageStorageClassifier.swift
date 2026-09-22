import DiskArbitration
import Foundation
import IOKit
import IOKit.storage

/// Queries only the selected file's volume metadata, never image contents or a
/// list of the user's disks. Unknown removable media gets the SD-card budget.
actor ImageStorageClassifier {
  private struct CachedVolume {
    let kind: ImageStorageKind
    let expires: Date
  }

  private var volumes: [URL: CachedVolume] = [:]
  private let cacheLifetime: TimeInterval = 30
  private let maximumCachedVolumes = 32

  func storageKind(for url: URL) -> ImageStorageKind {
    guard url.isFileURL else { return .network }
    // A fresh URL avoids retaining a disconnected volume's cached metadata.
    let freshURL = URL(fileURLWithPath: url.path)
    guard let volumeURL = try? freshURL.resourceValues(forKeys: [.volumeURLKey]).volume
    else { return .unknown }
    let now = Date()
    if let cached = volumes[volumeURL], cached.expires > now { return cached.kind }

    let keys: Set<URLResourceKey> = [
      .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRemovableKey,
      .volumeIsEjectableKey,
    ]
    let values = try? URL(fileURLWithPath: volumeURL.path).resourceValues(forKeys: keys)
    var properties = ImageStorageProperties(
      isInternal: values?.volumeIsInternal,
      isLocal: values?.volumeIsLocal,
      isRemovable: values?.volumeIsRemovable,
      isEjectable: values?.volumeIsEjectable)

    // Network volumes need no Disk Arbitration request. A built-in SD reader can
    // be on an internal bus, so inspect the protocol before assuming internal SSD.
    // USB enclosures are not assumed fast merely because the disk is local.
    if properties.isLocal != false {
      Self.addDeviceProperties(volumeURL: volumeURL, to: &properties)
    }
    if properties.isSolidState == nil && properties.isInternal == true
      && properties.isLocal == true && properties.isRemovable == false
      && properties.isEjectable == false && ImageLoadingPolicy.usesAppleSilicon
    { properties.isSolidState = true }
    let kind = properties.storageKind
    volumes = volumes.filter { $0.value.expires > now }
    if volumes.count >= maximumCachedVolumes,
      let oldest = volumes.min(by: { $0.value.expires < $1.value.expires })
    {
      volumes.removeValue(forKey: oldest.key)
    }
    volumes[volumeURL] = CachedVolume(kind: kind, expires: now.addingTimeInterval(cacheLifetime))
    return kind
  }

  private static func addDeviceProperties(
    volumeURL: URL, to properties: inout ImageStorageProperties
  ) {
    guard let session = DASessionCreate(kCFAllocatorDefault),
      let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volumeURL as CFURL)
    else { return }
    inspect(disk: disk, properties: &properties)
    // Partition/virtual-volume descriptions can omit removability that the whole
    // device reports. Inspect only this volume's associated disk, never all disks.
    if let wholeDisk = DADiskCopyWholeDisk(disk), !CFEqual(disk, wholeDisk) {
      inspect(disk: wholeDisk, properties: &properties)
    }
  }

  private static func inspect(disk: DADisk, properties: inout ImageStorageProperties) {
    if let description = DADiskCopyDescription(disk) as? [String: Any] {
      properties.mergeDeviceFlags(
        isInternal: description[kDADiskDescriptionDeviceInternalKey as String] as? Bool,
        isRemovable: description[kDADiskDescriptionMediaRemovableKey as String] as? Bool,
        isEjectable: description[kDADiskDescriptionMediaEjectableKey as String] as? Bool,
        physicalInterconnect: description[kDADiskDescriptionDeviceProtocolKey as String] as? String)
    }
    var entry = DADiskCopyIOMedia(disk)
    guard entry != IO_OBJECT_NULL else { return }
    defer { IOObjectRelease(entry) }
    // A bridge may expose an incomplete Device Characteristics dictionary. Read
    // this device's bounded parent chain rather than stopping at that dictionary
    // or walking unrelated children. SD protocol evidence stays sticky above USB.
    for _ in 0..<16 {
      if let device = IORegistryEntrySearchCFProperty(
        entry, kIOServicePlane, kIOPropertyDeviceCharacteristicsKey as CFString,
        kCFAllocatorDefault, 0
      ) as? [String: Any] {
        properties.mergeMediumType(device[kIOPropertyMediumTypeKey] as? String)
      }
      if let connection = IORegistryEntrySearchCFProperty(
        entry, kIOServicePlane, kIOPropertyProtocolCharacteristicsKey as CFString,
        kCFAllocatorDefault, 0
      ) as? [String: Any] {
        properties.mergeDeviceFlags(
          physicalInterconnect: connection[kIOPropertyPhysicalInterconnectTypeKey] as? String)
      }
      var parent: io_registry_entry_t = IO_OBJECT_NULL
      guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS,
        parent != IO_OBJECT_NULL
      else { break }
      IOObjectRelease(entry)
      entry = parent
    }
  }
}

/// Kept separate from device discovery so conservative fallbacks are testable
/// without an SD card, external SSD, or network share connected to the test Mac.
struct ImageStorageProperties {
  var isInternal: Bool?
  var isLocal: Bool?
  var isRemovable: Bool?
  var isEjectable: Bool?
  var isSolidState: Bool?
  var physicalInterconnect: String?

  mutating func mergeDeviceFlags(
    isInternal deviceIsInternal: Bool? = nil,
    isRemovable deviceIsRemovable: Bool? = nil,
    isEjectable deviceIsEjectable: Bool? = nil,
    physicalInterconnect deviceInterconnect: String? = nil
  ) {
    // Positive removable/ejectable evidence on either the volume or whole device
    // wins over a partition's false value. External evidence also wins over internal.
    if deviceIsInternal == false || isInternal == nil { isInternal = deviceIsInternal }
    if deviceIsRemovable == true || isRemovable == nil { isRemovable = deviceIsRemovable }
    if deviceIsEjectable == true || isEjectable == nil { isEjectable = deviceIsEjectable }
    if deviceInterconnect == kIOPropertyPhysicalInterconnectTypeSecureDigital
      || physicalInterconnect == nil
    { physicalInterconnect = deviceInterconnect }
  }

  mutating func mergeMediumType(_ medium: String?) {
    if medium == kIOPropertyMediumTypeRotationalKey {
      isSolidState = false
    } else if medium == kIOPropertyMediumTypeSolidStateKey && isSolidState == nil {
      isSolidState = true
    }
  }

  var storageKind: ImageStorageKind {
    if isLocal == false { return .network }
    // SD cards are solid-state too. Removability/protocol must take precedence.
    if isRemovable == true
      || physicalInterconnect == kIOPropertyPhysicalInterconnectTypeSecureDigital
    { return .removable }
    if isInternal == true && isLocal == true && isSolidState == true
      && isRemovable == false && isEjectable == false
    {
      return .internalSSD
    }
    if isInternal == false && isSolidState == true { return .external }
    if isEjectable == true { return .removable }
    return .unknown
  }
}

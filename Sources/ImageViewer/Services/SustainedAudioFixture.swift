import Foundation

/// Valid silent PCM, generated only inside the opt-in private diagnostic runtime.
/// The original media directory is never a destination for generated data.
enum SustainedAudioFixture {
  static func create(in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("sustained-silent.wav")
    let samples: UInt32 = 16_000 * 3, bytes = samples * 2
    var data = Data()
    func text(_ value: String) { data.append(contentsOf: value.utf8) }
    func word<T: FixedWidthInteger>(_ value: T) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    text("RIFF"); word(bytes + 36); text("WAVEfmt "); word(UInt32(16))
    word(UInt16(1)); word(UInt16(1)); word(UInt32(16_000)); word(UInt32(32_000))
    word(UInt16(2)); word(UInt16(16)); text("data"); word(bytes)
    data.append(Data(count: Int(bytes)))
    try data.write(to: url, options: .withoutOverwriting)
    return url
  }
}

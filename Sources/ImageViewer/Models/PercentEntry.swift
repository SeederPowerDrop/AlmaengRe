import Foundation

/// Strict, locale-aware percent entry. Invalid drafts leave the existing value to
/// the caller; accepted numbers are clamped as fractions before they reach export.
enum PercentEntry {
  static func fraction(from text: String, in range: ClosedRange<Double>,
    locale: Locale = .current) -> Double? {
    let formatter = numberFormatter(locale: locale)
    var input = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // Number formatters can add directional marks in RTL locales.
    input = input.unicodeScalars.filter { ![0x061C, 0x200E, 0x200F].contains($0.value) }
      .map(String.init).joined()
    let percent = (formatter.percentSymbol ?? "%").unicodeScalars
      .filter { ![0x061C, 0x200E, 0x200F].contains($0.value) }.map(String.init).joined()
    if input.hasSuffix(percent) {
      input.removeLast(percent.count)
      input = input.trimmingCharacters(in: .whitespacesAndNewlines)
    } else if input.hasSuffix("%") || input.hasSuffix("٪") {
      input.removeLast()
      input = input.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !input.isEmpty else { return nil }
    let decimal = formatter.decimalSeparator ?? "."
    // Accept the locale decimal separator and the portable dot used when pasting.
    // Grouping separators are deliberately excluded: all controls are below 100%.
    if decimal != "." { input = input.replacingOccurrences(of: decimal, with: ".") }
    var normalized = ""
    var hasDecimal = false
    var hasDigit = false
    for (index, character) in input.enumerated() {
      if index == 0, character == "+" || character == "-" || character == "−" {
        normalized.append(character == "−" ? "-" : character)
      } else if character == ".", !hasDecimal {
        hasDecimal = true
        normalized.append(".")
      } else if character.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains),
        let digit = character.wholeNumberValue, (0...9).contains(digit) {
        hasDigit = true
        normalized.append(String(digit))
      } else {
        return nil
      }
    }
    guard hasDigit, let percentValue = Double(normalized), percentValue.isFinite else { return nil }
    let fraction = percentValue / 100
    guard fraction.isFinite else { return nil }
    return min(range.upperBound, max(range.lowerBound, fraction))
  }

  static func string(for fraction: Double, locale: Locale = .current) -> String {
    guard fraction.isFinite else { return "" }
    return numberFormatter(locale: locale).string(from: NSNumber(value: fraction * 100)) ?? ""
  }

  static func accessibilityValue(for fraction: Double, locale: Locale = .current) -> String {
    let formatter = numberFormatter(locale: locale)
    formatter.numberStyle = .percent
    formatter.maximumFractionDigits = 12
    return formatter.string(from: NSNumber(value: fraction)) ?? ""
  }

  private static func numberFormatter(locale: Locale) -> NumberFormatter {
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 12
    formatter.isLenient = false
    return formatter
  }
}

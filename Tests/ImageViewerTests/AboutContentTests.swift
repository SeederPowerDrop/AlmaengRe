import CoreImage
import Foundation
import Testing

@testable import ImageViewer

@Suite("정보창의 앱 언어와 후원 정보")
struct AboutContentTests {
  private let contentKeys = [
    "subtitle", "opening", "story", "philosophy", "thanks", "closing",
    "supportTitle", "supportMessage", "bitcoinDescription", "bitcoinAddress",
    "bitcoinQR", "copyAddress", "addressCopied", "openWallet", "walletUnavailable",
  ]

  @Test("소개·철학·후원 안내는 선택한 앱 언어의 번역을 사용한다", arguments: L10n.supportedLocalizations)
  func selectedLanguageContent(language: String) {
    for key in contentKeys {
      let translated = AboutContent.text(key, localeIdentifier: language)
      #expect(!translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        "\(language): \(key)")
      #expect(translated != key, "\(language): \(key)")
      #expect(translated == L10n.text(key, localeIdentifier: language, table: "About"),
        "\(language): \(key)")
    }
    #expect(AboutContent.text("closing", localeIdentifier: language).contains("ERW FWS WRG"))
  }

  @Test("지역과 대소문자가 포함된 언어도 해당 소개를 보여준다")
  func regionalLanguages() {
    let cases = [
      "ko-KR": "ko", "en-GB": "en", "en_US": "en", "EN-us": "en",
      "ja-JP": "ja", "zh-Hans-CN": "zh-Hans", "zh_Hans_CN": "zh-Hans",
      "vi-VN": "vi", "es-MX": "es", "fr-FR": "fr", "de-AT": "de",
      "ru-RU": "ru", "ar-SA": "ar",
    ]
    for (identifier, language) in cases {
      for key in ["opening", "philosophy", "supportMessage"] {
        #expect(AboutContent.text(key, localeIdentifier: identifier)
          == L10n.text(key, localeIdentifier: language, table: "About"),
          "\(identifier): \(key)")
      }
    }
  }

  @Test("macOS 언어 우선순위를 따르고 미지원 언어만 있으면 한국어를 선택한다")
  func preferredLanguages() {
    #expect(AboutContent.languageIdentifier(for: ["fr-FR", "en-US"]) == "fr")
    #expect(AboutContent.languageIdentifier(for: ["it-IT", "ja-JP"]) == "ja")
    #expect(AboutContent.languageIdentifier(for: ["it-IT"]) == "ko")
    #expect(AboutContent.languageIdentifier(for: []) == "ko")
    #expect(AboutContent.languageIdentifier(for: ["zh-CN"]) == "zh-Hans")
    #expect(AboutContent.languageIdentifier(for: ["ar-SA"]) == "ar")
  }

  @Test("지원하지 않는 언어와 빈 언어는 한국어 원문을 보여준다",
    arguments: ["nl-NL", "pt-BR", "pt_BR", "unknown", ""])
  func unsupportedLanguagesUseKorean(identifier: String) {
    for key in contentKeys {
      #expect(AboutContent.text(key, localeIdentifier: identifier)
        == L10n.text(key, localeIdentifier: "ko", table: "About"),
        "\(identifier): \(key)")
    }
  }

  @Test("후원 링크와 지갑 주소는 ZipLens의 공개 후원 정보와 일치한다")
  func publicSupportDestinations() {
    #expect(AboutSupport.buyMeACoffeeURL.absoluteString == "https://buymeacoffee.com/master_chief")
    #expect(AboutSupport.koFiURL.absoluteString == "https://ko-fi.com/seederpower")
    #expect(AboutSupport.bitcoinAddress == "BC1QUEUAX3FJP77NZUKF732AEWVFE0YVS9ZPKUMLTV")
    #expect(AboutSupport.bitcoinURL.absoluteString == "bitcoin:\(AboutSupport.bitcoinAddress)")
  }

  @Test("화면에 표시할 QR 코드는 동일한 Bitcoin 후원 URI로 해독된다")
  func bitcoinQRCodeDecodesToSupportAddress() throws {
    let image = try #require(AboutSupport.makeBitcoinQRCode())
    let detector = try #require(CIDetector(
      ofType: CIDetectorTypeQRCode,
      context: CIContext(),
      options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
    ))
    let messages = detector.features(in: CIImage(cgImage: image))
      .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    #expect(messages == [AboutSupport.bitcoinURL.absoluteString])
  }
}

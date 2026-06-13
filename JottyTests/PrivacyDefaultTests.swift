import XCTest
@testable import Jotty

/// SC6 (privacy-by-default): the default config resolves to the on-device Apple FM
/// provider and constructs NO HTTP-client (cloud) provider on the default path.
/// GREEN against existing ProviderFactory; live packet capture is human-only.
final class PrivacyDefaultTests: XCTestCase {

    func testDefaultConfigIsAppleFM() {
        XCTAssertTrue(ProviderFactory.isAppleFM(.defaultValue))
    }

    /// The default config builds an `AppleFMProvider` concretely — never a cloud
    /// HTTP-client provider (Claude/OpenAI/Gemini/Ollama).
    func testMakeOnDefaultConfigReturnsAppleFMProvider() {
        let provider = ProviderFactory.make(config: .defaultValue)
        XCTAssertTrue(provider is AppleFMProvider,
                      "default path must construct AppleFMProvider, not a cloud provider")
    }

    /// An unknown / corrupted provider ID degrades to Apple FM, never a cloud type.
    func testUnknownProviderIDDegradesToAppleFM() {
        var cfg = AppConfig.defaultValue
        cfg.aiProviderID = "totally-unknown-provider"
        XCTAssertTrue(ProviderFactory.isAppleFM(cfg))
        XCTAssertTrue(ProviderFactory.make(config: cfg) is AppleFMProvider)
    }
}

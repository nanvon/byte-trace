import Foundation
import XCTest

@testable import ByteTraceCore

final class ExecutablePathNormalizerTests: XCTestCase {
    func testVersionDirectoriesCollapse() {
        let cases: [(String, String)] = [
            ("/Users/u/.local/share/claude/versions/2.1.314", "/Users/u/.local/share/claude/versions/*"),
            ("/Users/u/.local/share/mise/installs/node/24.17.0/bin/node", "/Users/u/.local/share/mise/installs/node/*/bin/node"),
            ("/Users/u/.local/share/fnm/node-versions/v24.17.0/installation/bin/node", "/Users/u/.local/share/fnm/node-versions/*/installation/bin/node"),
            ("/Users/u/.codex/packages/standalone/releases/0.164.0-aarch64-apple-darwin/bin/codex", "/Users/u/.codex/packages/standalone/releases/*/bin/codex"),
            ("/Users/u/.local/share/cursor-agent/versions/2026.10.22-27dcf5f/node", "/Users/u/.local/share/cursor-agent/versions/*/node"),
            ("/Users/u/.claude/downloads/claude-2.1.300-darwin-arm64", "/Users/u/.claude/downloads/claude-*-darwin-arm64"),
            ("/Users/u/.vscode/extensions/anthropic.claude-code-2.1.246-darwin-arm64/resources/native-binary/claude", "/Users/u/.vscode/extensions/anthropic.claude-code-*-darwin-arm64/resources/native-binary/claude"),
            ("/Applications/Raycast.app/Contents/Resources/node-v22.22.2/bin/node", "/Applications/Raycast.app/Contents/Resources/node-*/bin/node"),
            ("/Users/u/.npm/_npx/1a4eb60c8f6b0f89/node_modules/x/bin/x", "/Users/u/.npm/_npx/*/node_modules/x/bin/x"),
            ("/System/Library/AssetsV2/x/28f9b40aedc0bda53bdc29e31682c998de89e5cb.asset/AssetData/Foo", "/System/Library/AssetsV2/x/*.asset/AssetData/Foo")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(ExecutablePathNormalizer.normalize(input), expected, input)
        }
    }

    func testOrdinaryPathsAreUnchanged() {
        let paths = [
            "/usr/bin/curl",
            "/Library/Java/JavaVirtualMachines/jdk-17.jdk/Contents/Home/bin/java",
            "/Users/u/.rustup/toolchains/stable-aarch64-apple-darwin/bin/cargo",
            "/System/Library/Frameworks/Accounts.framework/Versions/A/Support/accountsd",
            "/opt/homebrew/bin/python3.12",
            "/usr/local/lib/x86_64/tool"
        ]
        for path in paths {
            XCTAssertEqual(ExecutablePathNormalizer.normalize(path), path)
        }
    }

    func testDisplayNameSkipsVersionAndGenericDirectories() {
        XCTAssertEqual(
            ExecutablePathNormalizer.displayName(forExecutablePath: "/Users/u/.local/share/claude/versions/2.1.314"),
            "claude"
        )
        XCTAssertEqual(
            ExecutablePathNormalizer.displayName(forExecutablePath: "/Users/u/.claude/downloads/claude-2.1.300-darwin-arm64"),
            "claude"
        )
        XCTAssertEqual(
            ExecutablePathNormalizer.displayName(forExecutablePath: "/usr/bin/curl"),
            "curl"
        )
    }
}

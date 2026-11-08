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

    func testCommandNameMergesToolsInBinDirectories() {
        let merged: [(String, String)] = [
            ("/usr/bin/curl", "curl"),
            ("/opt/homebrew/Cellar/curl/8.23.0/bin/curl", "curl"),
            ("/usr/sbin/mDNSResponder", "mDNSResponder"),
            ("/Users/u/.local/share/mise/installs/node/24.17.0/bin/node", "node"),
            ("/Users/u/.local/share/fnm/node-versions/v24.17.0/installation/bin/node", "node"),
            ("/Users/u/.local/bin/mise", "mise"),
            ("/Users/u/.local/share/claude/versions/2.1.314", "claude"),
            ("/Users/u/.local/share/cursor-agent/versions/2026.10.22-27dcf5f/node", "cursor-agent"),
            ("/opt/homebrew/Caskroom/claude-code/2.1.292/claude", "claude"),
            ("/Users/u/.claude/downloads/claude-2.1.300-darwin-arm64", "claude"),
            ("/opt/homebrew/Cellar/git/2.50.0/libexec/git-core/git-remote-http", "git"),
            ("/Library/Developer/CommandLineTools/usr/libexec/git-core/git-remote-https", "git")
        ]
        for (path, name) in merged {
            XCTAssertEqual(ExecutablePathNormalizer.commandName(forExecutablePath: path), name, path)
        }

        let kept = [
            "/usr/libexec/nsurlsessiond",
            "/Users/u/Library/Application Support/Cursor/User/globalStorage/agent-cli/.local/share/cursor-agent/versions/2026.10.22/node",
            "/Applications/Fork.app/Contents/Resources/git-instance/libexec/git-core/git-remote-http",
            "/opt/homebrew/Caskroom/some-app/1.0/Some.app/Contents/MacOS/Some",
            "/Applications/Raycast.app/Contents/Resources/node-v22.22.2/bin/node",
            "/Users/u/Library/Application Support/com.raycast.macos/node/runtime/node-v22-darwin-arm64/bin/node",
            "/Users/u/.cache/magpie/bin/magpie-bun"
        ]
        for path in kept {
            XCTAssertNil(ExecutablePathNormalizer.commandName(forExecutablePath: path), path)
        }
    }

    func testProgramNameCoversInterpretersAndBundledTools() {
        let named: [(String, String)] = [
            ("/usr/bin/curl", "curl"),
            ("/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift", "swift"),
            ("/opt/homebrew/Cellar/python@3.13/3.13.0/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python", "python"),
            ("/Users/u/Library/Application Support/Claude/claude-code/2.1.317/abc/claude.app/Contents/MacOS/claude", "claude"),
            ("/Users/u/.vscode/extensions/ms-python.python-2026.1.0/dist/lsp-server", "lsp-server")
        ]
        for (path, name) in named {
            XCTAssertEqual(ExecutablePathNormalizer.programName(forExecutablePath: path), name, path)
        }
        XCTAssertNil(ExecutablePathNormalizer.programName(forExecutablePath: "/usr/libexec/nsurlsessiond"))
        XCTAssertNil(ExecutablePathNormalizer.programName(forExecutablePath: "/Users/u/.marscode/ai-chat/binary/1.0/modules/ai-agent/ai-agent"))

        XCTAssertTrue(ExecutablePathNormalizer.isInterpreter("python3.13"))
        XCTAssertTrue(ExecutablePathNormalizer.isInterpreter("node"))
        XCTAssertFalse(ExecutablePathNormalizer.isInterpreter("python-config"))
        XCTAssertFalse(ExecutablePathNormalizer.isInterpreter("bun"))
    }

    func testScriptProgramNameFollowsTheScriptArgument() {
        let cases: [([String], String?)] = [
            (["/opt/homebrew/Library/Homebrew/vendor/portable-ruby/current/bin/ruby", "-W1", "--disable=gems", "/opt/homebrew/Library/Homebrew/brew.rb", "update"], "brew"),
            (["python3", "-m", "pip.__main__", "install", "x"], "pip"),
            (["python3", "-c", "print(1)"], nil),
            (["node", "-e", "1"], nil),
            (["node", "--require", "/tmp/hook.js", "/opt/homebrew/bin/npx", "figma-developer-mcp"], "npx"),
            (["node", "/Users/u/.npm/_npx/abc/node_modules/figma-developer-mcp/dist/cli.js", "--stdio"], "figma-developer-mcp"),
            (["node", "/Users/u/.npm/node_modules/@anthropic-ai/claude-code/cli.js"], "claude-code"),
            (["node", "/Users/u/work/tool/dist/index.js"], "tool"),
            (["node", "worker.mjs"], "worker"),
            (["node"], nil)
        ]
        for (arguments, name) in cases {
            XCTAssertEqual(ExecutablePathNormalizer.scriptProgramName(arguments: arguments), name, arguments.joined(separator: " "))
        }
    }
}

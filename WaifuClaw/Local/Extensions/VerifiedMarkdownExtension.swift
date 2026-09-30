import Foundation

/// A manually installed declarative action for GitHub's documented REST API.
/// https://docs.github.com/en/rest/markdown/markdown#render-a-markdown-document
/// It is not installed automatically and cannot run until the user reviews a
/// specific request in the manual action screen. GitHub's response is shown as
/// text, not executed or rendered as untrusted HTML.
enum VerifiedMarkdownExtension {
    static let manifest = ExtensionManifest(
        id: "com.github.markdown",
        name: "GitHub Markdown",
        vendor: "GitHub",
        capabilities: ["markdown.render"],
        baseEndpoint: URL(string: "https://api.github.com")!,
        actions: [
            ExtensionActionManifest(
                name: "render_markdown",
                path: "/markdown",
                parameters: [
                    ExtensionParameterSchema(name: "text", type: .string, required: true, maxLength: 4_096),
                    ExtensionParameterSchema(name: "mode", type: .string, required: false, enumValues: ["markdown", "gfm"]),
                    ExtensionParameterSchema(name: "context", type: .string, required: false, maxLength: 256)
                ]
            )
        ]
    )
}

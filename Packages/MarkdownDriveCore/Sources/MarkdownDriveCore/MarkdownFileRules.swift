public enum MarkdownFileRules {
    public static let requiredExtension = ".md"

    public static func isMarkdownFile(name: String) -> Bool {
        guard let dotIndex = name.lastIndex(of: "."), dotIndex != name.startIndex else {
            return false
        }

        return name[name.index(after: dotIndex)...].lowercased() == "md"
    }
}

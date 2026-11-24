import Foundation

@main
struct BuildFinderMenuIcons {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FinderMenuIcons().writeArchive(to: output)
    }
}

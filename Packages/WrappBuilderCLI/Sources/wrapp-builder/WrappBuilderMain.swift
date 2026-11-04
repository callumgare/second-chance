import ArgumentParser
import WrappBuilderTool

@main
struct WrappBuilderMain {
    static func main() async {
        await WrappBuilderCommand.main()
    }
}

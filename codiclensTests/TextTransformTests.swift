import Testing
@testable import codiclens

/// Pure text rules. These already had no dependencies — they just had no tests.
struct TextTransformTests {

    @Test(arguments: [
        (TextTransform.uppercase, "hello world", "HELLO WORLD"),
        (.lowercase, "Hello World", "hello world"),
        (.camelCase, "hello world", "helloWorld"),
        (.pascalCase, "hello world", "HelloWorld"),
        (.snakeCase, "hello world", "hello_world"),
        (.constantCase, "hello world", "HELLO_WORLD"),
        (.dotCase, "hello world", "hello.world"),
        (.kebabCase, "hello world", "hello-world"),
        (.kebabUpperCase, "hello world", "HELLO-WORLD"),
        (.titleCase, "hello world", "Hello World"),
        (.reverseText, "abc", "cba"),
        (.base64Encode, "hi", "aGk="),
        (.base64Decode, "aGk=", "hi"),
        (.urlEncode, "a b", "a%20b"),
        (.urlDecode, "a%20b", "a b"),
    ])
    func transformsProduceTheExpectedText(transform: TextTransform, input: String, expected: String) {
        #expect(transform.apply(input) == expected)
    }

    @Test func caseTransformsSplitOnExistingWordBoundaries() {
        #expect(TextTransform.snakeCase.apply("helloWorldAgain") == "hello_world_again")
        #expect(TextTransform.camelCase.apply("hello-world_again") == "helloWorldAgain")
        #expect(TextTransform.kebabCase.apply("some.dotted.name") == "some-dotted-name")
    }

    @Test func whitespaceTransforms() {
        #expect(TextTransform.trimWhitespace.apply("  hi  ") == "hi")
        #expect(TextTransform.collapseWhitespace.apply("a    b") == "a b")
        #expect(TextTransform.removeBlankLines.apply("a\n\n  \nb") == "a\nb")
        #expect(TextTransform.reverseLines.apply("a\nb\nc") == "c\nb\na")
    }

    @Test func htmlEscapingRoundTrips() {
        let raw = "<a href=\"x\">A & B</a>"
        #expect(TextTransform.unescapeHTML.apply(TextTransform.escapeHTML.apply(raw)) == raw)
    }

    @Test func undecodableBase64IsLeftAlone() {
        #expect(TextTransform.base64Decode.apply("not base64!") == "not base64!")
    }

    @Test func counts() {
        #expect(CountType.characters.count("abc") == "3 characters")
        #expect(CountType.words.count("a b c") == "3 words")
        #expect(CountType.lines.count("a\nb") == "2 lines")
    }
}

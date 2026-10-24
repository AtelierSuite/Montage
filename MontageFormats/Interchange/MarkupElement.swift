import Foundation

/// An XML element read whole into memory: its attributes, the elements
/// inside it and its text. Interchange files are small enough to read this
/// way, and walking a tree is far easier than following a parser's events.
///
/// Foundation's `XMLDocument` would do the same but is only on the Mac, so
/// this is built with `XMLParser`, which is everywhere.
struct MarkupElement: Equatable, Sendable {
    var name: String
    /// In the order they were written, so writing the element out again
    /// keeps them that way.
    var attributes: [(name: String, value: String)]
    var children: [MarkupElement]
    /// The text directly inside the element, trimmed of surrounding space
    /// except in a title's words.
    var text: String

    init(_ name: String, _ attributes: [(String, String?)] = [], children: [MarkupElement] = [], text: String = "") {
        self.name = name
        self.attributes = attributes.compactMap { name, value in value.map { (name, $0) } }
        self.children = children
        self.text = text
    }

    static func == (lhs: MarkupElement, rhs: MarkupElement) -> Bool {
        lhs.name == rhs.name && lhs.text == rhs.text && lhs.children == rhs.children
            && lhs.attributes.elementsEqual(rhs.attributes) { $0.name == $1.name && $0.value == $1.value }
    }

    subscript(attribute: String) -> String? {
        attributes.first { $0.name == attribute }?.value
    }

    /// The first element inside with this name.
    func child(_ name: String) -> MarkupElement? {
        children.first { $0.name == name }
    }

    func children(_ name: String) -> [MarkupElement] {
        children.filter { $0.name == name }
    }

    /// The element at a path of names below this one, such as
    /// `["rate", "timebase"]`.
    func descendant(_ path: String...) -> MarkupElement? {
        var element: MarkupElement? = self
        for name in path { element = element?.child(name) }
        return element
    }

    /// Every element below this one, depth first, in document order.
    var allDescendants: [MarkupElement] {
        children.flatMap { [$0] + $0.allDescendants }
    }

    // MARK: - Reading

    /// Reads a document's root element.
    static func parse(_ data: Data) throws -> MarkupElement {
        let parser = XMLParser(data: data)
        let builder = Builder()
        parser.delegate = builder
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = builder.root else {
            throw InterchangeError.unreadable(parser.parserError?.localizedDescription)
        }
        return root
    }

    /// Deeper than any interchange file goes. Reading, walking and even
    /// freeing a tree is recursive, so a file nested far deeper would run
    /// out of stack; it's refused instead.
    static let maximumDepth = 256

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [MarkupElement] = []
        var texts: [String] = []
        var root: MarkupElement?

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            guard stack.count < MarkupElement.maximumDepth else {
                parser.abortParsing()
                return
            }
            // The parser hands attributes over unordered; sorting keeps the
            // tree the same every time the file is read.
            var element = MarkupElement(elementName)
            element.attributes = attributeDict.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            stack.append(element)
            texts.append("")
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !texts.isEmpty else { return }
            texts[texts.count - 1] += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self))
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
        ) {
            guard var element = stack.popLast() else { return }
            let text = texts.removeLast()
            // A title's words keep their spaces and line breaks.
            let keepsSpace = elementName == "text-style" && element.children.isEmpty
            element.text = keepsSpace ? text : text.trimmingCharacters(in: .whitespacesAndNewlines)
            if stack.isEmpty {
                root = element
            } else {
                stack[stack.count - 1].children.append(element)
            }
        }
    }

    // MARK: - Writing

    /// The element as indented XML, one element to a line.
    func xmlString(indent: Int = 0) -> String {
        let padding = String(repeating: "    ", count: indent)
        var line = padding + "<" + name
        for attribute in attributes {
            line += " \(attribute.name)=\"\(Self.escape(attribute.value, quoting: true))\""
        }
        if children.isEmpty && text.isEmpty { return line + "/>\n" }
        if children.isEmpty { return line + ">" + Self.escape(text, quoting: false) + "</\(name)>\n" }
        var result = line + ">\n"
        if !text.isEmpty { result += padding + "    " + Self.escape(text, quoting: false) + "\n" }
        for child in children { result += child.xmlString(indent: indent + 1) }
        return result + padding + "</\(name)>\n"
    }

    static func escape(_ string: String, quoting: Bool) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for character in string {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"" where quoting: result += "&quot;"
            case "\n" where quoting: result += "&#10;"
            default: result.append(character)
            }
        }
        return result
    }
}

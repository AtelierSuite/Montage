import Foundation

/// The objects of a Premiere Pro project, read from its XML as a stream and
/// linked to each other afterwards.
///
/// A `.prproj` is gzipped XML whose root, `PremiereData`, holds a flat list
/// of objects. Each is identified by a number (`ObjectID`) or a UUID
/// (`ObjectUID`), and refers to others by an element with `ObjectRef` or
/// `ObjectURef`, which may point forwards, so every object is collected
/// before any reference is followed:
///
///     <Sequence ObjectUID="6732…" ClassID="…" Version="11">
///         <TrackGroups><TrackGroup Index="0">
///             <First>228cda18-…</First>      (the media type)
///             <Second ObjectRef="110"/>       (a VideoTrackGroup)
///         </TrackGroup></TrackGroups>
///     </Sequence>
///     <VideoTrackGroup ObjectID="110" …>
///
/// Only the objects the importer reads are kept, and inside them nothing it
/// doesn't: property bags (`Node`) and base64 blobs, which are most of a
/// large project, are skipped as they stream past. Objects nested inside
/// others have IDs of their own, scoped to their parent, so only the
/// objects directly inside the root are looked up by ID.
struct PremiereObjectGraph {
    /// The project's format version, the `Version` of its `Project` object,
    /// which goes up with Premiere releases.
    var projectVersion: Int?
    /// The `Version` of the root `PremiereData` element.
    var documentVersion: Int?
    private(set) var objectsByID: [String: MarkupElement] = [:]
    private(set) var objectsByUID: [String: MarkupElement] = [:]
    /// The sequences, in the order the file has them.
    private(set) var sequences: [MarkupElement] = []
    /// Every kept object, in the order the file has them.
    private(set) var objects: [MarkupElement] = []

    /// The object a reference element points to.
    func resolve(_ reference: MarkupElement?) -> MarkupElement? {
        guard let reference else { return nil }
        if let id = reference["ObjectRef"] { return objectsByID[id] }
        if let uid = reference["ObjectURef"] { return objectsByUID[uid] }
        return nil
    }

    mutating func add(_ object: MarkupElement) {
        if let id = object["ObjectID"] { objectsByID[id] = object }
        if let uid = object["ObjectUID"] { objectsByUID[uid] = object }
        if object.name == "Sequence" { sequences.append(object) }
        objects.append(object)
    }

    // MARK: - Reading

    /// Whether data, uncompressed, starts as a Premiere project does.
    static func isPremiereXML(_ data: Data) -> Bool {
        String(decoding: data.prefix(1024), as: UTF8.self).contains("<PremiereData")
    }

    /// Reads a project, gzipped or not. `acceptsVersion` is asked as soon
    /// as the project's version is read, and a project it turns down is
    /// refused without reading on.
    static func read(_ data: Data, acceptsVersion: @escaping (Int) -> Bool) throws -> PremiereObjectGraph {
        let gzip = GzipInputStream.isGzip(data) ? GzipInputStream(gzipped: data) : nil
        let parser = gzip.map { XMLParser(stream: $0) } ?? XMLParser(data: data)
        let collector = Collector(acceptsVersion: acceptsVersion)
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        let parsed = parser.parse()
        if let failure = collector.failure { throw failure }
        if gzip?.failure != nil { throw PremiereProjectError.damaged }
        guard parsed else {
            // A stream cut short inside the XML reads as a parse error.
            if gzip != nil, collector.depth > 0 { throw PremiereProjectError.damaged }
            throw InterchangeError.unreadable(parser.parserError?.localizedDescription)
        }
        guard collector.sawRoot else { throw InterchangeError.unsupportedFormat }
        guard let version = collector.graph.projectVersion else { throw PremiereProjectError.unsupportedVersion }
        guard acceptsVersion(version) else { throw PremiereProjectError.unsupportedVersion }
        return collector.graph
    }

    /// Whether an object directly inside the root is one the importer reads.
    static func keeps(_ name: String) -> Bool {
        keptSuffixes.contains { name.hasSuffix($0) }
    }

    private static let keptSuffixes = [
        "Sequence", "TrackGroup", "ClipTrack", "TrackItem", "Clip", "Source", "Media", "Stream",
        "ComponentChain", "Component", "Param", "Markers", "Marker", "TimeRemapping",
    ]

    private final class Collector: NSObject, XMLParserDelegate {
        var graph = PremiereObjectGraph()
        var failure: Error?
        var sawRoot = false
        /// How deep the parser is, the root being 1.
        var depth = 0
        private let acceptsVersion: (Int) -> Bool
        /// The object being collected, and the elements open inside it.
        private var stack: [MarkupElement] = []
        private var texts: [String] = []
        /// The depth of the element whose content is being skipped.
        private var skippingFrom: Int?

        init(acceptsVersion: @escaping (Int) -> Bool) {
            self.acceptsVersion = acceptsVersion
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes: [String: String] = [:]
        ) {
            depth += 1
            if skippingFrom != nil { return }
            switch depth {
            case 1:
                guard elementName == "PremiereData" else {
                    stop(parser, InterchangeError.unsupportedFormat)
                    return
                }
                sawRoot = true
                graph.documentVersion = attributes["Version"].flatMap { Int($0) }
                // Every Premiere since CS6 writes version 3.
                if graph.documentVersion != 3 { stop(parser, PremiereProjectError.unsupportedVersion) }
            case 2:
                if elementName == "Project", attributes["ObjectID"] != nil, graph.projectVersion == nil {
                    guard let version = attributes["Version"].flatMap({ Int($0) }), acceptsVersion(version) else {
                        stop(parser, PremiereProjectError.unsupportedVersion)
                        return
                    }
                    graph.projectVersion = version
                    skippingFrom = depth
                    return
                }
                guard attributes["ObjectID"] != nil || attributes["ObjectUID"] != nil,
                      PremiereObjectGraph.keeps(elementName) else {
                    skippingFrom = depth
                    return
                }
                open(elementName, attributes)
            default:
                guard !stack.isEmpty else { return }
                if elementName == "Node" || attributes["Encoding"] != nil || stack.count >= MarkupElement.maximumDepth {
                    skippingFrom = depth
                    return
                }
                open(elementName, attributes)
            }
        }

        private func open(_ name: String, _ attributes: [String: String]) {
            var element = MarkupElement(name)
            element.attributes = attributes.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            stack.append(element)
            texts.append("")
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard skippingFrom == nil, !texts.isEmpty else { return }
            texts[texts.count - 1] += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
        ) {
            defer { depth -= 1 }
            if let skippingFrom {
                if skippingFrom == depth { self.skippingFrom = nil }
                return
            }
            guard depth >= 2, var element = stack.popLast() else { return }
            element.text = texts.removeLast().trimmingCharacters(in: .whitespacesAndNewlines)
            if stack.isEmpty {
                graph.add(element)
            } else {
                stack[stack.count - 1].children.append(element)
            }
        }

        private func stop(_ parser: XMLParser, _ error: Error) {
            failure = error
            parser.abortParsing()
        }
    }
}

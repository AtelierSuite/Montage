import CoreMedia
import Foundation
@testable import MontageFormats

/// Writes AAF files for the importer's tests, in the binary structured
/// storage form: each object a storage with its class ID and a "properties"
/// stream, strong references as storages inside it, vectors and sets with
/// index streams, and weak references by key.
///
/// It writes only what's asked of it, so a test can leave out what a real
/// application would always write, such as the meta-dictionary.
final class AAFTestObject {
    struct Property {
        var pid: UInt16
        var form: UInt16
        var data: Data
        var objects: [AAFTestObject] = []
        /// For a set, the key property's ID and the keys' size.
        var setKey: (pid: UInt16, size: Int)?
    }

    var classID: AUID
    var properties: [Property] = []

    init(_ classID: AUID) {
        self.classID = classID
    }

    @discardableResult
    func set(_ pid: UInt16, data: Data) -> Self {
        properties.removeAll { $0.pid == pid }
        properties.append(Property(pid: pid, form: AAFProperty.Form.data, data: data))
        return self
    }

    @discardableResult
    func set(_ pid: UInt16, int64 value: Int64) -> Self { set(pid, data: Data(le: value)) }
    @discardableResult
    func set(_ pid: UInt16, uint32 value: UInt32) -> Self { set(pid, data: Data(le: value)) }
    @discardableResult
    func set(_ pid: UInt16, bool value: Bool) -> Self { set(pid, data: Data([value ? 1 : 0])) }
    @discardableResult
    func set(_ pid: UInt16, auid value: AUID) -> Self { set(pid, data: Data(value.bytes)) }
    @discardableResult
    func set(_ pid: UInt16, mobID value: MobID) -> Self { set(pid, data: Data(value.bytes)) }

    @discardableResult
    func set(_ pid: UInt16, string value: String) -> Self { set(pid, data: Data(utf16: value)) }

    @discardableResult
    func set(_ pid: UInt16, rational numerator: Int32, _ denominator: Int32) -> Self {
        set(pid, data: Data(le: numerator) + Data(le: denominator))
    }

    /// A value of another type: a byte order, the type, then the value.
    @discardableResult
    func set(_ pid: UInt16, indirectRational numerator: Int32, _ denominator: Int32) -> Self {
        set(pid, data: Data([0x4C]) + Data(AAFType.rational.bytes) + Data(le: numerator) + Data(le: denominator))
    }

    @discardableResult
    func strong(_ pid: UInt16, _ object: AAFTestObject) -> Self {
        properties.removeAll { $0.pid == pid }
        properties.append(Property(pid: pid, form: AAFProperty.Form.strongReference, data: Data(), objects: [object]))
        return self
    }

    @discardableResult
    func vector(_ pid: UInt16, _ objects: [AAFTestObject]) -> Self {
        properties.removeAll { $0.pid == pid }
        properties.append(Property(pid: pid, form: AAFProperty.Form.strongReferenceVector, data: Data(), objects: objects))
        return self
    }

    /// A set, keyed by one of its objects' properties, such as a mob's ID.
    @discardableResult
    func set(_ pid: UInt16, objects: [AAFTestObject], keyPID: UInt16, keySize: Int) -> Self {
        properties.removeAll { $0.pid == pid }
        properties.append(Property(pid: pid, form: AAFProperty.Form.strongReferenceSet, data: Data(), objects: objects,
                                   setKey: (keyPID, keySize)))
        return self
    }

    @discardableResult
    func weak(_ pid: UInt16, key: AUID) -> Self {
        properties.removeAll { $0.pid == pid }
        var data = Data(le: UInt16(0)) + Data(le: UInt16(AAFProperty.ID.identification))
        data.append(16)
        data.append(contentsOf: key.bytes)
        properties.append(Property(pid: pid, form: AAFProperty.Form.weakReference, data: data))
        return self
    }

    func value(of pid: UInt16) -> Data? { properties.first { $0.pid == pid }?.data }

    /// The object's storage, its referenced objects inside, named as the
    /// AAF SDK names them: the property's name, its ID in hex, and for
    /// vectors and sets, each element's key in braces.
    func node(named name: String) -> CompoundFileTestWriter.Node {
        let node = CompoundFileTestWriter.Node(storage: name, classID: classID.bytes)
        var stream = Data([0x4C, 0x20])
        stream.appendLE(UInt16(properties.count))
        var values = Data()
        for property in properties {
            var data = property.data
            if property.form != AAFProperty.Form.data && property.form != AAFProperty.Form.weakReference {
                let referenceName = "P-" + String(property.pid, radix: 16)
                data = Data(utf16: referenceName)
                switch property.form {
                case AAFProperty.Form.strongReference:
                    node.add(property.objects[0].node(named: referenceName))
                default:
                    var index = Data()
                    index.appendLE(UInt32(property.objects.count))
                    index.appendLE(UInt32(property.objects.count))
                    index.appendLE(UInt32.max)
                    if let key = property.setKey {
                        index.appendLE(key.pid)
                        index.append(UInt8(key.size))
                    }
                    for (number, object) in property.objects.enumerated() {
                        // Keys out of step with the order, as after edits.
                        let localKey = UInt32(number * 3 + 1)
                        index.appendLE(localKey)
                        if let key = property.setKey {
                            index.appendLE(UInt32(1))
                            var keyBytes = object.value(of: key.pid) ?? Data()
                            keyBytes.append(Data(count: max(0, key.size - keyBytes.count)))
                            index.append(keyBytes.prefix(key.size))
                        }
                        node.add(object.node(named: referenceName + "{" + String(localKey, radix: 16) + "}"))
                    }
                    node.add(.init(stream: referenceName + " index", contents: index))
                }
            }
            stream.appendLE(property.pid)
            stream.appendLE(property.form)
            stream.appendLE(UInt16(data.count))
            values.append(data)
        }
        node.add(.init(stream: "properties", contents: stream + values))
        return node
    }
}

/// Builds the objects of an AAF file: mobs, slots and the segments of a
/// timeline, with the header, content storage and dictionary around them.
struct AAFTestFile {
    var mobs: [AAFTestObject] = []
    /// Operation and parameter definitions, with their names.
    var operationDefinitions: [AAFTestObject] = []
    var parameterDefinitions: [AAFTestObject] = []
    /// Class definitions for the meta-dictionary: each class and its parent.
    var classDefinitions: [(id: AUID, parent: AUID)] = []

    func data(sectorSize: Int = 4096) -> Data {
        let content = AAFTestObject(AUID("0d010101-0101-1800-060e-2b3402060101"))
            .set(AAFProperty.ID.mobs, objects: mobs, keyPID: AAFProperty.ID.mobID, keySize: 32)
        let dictionary = AAFTestObject(AUID("0d010101-0101-2200-060e-2b3402060101"))
            .set(AAFProperty.ID.operationDefinitions, objects: operationDefinitions,
                 keyPID: AAFProperty.ID.identification, keySize: 16)
            .set(AAFProperty.ID.parameterDefinitions, objects: parameterDefinitions,
                 keyPID: AAFProperty.ID.identification, keySize: 16)
        let header = AAFTestObject(AUID("0d010101-0101-2f00-060e-2b3402060101"))
            .strong(AAFProperty.ID.content, content)
            .strong(AAFProperty.ID.dictionary, dictionary)
        let root = AAFTestObject(AUID("b3b398a5-1c90-11d4-8053-080036210804"))
            .strong(AAFProperty.ID.header, header)
        if !classDefinitions.isEmpty {
            let definitions = classDefinitions.map { id, parent in
                AAFTestObject(AUID("0d010101-0201-0000-060e-2b3402060101"))
                    .set(AAFProperty.ID.metaIdentification, auid: id)
                    .weakMeta(AAFProperty.ID.parentClass, key: parent)
            }
            let metaDictionary = AAFTestObject(AUID("0d010101-0225-0000-060e-2b3402060101"))
                .set(AAFProperty.ID.classDefinitions, objects: definitions, keyPID: AAFProperty.ID.metaIdentification,
                     keySize: 16)
            root.strong(AAFProperty.ID.metaDictionary, metaDictionary)
        }
        var writer = CompoundFileTestWriter()
        writer.sectorSize = sectorSize
        let rootNode = root.node(named: "Root Entry")
        writer.root = rootNode
        return writer.data()
    }

    // MARK: - Objects

    static func mobID(_ number: UInt8) -> MobID {
        MobID(bytes: [0x06, 0x0A, 0x2B, 0x34, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x0F, 0x00, 0x13, 0x00, 0x00, 0x00]
            + Array(repeating: number, count: 16))
    }

    static func mob(_ classID: AUID, id: MobID, name: String?, slots: [AAFTestObject]) -> AAFTestObject {
        let mob = AAFTestObject(classID).set(AAFProperty.ID.mobID, mobID: id).vector(AAFProperty.ID.slots, slots)
        if let name { mob.set(AAFProperty.ID.mobName, string: name) }
        return mob
    }

    static func timelineSlot(_ id: UInt32, rate: (Int32, Int32) = (25, 1), origin: Int64 = 0,
                             _ segment: AAFTestObject) -> AAFTestObject {
        AAFTestObject(AAFClass.timelineMobSlot)
            .set(AAFProperty.ID.slotID, uint32: id)
            .set(AAFProperty.ID.editRate, rational: rate.0, rate.1)
            .set(AAFProperty.ID.origin, int64: origin)
            .strong(AAFProperty.ID.segment, segment)
    }

    static func eventSlot(_ id: UInt32, rate: (Int32, Int32) = (25, 1), _ segment: AAFTestObject) -> AAFTestObject {
        AAFTestObject(AAFClass.eventMobSlot)
            .set(AAFProperty.ID.slotID, uint32: id)
            .set(AAFProperty.ID.eventEditRate, rational: rate.0, rate.1)
            .strong(AAFProperty.ID.segment, segment)
    }

    static func component(_ classID: AUID, _ kind: AUID, length: Int64?) -> AAFTestObject {
        let component = AAFTestObject(classID).weak(AAFProperty.ID.dataDefinition, key: kind)
        if let length { component.set(AAFProperty.ID.length, int64: length) }
        return component
    }

    static func sequence(_ kind: AUID, _ components: [AAFTestObject]) -> AAFTestObject {
        let length = components.reduce(Int64(0)) { total, component in
            let value = component.value(of: AAFProperty.ID.length).map { $0.readLE(Int64.self, at: 0) } ?? 0
            return component.classID == AAFClass.transition ? total &- value : total &+ value
        }
        return component(AAFClass.sequence, kind, length: length).vector(AAFProperty.ID.components, components)
    }

    static func sourceClip(_ kind: AUID, length: Int64, start: Int64 = 0, mob: MobID?, slot: UInt32 = 1) -> AAFTestObject {
        component(AAFClass.sourceClip, kind, length: length)
            .set(AAFProperty.ID.startTime, int64: start)
            .set(AAFProperty.ID.sourceID, mobID: mob ?? MobID(bytes: Array(repeating: 0, count: 32)))
            .set(AAFProperty.ID.sourceMobSlotID, uint32: slot)
    }

    static func filler(_ kind: AUID, length: Int64) -> AAFTestObject {
        component(AAFClass.filler, kind, length: length)
    }

    static func transition(_ kind: AUID, length: Int64, cutPoint: Int64, operation: AUID = AAFDefinition.videoDissolve)
        -> AAFTestObject {
        component(AAFClass.transition, kind, length: length)
            .set(AAFProperty.ID.cutPoint, int64: cutPoint)
            .strong(AAFProperty.ID.transitionOperationGroup,
                    component(AAFClass.operationGroup, kind, length: length).weak(AAFProperty.ID.operation, key: operation))
    }

    static func operationGroup(_ kind: AUID, length: Int64, operation: AUID, inputs: [AAFTestObject],
                               parameters: [AAFTestObject] = []) -> AAFTestObject {
        let group = component(AAFClass.operationGroup, kind, length: length)
            .weak(AAFProperty.ID.operation, key: operation)
            .vector(AAFProperty.ID.inputSegments, inputs)
        if !parameters.isEmpty { group.vector(AAFProperty.ID.parameters, parameters) }
        return group
    }

    static func constant(_ definition: AUID, rational numerator: Int32, _ denominator: Int32) -> AAFTestObject {
        AAFTestObject(AAFClass.constantValue)
            .set(AAFProperty.ID.parameterDefinition, auid: definition)
            .set(AAFProperty.ID.value, indirectRational: numerator, denominator)
    }

    static func scopeReference(_ kind: AUID, length: Int64) -> AAFTestObject {
        component(AAFClass.scopeReference, kind, length: length)
    }

    static func nestedScope(_ kind: AUID, length: Int64, _ layers: [AAFTestObject]) -> AAFTestObject {
        component(AAFClass.nestedScope, kind, length: length).vector(AAFProperty.ID.scopeSlots, layers)
    }

    static func selector(_ kind: AUID, length: Int64, selected: AAFTestObject, alternates: [AAFTestObject]) -> AAFTestObject {
        component(AAFClass.selector, kind, length: length)
            .strong(AAFProperty.ID.selected, selected)
            .vector(AAFProperty.ID.alternates, alternates)
    }

    static func definition(_ classID: AUID, id: AUID, name: String) -> AAFTestObject {
        AAFTestObject(classID).set(AAFProperty.ID.identification, auid: id).set(AAFProperty.ID.name, string: name)
    }

    static func marker(at position: Int64, comment: String?, descriptive: Bool = true) -> AAFTestObject {
        let marker = component(descriptive ? AAFClass.descriptiveMarker : AAFClass.commentMarker,
                               AUID("01030201-1000-0000-060e-2b3404010101"), length: nil)
            .set(AAFProperty.ID.position, int64: position)
        if let comment { marker.set(AAFProperty.ID.comment, string: comment) }
        return marker
    }

    /// A file's media: a source mob for the file, with a locator if it has
    /// a URL, and a master mob that refers to it, with a picture slot, a
    /// sound slot, or both.
    static func media(
        master: MobID, file: MobID, name: String, url: String?, length: Int64, rate: (Int32, Int32) = (25, 1),
        picture: Bool = true, sound: Bool = true
    ) -> [AAFTestObject] {
        let descriptor = AAFTestObject(picture ? AAFClass.cdciDescriptor : AAFClass.pcmDescriptor)
            .set(AAFProperty.ID.sampleRate, rational: rate.0, rate.1)
            .set(AAFProperty.ID.fileLength, int64: length)
        if picture {
            descriptor.set(AAFProperty.ID.storedWidth, uint32: 1920).set(AAFProperty.ID.storedHeight, uint32: 1080)
        }
        if sound { descriptor.set(AAFProperty.ID.channels, uint32: 2) }
        if let url {
            descriptor.vector(AAFProperty.ID.locators, [
                AAFTestObject(AAFClass.networkLocator).set(AAFProperty.ID.urlString, string: url),
            ])
        }
        var fileSlots: [AAFTestObject] = []
        var masterSlots: [AAFTestObject] = []
        let kinds = (picture ? [AAFDefinition.picture] : []) + (sound ? [AAFDefinition.sound] : [])
        for (number, kind) in kinds.enumerated() {
            let id = UInt32(number + 1)
            fileSlots.append(timelineSlot(id, rate: rate, sourceClip(kind, length: length, mob: nil, slot: 0)))
            masterSlots.append(timelineSlot(id, rate: rate,
                                            sequence(kind, [sourceClip(kind, length: length, mob: file, slot: id)])))
        }
        let fileMob = mob(AAFClass.sourceMob, id: file, name: name, slots: fileSlots)
            .strong(AAFProperty.ID.essenceDescription, descriptor)
        return [mob(AAFClass.masterMob, id: master, name: name, slots: masterSlots), fileMob]
    }
}

extension AAFTestObject {
    /// A weak reference to a meta-definition, keyed by its identification.
    @discardableResult
    func weakMeta(_ pid: UInt16, key: AUID) -> Self {
        weak(pid, key: key)
    }
}

extension Data {
    init<Value: FixedWidthInteger>(le value: Value) {
        self.init()
        appendLE(value)
    }

    /// Null-terminated UTF-16, as AAF writes text.
    init(utf16 string: String) {
        self.init()
        for unit in string.utf16 { appendLE(unit) }
        appendLE(UInt16(0))
    }
}

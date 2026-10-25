import Foundation

/// The classes of AAF's object model that a timeline is read from, by the
/// AUIDs files store them under. AAF's own classes are SMPTE labels which
/// differ only in their third field.
enum AAFClass {
    private static func label(_ number: UInt8) -> AUID {
        AUID(bytes: [0x01, 0x01, 0x01, 0x0D, 0x01, 0x01, 0x00, number, 0x06, 0x0E, 0x2B, 0x34, 0x02, 0x06, 0x01, 0x01])!
    }

    static let interchangeObject = label(0x01)
    static let component = label(0x02)
    static let segment = label(0x03)
    static let edgeCode = label(0x04)
    static let essenceGroup = label(0x05)
    static let event = label(0x06)
    static let gpiTrigger = label(0x07)
    static let commentMarker = label(0x08)
    static let filler = label(0x09)
    static let operationGroup = label(0x0A)
    static let nestedScope = label(0x0B)
    static let pulldown = label(0x0C)
    static let scopeReference = label(0x0D)
    static let selector = label(0x0E)
    static let sequence = label(0x0F)
    static let sourceReference = label(0x10)
    static let sourceClip = label(0x11)
    static let textClip = label(0x12)
    static let htmlClip = label(0x13)
    static let timecode = label(0x14)
    static let timecodeStream = label(0x15)
    static let timecodeStream12M = label(0x16)
    static let transition = label(0x17)
    static let essenceDescriptor = label(0x24)
    static let fileDescriptor = label(0x25)
    static let aifcDescriptor = label(0x26)
    static let digitalImageDescriptor = label(0x27)
    static let cdciDescriptor = label(0x28)
    static let rgbaDescriptor = label(0x29)
    static let waveDescriptor = label(0x2C)
    static let filmDescriptor = label(0x2D)
    static let tapeDescriptor = label(0x2E)
    static let locator = label(0x31)
    static let networkLocator = label(0x32)
    static let textLocator = label(0x33)
    static let mob = label(0x34)
    static let compositionMob = label(0x35)
    static let masterMob = label(0x36)
    static let sourceMob = label(0x37)
    static let mobSlot = label(0x38)
    static let eventMobSlot = label(0x39)
    static let staticMobSlot = label(0x3A)
    static let timelineMobSlot = label(0x3B)
    static let parameter = label(0x3C)
    static let constantValue = label(0x3D)
    static let varyingValue = label(0x3E)
    static let descriptiveMarker = label(0x41)
    static let soundDescriptor = label(0x42)
    static let dataEssenceDescriptor = label(0x43)
    static let multipleDescriptor = label(0x44)
    static let pcmDescriptor = label(0x48)
    static let physicalDescriptor = label(0x49)
    static let importDescriptor = label(0x4A)
    static let auxiliaryDescriptor = label(0x4E)

    /// Each built-in class's parent. Files usually define these again in
    /// their meta-dictionary, but needn't.
    static let parents: [AUID: AUID] = [
        component: interchangeObject, segment: component, edgeCode: segment, essenceGroup: segment,
        event: segment, gpiTrigger: event, commentMarker: event, descriptiveMarker: commentMarker,
        filler: segment, operationGroup: segment, nestedScope: segment, pulldown: segment,
        scopeReference: segment, selector: segment, sequence: segment, sourceReference: segment,
        sourceClip: sourceReference, textClip: sourceReference, htmlClip: textClip, timecode: segment,
        timecodeStream: segment, timecodeStream12M: timecodeStream, transition: component,
        essenceDescriptor: interchangeObject, fileDescriptor: essenceDescriptor, aifcDescriptor: fileDescriptor,
        digitalImageDescriptor: fileDescriptor, cdciDescriptor: digitalImageDescriptor,
        rgbaDescriptor: digitalImageDescriptor, waveDescriptor: fileDescriptor, filmDescriptor: essenceDescriptor,
        tapeDescriptor: essenceDescriptor, soundDescriptor: fileDescriptor, pcmDescriptor: soundDescriptor,
        dataEssenceDescriptor: fileDescriptor, multipleDescriptor: fileDescriptor,
        physicalDescriptor: essenceDescriptor, importDescriptor: physicalDescriptor,
        auxiliaryDescriptor: physicalDescriptor,
        locator: interchangeObject, networkLocator: locator, textLocator: locator,
        mob: interchangeObject, compositionMob: mob, masterMob: mob, sourceMob: mob,
        mobSlot: interchangeObject, eventMobSlot: mobSlot, staticMobSlot: mobSlot, timelineMobSlot: mobSlot,
        parameter: interchangeObject, constantValue: parameter, varyingValue: parameter,
    ]
}

extension AAFProperty {
    /// The properties read, by their IDs, which AAF fixes for its own
    /// classes.
    enum ID {
        // Root
        static let metaDictionary: UInt16 = 0x0001
        static let header: UInt16 = 0x0002
        // MetaDictionary, MetaDefinition, ClassDefinition
        static let classDefinitions: UInt16 = 0x0003
        static let metaIdentification: UInt16 = 0x0005
        static let metaName: UInt16 = 0x0006
        static let parentClass: UInt16 = 0x0008
        // Component
        static let dataDefinition: UInt16 = 0x0201
        static let length: UInt16 = 0x0202
        // EssenceGroup
        static let choices: UInt16 = 0x0501
        // Event
        static let position: UInt16 = 0x0601
        static let comment: UInt16 = 0x0602
        // CommentMarker
        static let annotation: UInt16 = 0x0901
        // OperationGroup
        static let operation: UInt16 = 0x0B01
        static let inputSegments: UInt16 = 0x0B02
        static let parameters: UInt16 = 0x0B03
        // NestedScope
        static let scopeSlots: UInt16 = 0x0C01
        // Selector
        static let selected: UInt16 = 0x0F01
        static let alternates: UInt16 = 0x0F02
        // Sequence
        static let components: UInt16 = 0x1001
        // SourceReference
        static let sourceID: UInt16 = 0x1101
        static let sourceMobSlotID: UInt16 = 0x1102
        // SourceClip
        static let startTime: UInt16 = 0x1201
        static let fadeInLength: UInt16 = 0x1202
        static let fadeOutLength: UInt16 = 0x1204
        // Timecode
        static let timecodeStart: UInt16 = 0x1501
        static let timecodeFPS: UInt16 = 0x1502
        static let timecodeDrop: UInt16 = 0x1503
        // Transition
        static let transitionOperationGroup: UInt16 = 0x1801
        static let cutPoint: UInt16 = 0x1802
        // ContentStorage
        static let mobs: UInt16 = 0x1901
        // DefinitionObject
        static let identification: UInt16 = 0x1B01
        static let name: UInt16 = 0x1B02
        // OperationDefinition
        static let isTimeWarp: UInt16 = 0x1E02
        // Dictionary
        static let operationDefinitions: UInt16 = 0x2603
        static let parameterDefinitions: UInt16 = 0x2604
        static let dataDefinitions: UInt16 = 0x2605
        // EssenceDescriptor
        static let locators: UInt16 = 0x2F01
        // FileDescriptor
        static let sampleRate: UInt16 = 0x3001
        static let fileLength: UInt16 = 0x3002
        // DigitalImageDescriptor
        static let storedHeight: UInt16 = 0x3202
        static let storedWidth: UInt16 = 0x3203
        static let displayHeight: UInt16 = 0x3208
        static let displayWidth: UInt16 = 0x3209
        // Header
        static let content: UInt16 = 0x3B03
        static let dictionary: UInt16 = 0x3B04
        // SoundDescriptor
        static let audioSamplingRate: UInt16 = 0x3D03
        static let channels: UInt16 = 0x3D07
        // NetworkLocator, TextLocator
        static let urlString: UInt16 = 0x4001
        static let locatorName: UInt16 = 0x4101
        // Mob
        static let mobID: UInt16 = 0x4401
        static let mobName: UInt16 = 0x4402
        static let slots: UInt16 = 0x4403
        static let usageCode: UInt16 = 0x4408
        // SourceMob
        static let essenceDescription: UInt16 = 0x4701
        // MobSlot
        static let slotID: UInt16 = 0x4801
        static let slotName: UInt16 = 0x4802
        static let segment: UInt16 = 0x4803
        // EventMobSlot, TimelineMobSlot
        static let eventEditRate: UInt16 = 0x4901
        static let editRate: UInt16 = 0x4B01
        static let origin: UInt16 = 0x4B02
        // Parameter
        static let parameterDefinition: UInt16 = 0x4C01
        // ConstantValue
        static let value: UInt16 = 0x4D01
        // VaryingValue, ControlPoint
        static let pointList: UInt16 = 0x4E02
        static let controlPointValue: UInt16 = 0x1A02
        static let controlPointTime: UInt16 = 0x1A03
    }
}

/// The types of values read out of parameters.
enum AAFType {
    static let uint8 = AUID("01010100-0000-0000-060e-2b3401040101")
    static let uint16 = AUID("01010200-0000-0000-060e-2b3401040101")
    static let uint32 = AUID("01010300-0000-0000-060e-2b3401040101")
    static let int8 = AUID("01010500-0000-0000-060e-2b3401040101")
    static let int16 = AUID("01010600-0000-0000-060e-2b3401040101")
    static let int32 = AUID("01010700-0000-0000-060e-2b3401040101")
    static let int64 = AUID("01010800-0000-0000-060e-2b3401040101")
    static let rational = AUID("03010100-0000-0000-060e-2b3401040101")
}

/// The definitions in AAF's dictionary that a timeline is read with: the
/// kinds of data a component carries, the effects an operation group can
/// be, and their parameters.
enum AAFDefinition {
    static let picture = AUID("01030202-0100-0000-060e-2b3404010101")
    static let legacyPicture = AUID("6f3c8ce1-6cef-11d2-807d-006008143e6f")
    static let pictureWithMatte = AUID("05cba732-1daa-11d3-80ad-006008143e6f")
    static let sound = AUID("01030202-0200-0000-060e-2b3404010101")
    static let legacySound = AUID("78e1ebe1-6cef-11d2-807d-006008143e6f")

    static let videoDissolve = AUID("0c3bea40-fc05-11d2-8a29-0050040ef7d2")
    static let monoAudioDissolve = AUID("0c3bea41-fc05-11d2-8a29-0050040ef7d2")
    static let stereoAudioDissolve = AUID("0c3bea42-fc05-11d2-8a29-0050040ef7d2")
    static let videoSpeedControl = AUID("9d2ea890-0968-11d3-8a38-0050040ef7d2")
    static let monoAudioGain = AUID("9d2ea894-0968-11d3-8a38-0050040ef7d2")
    static let stereoAudioGain = AUID("9d2ea895-0968-11d3-8a38-0050040ef7d2")
    static let monoAudioPan = AUID("9d2ea893-0968-11d3-8a38-0050040ef7d2")

    static let speedRatio = AUID("72559a80-24d7-11d3-8a50-0050040ef7d2")
    static let amplitude = AUID("e4962321-2267-11d3-8a4c-0050040ef7d2")
    static let pan = AUID("e4962322-2267-11d3-8a4c-0050040ef7d2")

    static let topLevelUsage = AUID("0d010102-0101-0700-060e-2b3404010101")
}

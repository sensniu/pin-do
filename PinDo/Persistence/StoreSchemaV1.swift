import Foundation
import Observation
import SwiftData

/// Explicit public SwiftData model conformance keeps the schema independent of build-time macros.
/// Backing and observation layout matches the SDK's generated model for change tracking.
final class StoreRecord: PersistentModel {
    private var _$backingData: any BackingData<StoreRecord> = StoreRecord.createBackingData()
    private let _$observationRegistrar = ObservationRegistrar()

    var persistentBackingData: any BackingData<StoreRecord> {
        get { _$backingData }
        set { _$backingData = newValue }
    }

    static var schemaMetadata: [Schema.PropertyMetadata] {
        [
            .init(name: "key", keypath: \StoreRecord.key, defaultValue: ""),
            .init(name: "bucket", keypath: \StoreRecord.bucket, defaultValue: ""),
            .init(name: "payload", keypath: \StoreRecord.payload, defaultValue: Data())
        ]
    }

    init(backingData: any BackingData<StoreRecord>) { persistentBackingData = backingData }

    init(key: String, bucket: String, payload: Data) {
        persistentBackingData = Self.createBackingData()
        self.key = key
        self.bucket = bucket
        self.payload = payload
    }

    var key: String {
        get {
            _$observationRegistrar.access(self, keyPath: \Self.key)
            return getValue(forKey: \Self.key)
        }
        set {
            _$observationRegistrar.withMutation(of: self, keyPath: \Self.key) {
                setValue(forKey: \Self.key, to: newValue)
            }
        }
    }

    var bucket: String {
        get {
            _$observationRegistrar.access(self, keyPath: \Self.bucket)
            return getValue(forKey: \Self.bucket)
        }
        set {
            _$observationRegistrar.withMutation(of: self, keyPath: \Self.bucket) {
                setValue(forKey: \Self.bucket, to: newValue)
            }
        }
    }

    var payload: Data {
        get {
            _$observationRegistrar.access(self, keyPath: \Self.payload)
            return getValue(forKey: \Self.payload)
        }
        set {
            _$observationRegistrar.withMutation(of: self, keyPath: \Self.payload) {
                setValue(forKey: \Self.payload, to: newValue)
            }
        }
    }
}

enum StoreSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [StoreRecord.self] }
}

enum StoreMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [StoreSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}


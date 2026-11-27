import Foundation

nonisolated public struct RailwayBase: Codable, Equatable, Sendable {
    public let resource:String
    public let key:[String:String]
    public let revision:String?
    public init(resource:String,key:[String:String],revision:String?){self.resource=resource;self.key=key;self.revision=revision}
    enum CodingKeys:String,CodingKey{case resource,key,revision}
    public func encode(to encoder:Encoder)throws{
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(resource,forKey:.resource);try c.encode(key,forKey:.key)
        if let revision{try c.encode(revision,forKey:.revision)}else{try c.encodeNil(forKey:.revision)}
    }
}
nonisolated public struct RailwayMutation: Codable, Equatable, Sendable {
    public let id:String
    public let changedAt:String
    public let spaceID:String
    public let operation:String
    public let params:[String:String]
    public let body:RailwayJSON
    public let base:[RailwayBase]
    public let identityPlan:[String]?
    public let dependsOn:[String]?
    public let priority:String?
    public init(id:String=UUID().uuidString,changedAt:String=RailwayJSON.timestamp(),spaceID:String,operation:String,params:[String:String]=[:],body:RailwayJSON = .object([:]),base:[RailwayBase],identityPlan:[String]?=nil,dependsOn:[String]?=nil,priority:String?=nil){
        self.id=id;self.changedAt=changedAt;self.spaceID=spaceID;self.operation=operation;self.params=params;self.body=body;self.base=base;self.identityPlan=identityPlan;self.dependsOn=dependsOn;self.priority=priority
    }
}
nonisolated public struct RailwayRecord: Codable, Equatable, Sendable {
    public let resource:String
    public let record_key:[String:String]
    public let revision:String
    public let payload:RailwayJSON?
    public let deleted:Bool?
    public let changed_at:String?
    public let edit_source:String?
    public let ordinal:String?
    public let cursor:String?
    public var isDeleted:Bool{deleted==true}
    public var key:RailwayRecordKey{.init(resource:resource,key:record_key)}
}
nonisolated public struct RailwayRecordKey: Codable, Equatable, Sendable {
    public let resource:String
    public let key:[String:String]
    public var stable:String {resource+":"+(String(data:(try? RailwayJSON.encoder.encode(key)) ?? Data(),encoding:.utf8) ?? "")}
}
nonisolated public struct RailwayTransaction:Codable,Sendable {public let id:String;public let changes:[RailwayRecord]}
nonisolated public struct RailwayPull:Codable,Sendable {public let transactions:[RailwayTransaction];public let nextCursor:String;public let hasMore:Bool}
nonisolated public struct RailwaySnapshot:Codable,Sendable {public let snapshotID:String;public let cursor:String;public let itemCount:String;public let expiresAt:String}
nonisolated public struct RailwaySnapshotPage:Codable,Sendable {public let items:[RailwayRecord];public let nextAfter:String;public let hasMore:Bool;public let cursor:String}
nonisolated public struct RailwayAck:Codable,Sendable {public let cursor:String}
nonisolated public struct RailwayReceiptChange:Codable,Sendable {
    public let resource:String;public let key:[String:String];public let revision:String;public let deleted:Bool;public let changed_at:String?
}
nonisolated public struct RailwayOutcome:Codable,Sendable {
    public let id:String
    public let status:String
    public let code:String?
    public let reason:String?
    public let retryable:Bool?
    public let resolution:String?
    public let cursor:String?
    public let changes:[RailwayReceiptChange]?
    public let authoritative:[RailwayAuthoritativeRecord]?
    public let refreshFromCloud:Bool?
    public let data:RailwayJSON?
    public var terminal:Bool{status=="applied" || status=="superseded"}
}
nonisolated public struct RailwayAuthoritativeRecord:Codable,Sendable {
    public let resource:String;public let key:[String:String];public let revision:String;public let deleted:Bool;public let payload:RailwayJSON?;public let changed_at:String?
    public var record:RailwayRecord{.init(resource:resource,record_key:key,revision:revision,payload:payload,deleted:deleted,changed_at:changed_at,edit_source:nil,ordinal:nil,cursor:nil)}
}
nonisolated public struct RailwayPushResponse:Codable,Sendable {public let results:[RailwayOutcome];public let headCursor:String;public let atomic:Bool;public let committed:Bool}
nonisolated public struct RailwaySyncPreferences:Codable,Equatable,Sendable {
    public var cellularMetadata=true
    public var wifiLargeDownloads=true
    public var wifiLargeUploads=true
    public var pauseMeteredTransfers=true
    public var respectLowDataMode=true
    public init(){}
}
nonisolated public struct RailwaySyncStatus:Codable,Sendable {
    public let initialized:Bool;public let paused:Bool;public let lastSuccessAt:String?;public let acknowledgedCursor:String;public let headCursor:String
    public let snapshotRequired:Bool;public let preferences:RailwayJSON;public let diagnostics:RailwayJSON;public let operations:[RailwayJSON];public let transfers:[RailwayJSON];public let errors:[RailwayJSON]
}
public actor RailwaySyncAPI {
    private let account:RailwayAccountSession
    public init(account:RailwayAccountSession){self.account=account}
    private func call<T:Decodable & Sendable>(_ type:T.Type,_ method:String,_ path:[String],query:[URLQueryItem]=[],body:RailwayJSON?=nil)async throws->T{
        try await account.request(type,method,["internal","sync"]+path,query:query,body:body)
    }
    public func status()async throws->RailwaySyncStatus{try await call(RailwaySyncStatus.self,"GET",["status"])}
    public func snapshot()async throws->RailwaySnapshot{try await call(RailwaySnapshot.self,"POST",["snapshot"])}
    public func page(_ id:String,after:String)async throws->RailwaySnapshotPage{try await call(RailwaySnapshotPage.self,"GET",["snapshot",id],query:[.init(name:"after",value:after),.init(name:"limit",value:"200")])}
    public func snapshotAck(_ id:String)async throws->RailwayAck{try await call(RailwayAck.self,"POST",["snapshot",id,"ack"])}
    public func pull(after:String)async throws->RailwayPull{try await call(RailwayPull.self,"GET",["changes"],query:[.init(name:"after",value:after),.init(name:"limit",value:"200")])}
    public func acknowledge(_ cursor:String)async throws->RailwayAck{try await call(RailwayAck.self,"POST",["ack"],body:.object(["cursor":.string(cursor)]))}
    public func push(_ mutations:[RailwayMutation],atomic:Bool)async throws->RailwayPushResponse{
        guard !mutations.isEmpty,mutations.count<=100 else{throw RailwayError.invalidParameter}
        return try await call(RailwayPushResponse.self,"POST",["push"],body:.object(["mutations":try RailwayJSON.from(mutations),"mode":.string(atomic ? "atomic":"ordered")]))
    }
    public func configure(paused:Bool?=nil,preferences:RailwaySyncPreferences?=nil,diagnostics:RailwayJSON?=nil)async throws->RailwaySyncStatus{
        var body:[String:RailwayJSON]=[:]
        if let paused{body["paused"] = .bool(paused)}
        if let preferences{body["preferences"] = try RailwayJSON.from(preferences)}
        if let diagnostics{body["diagnostics"]=diagnostics}
        return try await call(RailwaySyncStatus.self,"PATCH",["preferences"],body:.object(body))
    }
}

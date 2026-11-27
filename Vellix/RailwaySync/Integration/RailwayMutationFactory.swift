import Foundation
import GRDB

// A resource-specific command mapper is invoked inside each native domain save.
// IDs and original timestamps are chosen once, then the exact command is persisted.
nonisolated struct RailwayMutationFactory:Sendable {
    let journal:RailwayJournal
    func make(in db:Database,spaceID:String,operation:String,params:[String:String]=[:],body:RailwayJSON = .object([:]),targets:[RailwayRecordKey],changed:[RailwayRecordKey],identityPlan:[String]?=nil,priority:String?=nil,changedAt:String=RailwayJSON.timestamp(),additionalDependencies:[String]=[])throws->RailwayMutation{
        guard !changed.isEmpty,Set(changed.map(\.stable)).count==changed.count,Set(targets.map(\.stable)).count==targets.count else{throw RailwayError.invalidParameter}
        let bases=try targets.map{try journal.base(in:db,key:$0)}
        let deps=Set(additionalDependencies+bases.compactMap{$0.revision?.hasPrefix("after:")==true ? String($0.revision!.dropFirst(6)):nil}).sorted()
        return .init(changedAt:changedAt,spaceID:spaceID,operation:operation,params:params,body:body,base:bases,identityPlan:identityPlan,dependsOn:deps.isEmpty ? nil:deps,priority:priority)
    }
    func documentSave(in db:Database,spaceID:String,id:String,body:RailwayJSON,changedAt:String=RailwayJSON.timestamp())throws{
        let target=RailwayRecordKey(resource:"documents",key:["id":id])
        let mutation=try make(in:db,spaceID:spaceID,operation:"native_document_update",params:["id":id],body:body,targets:[target],changed:[target],priority:"opened",changedAt:changedAt)
        try journal.enqueue(in:db,mutations:[mutation],targets:[[target]])
    }
    func documentCreate(in db:Database,spaceID:String,id:String,body:RailwayJSON,identityPlan:[String]?=nil,changedAt:String=RailwayJSON.timestamp())throws{
        let target=RailwayRecordKey(resource:"documents",key:["id":id])
        var bases=[target]
        for (key,resource) in [("parentDocumentID","documents"),("folderID","folders"),("templateID","templates")]{
            if let id=body[key]?.string{bases.append(.init(resource:resource,key:["id":id]))}
        }
        let mutation=try make(in:db,spaceID:spaceID,operation:"native_document_create",params:["id":id],body:body,targets:bases,changed:[target],identityPlan:identityPlan,priority:"opened",changedAt:changedAt)
        try journal.enqueue(in:db,mutations:[mutation],targets:[[target]])
    }
    func documentMove(in db:Database,spaceID:String,id:String,parentID:String?,folderID:String?,changedAt:String=RailwayJSON.timestamp())throws{
        let target=RailwayRecordKey(resource:"documents",key:["id":id]);var bases=[target]
        if let parentID{bases.append(.init(resource:"documents",key:["id":parentID]))}
        if let folderID{bases.append(.init(resource:"folders",key:["id":folderID]))}
        let mutation=try make(in:db,spaceID:spaceID,operation:"native_document_move",params:["id":id],body:.object(["parentID":parentID.map(RailwayJSON.string) ?? .null,"folderID":folderID.map(RailwayJSON.string) ?? .null]),targets:bases,changed:[target],changedAt:changedAt)
        try journal.enqueue(in:db,mutations:[mutation],targets:[[target]])
    }
    func documentLifecycle(in db:Database,spaceID:String,id:String,action:String,changedAt:String=RailwayJSON.timestamp())throws{
        guard ["trash","restore","purge"].contains(action)else{throw RailwayError.invalidParameter}
        let target=RailwayRecordKey(resource:"documents",key:["id":id])
        let mutation=try make(in:db,spaceID:spaceID,operation:"native_document_"+action,params:["id":id],targets:[target],changed:[target],changedAt:changedAt)
        try journal.enqueue(in:db,mutations:[mutation],targets:[[target]])
    }
}

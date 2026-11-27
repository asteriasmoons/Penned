import Foundation
import GRDB

// Mirrors the server's explicit native command target policy. Resource-specific
// domain hooks supply changed record identities and any compound allocation plan.
nonisolated enum RailwayCommandCatalog {
    static func targets(operation op:String,spaceID:String,params p:[String:String],body b:RailwayJSON,existingDailyNoteID:String?=nil)throws->[RailwayRecordKey]{
        var result:[RailwayRecordKey]=[]
        func add(_ resource:String,_ value:String?,key:String="id")throws{
            guard let value,!value.isEmpty else{throw RailwayError.invalidParameter}
            result.append(.init(resource:resource,key:[key:value]))
        }
        func optional(_ resource:String,_ value:RailwayJSON?)throws{
            if let id=value?.string{try add(resource,id)}
        }
        if op.hasPrefix("native_space_"){try add("spaces",spaceID)}
        else if op.hasPrefix("native_style_"){try add("documentStyles",p["id"])}
        else if op.hasPrefix("native_calendar_"){
            try add("calendarEventNotes",p["id"]);if op != "native_calendar_delete"{try add("documents",b["documentID"]?.string)}
        }else if op=="native_library_default"{try add("librarySpaceDefaults",p["id"],key:"libraryID");try add("spaces",b["spaceID"]?.string)}
        else if op=="native_document_create" || op=="post_v1_documents"{
            if op=="native_document_create"{try add("documents",p["id"])}
            try optional("documents",b["parentDocumentID"]);try optional("folders",b["folderID"]);try optional("templates",b["templateID"])
        }else if op.hasPrefix("native_document_") || op.contains("_v1_documents_"){
            try add("documents",p["documentId"] ?? p["id"])
            if op.hasSuffix("_move") || op.hasSuffix("_duplicate"){try optional("documents",b["parentID"]);try optional("folders",b["folderID"])}
            if let revision=p["revisionId"]{try add("documentSnapshots",revision)}
        }else if op=="native_collection_select_view" || op=="native_collection_restore_field"{
            try add("collections",p["id"]);if op.hasSuffix("_view"){try add("collectionViews",p["itemId"])}
        }else if op.hasPrefix("native_attachment_") || op=="delete_v1_attachments_id"{try add("attachments",p["id"])}
        else if op=="native_snapshot_create"{try add("documentSnapshots",p["id"]);try add("documents",b["documentID"]?.string)}
        else if op=="native_snapshot_delete"{try add("documentSnapshots",p["id"])}
        else if op=="post_v1_folders"{try optional("folders",b["parentFolderID"])}
        else if op.contains("_v1_folders_"){try add("folders",p["id"]);try optional("folders",b["parentID"])}
        else if op=="put_v1_daily_notes_settings"{try add("dailyNoteSettings",spaceID,key:"spaceID");try optional("templates",b["templateID"])}
        else if op.contains("_v1_daily_notes_date"){
            if let existingDailyNoteID{try add("documents",existingDailyNoteID)}
            else if op=="put_v1_daily_notes_date"{try add("dailyNoteSettings",spaceID,key:"spaceID")}
            else{throw RailwayError.invalidParameter}
        }else if op=="post_v1_tasks" || op=="post_v1_collections"{try add("documents",b["documentID"]?.string)}
        else if op.contains("_v1_tasks_"){try add("documentTasks",p["id"])}
        else if op=="post_v1_templates"{}
        else if op.contains("_v1_templates_"){
            try add("templates",p["id"]);try optional("documents",b["parentID"]);try optional("documents",b["appendToID"]);try optional("folders",b["folderID"])
        }else if op=="post_v1_styles_id_apply"{
            try add("documents",b["documentID"]?.string)
            if let id=p["id"],!id.hasPrefix("theme-"){try add("documentStyles",id)}
        }else if op.contains("_v1_collections_"){
            try add("collections",p["id"])
            if let item=p["itemId"]{
                if op.contains("_fields_"){try add("collectionFields",item)}
                else if op.contains("_views_"){try add("collectionViews",item)}
                else if op.contains("_entries_"){try add("collectionEntries",item,key:"documentID");try add("documents",item)}
            }
        }else{throw RailwayError.unsupportedRecord}
        var seen=Set<String>();return result.filter{seen.insert($0.stable).inserted}
    }
}
extension RailwayMutationFactory {
    nonisolated func submit(in db:Database,spaceID:String,operation:String,params:[String:String]=[:],body:RailwayJSON = .object([:]),changed:[RailwayRecordKey],identityPlan:[String]?=nil,existingDailyNoteID:String?=nil,priority:String?=nil,changedAt:String=RailwayJSON.timestamp(),transferIDs:[String]=[])throws{
        let targets=try RailwayCommandCatalog.targets(operation:operation,spaceID:spaceID,params:params,body:body,existingDailyNoteID:existingDailyNoteID)
        let command=try make(in:db,spaceID:spaceID,operation:operation,params:params,body:body,targets:targets,changed:changed,identityPlan:identityPlan,priority:priority,changedAt:changedAt)
        try journal.enqueue(in:db,mutations:[command],targets:[changed],transferIDs:transferIDs)
    }
}

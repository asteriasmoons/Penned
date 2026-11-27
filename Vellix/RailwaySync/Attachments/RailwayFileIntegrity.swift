import Foundation
import CryptoKit

nonisolated enum RailwayFileIntegrity {
    static func digest(_ url:URL)throws->(sha256:String,bytes:Int64){
        let file=try FileHandle(forReadingFrom:url);defer{try? file.close()}
        var hasher=SHA256(),count:Int64=0
        while let bytes=try file.read(upToCount:1024*1024),!bytes.isEmpty{
            try Task.checkCancellation();hasher.update(data:bytes);count+=Int64(bytes.count)
        }
        return(hasher.finalize().map{String(format:"%02x",$0)}.joined(),count)
    }
    static func verify(_ url:URL,sha256:String,bytes:Int64)throws{
        let actual=try digest(url)
        guard actual.sha256==sha256,actual.bytes==bytes else{throw RailwayError.corruptFile}
    }
    static func multipart(source:URL,filename:String,mime:String?,directory:URL,fields:[String:String]=[:])throws->(URL,String){
        guard !filename.isEmpty,!filename.contains("\r"),!filename.contains("\n"),!filename.contains("\""),!filename.contains("\\"),!(mime?.contains("\r") ?? false),!(mime?.contains("\n") ?? false) else{throw RailwayError.invalidParameter}
        let boundary="Penned-"+UUID().uuidString
        let target=directory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath:target.path,contents:nil) else{throw RailwayError.corruptFile}
        do{
            let out=try FileHandle(forWritingTo:target);defer{try? out.close()}
            let input=try FileHandle(forReadingFrom:source);defer{try? input.close()}
            for (key,value) in fields.sorted(by:{$0.key<$1.key}){
                guard ["documentID","revision"].contains(key),!value.contains("\r"),!value.contains("\n"),value.utf8.count<=4096 else{throw RailwayError.invalidParameter}
                try out.write(contentsOf:Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
            }
            try out.write(contentsOf:Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mime ?? "application/octet-stream")\r\n\r\n".utf8))
            while let data=try input.read(upToCount:1024*1024),!data.isEmpty{try Task.checkCancellation();try out.write(contentsOf:data)}
            try out.write(contentsOf:Data("\r\n--\(boundary)--\r\n".utf8));try out.synchronize()
            return(target,"multipart/form-data; boundary="+boundary)
        }catch{try? FileManager.default.removeItem(at:target);throw error}
    }
}

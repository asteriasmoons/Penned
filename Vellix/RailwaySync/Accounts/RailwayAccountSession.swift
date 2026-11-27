import Foundation
import Security
import CryptoKit
import AuthenticationServices

nonisolated public struct RailwaySession: Codable, Sendable {
    public let accessToken:String
    public let refreshToken:String
    public let expiresAt:String
    public let deviceID:String
    public let libraryID:String
    public let ownerKey:String
}
nonisolated public struct RailwayDevice: Codable, Sendable {
    public let name:String?
    public let platform:String
    public init(name:String?,platform:String){self.name=name;self.platform=platform}
}
nonisolated public struct RailwayAppleChallenge: Codable, Sendable { public let challengeId:String; public let nonce:String }
nonisolated private struct LoginResponse: Codable, Sendable { let accessToken:String; let refreshToken:String; let expiresAt:String; let deviceID:String; let libraryID:String }
nonisolated private struct RefreshResponse: Codable, Sendable { let accessToken:String; let expiresAt:String }
nonisolated public struct RailwayAccountProfile: Codable, Sendable {
    public let accountID:String
    public let displayName:String?
    public let email:String?
    public let avatarObjectKey:String?
    public let preferences:RailwayJSON
    public let createdAt:String
    public let purchaseToken:String
    public let identity:RailwayJSON
    public let entitlements:[RailwayJSON]
    public let storageAllowances:RailwayJSON?
    public let devices:[RailwayJSON]
}
nonisolated public struct RailwayKeychain: Sendable {
    let service:String
    public init(service:String){self.service=service}
    private func query(_ key:String)->[String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:key,kSecAttrSynchronizable as String:false] }
    public func read(_ key:String)throws->Data? {
        var q=query(key);q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?;let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status == errSecItemNotFound{return nil}
        guard status == errSecSuccess, let bytes=result as? Data else {throw RailwayError.signedOut};return bytes
    }
    public func write(_ data:Data,key:String)throws {
        let q=query(key); let changes=[kSecValueData as String:data]
        let status=SecItemUpdate(q as CFDictionary,changes as CFDictionary)
        if status == errSecItemNotFound {
            var item=q;item[kSecValueData as String]=data;item[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary,nil) == errSecSuccess else{throw RailwayError.signedOut}
        }else if status != errSecSuccess{throw RailwayError.signedOut}
    }
    public func remove(_ key:String)throws {
        let status=SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {throw RailwayError.signedOut}
    }
}
public actor RailwayAccountSession {
    private let transport:RailwayTransport
    private let keychain:RailwayKeychain
    private var active:RailwaySession?
    private var generation=UUID()
    private var renewal:Task<RefreshResponse,Error>?
    private var signingIn=false
    public init(transport:RailwayTransport,keychain:RailwayKeychain){self.transport=transport;self.keychain=keychain}
    public nonisolated static func libraryID(ownerKey:String)->String {"account-"+SHA256.hash(data:Data(ownerKey.utf8)).map{String(format:"%02x",$0)}.joined()}
    public func suspend(){generation=UUID();renewal?.cancel();renewal=nil;active=nil}
    public func restore(expectedOwner:String)throws->RailwaySession? {
        if let active{guard active.ownerKey==expectedOwner else{throw RailwayError.accountMismatch};return active}
        guard let data=try keychain.read("active-session") else{return nil}
        let record=try JSONDecoder().decode(RailwaySession.self,from:data)
        guard record.ownerKey==expectedOwner,record.libraryID==Self.libraryID(ownerKey:expectedOwner) else{throw RailwayError.accountMismatch}
        active=record;return record
    }
    public nonisolated static func prepareAppleSignInChallenge()async throws->RailwayAppleChallenge{
        let transport=try RailwayTransport(baseURL:URL(string:"https://api.penned.im")!,requestTimeout:5)
        return try await transport.json(RailwayAppleChallenge.self,"POST",["internal","account","apple","challenge"],body:.object(["nonceMode":.string("sha256")]))
    }
    public func appleChallenge()async throws->RailwayAppleChallenge {
        try await transport.json(RailwayAppleChallenge.self,"POST",["internal","account","apple","challenge"])
    }
    // Call the native AuthenticationServices UI with this exact nonce (server hashes it).
    @MainActor public static func appleRequest(_ challenge:RailwayAppleChallenge)->ASAuthorizationAppleIDRequest {
        let request=ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes=[.email,.fullName];request.nonce=challenge.nonce;return request
    }
    public func signInApple(identityToken:Data,challenge:RailwayAppleChallenge,device:RailwayDevice,expectedOwner:String?=nil,recover:Bool=false)async throws->RailwaySession {
        guard let token=String(data:identityToken,encoding:.utf8) else{throw RailwayError.invalidParameter}
        return try await signIn(.object(["provider":.string("apple"),"identityToken":.string(token),"challengeId":.string(challenge.challengeId),"device":try RailwayJSON.from(device)]),expectedOwner:expectedOwner,recover:recover)
    }
    // Existing Supabase auth UI obtains provider proof. Do not store its credential in SQLite.
    public func signInSupabase(accessToken:String,device:RailwayDevice,expectedOwner:String?=nil,recover:Bool=false)async throws->RailwaySession {
        try await signIn(.object(["provider":.string("supabase"),"accessToken":.string(accessToken),"device":try RailwayJSON.from(device)]),expectedOwner:expectedOwner,recover:recover)
    }
    private func signIn(_ body:RailwayJSON,expectedOwner:String?,recover:Bool)async throws->RailwaySession {
        guard !signingIn,active==nil,try keychain.read("active-session")==nil else{throw RailwayError.accountMismatch}
        signingIn=true;defer{signingIn=false}
        let attempt=UUID();generation=attempt
        try await finishPendingRevocation()
        guard generation==attempt else{throw RailwayError.signedOut}
        let result=try await transport.json(LoginResponse.self,"POST",["internal","account",recover ? "recover":"sign-in"],body:body)
        do {
            let profile=try await transport.json(RailwayAccountProfile.self,"GET",["internal","account","profile"],token:result.accessToken)
            guard generation==attempt, result.libraryID==Self.libraryID(ownerKey:profile.accountID),expectedOwner==nil || expectedOwner==profile.accountID else {throw RailwayError.accountMismatch}
            let session=RailwaySession(accessToken:result.accessToken,refreshToken:result.refreshToken,expiresAt:result.expiresAt,deviceID:result.deviceID,libraryID:result.libraryID,ownerKey:profile.accountID)
            try keychain.write(RailwayJSON.encoder.encode(session),key:"active-session");active=session;return session
        }catch{
            _ = try? await transport.send("POST",["internal","account","sign-out"],token:result.accessToken)
            throw error
        }
    }
    // A definitively rejected refresh may be replaced with fresh provider proof.
    // A temporary network error must never discard the persisted account session.
    public func discardRejectedSession()throws {
        generation=UUID();renewal?.cancel();renewal=nil;active=nil
        try keychain.remove("active-session")
    }

    public func binding()throws->RailwaySession {guard let active else{throw RailwayError.signedOut};return active}
    public func token(forceRefresh:Bool=false)async throws->String {
        guard let current=active else{throw RailwayError.signedOut}
        if !forceRefresh,try RailwayJSON.date(current.expiresAt).timeIntervalSinceNow>60{return current.accessToken}
        let fence=generation
        let task:Task<RefreshResponse,Error>
        if let renewal {task=renewal}else {
            let t=transport
            task=Task {try await t.json(RefreshResponse.self,"POST",["internal","account","refresh"],body:.object(["refreshToken":.string(current.refreshToken)]))}
            renewal=task
        }
        do{
            let result=try await task.value
            guard fence==generation,active?.deviceID==current.deviceID else{throw RailwayError.signedOut}
            let next=RailwaySession(accessToken:result.accessToken,refreshToken:current.refreshToken,expiresAt:result.expiresAt,deviceID:current.deviceID,libraryID:current.libraryID,ownerKey:current.ownerKey)
            try keychain.write(RailwayJSON.encoder.encode(next),key:"active-session");active=next;renewal=nil;return next.accessToken
        }catch{
            if fence==generation{
                renewal=nil
                if case RailwayError.http(401,_,_)=error{try discardRejectedSession()}
            }
            throw error
        }
    }
    public func request<T:Decodable & Sendable>(_ type:T.Type,_ method:String,_ path:[String],query:[URLQueryItem]=[],body:RailwayJSON?=nil)async throws->T {
        let fence=generation
        let result:T
        do{result=try await transport.json(type,method,path,query:query,token:token(),body:body)}
        catch RailwayError.http(401,_,_){result=try await transport.json(type,method,path,query:query,token:token(forceRefresh:true),body:body)}
        guard fence==generation else{throw RailwayError.signedOut};return result
    }
    // The workspace coordinator must stop sync and invalidate the old scoped AppDatabase before invoking.
    // Retain the local Library and files. Offline revocation must be retried, not silently claimed successful.
    public func signOut()async throws {
        guard let current=active else{return}
        let pendingKey="pending-revocation"
        try keychain.write(RailwayJSON.encoder.encode(current),key:pendingKey)
        generation=UUID();renewal?.cancel();renewal=nil;active=nil
        try keychain.remove("active-session")
        try await finishPendingRevocation()
    }
    public func finishPendingRevocation()async throws{
        let key="pending-revocation"
        guard let bytes=try keychain.read(key)else{return}
        let old=try JSONDecoder().decode(RailwaySession.self,from:bytes)
        do{
            let result=try await transport.json(RefreshResponse.self,"POST",["internal","account","refresh"],body:.object(["refreshToken":.string(old.refreshToken)]))
            _ = try await transport.send("POST",["internal","account","sign-out"],token:result.accessToken)
        }catch RailwayError.http(401,_,_){
            // An already-revoked device cannot refresh.
        }
        if try keychain.read(key)==bytes{try keychain.remove(key)}
    }
}

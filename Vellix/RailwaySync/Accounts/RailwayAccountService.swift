import Foundation
import StoreKit

nonisolated public struct RailwayRevocation:Codable,Sendable {public let revoked:Bool}
nonisolated public struct RailwayAccountDeactivation:Codable,Sendable {public let purgeAfter:String}
nonisolated public struct RailwayEntitlementResult:Codable,Sendable {public let entitlements:[RailwayJSON]}
public actor RailwayAccountService {
    private let session:RailwayAccountSession
    public init(session:RailwayAccountSession){self.session=session}
    public func profile()async throws->RailwayAccountProfile{try await session.request(RailwayAccountProfile.self,"GET",["internal","account","profile"])}
    public func updateProfile(displayName:RailwayJSON?=nil,preferences:RailwayJSON?=nil,avatarObjectKey:RailwayJSON?=nil)async throws->RailwayAccountProfile{
        var body:[String:RailwayJSON]=[:]
        if let displayName{body["displayName"]=displayName};if let preferences{body["preferences"]=preferences};if let avatarObjectKey{body["avatarObjectKey"]=avatarObjectKey}
        return try await session.request(RailwayAccountProfile.self,"PATCH",["internal","account","profile"],body:.object(body))
    }
    public func devices()async throws->[RailwayJSON]{try await session.request([RailwayJSON].self,"GET",["internal","account","devices"])}
    public func revoke(deviceID:String)async throws->RailwayRevocation{try await session.request(RailwayRevocation.self,"DELETE",["internal","account","devices",deviceID])}
    public func deactivate()async throws->RailwayAccountDeactivation{try await session.request(RailwayAccountDeactivation.self,"POST",["internal","account","deactivate"])}
    // Pass StoreKit's signed JWS. Only the server grants entitlements.
    public func verify(signedTransaction:String)async throws->RailwayEntitlementResult{
        try await session.request(RailwayEntitlementResult.self,"POST",["internal","account","entitlements","verify"],body:.object(["signedTransaction":.string(signedTransaction)]))
    }
}

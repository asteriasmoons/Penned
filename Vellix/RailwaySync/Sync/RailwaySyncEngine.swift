import Foundation
import Network

nonisolated enum RailwaySyncTrigger:Equatable,Sendable {case saved,launch,foreground,reconnected,periodic,realtime,manual,retry}
nonisolated struct RailwayNetworkState:Sendable {
    var connected=false
    var wifi=false
    var expensive=false
    var constrained=false
    func metadataAllowed(_ preferences:RailwaySyncPreferences)->Bool{
        connected && (preferences.cellularMetadata || wifi) && (!preferences.pauseMeteredTransfers || !expensive) && (!preferences.respectLowDataMode || !constrained)
    }
    func assetAllowed(_ preferences:RailwaySyncPreferences,upload:Bool,large:Bool)->Bool{
        connected && (!preferences.pauseMeteredTransfers || !expensive) && (!preferences.respectLowDataMode || !constrained) && (!large || !(upload ? preferences.wifiLargeUploads : preferences.wifiLargeDownloads) || wifi)
    }
}
actor RailwaySyncEngine {
    typealias ApplyIncoming = @Sendable (@escaping @Sendable (Bool) throws -> Bool) async throws -> Void
    private let api:RailwaySyncAPI
    private let account:RailwayAccountSession
    private let transport:RailwayTransport
    private let journal:RailwayJournal
    private var preferences:RailwaySyncPreferences
    private let transfers:RailwayAttachmentTransfers?
    private let nativeRecords:RailwayNativeRecordSender?
    private let applyIncoming:ApplyIncoming
    private var network=RailwayNetworkState()
    private var running=false,working=false,requested=false
    private var generation=UUID()
    private var debounce:Task<Void,Never>?
    private var loop:Task<Void,Never>?
    private var realtime:Task<Void,Never>?
    private var operation:Task<Void,Never>?
    private var monitor:NWPathMonitor?
    private var socket:URLSessionWebSocketTask?
    private(set) var lastStatus:String="idle"
    init(api:RailwaySyncAPI,account:RailwayAccountSession,transport:RailwayTransport,journal:RailwayJournal,preferences:RailwaySyncPreferences = .init(),transfers:RailwayAttachmentTransfers?=nil,nativeRecords:RailwayNativeRecordSender?=nil,applyIncoming:@escaping ApplyIncoming){
        self.api=api;self.account=account;self.transport=transport;self.journal=journal;self.preferences=preferences;self.transfers=transfers;self.nativeRecords=nativeRecords;self.applyIncoming=applyIncoming
    }
    // Explicit integration authorization AND verified cutover are required.
    func start(authorization:RailwayActivationPermit)throws{
        guard authorization.libraryID==journal.libraryID,authorization.verified else{throw RailwayError.releaseDisabled}
        guard !running else{return}
        running=true;generation=UUID()
        let monitor=NWPathMonitor();self.monitor=monitor
        monitor.pathUpdateHandler={ [weak self] path in
            let state=RailwayNetworkState(connected:path.status == .satisfied,wifi:path.usesInterfaceType(.wifi)||path.usesInterfaceType(.wiredEthernet),expensive:path.isExpensive,constrained:path.isConstrained)
            Task{await self?.networkChanged(state)}
        }
        monitor.start(queue:DispatchQueue(label:"Penned.Railway.Network"))
        loop=Task{[weak self] in
            while !Task.isCancelled{
                do{try await Task.sleep(for:.seconds(30))}catch{return}
                await self?.trigger(.periodic)
            }
        }
        trigger(.launch)
    }
    func stop()async{
        running=false;generation=UUID();requested=false
        debounce?.cancel();loop?.cancel();realtime?.cancel();operation?.cancel();monitor?.cancel()
        socket?.cancel(with:.goingAway,reason:nil)
        let outstanding=operation;operation=nil
        await outstanding?.value
        working=false;debounce=nil;loop=nil;realtime=nil;monitor=nil;socket=nil;lastStatus="idle"
    }
    private func networkChanged(_ state:RailwayNetworkState){
        let allowed=network.metadataAllowed(preferences)
        network=state
        if !network.metadataAllowed(preferences){
            socket?.cancel(with:.goingAway,reason:nil);realtime?.cancel();realtime=nil
            lastStatus="offline"
        }else if !allowed{
            trigger(.reconnected);connectRealtime()
        }
    }
    func updatePreferences(_ value:RailwaySyncPreferences)async throws{
        preferences=value
        _ = try await api.configure(preferences:value)
        networkChanged(network)
        trigger(.manual)
    }
    func pause()async throws{
        try journal.setPaused(true);operation?.cancel();socket?.cancel(with:.goingAway,reason:nil);realtime?.cancel();realtime=nil
        await operation?.value
        lastStatus="paused"
        _ = try await api.configure(paused:true)
    }
    func resume()async throws{
        _ = try await api.configure(paused:false)
        try journal.setPaused(false);trigger(.manual);connectRealtime()
    }
    func retryFailed()throws{try journal.retryNow();trigger(.retry)}
    func trigger(_ reason:RailwaySyncTrigger){
        guard running else{return}
        if reason == .saved{
            debounce?.cancel()
            debounce=Task{[weak self] in
                do{try await Task.sleep(for:.milliseconds(750))}catch{return}
                await self?.trigger(.manual)
            };return
        }
        requested=true
        guard !working,network.metadataAllowed(preferences) else{return}
        working=true
        let fence=generation
        operation=Task{[weak self] in await self?.drain(fence:fence)}
    }
    private func check(_ fence:UUID)async throws{
        try Task.checkCancellation()
        guard running,generation==fence,network.metadataAllowed(preferences),!(try journal.checkpoint().paused) else{throw CancellationError()}
        let scope=try await account.binding()
        guard scope.libraryID==journal.libraryID,scope.deviceID==journal.deviceID else{throw RailwayError.accountMismatch}
    }
    private func drain(fence:UUID)async{
        defer{working=false;operation=nil;if requested && running && generation==fence{trigger(.manual)}}
        while requested{
            requested=false
            do{
                try await check(fence);lastStatus="syncing"
                try await synchronize(fence:fence)
                if lastStatus=="paused"{return}
                try await check(fence)
                try await transfers?.scheduleReferencedAssets()
                try await transfers?.drain(network:network,preferences:preferences)
                lastStatus="idle"
                connectRealtime()
            }catch is CancellationError{return}
            catch{
                lastStatus="failed"
                // No tight retry loop; network changes, polling and persisted retry times wake the scheduler.
                requested=false
                return
            }
        }
    }
    private func acknowledgePending(fence:UUID)async throws{
        let checkpoint=try journal.checkpoint()
        guard let pending=checkpoint.pendingAck else{return}
        try await check(fence)
        let ack:RailwayAck
        if pending.hasPrefix("snapshot:"){ack=try await api.snapshotAck(String(pending.dropFirst(9)))}
        else{ack=try await api.acknowledge(pending)}
        try await check(fence)
        try journal.didAcknowledge(ack.cursor,pending:pending)
    }
    private func bootstrap(fence:UUID)async throws{
        try await check(fence)
        let snapshot=try await api.snapshot()
        try await check(fence)
        try journal.stageSnapshot(snapshot)
        var after=try journal.checkpoint().snapshotAfter
        while try RailwayCursor(after)<RailwayCursor(snapshot.itemCount){
            try await check(fence)
            let page=try await api.page(snapshot.snapshotID,after:after)
            try await check(fence)
            guard page.cursor==snapshot.cursor,try RailwayCursor(page.nextAfter)>RailwayCursor(after) else{throw RailwayError.invalidResponse}
            try journal.stagePage(page,id:snapshot.snapshotID);after=page.nextAfter
        }
        let journal=self.journal
        try await applyIncoming {allowApply in try journal.finishSnapshot(snapshot,allowApply:allowApply)}
        try await check(fence)
        try await acknowledgePending(fence:fence)
    }
    private func synchronize(fence:UUID)async throws{
        do{try await acknowledgePending(fence:fence)}
        catch RailwayError.http(409,let code,_) where ["sync_snapshot_required","sync_snapshot_expired","invalid_acknowledgment"].contains(code ?? ""){
            try journal.resetSnapshot()
        }
        let status=try await api.status()
        try await check(fence)
        if status.paused{try journal.setPaused(true);lastStatus="paused";return}
        if try status.snapshotRequired || !journal.checkpoint().initialized {try await bootstrap(fence:fence)}
        // Push first so remote application does not overwrite pending local edits.
        try await nativeRecords?.drain()
        for _ in 0..<10{
            try await check(fence)
            guard let batch=try journal.nextBatch() else{break}
            do{
                let response=try await api.push(batch.mutations,atomic:batch.atomic)
                try await check(fence)
                try journal.receive(response,batch:batch)
                if response.results.contains(where:{!$0.terminal}){
                    try journal.delay(batch,code:response.results.first(where:{!$0.terminal})?.code ?? "retry_pending")
                    break
                }
            }catch is CancellationError{throw CancellationError()}
            catch{
                try journal.delay(batch,code:(error as? RailwayError)?.retryable == true ? "transient":"submission_failed")
                if case .http(409,"sync_snapshot_required",_)? = error as? RailwayError{try journal.resetSnapshot();throw error}
                break
            }
        }
        // Bounded draining per pass; every remote transaction is committed before acknowledgment.
        for _ in 0..<10{
            try await check(fence)
            let after=try journal.checkpoint().cursor
            let page:RailwayPull
            do{page=try await api.pull(after:after)}
            catch RailwayError.http(409,let code,_) where code=="sync_snapshot_required"{try journal.resetSnapshot();throw RailwayError.staleCheckpoint}
            try await check(fence)
            let journal=self.journal
            try await applyIncoming {allowApply in try journal.apply(page,after:after,allowApply:allowApply)}
            try await check(fence)
            try await acknowledgePending(fence:fence)
            if !page.hasMore{return}
        }
        requested=true
    }
    private func connectRealtime(){
        guard running,realtime==nil,network.metadataAllowed(preferences) else{return}
        let fence=generation
        realtime=Task{[weak self] in await self?.realtimeLoop(fence:fence)}
    }
    private func realtimeLoop(fence:UUID)async{
        defer{if fence==generation{realtime=nil;socket=nil}}
        var delay=1
        while !Task.isCancelled{
            do{
                try await check(fence)
                let token=try await account.token()
                let ws=try await transport.socket(["internal","sync","realtime"],token:token);socket=ws
                trigger(.realtime);delay=1
                while !Task.isCancelled{
                    let message=try await ws.receive()
                    try await check(fence)
                    if case .string(let body)=message,let data=body.data(using:.utf8),let value=try? JSONDecoder().decode(RailwayJSON.self,from:data),value["type"]?.string=="changes_available"{trigger(.realtime)}
                }
            }catch{
                socket?.cancel(with:.goingAway,reason:nil);socket=nil
                if Task.isCancelled{return}
                do{try await Task.sleep(for:.seconds(delay))}catch{return}
                delay=min(30,delay*2)
            }
        }
    }
}

import AppKit
import UniformTypeIdentifiers
import WebKit
import SlateTermCore
import SlateTermSettings

@MainActor
final class PluginPane: NSViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    let instance: PluginInstance
    let paneID: PaneID
    let viewID = UUID().uuidString
    let web: WKWebView
    lazy var automation = WebPaneAutomation(web: web, viewID: viewID)
    var onFocus: (() -> Void)?
    var onTitleChange: (() -> Void)?
    private var titleObservation: NSKeyValueObservation?
    private var customTitle: String?
    var paneTitle: String { customTitle ?? web.title.flatMap { $0.isEmpty ? nil : $0 } ?? instance.registration.title }
    func setPaneTitle(_ title: String?) throws {
        guard title == nil || title!.utf8.count <= 512 else { throw RPCFailure(code: -32602, message: "Pane title exceeds 512 UTF-8 bytes") }
        customTitle = title
        onTitleChange?()
    }
    var onRelease: (() -> Void)?
    var onCall: ((String, [String: JSONValue], RPCMetadata?) async throws -> JSONValue)?
    private var status = ""
    private let world = WKContentWorld.world(name: "SlatePluginBridge")
    private var observer: UUID?
    private var closed = false
    private var loadedReadyState = false
    private var currentNavigation: WKNavigation?
    private var blockedNavigations = 0
    var info: JSONValue { .object(["instanceId": .string(instance.id), "viewId": .string(viewID), "url": web.url.map { .string($0.absoluteString) } ?? .null,
                                  "status": .string(status), "documentId": activeDocumentID.map(JSONValue.string) ?? .null, "blockedNavigations": .integer(blockedNavigations)]) }
    private var requests: [String: Task<Void, Never>] = [:]
    // Cached documents retain their isolated script. The view credential stays
    // stable; a separate generation invalidates owned native work on navigation.
    private let bridgeToken = UUID().uuidString
    private var generation = UUID()
    private var acceptsDocument = false
    private var activeDocumentID: String?
    private var retiredDocumentIDs: [String] = []
    private var appearance: AppearanceSnapshot?

    func causationAudience(epoch: UUID) throws -> CausationAudience {
        guard !closed, instance.isReady, acceptsDocument, activeDocumentID != nil else { throw CancellationError() }
        return .plugin(epoch: epoch, registrationID: instance.registration.id, instanceID: instance.id,
                       viewID: UUID(uuidString: viewID)!, documentGeneration: generation)
    }

    init(instance: PluginInstance, paneID: PaneID) {
        self.instance = instance
        self.paneID = paneID
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = instance.dataStore
        if case .directory(let path, _) = instance.registration.source {
            configuration.setURLSchemeHandler(PluginSchemeHandler(root: URL(fileURLWithPath: path), origin: instance.origin), forURLScheme: "plugin")
        }
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        let controller = web.configuration.userContentController
        controller.addScriptMessageHandler(self, contentWorld: world, name: "slate")
        installBridgeScripts()
        web.navigationDelegate = self
        web.uiDelegate = self
        titleObservation = web.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.onTitleChange?() } }
        web.isInspectable = true
    }
    required init?(coder: NSCoder) { nil }
    isolated deinit { close() }

    override func loadView() {
        let root = PaneFocusView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        root.autoresizingMask = [.width, .height]
        root.onFocus = { [weak self] in self?.onFocus?() }
        view = root
        web.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: root.topAnchor), web.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: root.trailingAnchor), web.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        observer = instance.observe { [weak self] in self?.updateState() }
    }

    func activate() { instance.activate() }
    func focus() {
        guard let window = view.window else { return }
        if let responder = window.firstResponder as? NSView, responder !== view, responder.isDescendant(of: view) { return }
        window.makeFirstResponder(web)
    }
    private func updateState() {
        guard !closed else { return }
        status = instance.error ?? instance.state.capitalized
        if instance.isReady, !loadedReadyState {
            loadedReadyState = true
            installBridgeScripts()
            currentNavigation = web.load(URLRequest(url: instance.entryURL))
        } else if !instance.isReady {
            loadedReadyState = false
            currentNavigation = nil
            invalidateDocument()
            web.stopLoading()
        }
    }
    func reloadPlugin() {
        if instance.isReady { installBridgeScripts(); currentNavigation = web.reload() }
        else { Task { [weak self] in await self?.instance.restart() } }
    }

    func close() {
        guard !closed else { return }
        closed = true
        automation.close()
        currentNavigation = nil
        requests.values.forEach { $0.cancel() }
        requests.removeAll()
        if let observer { instance.removeObserver(observer); self.observer = nil }
        web.stopLoading()
        (web.configuration.urlSchemeHandler(forURLScheme: "plugin") as? PluginSchemeHandler)?.close()
        titleObservation = nil
        onTitleChange = nil
        web.navigationDelegate = nil; web.uiDelegate = nil
        web.loadHTMLString("", baseURL: nil)
        web.configuration.userContentController.removeScriptMessageHandler(forName: "slate", contentWorld: world)
        web.configuration.userContentController.removeAllUserScripts()
        onCall = nil; onFocus = nil
        let release = onRelease; onRelease = nil; release?()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = instance.isReady && (navigationAction.request.url.map { instance.origin.matches($0) } ?? false)
        if !allowed { blockedNavigations += 1; status = "External plugin navigation blocked" }
        decisionHandler(allowed ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, instance.isReady, instance.origin.matches(url) { currentNavigation = web.load(navigationAction.request) }
        else { blockedNavigations += 1; status = "External plugin navigation blocked" }
        return nil
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        currentNavigation = navigation
        automation.invalidate()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        currentNavigation = navigation
        invalidateDocument()
        acceptsDocument = true
        customTitle = nil
        onTitleChange?()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let navigation, navigation === currentNavigation, !closed, instance.isReady,
           web.url.map({ instance.origin.matches($0) }) == true {
            automation.documentFinished()
            status = "Ready"
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if navigation === currentNavigation { status = error.localizedDescription; automation.invalidate() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        guard let navigation, navigation === currentNavigation else { return }
        status = error.localizedDescription
        if !closed, instance.isReady, !web.isLoading,
           web.url.map({ instance.origin.matches($0) }) == true { automation.documentFinished() }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        currentNavigation = nil
        invalidateDocument()
        automation.processTerminated()
        status = "Web process exited — Reload Plugin to recover"
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let origin = instance.origin
        let actual = message.frameInfo.securityOrigin
        let port = actual.port == 0 ? (actual.protocol == "https" ? 443 : actual.protocol == "http" ? 80 : 0) : actual.port
        guard !closed, instance.isReady, acceptsDocument, message.webView === web, message.frameInfo.isMainFrame,
              actual.protocol.lowercased() == origin.scheme, actual.host.lowercased() == origin.host, port == origin.port,
              web.url.map({ origin.matches($0) }) == true else { replyHandler(nil, "Bridge origin is not registered"); return }
        do {
            guard JSONSerialization.isValidJSONObject(message.body) else { throw RPCFailure(code: -32602, message: "Invalid bridge object") }
            let data = try JSONSerialization.data(withJSONObject: message.body)
            guard data.count <= 65_536,
                  let object = try JSONDecoder().decode(JSONValue.self, from: data).object,
                  object["token"]?.string == bridgeToken,
                  let documentID = object["documentId"]?.string, documentID.utf8.count == 32,
                  !retiredDocumentIDs.contains(documentID), activeDocumentID == nil || activeDocumentID == documentID,
                  case .integer(let requestID) = object["requestId"], requestID > 0, requestID <= 9_007_199_254_740_991 else { throw RPCFailure(code: -32602, message: "Invalid bridge request") }
            activeDocumentID = documentID
            let id = documentID + ":" + String(requestID)
            if object["cancel"] == .bool(true) {
                // Cancellation must still work when all ordinary request slots are full.
                requests[id]?.cancel()
                replyHandler(NSNull(), nil)
                return
            }
            guard requests.count < 32, requests[id] == nil,
                  let method = object["method"]?.string, let params = object["params"]?.object else { throw RPCFailure(code: -32602, message: "Bridge request limit or duplicate/invalid request") }
            let metadata = try object["metadata"].map { try JSONDecoder().decode(RPCMetadata.self, from: JSONEncoder().encode($0)) }
            let expectedGeneration = generation
            requests[id] = Task { [weak self] in
                guard let self else { replyHandler(nil, "Plugin view closed"); return }
                defer { self.requests.removeValue(forKey: id) }
                do {
                    guard !self.closed, self.instance.isReady, self.generation == expectedGeneration, self.activeDocumentID == documentID, !Task.isCancelled, let call = self.onCall else { throw CancellationError() }
                    let result = try await call(method, params, metadata)
                    guard !self.closed, self.instance.isReady, self.generation == expectedGeneration, self.activeDocumentID == documentID, !Task.isCancelled else { throw CancellationError() }
                    let bytes = try JSONEncoder().encode(result)
                    guard bytes.count <= 1_048_576 else { throw RPCFailure(code: -32025, message: "Bridge response exceeds 1 MiB") }
                    replyHandler(["ok": true, "value": try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])], nil)
                } catch { replyHandler(Self.bridgeFailure(error), nil) }
            }
        } catch { replyHandler(Self.bridgeFailure(error), nil) }
    }

    private static func bridgeFailure(_ error: any Error) -> [String: Any] {
        let failure = error as? RPCFailure ?? RPCFailure(code: error is CancellationError ? -32022 : -32602, message: String(describing: error))
        var details: [String: Any] = ["code": failure.code, "message": failure.message]
        if let data = failure.data, let bytes = try? JSONEncoder().encode(data), let value = try? JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]) { details["data"] = value }
        return ["ok": false, "error": details]
    }

    /// Integration-only caller in WorkspaceHost; never part of the page bridge.
    func evaluateForTesting(_ source: String) async throws -> JSONValue {
        let value = try await web.callAsyncJavaScript("return await (\(source));", arguments: [:], in: nil, contentWorld: .page)
        let data = try JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.fragmentsAllowed])
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func invalidateDocument() {
        automation.invalidate()
        acceptsDocument = false
        generation = UUID()
        if let activeDocumentID {
            retiredDocumentIDs.append(activeDocumentID)
            if retiredDocumentIDs.count > 256 { retiredDocumentIDs.removeFirst() }
        }
        activeDocumentID = nil
        requests.values.forEach { $0.cancel() }
    }

    private func installBridgeScripts() {
        invalidateDocument()
        installUserScripts()
    }

    /// Replaces the scripts for future documents without retiring the live one.
    private func installUserScripts() {
        let controller = web.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: bridgeScript(isolated: true), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        controller.addUserScript(WKUserScript(source: bridgeScript(isolated: false), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        if let appearance {
            controller.addUserScript(WKUserScript(source: themeScript(appearance), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        }
    }

    /// Sets the terminal palette as CSS variables before page scripts run, and again in the live page on change.
    func apply(appearance snapshot: AppearanceSnapshot) {
        guard !closed else { return }
        appearance = snapshot
        web.underPageBackgroundColor = NSColor(hex: snapshot.colors.background)
        installUserScripts()
        web.evaluateJavaScript(themeScript(snapshot), in: nil, in: world) { _ in }
    }

    private func themeScript(_ snapshot: AppearanceSnapshot) -> String {
        let colors = snapshot.colors
        var variables = ["--st-bg": colors.background, "--st-fg": colors.foreground, "--st-cursor": colors.cursor,
                         "--st-selection-bg": colors.selectionBackground, "--st-selection-fg": colors.selectionForeground]
        for (index, color) in colors.ansi.enumerated() { variables["--st-ansi-\(index)"] = color }
        // WebKit cannot address the default "SF Mono" by name, so ui-monospace follows it.
        let family = snapshot.fontFamily.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "")
        variables["--st-font-mono"] = "\"\(family)\", ui-monospace, Menlo, monospace"
        // Plugin UIs read best one point below the terminal size.
        variables["--st-font-mono-size"] = String(format: "%gpx", min(16, max(10, snapshot.fontSize - 1)))
        let theme = JSONValue.object(["variables": .object(variables.mapValues(JSONValue.string)), "tone": .string(snapshot.tone)])
        let encoded = String(decoding: try! JSONEncoder().encode(theme), as: UTF8.self)
        return "(()=>{\(originGuard)const theme=\(encoded),root=document.documentElement;if(!root)return;" + #"""
        for(const [name,value] of Object.entries(theme.variables))root.style.setProperty(name,value);
        root.dataset.appearance=theme.tone;root.style.colorScheme=theme.tone;
        })();
        """#
    }

    private var originGuard: String {
        let origin = instance.origin
        let encodedHost = String(decoding: try! JSONEncoder().encode(origin.host), as: UTF8.self)
        let encodedScheme = String(decoding: try! JSONEncoder().encode(origin.scheme + ":"), as: UTF8.self)
        return "const url=new URL(location.href);if(url.protocol!==\(encodedScheme)||url.hostname!==\(encodedHost)||(Number(url.port)|| (url.protocol==='https:'?443:url.protocol==='http:'?80:0))!==\(origin.port))return;"
    }

    private func bridgeScript(isolated: Bool) -> String {
        let guardOrigin = originGuard
        if isolated {
            let token = String(decoding: try! JSONEncoder().encode(bridgeToken), as: UTF8.self)
            return "(()=>{\(guardOrigin)const token=\(token);" + #"""
            const newDocumentId=()=>Array.from(crypto.getRandomValues(new Uint8Array(16)),byte=>byte.toString(16).padStart(2,'0')).join('');
            let documentId=newDocumentId();
            window.addEventListener('pageshow',event=>{if(event.persisted)documentId=newDocumentId();});
            // Public correlation ID, not the privileged token. A synchronous DOM
            // event avoids changing author markup or racing framework hydration.
            document.addEventListener('slate-document-query',()=>{
              document.dispatchEvent(new CustomEvent('slate-document-identity',{detail:documentId}));
            });
            const send=window.postMessage.bind(window);
            window.addEventListener('message',async event=>{
              const data=event.data;
              if(event.source!==window||!data||data.documentId!==documentId||!['slate-request','slate-cancel'].includes(data.channel)||!Number.isSafeInteger(data.id)||data.id<=0)return;
              const cancel=data.channel==='slate-cancel',requestDocumentId=documentId;
              try {
                const value=await window.webkit.messageHandlers.slate.postMessage({token,documentId:requestDocumentId,requestId:data.id,cancel,method:data.method??'',params:data.params??{},...(data.metadata===undefined?{}:{metadata:data.metadata})});
                if(!cancel)send({channel:'slate-response',documentId:requestDocumentId,id:data.id,...(value.ok?{value:value.value}:{error:value.error})},'*');
              } catch(error) {if(!cancel)send({channel:'slate-response',documentId:requestDocumentId,id:data.id,error:String(error)},'*');}
            });
            })();
            """#
        }
        let identity = JSONValue.object(["id": .string(instance.registration.id), "instanceId": .string(instance.id), "scope": .string(instance.registration.scope.rawValue), "viewId": .string(viewID), "paneId": .string(paneID.description)])
        let encodedIdentity = String(decoding: try! JSONEncoder().encode(identity), as: UTF8.self)
        let encodedMethods = String(decoding: try! JSONEncoder().encode(AutomationMethod.publicMethods.map(\.rawValue)), as: UTF8.self)
        return "(()=>{\(guardOrigin)const plugin=Object.freeze(\(encodedIdentity)),methodNames=Object.freeze(\(encodedMethods));" + #"""
        const send=window.postMessage.bind(window),pending=new Map();let sequence=0;
        const currentDocumentId=()=>{
          let identity;
          const receive=event=>{if(typeof event.detail==='string')identity=event.detail;};
          document.addEventListener('slate-document-identity',receive);
          try{document.dispatchEvent(new Event('slate-document-query'));}finally{document.removeEventListener('slate-document-identity',receive);}
          return identity;
        };
        window.addEventListener('pagehide',()=>{
          for(const request of Array.from(pending.values()))request.cancel(new DOMException('Plugin document left the page','AbortError'));
        });
        window.addEventListener('message',event=>{
          const data=event.data;if(event.source!==window||!data||data.channel!=='slate-response')return;
          const request=pending.get(data.id);if(!request||request.documentId!==data.documentId)return;request.cleanup();
          if(data.error){const error=new Error(typeof data.error==='object'?data.error.message:String(data.error));if(Number.isInteger(data.error.code))error.code=data.error.code;if(data.error.data!==undefined)error.data=data.error.data;request.reject(error);}
          else request.resolve(data.value);
        });
        const call=(method,params={}, {signal,cause}={})=>new Promise((resolve,reject)=>{
          if(signal?.aborted){reject(new DOMException('Workspace request aborted','AbortError'));return;}
          if(pending.size>=32){reject(new Error('Too many outstanding workspace requests'));return;}
          const id=++sequence,documentId=currentDocumentId();
          if(typeof documentId!=='string'){reject(new Error('Plugin bridge document is unavailable'));return;}
          const cleanup=()=>{pending.delete(id);clearTimeout(timer);signal?.removeEventListener('abort',abort);};
          const cancel=error=>{if(!pending.has(id))return;cleanup();send({channel:'slate-cancel',documentId,id},'*');reject(error);};
          const abort=()=>cancel(new DOMException('Workspace request aborted','AbortError'));
          const nativeTimeout=Number.isInteger(params.timeoutMilliseconds)&&params.timeoutMilliseconds>=1&&params.timeoutMilliseconds<=295000?params.timeoutMilliseconds:30000;
          const timeout=method==='command.run'&&typeof params.id==='string'&&params.id.startsWith('plugin.')?300000:
            ['terminal.run','terminal.wait'].includes(method)?nativeTimeout+5000:30000;
          const timer=setTimeout(()=>cancel(new Error('Workspace request timed out')),timeout);
          pending.set(id,{resolve,reject,cleanup,cancel,documentId});
          signal?.addEventListener('abort',abort,{once:true});
          try{send({channel:'slate-request',documentId,id,method,params,...(cause===undefined?{}:{metadata:{version:1,cause}})},'*');}catch(error){cleanup();reject(error);}
        });
        const methodsFor=prefix=>Object.freeze(Object.fromEntries(methodNames.filter(name=>name.startsWith(prefix)).map(name=>[name.slice(prefix.length),(params={},options={})=>call(name,params,options)])));
        const workspace={
          plugin,call,methods:methodNames,
          rpc:Object.freeze(Object.fromEntries(methodNames.map(name=>[name,(params={},options={})=>call(name,params,options)]))),
          setTitle:(title,options={})=>call('pane.title',{title},options),
          context:(params={})=>call('context.get',params),
          self:()=>call('context.inspect'),
          inspect:(params={})=>call('workspace.snapshot',params),
          api:()=>call('api.describe'),
          panes:Object.freeze({
            inspect:(params={})=>call('pane.inspect',params),
            split:(params,options={})=>call('command.run',{...params,id:'pane.split'},options),
            move:(target,direction,params={},options={})=>call('command.run',{...params,id:'pane.move',target,direction},options),
            setTitle:(title,params={},options={})=>call('command.run',{...params,id:'pane.title.set',title},options),
            clearTitle:(params={},options={})=>call('command.run',{...params,id:'pane.title.clear'},options),
            showHeader:(params={},options={})=>call('command.run',{...params,id:'pane.header.show'},options),
            hideHeader:(params={},options={})=>call('command.run',{...params,id:'pane.header.hide'},options),
            toggleHeader:(params={},options={})=>call('command.run',{...params,id:'pane.header.toggle'},options)
          }),
          layout:Object.freeze({get:(params={})=>call('layout.get',params),resize:(path,firstChildFraction,params={},options={})=>call('command.run',{...params,id:'layout.resize',path,firstChildFraction},options)}),
          tabs:Object.freeze({
            reorder:(index,params={},options={})=>call('command.run',{...params,id:'tab.reorder',index},options),
            move:(group,params={},options={})=>call('command.run',{...params,id:'tab.move',group},options),
            detach:(params={},options={})=>call('command.run',{...params,id:'tab.detach'},options)
          }),
          command:(id,params={},options={})=>call('command.run',{...params,id},options),
          settings:()=>call('settings.get'),
          appearance:Object.freeze({
            get:()=>call('appearance.get'),
            onChange:(handler,options={})=>workspace.subscribe(handler,{...options,topics:['host.appearance.changed']})
          }),
          pluginSettings:Object.freeze({get:()=>call('plugins.settings.get'),patch:(operations,expectedWriteRevision,options={})=>call('plugins.settings.patch',{operations,expectedWriteRevision},options)}),
          web:methodsFor('web.'),
          browser:methodsFor('browser.'),
          services:methodsFor('plugins.service.'),
          layoutConfiguration:(params={},options={})=>call('layout.configuration',params,options),
          layouts:Object.freeze({
            list:(params={},options={})=>call('layouts.list',params,options),
            get:(id,params={},options={})=>call('layouts.get',{...params,id},options),
            fields:(type,options={})=>call('layouts.fields',type===undefined?{}:{type},options),
            validate:(definition,options={})=>call('layouts.validate',{definition},options),
            create:(definition,options={})=>call('layouts.create',{definition},options),
            update:(definition,expectedSavedLayoutRevision,options={})=>call('layouts.update',{definition,expectedSavedLayoutRevision},options),
            windows:(params={},options={})=>call('layouts.windows',params,options),
            capture:(params,options={})=>call('layouts.capture',params,options),
            open:(id,params={},options={})=>call('layouts.open',{...params,id},options),
            launcher:(id,path,options={})=>call('layouts.launcher',{id,path},options),
            startupStatus:(params={},options={})=>call('layouts.startupStatus',params,options)
          }),
          terminal:Object.freeze({
            send:(text,params={},options={})=>call('terminal.send',{...params,text},options),
            capture:(params={})=>call('terminal.capture',params),
            key:(key,params={},options={})=>call('terminal.key',{...params,key},options),
            run:(command,params={},options={})=>call('terminal.run',{...params,command},options),
            wait:(params={},options={})=>call('terminal.wait',params,options)
          }),
          storage:Object.freeze({get:key=>call('storage.get',key===undefined?{}:{key}),set:(key,value,options={})=>call('storage.set',{key,value},options),delete:(key,options={})=>call('storage.delete',{key},options)}),
          emit:(topic,payload,options={})=>{const {cause,signal,...routing}=options;return call('events.emit',{...routing,topic,payload},{cause,signal});},
          subscribe:async (handler,options={})=>{
            let active=true,cursor=options.after;
            const {onError,...query}=options,controller=new AbortController();
            if(typeof handler!=='function'||(onError!==undefined&&typeof onError!=='function'))throw new TypeError('Subscription callbacks must be functions');
            if(query.waitMilliseconds===0)throw new RangeError('Subscriptions require a positive waitMilliseconds');
            const loop=async()=>{while(active){try{const params={...query};if(cursor!==undefined)params.after=cursor;const batch=await call('events.poll',params,{signal:controller.signal});cursor=batch.cursor;for(const event of batch.events){if(active)await handler(event);}}catch(error){if(active){active=false;onError?.(error);}}}};
            void loop();return ()=>{active=false;controller.abort();};
          }
        };
        Object.defineProperty(window,'workspace',{value:Object.freeze(workspace),writable:false,configurable:false});
        })();
        """#
    }
}

@MainActor
private final class PluginSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: URL
    private let origin: PluginOrigin
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var closed = false
    init(root: URL, origin: PluginOrigin) { self.root = root; self.origin = origin }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard !closed else { urlSchemeTask.didFailWithError(CancellationError()); return }
        guard let url = urlSchemeTask.request.url, origin.matches(url), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            urlSchemeTask.didFailWithError(RPCFailure(code: -32602, message: "Invalid plugin asset origin")); return
        }
        guard requests.count < 64 else { urlSchemeTask.didFailWithError(RPCFailure(code: -32023, message: "Too many asset requests")); return }
        let id = ObjectIdentifier(urlSchemeTask)
        let root = root, path = components.percentEncodedPath, origin = origin
        requests[id] = Task { [weak self] in
            defer { self?.requests.removeValue(forKey: id) }
            do {
                // Disk/network-volume I/O must not block native input. Reads are
                // bounded even if an author replaces or grows an asset mid-load.
                let (data, mime) = try await Task.detached(priority: .userInitiated) {
                    let file = try PluginAssets(root: root).file(forPercentEncodedPath: path)
                    let handle = try FileHandle(forReadingFrom: file)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: 16_777_217) ?? Data()
                    guard data.count <= 16_777_216 else { throw RPCFailure(code: -32602, message: "Plugin asset exceeds 16 MiB") }
                    return (data, UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
                }.value
                guard !Task.isCancelled, self?.requests[id] != nil else { return }
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": String(data.count), "Cache-Control": "no-store", "Access-Control-Allow-Origin": "plugin://\(origin.host)"])!
                urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
            } catch {
                guard !Task.isCancelled, self?.requests[id] != nil else { return }
                urlSchemeTask.didFailWithError(error)
            }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        requests.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
    func close() { closed = true; requests.values.forEach { $0.cancel() }; requests.removeAll() }
}

private extension NSColor {
    /// Parses the normalized #rrggbb values produced by TerminalPalette.
    convenience init(hex: String) {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        self.init(srgbRed: CGFloat(value >> 16) / 255, green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}

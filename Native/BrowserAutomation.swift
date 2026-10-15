import Foundation
import SlateTermCore

/// Main-document DOM operations in a private WebKit content world, never a page bridge.
@MainActor
enum BrowserAutomation {
    static func prepareScript(viewID: String) throws -> String {
        try script(name: "prepare", parameters: ["viewId": .string(viewID)], documentID: "")
    }

    static func script(for action: BrowserAction, documentID: String) throws -> String {
        try script(name: action.kind == .wait ? "probe" : action.kind.rawValue, parameters: action.parameters, documentID: documentID)
    }

    private static func script(name: String, parameters: [String: JSONValue], documentID: String) throws -> String {
        let value = JSONValue.object(["action": .string(name), "args": .object(parameters), "epoch": .string(documentID)])
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        let literal = String(decoding: try JSONEncoder().encode(json), as: UTF8.self)
        return "(()=>{const {action,args,epoch}=JSON.parse(\(literal));" + body + "})()"
    }

    private static let body = #"""
    if(!globalThis.__slateBrowserAutomationLifecycle){
      globalThis.__slateBrowserAutomationLifecycle=true;
      window.addEventListener('pageshow',event=>{if(event.persisted)delete globalThis.__slateBrowserAutomation;});
    }
    let state=globalThis.__slateBrowserAutomation;
    if(action==='prepare'){
      if(!state){state={viewId:args.viewId,epoch:Array.from(crypto.getRandomValues(new Uint8Array(16)),byte=>byte.toString(16).padStart(2,'0')).join(''),next:0,ids:new WeakMap(),refs:new Map()};globalThis.__slateBrowserAutomation=state;}
      if(state.viewId!==args.viewId)throw new Error('Web view identity changed');
      return {viewId:state.viewId,documentId:state.epoch};
    }
    if(!state||state.epoch!==epoch)throw new Error('Stale browser document; take a new snapshot');
    let clipped=false;
    const clip=(value,limit)=>{
      const original=String(value??'');
      let text=original.slice(0,limit);
      if(original.length>limit)clipped=true;
      const last=text.charCodeAt(text.length-1);
      if(last>=0xd800&&last<=0xdbff){text=text.slice(0,-1);clipped=true;}
      return text;
    };
    const shown=element=>{
      if(!element?.isConnected)return false;
      const style=getComputedStyle(element);
      if(style.display==='none'||style.visibility==='hidden'||style.visibility==='collapse'||element.getClientRects().length===0)return false;
      let parent=element,depth=0;
      while(parent){if(++depth>256||Number(getComputedStyle(parent).opacity)===0)return false;parent=parent.parentElement;}
      return true;
    };
    const disabled=element=>element.matches(':disabled')||element.getAttribute('aria-disabled')==='true'||!!element.closest('[inert]');
    const ref=element=>{
      let id=state.ids.get(element);
      if(!id||!state.refs.has(id)){
        id=state.viewId+':'+epoch+':'+(++state.next);state.ids.set(element,id);state.refs.set(id,new WeakRef(element));
        if(state.refs.size>2048)state.refs.delete(state.refs.keys().next().value);
      }
      return id;
    };
    const target=(required=true)=>{
      let element;
      if(args.ref!==undefined){
        if(!args.ref.startsWith(state.viewId+':'+epoch+':')||!state.refs.has(args.ref))throw new Error('Stale element reference; take a new snapshot');
        element=state.refs.get(args.ref).deref();
        if(!element?.isConnected)element=null;
      }else if(args.selector!==undefined){
        const matches=document.querySelectorAll(args.selector);
        if(matches.length>1)throw new Error('Ambiguous selector; use a unique selector or snapshot reference');
        element=matches[0];
      }
      if(required&&!element)throw new Error('No attached element matches the target');
      return element??null;
    };
    const actionable=element=>{
      if(!shown(element)||disabled(element))throw new Error('Element is hidden, disabled or inert');
      element.scrollIntoView({block:'center',inline:'center',behavior:'instant'});
      const rect=element.getBoundingClientRect();
      const left=Math.max(0,rect.left),right=Math.min(innerWidth,rect.right);
      const top=Math.max(0,rect.top),bottom=Math.min(innerHeight,rect.bottom);
      if(right<=left||bottom<=top)throw new Error('Element is outside the viewport');
      const hit=document.elementFromPoint((left+right)/2,(top+bottom)/2);
      if(!hit||!(element===hit||element.contains(hit)))throw new Error('Element is covered by another element');
    };
    const changed=element=>{
      element.dispatchEvent(new Event('input',{bubbles:true}));
      element.dispatchEvent(new Event('change',{bubbles:true}));
    };
    if(action==='snapshot'){
      const elements=[],encoder=new TextEncoder();let visited=0,truncated=false,elementBytes=0;
      const walker=document.createTreeWalker(document.body??document.documentElement,NodeFilter.SHOW_ELEMENT);
      for(let element=walker.currentNode;element;element=walker.nextNode()){
        if(++visited>4000||elements.length>=args.maxElements){truncated=true;break;}
        const candidate=element.matches('a[href],button,input:not([type=hidden]),select,textarea,[role],summary')||(element.hasAttribute('contenteditable')&&element.isContentEditable);
        if(!candidate||!shown(element))continue;
        const tag=element.tagName.toLowerCase(),type=element.getAttribute('type')?.toLowerCase();
        const role=element.getAttribute('role')??({a:'link',button:'button',select:'combobox',textarea:'textbox',summary:'button'}[tag]??(tag==='input'?(type==='checkbox'?'checkbox':type==='radio'?'radio':['button','submit','reset'].includes(type)?'button':'textbox'):'generic'));
        const label=element.getAttribute('aria-label')||Array.from(element.labels??[]).map(label=>clip(label.textContent,256)).join(' ')||element.getAttribute('placeholder')||(tag==='input'?(['submit','reset','button'].includes(type)?element.value:''):element.textContent)||'';
        const rect=element.getBoundingClientRect();
        const item={ref:ref(element),tag,role,name:clip(label.trim(),256),enabled:!disabled(element),
          rect:{x:rect.x,y:rect.y,width:rect.width,height:rect.height},inViewport:rect.bottom>0&&rect.right>0&&rect.top<innerHeight&&rect.left<innerWidth};
        if('value' in element&&type!=='password')item.value=clip(element.value,512);
        if('checked' in element)item.checked=element.checked;
        if(element.hasAttribute('aria-expanded'))item.expanded=element.getAttribute('aria-expanded')==='true';
        elementBytes+=encoder.encode(JSON.stringify(item)).byteLength;
        if(elementBytes>350000){truncated=true;break;}
        elements.push(item);
      }
      const textWalker=document.createTreeWalker(document.body??document.documentElement,NodeFilter.SHOW_TEXT);
      let text='',node,count=0;
      while((node=textWalker.nextNode())){
        if(++count>2048||text.length>=16384){truncated=true;break;}
        const parent=node.parentElement;
        if(parent&&!parent.closest('script,style,noscript,template')&&shown(parent))text+=clip(node.nodeValue,Math.max(0,16384-text.length))+' ';
      }
      truncated=truncated||location.href.length>8192||document.title.length>512;
      return {url:clip(location.href,8192),title:clip(document.title,512),viewId:state.viewId,documentId:epoch,
        viewport:{width:innerWidth,height:innerHeight},scroll:{x:scrollX,y:scrollY},text:clip(text,16384),elements,truncated:truncated||clipped};
    }
    if(action==='probe'){
      const element=target(false),visible=shown(element);
      const matched={attached:!!element,detached:!element,visible,hidden:!visible}[args.state];
      return {matched,state:args.state,viewId:state.viewId,documentId:epoch};
    }
    if(action==='scroll'){
      const element=target(args.ref!==undefined||args.selector!==undefined);
      (element??window).scrollBy({left:args.x,top:args.y,behavior:'instant'});
      return {x:element?element.scrollLeft:scrollX,y:element?element.scrollTop:scrollY,viewId:state.viewId,documentId:epoch};
    }
    const element=target();
    if(action==='click'){
      if(typeof element.click!=='function')throw new Error('Element does not support click');
      actionable(element);
      element.click();return {performed:true,viewId:state.viewId,documentId:epoch};
    }
    if(action==='fill'){
      if(element.readOnly)throw new Error('Element is read-only');
      let prototype;
      if(element instanceof HTMLTextAreaElement)prototype=HTMLTextAreaElement.prototype;
      else if(element instanceof HTMLInputElement&&['text','search','email','url','tel','password'].includes(element.type))prototype=HTMLInputElement.prototype;
      else if(!element.isContentEditable)throw new Error('Fill requires a text input, textarea or contenteditable element');
      actionable(element);
      element.focus({preventScroll:true});
      if(prototype)Object.getOwnPropertyDescriptor(prototype,'value').set.call(element,args.text);
      else element.textContent=args.text;
      changed(element);return {performed:true,viewId:state.viewId,documentId:epoch};
    }
    if(action==='select'){
      if(!(element instanceof HTMLSelectElement))throw new Error('Select requires a select element');
      if(!element.multiple&&args.values.length!==1)throw new Error('Single-select requires exactly one value');
      const options=Array.from(element.options),selected=new Set();
      for(const value of args.values){
        const matches=options.filter(option=>option.value===value);
        if(matches.length!==1||matches[0].disabled||matches[0].parentElement?.disabled)throw new Error('Option value is missing, ambiguous or disabled');
        selected.add(matches[0]);
      }
      actionable(element);
      for(const option of options)option.selected=selected.has(option);
      changed(element);return {performed:true,values:Array.from(element.selectedOptions,option=>option.value),viewId:state.viewId,documentId:epoch};
    }
    throw new Error('Unsupported browser action');
    """#
}

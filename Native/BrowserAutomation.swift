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
    // The acted-on element's viewport rectangle, returned so hosts can frame it.
    let located=null;
    const bounds=element=>{const r=element.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height};};
    const placed=result=>located?Object.assign(result,{rect:located,viewport:{width:innerWidth,height:innerHeight}}):result;
    const actionable=element=>{
      if(!shown(element)||disabled(element))throw new Error('Element is hidden, disabled or inert');
      element.scrollIntoView({block:'center',inline:'center',behavior:'instant'});
      const rect=element.getBoundingClientRect();
      located={x:rect.x,y:rect.y,width:rect.width,height:rect.height};
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
        if(tag==='input'){item.type=element.type;for(const key of ['min','max','step'])if(element.hasAttribute(key))item[key]=clip(element.getAttribute(key),128);}
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
      if(matched&&visible)located=bounds(element);
      return placed({matched,state:args.state,viewId:state.viewId,documentId:epoch});
    }
    if(action==='scroll'){
      const element=target(args.ref!==undefined||args.selector!==undefined);
      (element??window).scrollBy({left:args.x,top:args.y,behavior:'instant'});
      if(element&&shown(element))located=bounds(element);
      return placed({x:element?element.scrollLeft:scrollX,y:element?element.scrollTop:scrollY,viewId:state.viewId,documentId:epoch});
    }
    const element=target();
    const focus=()=>{
      actionable(element);
      element.focus({preventScroll:true});
      if(!element.isConnected||document.activeElement!==element)throw new Error('Target did not retain focus');
      actionable(element);
    };
    if(action==='focus'){
      focus();return placed({focused:true,viewId:state.viewId,documentId:epoch});
    }
    if(action==='key'){
      focus();
      const names={enter:'Enter',tab:'Tab',escape:'Escape',space:' ',plus:'+',backspace:'Backspace',delete:'Delete',
        home:'Home',end:'End',arrowleft:'ArrowLeft',arrowright:'ArrowRight',arrowup:'ArrowUp',arrowdown:'ArrowDown',pageup:'PageUp',pagedown:'PageDown'};
      const mods=new Set(args.modifiers),key=names[args.key]??(mods.has('shift')?args.key.toUpperCase():args.key);
      const init={key,bubbles:true,cancelable:true,composed:true,ctrlKey:mods.has('ctrl'),altKey:mods.has('alt'),shiftKey:mods.has('shift'),metaKey:mods.has('meta')};
      let candidates=[],documentCandidates=[];
      if(key==='Tab'){
        const nodes=document.querySelectorAll('a[href],area[href],button,input,select,textarea,summary,[tabindex],[contenteditable]');
        if(nodes.length>4000)throw new Error('Too many focus candidates');
        documentCandidates=Array.from(nodes).filter(e=>e.tabIndex>=0&&shown(e)&&!disabled(e));
        candidates=[...documentCandidates].sort((a,b)=>{
          const ai=a.tabIndex===0?Infinity:a.tabIndex,bi=b.tabIndex===0?Infinity:b.tabIndex;return ai-bi;
        });
      }
      const unmodified=!mods.has('ctrl')&&!mods.has('alt')&&!mods.has('meta');
      const eligible=()=>element.isConnected&&document.activeElement===element&&!disabled(element)&&shown(element);
      const activatable=()=>element instanceof HTMLButtonElement||element instanceof HTMLInputElement&&['button','submit','reset','checkbox','radio'].includes(element.type);
      const accepted=element.dispatchEvent(new KeyboardEvent('keydown',init));
      let defaultAction='none',released=false;
      // Always balance a submitted press, even if a default action fails. Synthetic
      // events have no native editing defaults beyond those explicitly handled here.
      try {
      if(accepted&&eligible()&&unmodified){
        if(key==='Tab'&&candidates.length){
          const index=candidates.indexOf(element),delta=mods.has('shift')?-1:1;
          const direction=mods.has('shift')?Node.DOCUMENT_POSITION_PRECEDING:Node.DOCUMENT_POSITION_FOLLOWING;
          const relatives=documentCandidates.filter(e=>element.compareDocumentPosition(e)&direction);
          const next=index>=0?candidates[(index+delta+candidates.length)%candidates.length]:
            (mods.has('shift')?relatives.at(-1)??candidates.at(-1):relatives[0]??candidates[0]);
          if(next?.isConnected&&!disabled(next)&&shown(next)){
            next.focus();
            if(!next.isConnected||document.activeElement!==next)throw new Error('Tab destination did not retain focus');
            defaultAction='focus';
          }
        }else if(key==='Enter'&&activatable()){
          element.click();defaultAction='activate';
        }else if(key==='Enter'&&element instanceof HTMLInputElement&&['text','search','email','url','tel','password','number'].includes(element.type)&&element.form){
          const form=element.form,controls=document.querySelectorAll('input,button');
          if(controls.length>4000)throw new Error('Too many form controls');
          const owned=Array.from(controls).filter(e=>e.form===form);
          const submitter=owned.find(e=>e instanceof HTMLButtonElement&&e.type==='submit'||e instanceof HTMLInputElement&&['submit','image'].includes(e.type));
          if(submitter){
            if(!disabled(submitter)){submitter.click();defaultAction='submit';}
          }else{
            const blocking=owned.filter(e=>e instanceof HTMLInputElement&&['text','search','email','url','tel','password','number','date','time','datetime-local','month','week'].includes(e.type));
            if(blocking.length<=1){HTMLFormElement.prototype.requestSubmit.call(form);defaultAction='submit';}
          }
        }
      }
      } finally {
        // Balance against the original element, never a newly focused sibling.
        released=element.dispatchEvent(new KeyboardEvent('keyup',init));
      }
      if(key===' '&&accepted&&released&&eligible()&&unmodified&&activatable()){
        actionable(element);element.click();defaultAction='activate';
      }
      return placed({dispatched:true,defaultPrevented:!accepted||!released,defaultAction,synthetic:true,viewId:state.viewId,documentId:epoch});
    }
    if(action==='check'){
      if(!(element instanceof HTMLInputElement)||!['checkbox','radio'].includes(element.type))throw new Error('Check requires a native checkbox or radio input');
      if(element.type==='radio'&&!args.checked)throw new Error('Select another radio instead of clearing a radio');
      actionable(element);
      const changedState=element.checked!==args.checked;
      if(changedState)element.click();
      if(!element.isConnected||element.checked!==args.checked||element.indeterminate)throw new Error('Control did not retain the requested checked state');
      return placed({performed:changedState,checked:element.checked,viewId:state.viewId,documentId:epoch});
    }
    if(action==='setValue'){
      if(!(element instanceof HTMLInputElement)||!['number','date','time','datetime-local','range'].includes(element.type))throw new Error('SetValue requires a supported typed input');
      if(element.readOnly)throw new Error('Element is read-only');
      actionable(element);
      const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;
      const probe=element.cloneNode(false);
      setter.call(probe,args.value);
      if(probe.value!==args.value||!probe.validity.valid)throw new Error('Value is not canonical or violates input constraints');
      setter.call(element,args.value);changed(element);
      if(!element.isConnected||element.value!==args.value)throw new Error('Input did not retain the requested value');
      return placed({performed:true,value:element.value,type:element.type,viewId:state.viewId,documentId:epoch});
    }
    if(action==='click'){
      if(typeof element.click!=='function')throw new Error('Element does not support click');
      actionable(element);
      element.click();return placed({performed:true,viewId:state.viewId,documentId:epoch});
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
      changed(element);return placed({performed:true,viewId:state.viewId,documentId:epoch});
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
      changed(element);return placed({performed:true,values:Array.from(element.selectedOptions,option=>option.value),viewId:state.viewId,documentId:epoch});
    }
    throw new Error('Unsupported browser action');
    """#
}

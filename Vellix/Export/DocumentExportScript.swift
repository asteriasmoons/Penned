import Foundation

enum DocumentExportScript {
    static let resources = #"""
    const root=document.querySelector('.tiptap-editor');
    if(!root)throw new Error('The export renderer did not initialize.');
    for(;;){
      const more=[...root.querySelectorAll('.penned-collection-footer button')].filter(n=>/^Show More \(/.test(n.textContent));
      if(!more.length)break;more.forEach(n=>n.click());
    }
    const urls=new Set(),styles=[];
    const local=value=>/^(penned-file|penned-cover|vellix-icon):/.test(value);
    const find=value=>{for(const match of value.matchAll(/url\(\s*(['"]?)(.*?)\1\s*\)/g))if(local(match[2]))urls.add(match[2]);};
    for(const img of root.querySelectorAll('img')){const src=img.currentSrc||img.src;if(local(src))urls.add(src);}
    const properties=['background-image','mask-image','-webkit-mask-image'];
    [root,...root.querySelectorAll('*')].forEach((node,index)=>{
      for(const pseudo of ['', '::before','::after']){
        const computed=getComputedStyle(node,pseudo||null),values={};
        for(const property of properties){const value=computed.getPropertyValue(property);if(/(?:penned-file|penned-cover|vellix-icon):/.test(value)){find(value);values[property]=value;}}
        if(Object.keys(values).length)styles.push({index,pseudo,values});
      }
    });
    window.pennedExportResources=styles;
    return [...urls];
    """#

    // Executed after readiness in an export-only WebView. No assembled HTML
    // replacement, live-editor commands, or changes to document JSON.
    static let prepare = #"""
    const root = document.querySelector('.tiptap-editor');
    if (!root) throw new Error('The export renderer did not initialize.');
    const el = (tag, cls, text) => { const n = document.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; };
    const style = el('style'); style.textContent = `
      html,body { margin:0!important; padding:0!important; width:100%!important; overflow:hidden!important; -webkit-print-color-adjust:exact!important; print-color-adjust:exact!important }
      #export-canvas { position:relative; overflow:hidden; background:white; isolation:isolate }
      #export-backdrop,#export-paper { position:absolute; inset:0; background-size:100% 100%; background-repeat:no-repeat }
      #export-paper { inset:18px; border-radius:12px }
      #export-sheets { position:absolute; inset:0 }
      #export-sheets .export-sheet { position:absolute; background-size:100% 100%; background-repeat:no-repeat; border-radius:12px; box-sizing:border-box }
      #export-clip { position:absolute; left:36px; right:36px; top:36px; overflow:hidden }
      #export-flow { position:relative; width:100%; transform-origin:top left }
      #export-flow .tiptap-editor { padding:0!important; min-height:0!important; overflow:visible!important }
      #export-flow * { caret-color:transparent!important; animation:none!important; transition:none!important }
      #export-flow .ProseMirror-selectednode { outline:none!important }
      #export-flow [data-vellix-selected] { outline:none!important; box-shadow:none!important }
      #export-flow .vellix-toggle-content { display:block!important }
      #export-flow details > :not(summary) { display:block!important }
      #export-flow .penned-collection-gallery-scroll { max-height:none!important; overflow:visible!important; mask-image:none!important; -webkit-mask-image:none!important }
      #export-flow .penned-collection-card { padding-bottom:6px!important }
      #export-flow .penned-collection-card-title { display:block!important; -webkit-line-clamp:unset!important }
      #export-flow .penned-collection-scroll,.tableWrapper { overflow:visible!important; max-height:none!important }
      #export-flow button { color:inherit; background:transparent; border:none; text-align:inherit; pointer-events:none }
      #export-flow input { pointer-events:none }
      #export-flow button:disabled,#export-flow input:disabled { opacity:1!important }
      #export-flow .export-title { font-size:24px; font-weight:800; line-height:1.24; margin:24px 0 10px; overflow-wrap:anywhere }
      #export-flow .export-cover { display:block; width:100%; aspect-ratio:1.78; object-fit:cover; border-radius:7px; margin:0 0 28px }
      #export-flow .export-heading { border-bottom:1px solid currentColor; border-color:color-mix(in srgb,currentColor 13%,transparent); padding-bottom:10px; margin-bottom:12px }
      #export-flow .export-subtitle { font-size:21px; opacity:.65; margin:8px 0 }
      #export-flow .export-entry-field { display:grid; grid-template-columns:40% 1fr; gap:10px; align-items:center; padding:12px 0 }
      #export-flow .export-entry-label { display:flex; align-items:center; gap:10px; font-weight:600 }
      #export-flow .export-entry-label img { width:22px; height:22px; margin:0 }
      #export-flow .export-board-column { border-radius:12px; padding:12px; margin:12px 0; color:#f7f7f7 }
      #export-flow .export-board-heading { font-weight:600; display:flex; gap:8px; align-items:center; margin:4px 0 14px }
      #export-flow .export-board-count { background:#0002; border-radius:12px; font-size:12px; padding:3px 7px }
      #export-flow .export-board-card { border-radius:9px; background:#29292b; color:#f7f7f7; padding:12px; margin-top:10px }
      #export-flow .export-board-values { display:flex; flex-wrap:wrap; gap:4px; font-size:13px; margin-top:7px }
      #export-footer { position:absolute; left:36px; right:36px; bottom:28px; display:flex; justify-content:space-between; font:10px system-ui; opacity:.65 }
      #export-flow pre { white-space:pre-wrap!important; overflow-wrap:anywhere; overflow:visible!important }
      #export-flow .vellix-guided-empty::before { content:none!important }
      ${options.image ? '' : '#export-flow [data-vellix-page-break],#export-flow [data-type="pageBreak"] { height:0!important; min-height:0!important; margin:0!important; padding:0!important; border:0!important }'}
      #export-flow .export-media { padding:12px; border:1px solid #8885; border-radius:8px }
    `; document.head.append(style);
    // Materialize lazy collection entries while their real NodeViews still own
    // them; the copied flow has no events and never edits the source document.
    for (;;) {
      const more = [...root.querySelectorAll('.penned-collection-footer button')].filter(n => /^Show More \(/.test(n.textContent));
      if (!more.length) break;
      more.forEach(n => n.click());
    }
    root.querySelectorAll('details').forEach(n => n.open = true);
    root.querySelectorAll('.vellix-toggle-content').forEach(n => { n.hidden = false; n.style.display = 'block'; });
    const flow = el('div'); flow.id = 'export-flow';
    flow.style.fontFamily = options.fontFamily; flow.style.color = options.textColor;
    const heading = el('header', 'export-heading');
    if (options.cover) { const img = el('img', 'export-cover'); img.src = options.cover; img.alt = ''; heading.append(img); }
    if (options.showTitle) {
      const title = el('div', 'export-title');
      if (options.icon) { const icon = el('img'); icon.src = options.icon; icon.style.cssText = 'width:26px;height:26px;display:inline-block;vertical-align:middle;margin:0 8px 0 0'; title.append(icon); }
      title.append(document.createTextNode(options.title)); heading.append(title);
    }
    if (options.subtitle) heading.append(el('div', 'export-subtitle', options.subtitle));
    if (heading.childElementCount) flow.append(heading);
    for (const field of options.entryFields || []) {
      const row = el('div', 'export-entry-field'), label = el('div', 'export-entry-label');
      if (field.icon) { const icon = el('img'); icon.src = field.icon; label.append(icon); }
      label.append(document.createTextNode(field.name)); row.append(label);
      const values = el('div', 'export-board-values');
      if (field.chips?.length) for (const chip of field.chips) { const n = el('span', 'penned-collection-chip', chip.name); n.style.setProperty('--chip-color', chip.color); values.append(n); }
      else values.append(document.createTextNode(field.text));
      row.append(values); flow.append(row);
    }
    const content = root.cloneNode(true); content.contentEditable = 'false';
    [content,...content.querySelectorAll('*')].forEach((node,index)=>node.setAttribute('data-export-resource',String(index)));
    const embedded=options.assetURLs||{};
    const replaceURLs=value=>value.replace(/url\(\s*(['"]?)(.*?)\1\s*\)/g,(match,quote,url)=>embedded[url]?`url("${embedded[url]}")`:match);
    for(const img of content.querySelectorAll('img')){
      const src=img.currentSrc||img.src;if(embedded[src]){img.removeAttribute('srcset');img.src=embedded[src];}
    }
    for(const resource of window.pennedExportResources||[]){
      const selector=`[data-export-resource="${resource.index}"]`;
      if(resource.pseudo){
        const declarations=Object.entries(resource.values).map(([key,value])=>`${key}:${replaceURLs(value)}!important`).join(';');
        style.textContent+=`#export-flow ${selector}${resource.pseudo}{${declarations}}`;
      }else{
        const node=content.matches(selector)?content:content.querySelector(selector);
        if(node)for(const [property,value]of Object.entries(resource.values))node.style.setProperty(property,replaceURLs(value),'important');
      }
    }
    const byID = new Map((options.collections || []).map(n => [n.id,n]));
    for (const host of content.querySelectorAll('[data-native-collection]')) {
      const collection = byID.get(host.dataset.nativeCollection); if (!collection) throw new Error('A collection could not be exported.');
      host.replaceChildren(); host.removeAttribute('aria-hidden'); host.removeAttribute('style');
      const header = el('div', 'penned-collection-header'); header.append(el('div','penned-collection-name',collection.name),el('span','penned-collection-selector',collection.viewName)); host.append(header);
      for (const column of collection.columns || []) {
        const section = el('section','export-board-column'); section.style.backgroundColor = column.color;
        // Native board colors use dark ink on light columns.
        const rgb = /^#([0-9a-f]{6})$/i.exec(column.color || '');
        if (rgb) { const c=parseInt(rgb[1],16); if (((c>>16)*.2126+((c>>8)&255)*.7152+(c&255)*.0722)>160) section.style.color='#171717'; }
        const title=el('div','export-board-heading',column.name); title.append(el('span','export-board-count',String(column.entries.length))); section.append(title);
        for (const id of column.entries) {
          const entry=collection.entries.find(n=>n.id===id); if (!entry) continue;
          const card=el('article','export-board-card'); card.append(el('div','',entry.title));
          const values=el('div','export-board-values');
          for (const field of collection.fields || []) {
            const value=entry.values?.[field.id]; if (!value || value.empty) continue;
            if (value.chips?.length) for (const chip of value.chips) { const tag=el('span','penned-collection-chip',chip.name); tag.style.setProperty('--chip-color',chip.color); values.append(tag); }
            else values.append(el('span','',value.text));
          }
          if (values.childNodes.length) card.append(values); section.append(card);
        }
        host.append(section);
      }
    }
    content.querySelectorAll('.penned-collection-footer,.penned-collection-entry-actions,.penned-collection-header > button:last-child,.column-resize-handle,.resize-handle,.table-resize-handle,.vellix-table-cell-menu,.vellix-table-resize-line,.vellix-plain-callout-color-button,.vellix-blockquote-color-button,.ProseMirror-gapcursor,.ProseMirror-trailingBreak,[data-placeholder-overlay],.penned-attachment-actions').forEach(n=>n.remove());
    // Drop the action column without dropping any actual property columns.
    content.querySelectorAll('.penned-collection-row').forEach(n=>n.lastElementChild?.remove());
    content.querySelectorAll('.penned-collection-table').forEach(n=>n.style.removeProperty('--collection-tracks'));
    content.querySelectorAll('.penned-collection-row').forEach(n=>n.style.gridTemplateColumns=`minmax(140px,1.4fr) ${'minmax(90px,1fr) '.repeat(Math.max(0,n.childElementCount-1))}`);
    content.querySelectorAll('.penned-collection-table').forEach(n=>{n.style.width='100%';n.style.minWidth='0';});
    if (!options.showTags) content.querySelectorAll('[data-inline-tag],.penned-inline-tag,[data-type="inlineTag"]').forEach(n=>n.remove());
    content.querySelectorAll('[contenteditable]').forEach(n=>n.removeAttribute('contenteditable'));
    content.querySelectorAll('[data-vellix-selected]').forEach(n=>n.removeAttribute('data-vellix-selected'));
    content.querySelectorAll('img').forEach(n=>{n.loading='eager';n.style.maxWidth='100%';});
    content.querySelectorAll('video,audio').forEach(n=>{
      const box=el('div','export-media');
      const poster=n.poster; if (poster) {const img=el('img');img.src=poster;box.append(img);}
      box.append(el('div','',n.getAttribute('aria-label') || (n.tagName==='VIDEO'?'Video attachment':'Audio attachment'))); n.replaceWith(box);
    });
    // Retain native component values; exclude configuration buttons only.
    content.querySelectorAll('[data-template-component] button[title*="Configure"],.penned-component-configure').forEach(n=>n.remove());
    flow.append(content);
    const canvas=el('div');canvas.id='export-canvas';canvas.style.width=options.width+'px';canvas.style.height=options.height+'px';
    const backdrop=el('div');backdrop.id='export-backdrop';const paper=el('div');paper.id='export-paper';
    if(options.backdrop) backdrop.style.backgroundImage=`url("${options.backdrop}")`;
    if(options.paper) paper.style.backgroundImage=`url("${options.paper}")`;
    const clip=el('div');clip.id='export-clip';clip.append(flow);
    const sheets=el('div');sheets.id='export-sheets';
    canvas.append(backdrop,paper,sheets,clip);
    const footer=el('div');footer.id='export-footer';canvas.append(footer);
    document.querySelector('#export-canvas')?.remove(); document.body.append(canvas);
    document.querySelector('#editor-root')?.remove(); if(root.isConnected) root.remove();
    document.body.style.color=options.textColor;
    const wait = (promise, milliseconds) => Promise.race([promise,new Promise(resolve=>setTimeout(resolve,milliseconds))]);
    await wait(document.fonts.ready,10000);
    const images=[...flow.querySelectorAll('img')].filter(img=>!img.closest('[hidden]')&&Boolean(img.getAttribute('src')));
    await Promise.all(images.map(img=>wait(img.decode().catch(()=>{}),15000)));
    await Promise.all([...new Set(Object.values(embedded))].map(src=>{const img=new Image();img.src=src;return wait(img.decode().catch(()=>{}),15000);}));
    const warnings=images.filter(n=>!n.naturalWidth).map(n=>'Image unavailable: '+(n.alt||'embedded image'));
    // Scale typography once, before pagination. The clone is no longer managed
    // by ProseMirror, so line geometry cannot become stale during capture.
    if(options.fontScale!==1) {
      const fonts=[...flow.querySelectorAll('*')].map(n=>[n,parseFloat(getComputedStyle(n).fontSize)]);
      fonts.forEach(([n,size])=>{if(Number.isFinite(size))n.style.setProperty('font-size',size*options.fontScale+'px','important');});
    }
    flow.querySelectorAll('.tableWrapper').forEach(wrapper=>{
      const table=wrapper.querySelector('table');if(!table)return;
      const width=table.getBoundingClientRect().width,available=flow.clientWidth;
      if(width>available){const scale=available/width;table.style.transformOrigin='top left';table.style.transform=`scale(${scale})`;wrapper.style.height=table.getBoundingClientRect().height+'px';}
    });
    // Repaint gradient text against export line geometry, preserving angle and
    // a continuous gradient across lines and differently formatted runs.
    flow.querySelectorAll('.vellix-gradient-fragment').forEach(n=>n.replaceWith(...n.childNodes));
    const marks=[...flow.querySelectorAll('[data-vellix-gradient]')];
    for(const mark of marks){
      let value;try{value=JSON.parse(mark.dataset.vellixGradient);}catch{continue;}
      const walker=document.createTreeWalker(mark,NodeFilter.SHOW_TEXT),parts=[];let node;
      while((node=walker.nextNode())){let start=0;while(start<node.length){
        const range=document.createRange();range.setStart(node,start);range.setEnd(node,node.length);
        if(!range.getClientRects().length)break;
        let lo=start+1,hi=node.length;
        while(lo<hi){const mid=Math.ceil((lo+hi)/2);range.setEnd(node,mid);if(range.getClientRects().length<=1)lo=mid;else hi=mid-1;}
        range.setEnd(node,lo);parts.push({node,start,end:lo,rect:range.getBoundingClientRect()});start=lo;
      }}
      if(!parts.length)continue;
      const left=Math.min(...parts.map(n=>n.rect.left)),right=Math.max(...parts.map(n=>n.rect.right)),top=Math.min(...parts.map(n=>n.rect.top)),bottom=Math.max(...parts.map(n=>n.rect.bottom));
      const dx=Math.sin(value.angle*Math.PI/180),dy=-Math.cos(value.angle*Math.PI/180),length=Math.abs(dx)*(right-left)+Math.abs(dy)*(bottom-top);
      for(const p of parts.reverse()){
        const r=p.rect,local=Math.abs(dx)*r.width+Math.abs(dy)*r.height;if(!local)continue;
        const offset=dx*(left+right-r.left-r.right)/2+dy*(top+bottom-r.top-r.bottom)/2;
        const start=(offset-(length-local)/2)/local,end=start+length/local;
        const range=document.createRange();range.setStart(p.node,p.start);range.setEnd(p.node,p.end);
        const fragment=el('span','export-gradient');fragment.style.cssText=`background-image:linear-gradient(${value.angle}deg,${value.start} ${start*100}%,${value.end} ${end*100}%);background-size:${r.width}px ${r.height}px;background-clip:text;-webkit-background-clip:text;-webkit-text-fill-color:transparent;color:transparent;box-decoration-break:clone;-webkit-box-decoration-break:clone`;
        range.surroundContents(fragment);
      }
      mark.style.setProperty('background-image','none','important');
    }
    // WebKit's PDF compositor paints masked icons as opaque squares. Flatten any
    // masked icon (the collection view-switcher chevron, checkbox glyphs, ...)
    // into a tinted bitmap so the real glyph prints instead of a solid box.
    const rasterizeMaskedIcon=async(source,width,height,color)=>{
      const match=/url\(["']?(.*?)["']?\)/.exec(source||'');
      if(!match||width<=0||height<=0)return null;
      const glyph=new Image();glyph.src=match[1];
      try{await glyph.decode();}catch{return null;}
      const canvas=el('canvas');canvas.width=Math.max(1,Math.ceil(width*3));canvas.height=Math.max(1,Math.ceil(height*3));
      const context=canvas.getContext('2d');
      const scale=Math.min(canvas.width/glyph.naturalWidth,canvas.height/glyph.naturalHeight);
      const w=glyph.naturalWidth*scale,h=glyph.naturalHeight*scale;
      context.drawImage(glyph,(canvas.width-w)/2,(canvas.height-h)/2,w,h);
      context.globalCompositeOperation='source-in';context.fillStyle=color;context.fillRect(0,0,canvas.width,canvas.height);
      return canvas.toDataURL('image/png');
    };
    for(const span of flow.querySelectorAll('.penned-collection-icon')){
      const computed=getComputedStyle(span),mask=computed.webkitMaskImage||computed.maskImage;
      if(!mask||mask==='none')continue;
      const rect=span.getBoundingClientRect();
      const png=await rasterizeMaskedIcon(mask,rect.width||18,rect.height||18,computed.color);
      if(!png)continue;
      span.style.setProperty('mask-image','none','important');
      span.style.setProperty('-webkit-mask-image','none','important');
      span.style.setProperty('background-color','transparent','important');
      span.style.setProperty('background-image',`url("${png}")`,'important');
      span.style.setProperty('background-size','contain','important');
      span.style.setProperty('background-repeat','no-repeat','important');
      span.style.setProperty('background-position','center','important');
    }
    const origin=flow.getBoundingClientRect().top, height=Math.ceil(flow.getBoundingClientRect().height);
    // Collections flow across paper boundaries; a tall gallery card must not
    // move the whole first row away from its heading. Rows and text lines still
    // supply safe cut positions, while the collection itself is never atomic.
    const boxes=[...flow.querySelectorAll('p,h1,h2,h3,h4,h5,h6,li,blockquote,.vellix-callout,.vellix-plain-callout,.penned-collection-row,.export-entry-field,tr,figure,pre,.export-heading,.export-cover')]
      .filter(n=>!n.querySelector('.penned-collection'))
      .map(n=>{const r=n.getBoundingClientRect();return {top:r.top-origin,bottom:r.bottom-origin};}).filter(n=>n.bottom>n.top);
    const textWalker=document.createTreeWalker(flow,NodeFilter.SHOW_TEXT);let textNode;
    while((textNode=textWalker.nextNode())){
      const range=document.createRange();range.selectNodeContents(textNode);
      for(const r of range.getClientRects())if(r.height>0)boxes.push({top:r.top-origin,bottom:r.bottom-origin});
    }
    const breaks=[...flow.querySelectorAll('[data-vellix-page-break],[data-type="pageBreak"]')].map(n=>n.getBoundingClientRect().top-origin);
    window.pennedExport={flow,clip,canvas,footer,paper,sheets,options,height,boxes,breaks};
    return {height,boxes,breaks,warnings};
    """#

    static let showPage = #"""
    const state=window.pennedExport;if(!state)throw new Error('Export content is unavailable.');
    state.flow.style.transform=`translateY(${-start}px)`;
    state.clip.style.height=Math.max(1,end-start)+'px';state.canvas.style.height=height+'px';
    // Page breaks render as separated page sheets, matching the editor's native
    // page breaks: the paper splits with a gap (the backdrop shows through) and
    // each sheet keeps the page's rounded corners. PDF keeps a single sheet.
    const inset=18, clipTop=36, sheetBottom=height-inset;
    const canvasTop=state.canvas.getBoundingClientRect().top;
    const windowBreaks=[...state.flow.querySelectorAll('[data-vellix-page-break],[data-type="pageBreak"]')]
      .map(n=>{const r=n.getBoundingClientRect();return {top:r.top-canvasTop,height:Math.max(1,r.height)};})
      .filter(b=>b.top>clipTop+1 && b.top<clipTop+(end-start)-1)
      .sort((a,b)=>a.top-b.top);
    state.sheets.replaceChildren();
    if(state.options.image && windowBreaks.length){
      state.paper.style.display='none';
      const sheet=(top,bottom)=>{
        if(bottom-top<2)return;
        const panel=document.createElement('div');panel.className='export-sheet';
        panel.style.left=inset+'px';panel.style.right=inset+'px';panel.style.top=top+'px';panel.style.height=(bottom-top)+'px';
        panel.style.border='1px solid rgba(255,255,255,0.12)';
        if(state.options.paper)panel.style.backgroundImage=`url("${state.options.paper}")`;
        state.sheets.append(panel);
      };
      let segStart=inset;
      for(const b of windowBreaks){sheet(segStart,b.top);segStart=b.top+b.height;}
      sheet(segStart,sheetBottom);
    }else{
      state.paper.style.display='';
    }
    state.footer.replaceChildren();
    const label=document.createElement('span');label.textContent=state.options.watermark?'Created with Penned':'';
    const number=document.createElement('span');number.textContent=state.options.pageNumbers?`${index} / ${total}`:'';
    state.footer.append(label,number);
    // Frame scheduling can be suspended for background WebViews. Force layout
    // synchronously; the native capture API performs the rendering fence.
    state.canvas.getBoundingClientRect(); return true;
    """#
}

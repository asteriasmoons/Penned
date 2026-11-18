#if os(iOS)
/// Read-only, bounded block/text metrics. No document text or JSON leaves JavaScript.
enum TipTapBlockRenderDiagnostics {
    static let script = #"""
    const started = performance.now(), root = document.querySelector('.tiptap-editor');
    const rect = r => ({x:r.x,y:r.y,width:r.width,height:r.height});
    const intersects = (a,b) => a.width>0 && a.height>0 && a.x<b.x+b.width && a.x+a.width>b.x && a.y<b.y+b.height && a.y+a.height>b.y;
    const ratio = innerWidth / Math.max(1,nativeWidth);
    const viewport = {x:nativeViewport.x*ratio+scrollX,y:nativeViewport.y*ratio+scrollY,
      width:nativeViewport.width*ratio,height:nativeViewport.height*ratio};
    const describe = e => {
      if (!e) return null;
      const r=e.getBoundingClientRect(),s=getComputedStyle(e);
      let fontCheck=null;
      try { fontCheck=document.fonts?.check(`${s.fontSize} ${s.fontFamily}`) ?? null; } catch {}
      return {tag:e.tagName,...rect(r),display:s.display,visibility:s.visibility,opacity:s.opacity,
        color:s.color,textFill:s.webkitTextFillColor,background:s.backgroundColor,font:s.fontFamily,
        fontSize:s.fontSize,fontCheck,overflow:s.overflow,contain:s.contain,transform:s.transform,
        willChange:s.willChange,clipPathSet:s.clipPath!=='none',pointerEvents:s.pointerEvents};
    };
    const byID=new Map(),typeCounts={}; let modelNodes=0,modelCharacters=0,modelAvailable=false;
    const labels=[];
    try {
      const model=await window.tiptapCommand('getDocument',{});
      const visit=n=>{
        if (!n || typeof n!=='object') return 0;
        modelNodes++; typeCounts[n.type]=(typeCounts[n.type]||0)+1;
        let count=typeof n.text==='string'?n.text.length:0;
        for(const child of n.content||[]) count+=visit(child);
        if(n.attrs?.id) byID.set(n.attrs.id,{type:n.type,textCharacters:count,children:n.content?.length||0,
          hideTitle:n.attrs.hideTitle===true,hideDescription:n.attrs.hideDescription===true,
          hideDivider:n.attrs.hideDivider===true,collapsed:n.attrs.collapsed===true,
          label:n.type==='heading'&&n.attrs.label?.presentation==='label'});
        if(n.type==='heading'&&n.attrs.label?.presentation==='label') labels.push({id:n.attrs.id||null,textCharacters:count});
        return count;
      };
      if(model?.type==='doc') {modelCharacters=visit(model);modelAvailable=true;}
    } catch {}
    const selector='[data-vellix-block-id],p,h1,h2,h3,h4,h5,h6,pre,.penned-information-card,.penned-heading-label,.vellix-callout,.vellix-plain-callout';
    const units=root?[...root.querySelectorAll(selector)]:[],indices=new Map(units.map((e,i)=>[e,i]));
    const domIDs=new Map();
    for(const e of units){const id=e.getAttribute('data-vellix-block-id');if(id&&!domIDs.has(id))domIDs.set(id,e);}
    const candidates=new Map();
    const add=(e,priority,source)=>{
      if(!e||!root?.contains(e))return;
      const old=candidates.get(e);
      if(!old||priority<old.priority)candidates.set(e,{priority,source});
    };
    units.slice(0,6).forEach(e=>add(e,40,'first-blocks'));
    units.slice(0,160).forEach(e=>{if(intersects(e.getBoundingClientRect(),viewport))add(e,10,'native-viewport');});
    const headingLabels=root?[...root.querySelectorAll('.penned-heading-label')]:[];
    headingLabels.slice(0,128).forEach(e=>add(e,intersects(e.getBoundingClientRect(),viewport)?0:30,'heading-label'));
    if(viewport.width>0&&viewport.height>0){
      for(let row=0;row<8;row++)for(let column=0;column<3;column++){
        const x=viewport.x+viewport.width*(column+.5)/3,y=viewport.y+viewport.height*(row+.5)/8;
        for(const hit of document.elementsFromPoint(x,y).slice(0,3))add(hit.closest(selector),5,'viewport-hit-test');
      }
    }
    const samples=[...candidates].sort((a,b)=>a[1].priority-b[1].priority||(indices.get(a[0])||0)-(indices.get(b[0])||0)).slice(0,24);
    const textMetrics=e=>{
      const walker=document.createTreeWalker(e,NodeFilter.SHOW_TEXT),rects=[];
      let node,visited=0,sampledCharacters=0,firstText=null;
      while((node=walker.nextNode())&&visited<8){
        if(!node.length)continue;
        visited++;firstText ||= node.parentElement;
        const range=document.createRange(),length=Math.min(node.length,256);
        range.setStart(node,0);range.setEnd(node,length);sampledCharacters+=length;
        for(const r of range.getClientRects())if(r.width>0&&r.height>0&&rects.length<16)rects.push(rect(r));
      }
      const ancestors=[];
      for(let a=firstText;a&&ancestors.length<10;a=a.parentElement){
        const s=getComputedStyle(a),r=a.getBoundingClientRect();
        if(a===firstText||a===e||s.display==='none'||s.visibility!=='visible'||Number(s.opacity)<1||s.overflow!=='visible')
          ancestors.push(describe(a));
        if(a===root)break;
      }
      return {characters:e.textContent.length,sampledCharacters,textNodesSampled:visited,
        rangeRects:rects,rangeRectCount:rects.length,visibleRangeRects:rects.filter(r=>intersects(r,viewport)).length,
        firstTextStyle:describe(firstText),ancestors};
    };
    const blockSamples=samples.map(([e,choice])=>{
      const id=e.getAttribute('data-vellix-block-id'),model=byID.get(id)||null;
      const label=e.matches('.penned-heading-label'),text=label?e.querySelector('.penned-label-text'):e;
      const metrics=text?textMetrics(text):null,container=describe(e);
      const parts=label?{tile:describe(e.querySelector('.penned-label-tile')),
        text:describe(text),surface:describe(e.querySelector('.penned-label-path-surface')),
        frame:describe(e.querySelector('.penned-label-path-frame')),textSurfaceExists:!!text}:null;
      const surfaces=label?[]:[...e.querySelectorAll('.penned-information-card-title,.penned-information-card-description,.penned-information-card-body,.vellix-callout-content,p')]
        .slice(0,4).map(child=>({surface:describe(child),text:textMetrics(child)}));
      return {key:id||`dom:${indices.get(e)??-1}:${e.tagName}`,id,kind:label?'headingLabel':model?.type||e.tagName,
        source:choice.source,model,container,text:metrics,parts,surfaces,
        inNativeViewport:intersects(e.getBoundingClientRect(),viewport),
        flags:{modelTextButEmptyDOM:model?model.textCharacters>0&&(!metrics||metrics.characters===0):null,
          textButNoRangeRects:!!metrics&&metrics.characters>0&&metrics.rangeRectCount===0,
          missingLabelTextSurface:label&&!text}};
    });
    const images=[...document.images];
    return {readyState:document.readyState,visibility:document.visibilityState,focus:document.hasFocus(),
      fonts:document.fonts?.status,commands:typeof window.tiptapCommand==='function',
      viewport:{width:innerWidth,height:innerHeight,scrollX,scrollY,scale:devicePixelRatio,nativeClip:viewport},
      blocks:root?.children.length||0,textCharacters:root?.textContent.length||0,root:describe(root),
      model:{available:modelAvailable,source:'canonical-getDocument',nodes:modelNodes,textCharacters:modelCharacters,typeCounts,
        headingLabels:labels.length,labelsWithoutDOM:labels.filter(l=>l.id&&!domIDs.has(l.id)).slice(0,16)},
      sampling:{matchedUnits:units.length,candidates:candidates.size,returned:blockSamples.length,limit:24,geometryScanLimit:160,
        headingLabels:headingLabels.length,headingScanLimit:128},blockSamples,
      images:{total:images.length,complete:images.filter(i=>i.complete).length,naturalSizeAvailable:images.filter(i=>i.naturalWidth>0).length},
      bodyHeight:document.body?.scrollHeight||0,probeMS:performance.now()-started};
    """#
}
#endif

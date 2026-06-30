import Foundation
import Hummingbird
import NIOCore

/// Returns the built-in display-only Reticle session panel.
func webPanelResponse() -> Response {
    var buffer = ByteBufferAllocator().buffer(capacity: webPanelHtml.utf8.count)
    buffer.writeString(webPanelHtml)
    return Response(
        status: .ok,
        headers: [.contentType: "text/html; charset=utf-8"],
        body: .init(byteBuffer: buffer)
    )
}

/// Self-contained HTML/JS for the zero-build read-only web panel.
private let webPanelHtml = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Reticle Panel</title>
<style>
:root{color-scheme:dark;--bg:#0b1020;--panel:#111827;--soft:#162033;--line:#263244;--muted:#9ca3af;--text:#e5e7eb;--accent:#60a5fa;--ok:#34d399}
*{box-sizing:border-box}
body{margin:0;background:linear-gradient(180deg,#0f172a 0,var(--bg) 180px);color:var(--text);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
body.modal-open{overflow:hidden}
header{padding:16px 20px;border-bottom:1px solid var(--line);background:rgba(15,23,42,.96)}
h1{margin:0;font-size:18px}
main{display:grid;grid-template-columns:340px 1fr;min-height:calc(100vh - 61px)}
aside{border-right:1px solid var(--line);background:#0d1424;overflow:auto}
section{padding:20px}
#detail{max-width:1180px;margin:0 auto}
.status{margin-top:4px;color:var(--muted);font-size:12px}
.item{display:block;width:100%;padding:12px 14px;border:0;border-bottom:1px solid var(--line);background:transparent;color:inherit;text-align:left;cursor:pointer}
.item:hover,.item.active{background:var(--soft)}
.item-title{font-weight:700}
.item-meta{margin-top:3px;color:var(--muted);font-size:12px}
.empty{padding:18px;color:var(--muted)}
.trace-view{border:1px solid var(--line);border-radius:18px;background:rgba(17,24,39,.92);box-shadow:0 22px 70px rgba(0,0,0,.26);overflow:hidden}
.trace-header{display:flex;align-items:flex-start;justify-content:space-between;padding:18px 20px;border-bottom:1px solid var(--line);background:linear-gradient(135deg,rgba(96,165,250,.12),rgba(17,24,39,0))}
.eyebrow,.section-title{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.05em}
.trace-title{margin-top:3px;font-size:20px;font-weight:760}
.trace-meta{margin-top:5px;color:var(--muted);font-size:12px;word-break:break-all}
.trace-score{margin-left:16px;text-align:right}
.trace-score b{display:block;font-size:24px;color:var(--ok)}
.trace-score span{color:var(--muted);font-size:12px}
.trace-flow{display:grid;grid-template-columns:1fr 28px 1fr 28px 1fr 28px 1fr;padding:14px 16px;border-bottom:1px solid var(--line);background:#0d1424}
.flow-step{min-width:0;padding:10px 12px;border-radius:12px;background:#0b1220}
.flow-step span{display:inline-block;margin-right:7px;color:var(--accent);font-weight:800}
.flow-step b{display:block;margin-top:4px}
.flow-step em{display:block;margin-top:3px;color:var(--muted);font-style:normal;font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.flow-arrow{align-self:center;color:var(--muted);text-align:center}
.evidence{display:grid;grid-template-columns:1fr 1fr;border-bottom:1px solid var(--line)}
.evidence-col{min-width:0;padding:16px}
.evidence-col:first-child{border-right:1px solid var(--line)}
.snapshot-line{margin:7px 0 12px;font-size:12px}
.facts{display:grid;grid-template-columns:repeat(3,1fr);border-bottom:1px solid var(--line)}
.fact{min-width:0;padding:12px 16px;border-right:1px solid var(--line)}
.fact:last-child{border-right:0}
.fact span{display:block;color:var(--muted);font-size:12px}
.fact b{display:block;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.raw{padding:0 16px 14px;border-bottom:1px solid var(--line)}
.raw details{padding:12px 0;border-bottom:1px solid var(--line)}
.raw details:last-child{border-bottom:0}
.raw summary{cursor:pointer;color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.05em}
.diff-section{padding:16px}
.shot-link{display:flex;align-items:center;justify-content:center;width:100%;height:min(38vh,360px);border:1px solid var(--line);border-radius:10px;background:#020617;overflow:hidden;cursor:zoom-in}
.shot{display:block;width:100%;height:100%;object-fit:contain}
.link{color:var(--accent);word-break:break-all}
pre{margin:0;max-height:260px;overflow:auto;white-space:pre-wrap;word-break:break-word;color:#d1d5db}
table{width:100%;border-collapse:collapse}
th,td{padding:7px 8px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
th{color:var(--muted);font-weight:600}
.lightbox{position:fixed;inset:0;z-index:10;display:flex;align-items:center;justify-content:center;padding:24px;background:rgba(2,6,23,.86)}
.lightbox[hidden]{display:none}
.lightbox-panel{position:relative;max-width:96vw;max-height:94vh;padding:42px 16px 16px;border:1px solid var(--line);border-radius:14px;background:#020617;box-shadow:0 24px 80px rgba(0,0,0,.45)}
.lightbox img{display:block;max-width:92vw;max-height:82vh;object-fit:contain}
.lightbox-close{position:absolute;right:12px;top:10px;border:1px solid var(--line);border-radius:999px;background:var(--soft);color:var(--text);padding:5px 10px;cursor:pointer}
.lightbox-caption{margin-top:8px;color:var(--muted);font-size:12px;text-align:center}
@media(max-width:900px){main{display:block}aside{border-right:0;border-bottom:1px solid var(--line);max-height:40vh}.trace-header,.trace-flow,.evidence,.facts{display:block}.trace-score{margin:12px 0 0;text-align:left}.flow-arrow{display:none}.evidence-col:first-child{border-right:0;border-bottom:1px solid var(--line)}.fact{border-right:0;border-bottom:1px solid var(--line)}}
</style>
</head>
<body>
<header>
<h1>Reticle Read-only Panel</h1>
<div id="status" class="status">Loading session events...</div>
</header>
<main>
<aside>
<div id="timeline"></div>
</aside>
<section>
<div id="detail" class="empty">Select an action trace from the timeline.</div>
</section>
</main>
<div id="lightbox" class="lightbox" hidden>
  <div class="lightbox-panel">
    <button id="lightbox-close" class="lightbox-close" type="button">Close</button>
    <img id="lightbox-image" alt="">
    <div id="lightbox-caption" class="lightbox-caption"></div>
  </div>
</div>
<script>
const state={events:[],selectedId:null,manifests:new Map()};
const timeline=document.getElementById('timeline');
const detail=document.getElementById('detail');
const statusEl=document.getElementById('status');
const lightbox=document.getElementById('lightbox'),lightboxImage=document.getElementById('lightbox-image'),lightboxCaption=document.getElementById('lightbox-caption');
function artifactUrl(event,ref){
  return `/sessions/current/artifacts?event=${encodeURIComponent(event.id)}&ref=${encodeURIComponent(ref)}`;
}
function escapeHtml(value){
  return String(value===undefined||value===null?'':value)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;')
    .replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
}
function pretty(value){
  return escapeHtml(JSON.stringify(value,null,2));
}
function actionEvents(){
  return state.events.filter((event)=>event.type==='action.trace');
}
function labelFor(event){
  const payload=event.payload||{};
  const gesture=payload.gesture||'action';
  const selector=payload.selector?JSON.stringify(payload.selector):'no selector';
  return `${gesture} ${selector}`;
}
function formatTime(ms){
  const date=new Date(ms);
  return Number.isNaN(date.getTime())?String(ms):date.toLocaleTimeString();
}
function mergeEvent(event){
  const index=state.events.findIndex((item)=>item.id===event.id);
  if(index>=0){state.events[index]=event;}else{state.events.push(event);}
  state.events.sort((a,b)=>a.id.localeCompare(b.id));
}
function renderTimeline(){
  const actions=actionEvents();
  statusEl.textContent=`${state.events.length} event(s), ${actions.length} action trace(s)`;
  if(actions.length===0){
    timeline.innerHTML='<div class="empty">No action traces yet. Run reticle act with --trace-output while serve is running.</div>';
    detail.className='empty';
    detail.textContent='Waiting for action.trace events...';
    return;
  }
  if(!state.selectedId){state.selectedId=actions[actions.length-1].id;}
  timeline.innerHTML=actions.map((event)=>{
    const payload=event.payload||{};
    const active=event.id===state.selectedId?' active':'';
    return `<button class="item${active}" data-id="${escapeHtml(event.id)}">
      <div class="item-title">${escapeHtml(labelFor(event))}</div>
      <div class="item-meta">${escapeHtml(formatTime(event.ts))} · ${escapeHtml(payload.packageName||event.target||'unknown target')}</div>
      <div class="item-meta">${escapeHtml(event.id)} · ${escapeHtml(payload.changeCount||0)} change(s)</div>
    </button>`;
  }).join('');
  timeline.querySelectorAll('.item').forEach((button)=>{
    button.addEventListener('click',()=>{
      state.selectedId=button.dataset.id;
      renderTimeline();
      renderDetail();
    });
  });
}
function refLink(event,ref,label){
  if(!event.refs||!event.refs[ref]){return '<span class="status">missing</span>';}
  return `<a class="link" href="${artifactUrl(event,ref)}" target="_blank" rel="noopener noreferrer">${escapeHtml(label||event.refs[ref])}</a>`;
}
function screenshot(event,ref){
  if(!event.refs||!event.refs[ref]){return '<div class="status">No screenshot captured.</div>';}
  const url=artifactUrl(event,ref);
  return `<button class="shot-link" type="button" data-shot-src="${url}" data-shot-label="${escapeHtml(ref)}"><img class="shot" src="${url}" alt="${escapeHtml(ref)}"></button>`;
}
function openLightbox(src,label){lightboxImage.src=src;lightboxImage.alt=label;lightboxCaption.textContent=label;lightbox.hidden=false;document.body.classList.add('modal-open');}
function closeLightbox(){lightbox.hidden=true;lightboxImage.removeAttribute('src');document.body.classList.remove('modal-open');}
function attachScreenshotPreviews(){detail.querySelectorAll('.shot-link').forEach((button)=>{button.addEventListener('click',()=>openLightbox(button.dataset.shotSrc,button.dataset.shotLabel));});}
async function loadManifest(event){
  if(!event.refs||!event.refs.manifest){return null;}
  if(state.manifests.has(event.id)){return state.manifests.get(event.id);}
  try{const response=await fetch(artifactUrl(event,'manifest'));if(!response.ok){throw new Error(`HTTP ${response.status}`);}
    const manifest=await response.json();state.manifests.set(event.id,manifest);return manifest;
  }catch(error){state.manifests.set(event.id,{error:String(error)});return state.manifests.get(event.id);}
}
function renderDiff(manifest){
  const diff=manifest&&Array.isArray(manifest.diff)?manifest.diff:[];
  if(diff.length===0){return '<div class="status">No snapshot diff entries.</div>';}
  return `<table><thead><tr><th>Ref</th><th>Field</th><th>Before</th><th>After</th></tr></thead><tbody>${diff.map((change)=>`<tr><td>${escapeHtml(change.ref||'snapshot')}</td><td>${escapeHtml(change.field)}</td><td>${escapeHtml(change.before)}</td><td>${escapeHtml(change.after)}</td></tr>`).join('')}</tbody></table>`;
}
async function renderDetail(){
  const event=state.events.find((item)=>item.id===state.selectedId);
  if(!event){return;}
  const payload=event.payload||{};
  const target=payload.target||{};
  const result=payload.result||{};
  const targetSource=target.source||result.source||'unknown';
  const targetRef=target.ref||result.ref||'none';
  const targetPoint=target.point?`${target.point.x}, ${target.point.y}`:(result.x&&result.y?`${result.x}, ${result.y}`:'none');
  detail.className='';
  detail.innerHTML=`<div class="trace-view"><div class="trace-header"><div><div class="eyebrow">Action trace</div><div class="trace-title">${escapeHtml(labelFor(event))}</div><div class="trace-meta">${escapeHtml(event.id)} · ${escapeHtml(payload.packageName||event.target||'unknown target')}</div></div><div class="trace-score"><b>${escapeHtml(payload.changeCount||0)}</b><span>changed facts</span></div></div>
  <div class="trace-flow"><div class="flow-step"><span>1</span><b>Gesture</b><em>${escapeHtml(payload.gesture||'action')}</em></div><div class="flow-arrow">→</div><div class="flow-step"><span>2</span><b>Selector</b><em>${escapeHtml(payload.selector?JSON.stringify(payload.selector):'direct target')}</em></div><div class="flow-arrow">→</div><div class="flow-step"><span>3</span><b>Resolved target</b><em>${escapeHtml(targetSource)} · ${escapeHtml(targetRef)}</em></div><div class="flow-arrow">→</div><div class="flow-step"><span>4</span><b>Evidence diff</b><em>${escapeHtml(payload.changeCount||0)} change(s)</em></div></div>
  <div class="evidence"><div class="evidence-col"><div class="section-title">Before</div><div class="snapshot-line">${refLink(event,'beforeSnapshot')}</div>${screenshot(event,'beforeScreenshot')}</div><div class="evidence-col"><div class="section-title">After</div><div class="snapshot-line">${refLink(event,'afterSnapshot')}</div>${screenshot(event,'afterScreenshot')}</div></div>
  <div class="facts"><div class="fact"><span>Target source</span><b>${escapeHtml(targetSource)}</b></div><div class="fact"><span>Target ref</span><b>${escapeHtml(targetRef)}</b></div><div class="fact"><span>Point</span><b>${escapeHtml(targetPoint)}</b></div></div>
  <div class="raw"><details><summary>Selector JSON</summary><pre>${pretty(payload.selector||{})}</pre></details><details><summary>Target / Result JSON</summary><pre>${pretty(payload.target||payload.result||{})}</pre></details><details><summary>Artifact refs</summary><pre>${pretty(event.refs||{})}</pre></details><details><summary>Full payload</summary><pre>${pretty(payload)}</pre></details></div>
  <div class="diff-section"><div class="section-title">Diff</div><div id="diff">Loading diff...</div></div></div>`;
  attachScreenshotPreviews();
  const manifest=await loadManifest(event);
  const diffEl=document.getElementById('diff');
  if(!diffEl){return;}
  diffEl.innerHTML=manifest&&manifest.error?`<div class="status">${escapeHtml(manifest.error)}</div>`:renderDiff(manifest);
}
async function loadHistory(){
  const response=await fetch('/sessions/current/events');
  const data=await response.json();
  (data.events||[]).forEach(mergeEvent);
  renderTimeline();
  renderDetail();
}
function connectStream(){
  const stream=new EventSource('/events/stream');
  const handleMessage=(message)=>{
    try{
      mergeEvent(JSON.parse(message.data));
      renderTimeline();
      if(state.selectedId===null){
        const actions=actionEvents();
        state.selectedId=actions.length>0?actions[actions.length-1].id:null;
      }
      renderDetail();
    }catch(error){
      statusEl.textContent=`Could not parse event: ${error}`;
    }
  };
  stream.onmessage=handleMessage;
  stream.addEventListener('action.trace',handleMessage);
  stream.onerror=()=>{statusEl.textContent='Live event stream disconnected; retrying...';};
}
document.getElementById('lightbox-close').addEventListener('click',closeLightbox);
lightbox.addEventListener('click',(event)=>{if(event.target===lightbox){closeLightbox();}});
document.addEventListener('keydown',(event)=>{if(event.key==='Escape'&&!lightbox.hidden){closeLightbox();}});
loadHistory().then(connectStream).catch((error)=>{statusEl.textContent=`Load failed: ${error}`;});
</script>
</body>
</html>
"""#

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
<title>Reticle Evidence Timeline</title>
<style>
:root{color-scheme:dark;--bg:#0b1020;--panel:#111827;--soft:#162033;--line:#263244;--muted:#9ca3af;--text:#e5e7eb;--accent:#60a5fa;--ok:#34d399;--warn:#fbbf24}
*{box-sizing:border-box}
body{margin:0;background:linear-gradient(180deg,#0f172a 0,var(--bg) 180px);color:var(--text);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
body.modal-open{overflow:hidden}
header{position:sticky;top:0;z-index:3;padding:16px 20px;border-bottom:1px solid var(--line);background:rgba(15,23,42,.96);backdrop-filter:blur(12px)}
.topbar{display:flex;align-items:flex-start;justify-content:space-between;gap:16px}
h1{margin:0;font-size:18px}
.status{margin-top:4px;color:var(--muted);font-size:12px}
.session-control{color:var(--muted);font-size:12px;text-align:right}
.session-control select{display:block;min-width:240px;margin-top:5px;padding:7px 10px;border:1px solid var(--line);border-radius:10px;background:#0b1220;color:var(--text)}
main{max-width:1320px;margin:0 auto;padding:22px 18px 42px}
.empty{padding:24px;border:1px solid var(--line);border-radius:18px;background:rgba(17,24,39,.9);color:var(--muted)}
.timeline{position:relative}
.timeline:before{content:"";position:absolute;left:50%;top:0;bottom:0;width:1px;background:linear-gradient(180deg,transparent,var(--line) 22px,var(--line) calc(100% - 22px),transparent)}
.lane-labels{display:grid;grid-template-columns:minmax(0,1fr) 64px minmax(0,1fr);margin:0 0 14px;color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.05em}
.lane-labels div:first-child{padding-right:18px;text-align:right}
.lane-labels div:last-child{padding-left:18px}
.trace-group{margin:0 0 24px}
.node{position:relative;display:grid;grid-template-columns:minmax(0,1fr) 64px minmax(0,1fr);align-items:start;margin:0 0 14px}
.event-side{display:flex;min-width:0;padding-right:18px;flex-direction:column;align-items:flex-end}
.network-side{min-height:1px;padding-left:18px}
.time{padding:0 0 6px;color:var(--muted);font-size:12px;text-align:right}
.marker{position:relative;min-height:42px}
.marker:before{content:"";position:absolute;left:50%;top:13px;width:13px;height:13px;border:2px solid var(--accent);border-radius:999px;background:#0b1020;box-shadow:0 0 0 6px rgba(96,165,250,.08);transform:translateX(-50%)}
.node.before .marker:before,.node.after .marker:before{border-color:var(--ok);box-shadow:0 0 0 6px rgba(52,211,153,.08)}
.node.diff .marker:before{border-color:var(--warn);box-shadow:0 0 0 6px rgba(251,191,36,.08)}
.card{width:100%;min-width:0;border:1px solid var(--line);border-radius:18px;background:rgba(17,24,39,.92);box-shadow:0 18px 50px rgba(0,0,0,.22);overflow:hidden}
.node.before .card,.node.after .card{width:auto;max-width:100%}
.card-head{display:flex;align-items:flex-start;justify-content:space-between;padding:14px 16px;border-bottom:1px solid var(--line);background:linear-gradient(135deg,rgba(96,165,250,.12),rgba(17,24,39,0))}
.phase{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.05em}
.title{margin-top:3px;font-size:17px;font-weight:760}
.meta{margin-top:4px;color:var(--muted);font-size:12px;word-break:break-all}
.badge{margin-left:12px;padding:4px 8px;border:1px solid var(--line);border-radius:999px;background:#0b1220;color:var(--muted);font-size:12px;white-space:nowrap}
.body{padding:14px 16px}
.shot-body{display:grid;grid-template-columns:minmax(180px,260px) max-content;gap:14px;align-items:start;max-width:100%}
.shot-copy{min-width:0}
.media{margin-top:10px}
.shot-body .media{display:flex;justify-content:flex-start;margin-top:0;max-width:100%}
.artifact{margin-top:10px;padding:10px 12px;border:1px solid var(--line);border-radius:12px;background:#0b1220;color:var(--muted);font-size:12px}
.shot-copy .artifact:first-child{margin-top:0}
.facts{display:grid;grid-template-columns:repeat(3,1fr);border:1px solid var(--line);border-radius:12px;overflow:hidden}
.fact{min-width:0;padding:10px 12px;border-right:1px solid var(--line);background:#0b1220}
.fact:last-child{border-right:0}
.fact span{display:block;color:var(--muted);font-size:12px}
.fact b{display:block;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
details{margin-top:12px;padding-top:12px;border-top:1px solid var(--line)}
summary{cursor:pointer;color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.05em}
.shot-link{display:inline-flex;align-items:center;justify-content:center;max-width:100%;border:1px solid var(--line);border-radius:10px;background:#020617;overflow:hidden;cursor:zoom-in}
.shot{display:block;width:auto;max-width:100%;height:min(54vh,560px);object-fit:contain}
.shot-error{padding:18px;border:1px solid var(--line);border-radius:10px;background:#170f13;color:#fca5a5;font-size:12px}
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
@media(max-width:900px){main{padding:16px 12px 36px}.timeline:before{left:24px}.lane-labels{display:none}.node{grid-template-columns:42px 1fr}.event-side{grid-column:2;padding-right:0;align-items:stretch}.network-side{display:none}.time{padding:0 0 4px;text-align:left}.marker{grid-column:1;grid-row:1 / span 2}.card{width:100%}.shot-body,.facts{display:block}.shot-body .media{margin-top:10px}.fact{border-right:0;border-bottom:1px solid var(--line)}.fact:last-child{border-bottom:0}.card-head{display:block}.badge{display:inline-block;margin:10px 0 0}}
</style>
</head>
<body>
<header>
<div class="topbar"><div><h1>Reticle Evidence Timeline</h1><div id="status" class="status">Loading session events...</div></div><label class="session-control">Session<select id="session-picker"></select></label></div>
</header>
<main>
<div id="timeline"></div>
</main>
<div id="lightbox" class="lightbox" hidden>
  <div class="lightbox-panel">
    <button id="lightbox-close" class="lightbox-close" type="button">Close</button>
    <img id="lightbox-image" alt="">
    <div id="lightbox-caption" class="lightbox-caption"></div>
  </div>
</div>
<script>
const state={events:[],sessions:[],selectedSession:null,currentSession:null,manifests:new Map(),stream:null};
const timeline=document.getElementById('timeline');
const statusEl=document.getElementById('status');
const sessionPicker=document.getElementById('session-picker');
const lightbox=document.getElementById('lightbox'),lightboxImage=document.getElementById('lightbox-image'),lightboxCaption=document.getElementById('lightbox-caption');
function selectedIsCurrent(){return state.selectedSession===state.currentSession;}
function sessionRoute(){return selectedIsCurrent()?'current':encodeURIComponent(state.selectedSession||'current');}
function artifactUrl(event,ref){
  return `/sessions/${sessionRoute()}/artifacts?event=${encodeURIComponent(event.id)}&ref=${encodeURIComponent(ref)}`;
}
function escapeHtml(value){
  return String(value===undefined||value===null?'':value)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;')
    .replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
}
function pretty(value){return escapeHtml(JSON.stringify(value,null,2));}
function actionEvents(){return state.events.filter((event)=>event.type==='action.trace');}
function isPresent(value){return value!==undefined&&value!==null&&value!==''&&value!=='<null>';}
function eventMillis(event){
  const payload=event.payload||{};
  const value=Number(payload.recordedAtMillis||event.ts||0);
  return Number.isFinite(value)?value:0;
}
function labelFor(event){const payload=event.payload||{};return `${payload.gesture||'action'} ${selectorLabel(payload.selector)}`;}
function selectorLabel(selector){
  if(!selector){return 'direct target';}
  const fields=[['testId','test-id'],['cssSelector','css'],['ref','ref'],['resourceId','res'],['region','region'],['point','point']];
  for(const [key,label] of fields){
    const value=selector[key];
    if(isPresent(value)){return `${label}=${typeof value==='object'?JSON.stringify(value):value}`;}
  }
  return 'direct target';
}
function formatTime(ms){const date=new Date(ms);return Number.isNaN(date.getTime())?String(ms):date.toLocaleTimeString();}
function mergeEvent(event){
  const index=state.events.findIndex((item)=>item.id===event.id);
  if(index>=0){state.events[index]=event;}else{state.events.push(event);}
  state.events.sort((a,b)=>eventMillis(a)-eventMillis(b)||a.id.localeCompare(b.id));
}
function renderTimeline(){
  const actions=actionEvents();
  const live=selectedIsCurrent()?'live':'history';
  statusEl.textContent=`${state.selectedSession||'session'} · ${live} · ${state.events.length} event(s), ${actions.length} action trace(s), ${actions.length*4} timeline node(s)`;
  if(actions.length===0){
    timeline.className='';
    timeline.innerHTML='<div class="empty">No action traces yet. Run reticle act while serve is running to build an evidence timeline.</div>';
    return;
  }
  timeline.className='timeline';
  timeline.innerHTML=`<div class="lane-labels"><div>UI evidence</div><div></div><div>Network requests (planned)</div></div>${actions.map((event,index)=>traceGroup(event,index+1)).join('')}`;
  attachScreenshotPreviews();
  hydrateDiffs();
}
function refLink(event,ref,label){
  if(!event.refs||!event.refs[ref]){return '<span class="status">missing</span>';}
  return `<a class="link" href="${artifactUrl(event,ref)}" target="_blank" rel="noopener noreferrer">${escapeHtml(label||event.refs[ref])}</a>`;
}
function screenshot(event,ref){
  if(!event.refs||!event.refs[ref]){return '<div class="status">No screenshot captured.</div>';}
  const url=artifactUrl(event,ref);
  return `<button class="shot-link" type="button" data-shot-src="${url}" data-shot-label="Screenshot"><img class="shot" src="${url}" alt="Screenshot" data-ref="${escapeHtml(ref)}"></button>`;
}
function node(event,kind,time,title,phase,badge,body){
  return `<div class="node ${kind}"><div class="event-side"><div class="time">${escapeHtml(time)}</div><div class="card"><div class="card-head"><div><div class="phase">${escapeHtml(phase)}</div><div class="title">${escapeHtml(title)}</div><div class="meta">${escapeHtml(event.id)} &middot; ${escapeHtml(event.payload&&event.payload.packageName||event.target||'unknown target')}</div></div><div class="badge">${escapeHtml(badge)}</div></div><div class="body">${body}</div></div></div><div class="marker"></div><div class="network-side"></div></div>`;
}
function traceGroup(event,index){
  const payload=event.payload||{}, target=payload.target||{}, result=payload.result||{};
  const time=formatTime(eventMillis(event)), targetSource=target.source||result.source||'unknown', targetRef=target.ref||result.ref||'none';
  const targetPoint=target.point?`${target.point.x}, ${target.point.y}`:(result.x&&result.y?`${result.x}, ${result.y}`:'none');
  const beforeBody=`<div class="shot-body"><div class="shot-copy"><div class="artifact">Snapshot: ${refLink(event,'beforeSnapshot','snapshot.json')}</div><details><summary>Evidence ref</summary><pre>${pretty({snapshot:event.refs&&event.refs.beforeSnapshot,screenshot:event.refs&&event.refs.beforeScreenshot})}</pre></details></div><div class="media">${screenshot(event,'beforeScreenshot')}</div></div>`;
  const actionBody=`<div class="facts"><div class="fact"><span>Selector</span><b>${escapeHtml(selectorLabel(payload.selector))}</b></div><div class="fact"><span>Target source</span><b>${escapeHtml(targetSource)}</b></div><div class="fact"><span>Point</span><b>${escapeHtml(targetPoint)}</b></div></div><details><summary>Selector JSON</summary><pre>${pretty(payload.selector||{})}</pre></details><details><summary>Target / result JSON</summary><pre>${pretty(payload.target||payload.result||{})}</pre></details>`;
  const afterBody=`<div class="shot-body"><div class="shot-copy"><div class="artifact">Snapshot: ${refLink(event,'afterSnapshot','snapshot.json')}</div><details><summary>Evidence ref</summary><pre>${pretty({snapshot:event.refs&&event.refs.afterSnapshot,screenshot:event.refs&&event.refs.afterScreenshot})}</pre></details></div><div class="media">${screenshot(event,'afterScreenshot')}</div></div>`;
  const diffBody=`<div class="artifact">Manifest: ${refLink(event,'manifest','trace.json')} &middot; target ref: ${escapeHtml(targetRef)}</div><div class="diff-target" data-event-id="${escapeHtml(event.id)}">Loading diff...</div><details><summary>Artifact refs</summary><pre>${pretty(event.refs||{})}</pre></details><details><summary>Full payload</summary><pre>${pretty(payload)}</pre></details>`;
  return `<article class="trace-group">${node(event,'before',time,`Screenshot`,`${index}.1 evidence`,event.refs&&event.refs.beforeScreenshot?'screenshot':'snapshot only',beforeBody)}${node(event,'action',time,labelFor(event),`${index}.2 action`,targetSource,actionBody)}${node(event,'after',time,`Screenshot`,`${index}.3 evidence`,event.refs&&event.refs.afterScreenshot?'screenshot':'snapshot only',afterBody)}${node(event,'diff',time,`Diff`,`${index}.4 changes`,`${payload.changeCount||0} change(s)`,diffBody)}</article>`;
}
function openLightbox(src,label){lightboxImage.src=src;lightboxImage.alt=label;lightboxCaption.textContent=label;lightbox.hidden=false;document.body.classList.add('modal-open');}
function closeLightbox(){lightbox.hidden=true;lightboxImage.removeAttribute('src');document.body.classList.remove('modal-open');}
function attachScreenshotPreviews(){timeline.querySelectorAll('.shot-link').forEach((button)=>{button.addEventListener('click',()=>openLightbox(button.dataset.shotSrc,button.dataset.shotLabel));button.querySelector('img')?.addEventListener('error',()=>{button.outerHTML=`<div class="shot-error">Screenshot artifact could not be loaded: ${escapeHtml(button.querySelector('img')?.dataset.ref||'unknown')}</div>`;});});}
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
  const sorted=[...diff].sort((a,b)=>diffRank(a)-diffRank(b));
  const rows=(items)=>`<table><thead><tr><th>Ref</th><th>Field</th><th>Before</th><th>After</th></tr></thead><tbody>${items.map((change)=>`<tr><td>${escapeHtml(change.ref||'snapshot')}</td><td>${escapeHtml(change.field)}</td><td>${escapeHtml(change.before)}</td><td>${escapeHtml(change.after)}</td></tr>`).join('')}</tbody></table>`;
  if(sorted.length<=8){return rows(sorted);}
  return `<div class="status">${sorted.length} diff entries; showing 8 highest-signal changes first.</div>${rows(sorted.slice(0,8))}<details><summary>Show all diff entries</summary>${rows(sorted)}</details>`;
}
function diffRank(change){const field=String(change.field||'');if(/text|label|contentDescription|testId|resourceId/.test(field)){return 0;}if(/visible|enabled|interactive|role|kind/.test(field)){return 1;}if(/frame|alpha|background|style/.test(field)){return 2;}if(/nodeCount|children|present/.test(field)){return 9;}return 4;}
function hydrateDiffs(){
  timeline.querySelectorAll('.diff-target').forEach(async (el)=>{
    const event=state.events.find((item)=>item.id===el.dataset.eventId);
    if(!event){return;}
    const manifest=await loadManifest(event);
    el.innerHTML=manifest&&manifest.error?`<div class="status">${escapeHtml(manifest.error)}</div>`:renderDiff(manifest);
  });
}
async function loadSessions(){
  const response=await fetch('/sessions');const data=await response.json();
  state.sessions=data.sessions||[];state.currentSession=(state.sessions.find((s)=>s.isCurrent)||state.sessions[0]||{}).id||null;
  if(!state.selectedSession){state.selectedSession=state.currentSession;}
  sessionPicker.innerHTML=state.sessions.map((s)=>`<option value="${escapeHtml(s.id)}">${escapeHtml(sessionLabel(s))}</option>`).join('');
  sessionPicker.value=state.selectedSession||'';
}
function sessionLabel(session){const stamp=session.updatedAtMillis?formatTime(session.updatedAtMillis):'no events';return `${session.isCurrent?'current · ':''}${session.id} · ${session.actionTraceCount} trace(s) · ${stamp}`;}
async function loadHistory(){
  if(!state.selectedSession){return;}
  const response=await fetch(`/sessions/${sessionRoute()}/events`),data=await response.json();state.events=[];state.manifests.clear();
  (data.events||[]).forEach(mergeEvent);
  renderTimeline();
}
function connectStream(){
  if(state.stream){state.stream.close();state.stream=null;}
  if(!selectedIsCurrent()){return;}
  const stream=new EventSource('/events/stream');
  state.stream=stream;
  const handleMessage=(message)=>{
    try{
      mergeEvent(JSON.parse(message.data));
      renderTimeline();
    }catch(error){
      statusEl.textContent=`Could not parse event: ${error}`;
    }
  };
  stream.onmessage=handleMessage;
  stream.addEventListener('action.trace',handleMessage);
  stream.onerror=()=>{statusEl.textContent='Live event stream disconnected; retrying...';};
}
sessionPicker.addEventListener('change',async()=>{state.selectedSession=sessionPicker.value;if(state.stream){state.stream.close();state.stream=null;}await loadHistory();connectStream();});
document.getElementById('lightbox-close').addEventListener('click',closeLightbox);
lightbox.addEventListener('click',(event)=>{if(event.target===lightbox){closeLightbox();}});
document.addEventListener('keydown',(event)=>{if(event.key==='Escape'&&!lightbox.hidden){closeLightbox();}});
loadSessions().then(loadHistory).then(connectStream).catch((error)=>{statusEl.textContent=`Load failed: ${error}`;});
</script>
</body>
</html>
"""#

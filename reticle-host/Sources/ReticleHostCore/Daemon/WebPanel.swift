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
:root{color-scheme:dark;--primary:#5e6ad2;--on-primary:#ffffff;--primary-hover:#828fff;--primary-focus:#5e69d1;--ink:#f7f8f8;--ink-muted:#d0d6e0;--ink-subtle:#8a8f98;--ink-tertiary:#62666d;--canvas:#010102;--surface-1:#0f1011;--surface-2:#141516;--surface-3:#18191a;--surface-4:#191a1b;--hairline:#23252a;--hairline-strong:#34343a;--hairline-tertiary:#3e3e44;--semantic-success:#27a644;--semantic-warning:#f2c94c;--semantic-danger:#eb5757;--semantic-network:#b59aff;--semantic-overlay:#000000;--rounded-xs:4px;--rounded-sm:6px;--rounded-md:8px;--rounded-lg:12px;--rounded-xl:16px;--rounded-xxl:24px;--rounded-pill:9999px;--rounded-full:9999px;--font-sans:Inter,-apple-system,BlinkMacSystemFont,"SF Pro Display","Segoe UI",sans-serif;--font-mono:"JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,monospace;--type-display-md:600 40px/1.15 var(--font-sans);--tracking-display-md:-1px;--type-headline:600 28px/1.2 var(--font-sans);--tracking-headline:-.6px;--type-card-title:500 22px/1.25 var(--font-sans);--tracking-card-title:-.4px;--type-subhead:400 20px/1.4 var(--font-sans);--tracking-subhead:-.2px;--type-body-lg:400 18px/1.5 var(--font-sans);--tracking-body-lg:-.1px;--type-body:400 16px/1.5 var(--font-sans);--tracking-body:-.05px;--type-body-sm:400 14px/1.5 var(--font-sans);--tracking-body-sm:0;--type-caption:400 12px/1.4 var(--font-sans);--tracking-caption:0;--type-button:500 14px/1.2 var(--font-sans);--tracking-button:0;--type-eyebrow:500 13px/1.3 var(--font-sans);--tracking-eyebrow:.4px;--type-mono:400 13px/1.5 var(--font-mono);--tracking-mono:0;--spacing-xxs:4px;--spacing-xs:8px;--spacing-sm:12px;--spacing-md:16px;--spacing-lg:24px;--spacing-xl:32px;--spacing-xxl:48px;--spacing-section:96px;--focus-ring:2px solid color-mix(in srgb,var(--primary-focus) 50%,transparent)}
*{box-sizing:border-box}
body{margin:0;background:var(--canvas);color:var(--ink);font:var(--type-body-sm);letter-spacing:var(--tracking-body-sm)}
body.modal-open{overflow:hidden}
:focus-visible{outline:var(--focus-ring);outline-offset:1px}
header{position:sticky;top:0;z-index:3;padding:var(--spacing-md) var(--spacing-lg);border-bottom:1px solid var(--hairline);background:color-mix(in srgb,var(--canvas) 96%,transparent);backdrop-filter:blur(12px)}
.topbar{display:flex;align-items:flex-start;justify-content:space-between;gap:var(--spacing-md)}
h1{margin:0;font:var(--type-headline);letter-spacing:var(--tracking-headline)}
.status{margin-top:var(--spacing-xxs);color:var(--ink-subtle);font:var(--type-caption);letter-spacing:var(--tracking-caption)}
.session-control{color:var(--ink-subtle);font:var(--type-caption);letter-spacing:var(--tracking-caption);text-align:right}
.session-control select{display:block;min-width:240px;margin-top:var(--spacing-xxs);padding:var(--spacing-xs) var(--spacing-sm);border:1px solid var(--hairline);border-radius:var(--rounded-md);background:var(--surface-1);color:var(--ink);font:var(--type-body);letter-spacing:var(--tracking-body)}
.filterbar{display:flex;flex-wrap:wrap;gap:var(--spacing-xs);margin-top:var(--spacing-sm)}
.filterbar button{border:1px solid var(--hairline);border-radius:var(--rounded-pill);background:var(--canvas);color:var(--ink-subtle);padding:6px 14px;font:var(--type-button);letter-spacing:var(--tracking-button);cursor:pointer}
.filterbar button:hover{background:var(--surface-1)}
.filterbar button.active{border-color:var(--primary);color:var(--ink);background:var(--surface-2)}
.copy-chip{border:1px solid var(--hairline-strong);border-radius:var(--rounded-sm);background:var(--surface-2);color:var(--ink-muted);padding:2px var(--spacing-xs);font:var(--type-mono);letter-spacing:var(--tracking-mono);cursor:pointer}
.copy-chip:hover{color:var(--ink);border-color:var(--primary-hover)}
.search{margin-top:var(--spacing-sm);width:100%;max-width:420px;padding:var(--spacing-xs) var(--spacing-sm);border:1px solid var(--hairline-strong);border-radius:var(--rounded-pill);background:var(--surface-1);color:var(--ink);font:var(--type-body-sm);letter-spacing:var(--tracking-body-sm)}
.search::placeholder{color:var(--ink-subtle)}
.group{margin:0 0 var(--spacing-lg)}
.group-head{display:flex;align-items:baseline;justify-content:space-between;gap:var(--spacing-sm);margin:0 0 var(--spacing-sm);padding-bottom:var(--spacing-xs);border-bottom:1px solid var(--hairline)}
.group-head h2{margin:0;font:var(--type-subhead);letter-spacing:var(--tracking-subhead);word-break:break-all}
.group-head .count{color:var(--ink-subtle);font:var(--type-caption);letter-spacing:var(--tracking-caption);white-space:nowrap}
.group-list{display:grid;gap:var(--spacing-md)}
.copy-chip{margin-left:var(--spacing-xs)}
.selector-chips{display:flex;flex-wrap:wrap;gap:var(--spacing-xs);margin-top:var(--spacing-sm)}
.selector-chips .copy-chip{margin-left:0}
main{max-width:1280px;margin:0 auto;padding:var(--spacing-lg) var(--spacing-lg) var(--spacing-xxl)}
.empty{padding:var(--spacing-xxl);font:var(--type-body);letter-spacing:var(--tracking-body);border:1px solid var(--hairline);border-radius:var(--rounded-lg);background:var(--surface-1);color:var(--ink-subtle)}
.timeline{position:relative}
.timeline:before{content:"";position:absolute;left:50%;top:0;bottom:0;width:1px;background:linear-gradient(180deg,transparent,var(--hairline) 22px,var(--hairline) calc(100% - 22px),transparent)}
.lane-labels{display:grid;grid-template-columns:minmax(0,1fr) 64px minmax(0,1fr);margin:0 0 var(--spacing-md);color:var(--ink-subtle);font:var(--type-eyebrow);letter-spacing:var(--tracking-eyebrow);text-transform:uppercase}
.lane-labels div:first-child{padding-right:var(--spacing-md);text-align:right}
.lane-labels div:last-child{padding-left:var(--spacing-md)}
.trace-group{margin:0 0 var(--spacing-lg)}
.node{--marker:var(--primary);position:relative;display:grid;grid-template-columns:minmax(0,1fr) 64px minmax(0,1fr);align-items:start;margin:0 0 var(--spacing-lg)}
.node.before,.node.after{--marker:var(--semantic-success)}
.node.diff{--marker:var(--semantic-warning)}
.node.runtime{--marker:var(--semantic-danger)}
.node.network{--marker:var(--semantic-network)}
.event-side{display:flex;min-width:0;padding-right:var(--spacing-md);flex-direction:column;align-items:flex-end}
.network-side{min-height:1px;padding-left:var(--spacing-md)}
.time{padding:0 0 var(--spacing-xs);color:var(--ink-tertiary);font:var(--type-caption);letter-spacing:var(--tracking-caption);text-align:right}
.marker{position:relative;min-height:42px}
.marker:before{content:"";position:absolute;left:50%;top:15px;width:10px;height:10px;border-radius:var(--rounded-full);background:var(--marker);box-shadow:0 0 0 4px color-mix(in srgb,var(--marker) 10%,transparent);transform:translateX(-50%)}
.card{font:var(--type-body);letter-spacing:var(--tracking-body);width:100%;min-width:0;border:1px solid var(--hairline);border-radius:var(--rounded-lg);background:var(--surface-1);overflow:hidden}
.node.before .card,.node.after .card{width:auto;max-width:100%;border-radius:var(--rounded-xl)}
.node.before .card:hover,.node.after .card:hover{border-color:var(--hairline-strong)}
.card-head{display:flex;align-items:flex-start;justify-content:space-between;padding:var(--spacing-lg);border-bottom:1px solid var(--hairline)}
.phase{color:var(--ink-subtle);font:var(--type-eyebrow);letter-spacing:var(--tracking-eyebrow);text-transform:uppercase}
.title{margin-top:var(--spacing-xxs);font:var(--type-card-title);letter-spacing:var(--tracking-card-title)}
.meta{margin-top:var(--spacing-xxs);color:var(--ink-subtle);font:var(--type-body-sm);letter-spacing:var(--tracking-body-sm);word-break:break-all}
.badge{align-self:flex-start;margin-left:var(--spacing-sm);padding:2px var(--spacing-xs);border:1px solid var(--hairline-strong);border-radius:var(--rounded-pill);background:var(--surface-2);color:var(--ink-muted);font:var(--type-caption);letter-spacing:var(--tracking-caption);white-space:nowrap}.badge.mock{color:var(--semantic-success)}
.body{padding:var(--spacing-lg)}
.shot-body{display:grid;grid-template-columns:minmax(180px,260px) max-content;gap:var(--spacing-md);align-items:start;max-width:100%}
.shot-copy{min-width:0}
.media{margin-top:var(--spacing-sm)}
.shot-body .media{display:flex;justify-content:flex-start;margin-top:0;max-width:100%}
.artifact{margin-top:var(--spacing-sm);padding:var(--spacing-xs) var(--spacing-sm);border:1px solid var(--hairline-strong);border-radius:var(--rounded-md);background:var(--surface-2);color:var(--ink-subtle);font:var(--type-caption);letter-spacing:var(--tracking-caption)}
.shot-copy .artifact:first-child{margin-top:0}
.facts{display:grid;grid-template-columns:repeat(3,1fr);border:1px solid var(--hairline-strong);border-radius:var(--rounded-md);overflow:hidden}
.fact{min-width:0;padding:var(--spacing-xs) var(--spacing-sm);border-right:1px solid var(--hairline-strong);background:var(--surface-2)}
.fact:last-child{border-right:0}
.fact span{display:block;color:var(--ink-subtle);font:var(--type-eyebrow);letter-spacing:var(--tracking-eyebrow)}
.fact b{display:block;margin-top:var(--spacing-xxs);font:var(--type-mono);letter-spacing:var(--tracking-mono);color:var(--ink-muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
details{margin-top:var(--spacing-sm);padding-top:var(--spacing-sm);border-top:1px solid var(--hairline)}
summary{cursor:pointer;color:var(--ink-subtle);font:var(--type-eyebrow);letter-spacing:var(--tracking-eyebrow);text-transform:uppercase}
.shot-link{display:inline-flex;align-items:center;justify-content:center;max-width:100%;border:1px solid var(--hairline);border-radius:var(--rounded-md);background:var(--canvas);overflow:hidden;cursor:zoom-in}
.shot{display:block;width:auto;max-width:100%;height:min(54vh,560px);object-fit:contain}
.shot-error{padding:var(--spacing-md);border:1px solid var(--hairline-strong);border-radius:var(--rounded-md);background:var(--surface-2);color:var(--semantic-danger);font:var(--type-caption);letter-spacing:var(--tracking-caption)}
.net-card{font:var(--type-body);letter-spacing:var(--tracking-body);border:1px solid var(--hairline);border-radius:var(--rounded-lg);background:var(--surface-1);overflow:hidden}
.net-head{display:flex;justify-content:space-between;gap:var(--spacing-sm);padding:var(--spacing-lg);border-bottom:1px solid var(--hairline)}
.net-url{margin-top:var(--spacing-xxs);font:var(--type-mono);letter-spacing:var(--tracking-mono);color:var(--ink-muted);word-break:break-all}.net-meta{color:var(--ink-subtle);font:var(--type-caption);letter-spacing:var(--tracking-caption)}.net-body{padding:var(--spacing-lg)}
.net-section{margin-top:var(--spacing-sm);padding:var(--spacing-xs) var(--spacing-sm);border:1px solid var(--hairline-tertiary);border-radius:var(--rounded-md);background:var(--surface-4)}
.net-section:first-child,.net-grid>.net-section{margin-top:0}.net-section h3{margin:0 0 var(--spacing-xs);color:var(--ink-subtle);font:var(--type-eyebrow);letter-spacing:var(--tracking-eyebrow);text-transform:uppercase}
.net-grid{display:grid;grid-template-columns:1fr 1fr;gap:var(--spacing-sm)}.body-preview{margin-top:var(--spacing-xs);max-height:180px;overflow:auto;white-space:pre-wrap;word-break:break-word;color:var(--ink-muted);font:var(--type-mono);letter-spacing:var(--tracking-mono)}
.link{color:var(--primary);word-break:break-all}
.link:hover{color:var(--primary-hover)}
pre{margin:0;max-height:260px;overflow:auto;white-space:pre-wrap;word-break:break-word;color:var(--ink-muted);font:var(--type-mono);letter-spacing:var(--tracking-mono)}
table{width:100%;border-collapse:collapse}
th,td{padding:var(--spacing-sm) var(--spacing-xs);border-bottom:1px solid var(--hairline);text-align:left;vertical-align:top}
td{color:var(--ink-muted);font:var(--type-mono);letter-spacing:var(--tracking-mono)}
th{color:var(--ink-subtle);font:var(--type-eyebrow);letter-spacing:var(--tracking-eyebrow);text-transform:uppercase}
.lightbox{position:fixed;inset:0;z-index:10;display:flex;align-items:center;justify-content:center;padding:var(--spacing-lg);background:color-mix(in srgb,var(--semantic-overlay) 70%,transparent)}
.lightbox[hidden]{display:none}
.lightbox-panel{position:relative;max-width:96vw;max-height:94vh;padding:var(--spacing-xxl) var(--spacing-md) var(--spacing-md);border:1px solid var(--hairline);border-radius:var(--rounded-xl);background:var(--surface-1);box-shadow:0 24px 80px rgba(0,0,0,.45)}
.lightbox img{display:block;max-width:92vw;max-height:82vh;object-fit:contain}
.lightbox-close{position:absolute;right:var(--spacing-sm);top:var(--spacing-sm);border:1px solid var(--hairline-strong);border-radius:var(--rounded-pill);background:var(--surface-2);color:var(--ink);padding:6px 14px;font:var(--type-button);letter-spacing:var(--tracking-button);cursor:pointer}
.lightbox-caption{margin-top:var(--spacing-xs);color:var(--ink-subtle);font:var(--type-caption);letter-spacing:var(--tracking-caption);text-align:center}
@media(max-width:900px){header{padding:var(--spacing-md)}main{padding:var(--spacing-md) var(--spacing-md) var(--spacing-xl)}.card-head,.body,.net-head,.net-body{padding:var(--spacing-md)}.timeline:before{left:24px}.lane-labels{display:none}.topbar{flex-direction:column;gap:var(--spacing-sm)}.session-control{width:100%;text-align:left}.session-control select{min-width:0;width:100%}.node{grid-template-columns:42px minmax(0,1fr)}.event-side{grid-column:2;padding-right:0;align-items:stretch}.network-side{grid-column:2;min-width:0;padding-left:0}.node:not(.network) .network-side{display:none}.net-grid{grid-template-columns:minmax(0,1fr)}.time{padding:0 0 var(--spacing-xxs);text-align:left}.marker{grid-column:1;grid-row:1 / span 2}.card{width:100%}.shot-body,.facts{display:block}.shot-body .media{margin-top:var(--spacing-sm)}.fact{border-right:0;border-bottom:1px solid var(--hairline-strong)}.fact:last-child{border-bottom:0}.card-head{display:block}.badge{display:inline-block;margin:var(--spacing-sm) 0 0}}
</style>
</head>
<body>
<header>
<div class="topbar"><div><h1>Reticle Evidence Timeline</h1><div id="status" class="status">Loading session events...</div><div id="view-toggle" class="filterbar"><button type="button" data-view="timeline" class="active">Timeline</button><button type="button" data-view="rules">Rule groups</button></div><div id="network-filters" class="filterbar"><button type="button" data-filter="all" class="active">All</button><button type="button" data-filter="rule">RULE</button><button type="button" data-filter="error">ERROR</button><button type="button" data-filter="mitm">MITM</button><button type="button" data-filter="tunnel">TUNNEL</button></div><div id="network-status-filters" class="filterbar"><button type="button" data-status="all" class="active">Any status</button><button type="button" data-status="2xx">2xx</button><button type="button" data-status="3xx">3xx</button><button type="button" data-status="4xx">4xx</button><button type="button" data-status="5xx">5xx</button></div><input id="network-search" class="search" type="search" placeholder="Filter network: method, url, host, status, rule id..."></div><label class="session-control">Session<select id="session-picker"></select></label></div>
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
const state={events:[],sessions:[],selectedSession:null,currentSession:null,manifests:new Map(),stream:null,networkFilter:'all',networkStatusClass:'all',networkSearch:'',view:'timeline'};
const timeline=document.getElementById('timeline');
const statusEl=document.getElementById('status');
const sessionPicker=document.getElementById('session-picker');
const networkFilters=document.getElementById('network-filters');
const networkStatusFilters=document.getElementById('network-status-filters');
const networkSearch=document.getElementById('network-search');
const viewToggle=document.getElementById('view-toggle');
const lightbox=document.getElementById('lightbox'),lightboxImage=document.getElementById('lightbox-image'),lightboxCaption=document.getElementById('lightbox-caption');
function selectedIsCurrent(){return state.selectedSession===state.currentSession;}
function sessionRoute(){return selectedIsCurrent()?'current':encodeURIComponent(state.selectedSession||'current');}
function artifactUrl(event,ref){return `/sessions/${sessionRoute()}/artifacts?event=${encodeURIComponent(event.id)}&ref=${encodeURIComponent(ref)}`;}
function escapeHtml(value){return String(value===undefined||value===null?'':value).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');}
function pretty(value){return escapeHtml(JSON.stringify(value,null,2));}
function actionEvents(){return state.events.filter((event)=>event.type==='action.trace');}
function networkEvents(){return state.events.filter((event)=>/^network\./.test(event.type));}
function runtimeEvents(){return state.events.filter((event)=>event.type==='runtime.advisory');}
function networkTransactions(){
  const groups=new Map();
  for(const event of networkEvents()){
    const p=event.payload||{}, id=p.requestId||event.id;
    const tx=groups.get(id)||{id,events:[],refs:{},request:null,response:null,error:null};
    tx.events.push(event);Object.assign(tx.refs,event.refs||{});
    if(event.type==='network.request'){tx.request=event;}
    if(event.type==='network.response'){tx.response=event;}
    if(event.type==='network.error'){tx.error=event;}
    groups.set(id,tx);
  }
  return [...groups.values()].map((tx)=>{tx.event=tx.error||tx.response||tx.request||tx.events[tx.events.length-1];tx.payload=Object.assign({},...(tx.events.map((e)=>e.payload||{})));return tx;});
}
function statusClassOf(payload){
  const status=Number(payload.status);
  if(!Number.isFinite(status)){return null;}
  if(status>=200&&status<300){return '2xx';}
  if(status>=300&&status<400){return '3xx';}
  if(status>=400&&status<500){return '4xx';}
  if(status>=500&&status<600){return '5xx';}
  return null;
}
function networkFilterMatches(tx){
  const p=tx.payload||{};
  switch(state.networkFilter){
    case 'rule': if(!p.ruleApplied){return false;} break;
    case 'error': if(!p.error){return false;} break;
    case 'mitm': if(!p.mitm){return false;} break;
    case 'tunnel': if(!p.tunnel){return false;} break;
  }
  if(state.networkStatusClass!=='all'&&statusClassOf(p)!==state.networkStatusClass){return false;}
  if(state.networkSearch){
    const needle=state.networkSearch.toLowerCase();
    const hay=[p.method,p.url,p.host,p.path,p.status,p.ruleId,p.ruleAction,p.mockValueId].map((v)=>String(v===undefined||v===null?'':v).toLowerCase()).join(' ');
    if(!hay.includes(needle)){return false;}
  }
  return true;
}
function slugForRule(value){
  const slug=String(value||'').toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-+|-+$/g,'').slice(0,48);
  return /^[a-z0-9]/.test(slug)?slug:`rule-${slug}`;
}
function shellQuote(value){return `'${String(value===undefined||value===null?'':value).replace(/'/g,"'\\''")}'`;}
function ruleCommandFor(tx){
  const p=tx.payload||{}, refs=tx.refs||{};
  const bodyRef=Object.keys(refs).find((ref)=>ref.startsWith('responseBody.'));
  const bodyPath=bodyRef?refs[bodyRef]:null;
  const id=slugForRule(`${p.host||'host'}${p.path||'/'}`);
  const status=isPresent(p.status)?p.status:200;
  const headers=p.responseHeaders||{};
  const contentType=headers['Content-Type']||headers['content-type']||'application/json';
  const parts=['reticle rule set',`--id ${id}`,'--action mock',`--value-id ${id}`,`--method ${p.method||'GET'}`,`--url ${shellQuote(p.path||'/')}`,'--match exact',`--status ${status}`,`--content-type ${shellQuote(contentType)}`];
  if(p.host){parts.push(`--host ${shellQuote(p.host)}`);}
  if(bodyPath){parts.push(`--body-file ${shellQuote(bodyPath)}`);}else{parts.push(`--body ${shellQuote('')}`);}
  return parts.join(' ');
}
function canCopyAsRule(tx){const p=tx.payload||{};return !(p.tunnel&&!p.mitm);}
function isPresent(value){return value!==undefined&&value!==null&&value!==''&&value!=='<null>';}
function eventMillis(event){
  const payload=event.payload||{};
  const value=Number(payload.recordedAtMillis||payload.startMillis||payload.endMillis||event.ts||0);
  return Number.isFinite(value)?value:0;
}
function labelFor(event){const payload=event.payload||{};return `${payload.gesture||'action'} ${selectorLabel(payload.selector)}`;}
function selectorLabel(selector){
  if(!selector){return 'direct target';}
  const fields=[['testId','test-id'],['cssSelector','css'],['ref','ref'],['resourceId','res'],['region','region'],['point','point']];
  for(const [key,label] of fields){const value=selector[key];if(isPresent(value)){return `${label}=${typeof value==='object'?JSON.stringify(value):value}`;}}
  return 'direct target';
}
function formatTime(ms){const date=new Date(ms);return Number.isNaN(date.getTime())?String(ms):date.toLocaleTimeString();}
function mergeEvent(event){
  const index=state.events.findIndex((item)=>item.id===event.id);
  if(index>=0){state.events[index]=event;}else{state.events.push(event);}
  state.events.sort((a,b)=>eventMillis(a)-eventMillis(b)||a.id.localeCompare(b.id));
}
function updateStatusLine(){
  const actions=actionEvents(), runtimes=runtimeEvents(), allNetworks=networkTransactions(), networks=allNetworks.filter(networkFilterMatches);
  const live=selectedIsCurrent()?'live':'history';
  const ruleCount=allNetworks.filter((tx)=>tx.payload&&tx.payload.ruleApplied).length;
  statusEl.textContent=`${state.selectedSession||'session'} · ${live} · ${state.events.length} event(s), ${actions.length} action trace(s), ${runtimes.length} runtime advisory(s), ${networks.length}/${allNetworks.length} network request(s), ${ruleCount} rule hit(s)`;
}
function renderTimeline(){
  updateStatusLine();
  if(state.view==='rules'){renderNetworkGroups();return;}
  const actions=actionEvents(), runtimes=runtimeEvents(), allNetworks=networkTransactions(), networks=allNetworks.filter(networkFilterMatches);
  if(actions.length===0&&allNetworks.length===0&&runtimes.length===0){
    timeline.className='';
    timeline.innerHTML='<div class="empty">No evidence yet. Run reticle act or enable the proxy while serve is running.</div>';
    return;
  }
  timeline.className='timeline';
  const items=[...actions.map((event,index)=>({at:eventMillis(event),html:traceGroup(event,index+1)})),...runtimes.map((event)=>({at:eventMillis(event),html:runtimeNode(event)})),...networks.map((tx)=>({at:eventMillis(tx.request||tx.event),html:networkNode(tx)}))].sort((a,b)=>a.at-b.at);
  timeline.innerHTML=`<div class="lane-labels"><div>UI evidence</div><div></div><div>Network requests</div></div>${items.map((item)=>item.html).join('')}`;
  attachScreenshotPreviews();
  attachCopyChips();
  hydrateDiffs();
  hydrateBodyPreviews();
}
function groupSection(title,count,txs){
  const cards=[...txs].sort((a,b)=>eventMillis(a.request||a.event)-eventMillis(b.request||b.event)).map(networkCard).join('');
  return `<section class="group"><div class="group-head"><h2>${escapeHtml(title)}</h2><div class="count">${escapeHtml(count)}</div></div><div class="group-list">${cards}</div></section>`;
}
function renderNetworkGroups(){
  const networks=networkTransactions().filter(networkFilterMatches);
  if(networks.length===0){
    timeline.className='';
    timeline.innerHTML='<div class="empty">No network requests match the current filters. Enable the proxy while serve is running, or relax the filters above.</div>';
    return;
  }
  timeline.className='';
  const groups=[];
  const byRule=new Map();
  for(const tx of networks.filter((tx)=>tx.payload&&tx.payload.ruleApplied)){
    const key=(tx.payload&&tx.payload.ruleId)||'(unknown rule)';
    if(!byRule.has(key)){byRule.set(key,[]);}
    byRule.get(key).push(tx);
  }
  for(const [ruleId,txs] of byRule){groups.push(groupSection(`Rule: ${ruleId}`,`${txs.length} hit(s)`,txs));}
  const byHost=new Map();
  for(const tx of networks.filter((tx)=>!(tx.payload&&tx.payload.ruleApplied))){
    const key=(tx.payload&&tx.payload.host)||'(unknown host)';
    if(!byHost.has(key)){byHost.set(key,[]);}
    byHost.get(key).push(tx);
  }
  for(const [host,txs] of byHost){groups.push(groupSection(`Host: ${host}`,`${txs.length} request(s)`,txs));}
  timeline.innerHTML=groups.join('');
  attachCopyChips();
  hydrateBodyPreviews();
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
function networkCard(tx){
  const p=tx.payload||{}, event=tx.event, status=p.error?'error':(p.status||'pending'), duration=isPresent(p.durationMs)?`${p.durationMs} ms`:'pending';
  const transport=p.tunnel?'CONNECT tunnel':(p.mitm?'HTTPS MITM':'HTTP');
  const action=(p.ruleAction||'').toUpperCase();
  const mode=p.ruleApplied?`${action||'RULE'} ${transport}`:transport;
  const badge=p.ruleApplied?(action||'RULE'):status;
  const valueChip=p.mockValueId?`<button class="copy-chip" type="button" data-copy="${escapeHtml(p.mockValueId)}">value ${escapeHtml(p.mockValueId)}</button>`:'';
  const ruleMeta=p.ruleApplied?` <button class="copy-chip" type="button" data-copy="${escapeHtml(p.ruleId||'')}">rule ${escapeHtml(p.ruleId||'unknown')}${p.ruleAction?` · ${escapeHtml(p.ruleAction)}`:''}</button>${valueChip}`:'';
  const ruleAction=canCopyAsRule(tx)?` <button class="copy-chip" type="button" data-copy="${escapeHtml(ruleCommandFor(tx))}">copy as rule</button>`:'';
  const facts=`<div class="facts"><div class="fact"><span>Host</span><b title="${escapeHtml(p.host||'unknown')}">${escapeHtml(p.host||'unknown')}</b></div><div class="fact"><span>Status</span><b>${escapeHtml(status)}</b></div><div class="fact"><span>Duration</span><b>${escapeHtml(duration)}</b></div></div>`;
  const refs=Object.keys(tx.refs||{}), requestRef=refs.find((ref)=>ref.startsWith('requestBody.')), responseRef=refs.find((ref)=>ref.startsWith('responseBody.'));
  const body=(label,ref,bytes,truncated)=>!ref?'':`<div class="net-section"><h3>${label} body</h3><div class="artifact">${refLink(event,ref,`${bytes||0} bytes${truncated?' · truncated':''}`)}</div><pre class="body-preview" data-event-id="${escapeHtml(event.id)}" data-ref="${escapeHtml(ref)}">Loading preview...</pre></div>`;
  const headers=(title,items)=>items?`<details class="net-section" open><summary>${escapeHtml(title)} headers</summary><pre>${pretty(items)}</pre></details>`:'';
  const refsBlock=refs.length?`<details class="net-section"><summary>Artifact refs</summary><pre>${pretty(tx.refs)}</pre></details>`:'';
  const request=`<div class="net-section"><h3>Request</h3><div class="meta">${escapeHtml(p.method||'HTTP')} ${escapeHtml(p.path||'/')}</div>${headers('request',p.requestHeaders)}${body('Request',requestRef,p.requestBodyBytes,p.requestBodyTruncated)}</div>`;
  const response=`<div class="net-section"><h3>Response</h3><div class="meta">${escapeHtml(isPresent(p.status)?`HTTP ${p.status}`:'pending')}</div>${headers('response',p.responseHeaders)}${body('Response',responseRef,p.responseBodyBytes,p.responseBodyTruncated)}</div>`;
  return `<div class="net-card"><div class="net-head"><div><div class="phase">${escapeHtml(mode)}</div><div class="net-url">${escapeHtml((p.method||'HTTP')+' '+(p.url||p.host||''))}</div><div class="net-meta">${escapeHtml(tx.id)} · ${tx.events.length} event(s)${ruleMeta}${ruleAction}</div></div><div class="badge ${p.ruleApplied?'mock':''}">${escapeHtml(badge)}</div></div><div class="net-body">${facts}${p.error?`<div class="shot-error">${escapeHtml(p.error)}</div>`:''}<div class="net-grid">${request}${response}</div>${refsBlock}</div></div>`;
}
function networkNode(tx){
  const event=tx.event;
  return `<div class="node network"><div class="event-side"><div class="time">${escapeHtml(formatTime(eventMillis(tx.request||event)))}</div></div><div class="marker"></div><div class="network-side">${networkCard(tx)}</div></div>`;
}
function runtimeNode(event){
  const p=event.payload||{}, kind=p.kind||'runtime advisory';
  const facts=`<div class="facts"><div class="fact"><span>Kind</span><b>${escapeHtml(kind)}</b></div><div class="fact"><span>Previous</span><b>${escapeHtml(pidRuntimeLabel(p.previousPid,p.previousRuntime))}</b></div><div class="fact"><span>Current</span><b>${escapeHtml(pidRuntimeLabel(p.currentPid,p.currentRuntime))}</b></div></div>`;
  const body=`${facts}<div class="artifact">${escapeHtml(p.message||'Runtime state changed.')}</div><details><summary>Runtime advisory payload</summary><pre>${pretty(p)}</pre></details>`;
  return node(event,'runtime',formatTime(eventMillis(event)),'Runtime advisory','runtime',kind,body);
}
function pidRuntimeLabel(pid,runtime){
  const parts=[];if(isPresent(pid)){parts.push(`pid=${pid}`);}if(isPresent(runtime)){parts.push(runtime);}return parts.join(' · ')||'unknown';
}
function traceGroup(event,index){
  const payload=event.payload||{}, target=payload.target||{}, result=payload.result||{};
  const time=formatTime(eventMillis(event)), targetSource=target.source||result.source||'unknown', targetRef=target.ref||result.ref||'none';
  const targetPoint=target.point?`${target.point.x}, ${target.point.y}`:(result.x&&result.y?`${result.x}, ${result.y}`:'none');
  const beforeBody=`<div class="shot-body"><div class="shot-copy"><div class="artifact">Snapshot: ${refLink(event,'beforeSnapshot','snapshot.json')}</div><details><summary>Evidence ref</summary><pre>${pretty({snapshot:event.refs&&event.refs.beforeSnapshot,screenshot:event.refs&&event.refs.beforeScreenshot})}</pre></details></div><div class="media">${screenshot(event,'beforeScreenshot')}</div></div>`;
  const actionBody=`<div class="facts"><div class="fact"><span>Selector</span><b>${escapeHtml(selectorLabel(payload.selector))}</b></div><div class="fact"><span>Target source</span><b>${escapeHtml(targetSource)}</b></div><div class="fact"><span>Point</span><b>${escapeHtml(targetPoint)}</b></div></div>${selectorChips(payload.selector,target,result)}<details><summary>Selector JSON</summary><pre>${pretty(payload.selector||{})}</pre></details><details><summary>Target / result JSON</summary><pre>${pretty(payload.target||payload.result||{})}</pre></details>`;
  const afterBody=`<div class="shot-body"><div class="shot-copy"><div class="artifact">Snapshot: ${refLink(event,'afterSnapshot','snapshot.json')}</div><details><summary>Evidence ref</summary><pre>${pretty({snapshot:event.refs&&event.refs.afterSnapshot,screenshot:event.refs&&event.refs.afterScreenshot})}</pre></details></div><div class="media">${screenshot(event,'afterScreenshot')}</div></div>`;
  const diffBody=`<div class="artifact">Manifest: ${refLink(event,'manifest','trace.json')} &middot; target ref: ${escapeHtml(targetRef)}</div><div class="diff-target" data-event-id="${escapeHtml(event.id)}">Loading diff...</div><details><summary>Artifact refs</summary><pre>${pretty(event.refs||{})}</pre></details><details><summary>Full payload</summary><pre>${pretty(payload)}</pre></details>`;
  return `<article class="trace-group">${node(event,'before',time,`Screenshot`,`${index}.1 evidence`,event.refs&&event.refs.beforeScreenshot?'screenshot':'snapshot only',beforeBody)}${node(event,'action',time,labelFor(event),`${index}.2 action`,targetSource,actionBody)}${node(event,'after',time,`Screenshot`,`${index}.3 evidence`,event.refs&&event.refs.afterScreenshot?'screenshot':'snapshot only',afterBody)}${node(event,'diff',time,`Diff`,`${index}.4 changes`,`${payload.changeCount||0} change(s)`,diffBody)}</article>`;
}
function selectorChips(selector,target,result){
  const chips=[];
  const add=(label,value)=>{if(isPresent(value)){chips.push(`<button class="copy-chip selector-chip" type="button" data-copy="${escapeHtml(value)}">${escapeHtml(label)} ${escapeHtml(value)}</button>`);}};
  selector=selector||{};target=target||{};result=result||{};
  add('test-id',selector.testId);add('css',selector.cssSelector);add('ref',selector.ref||target.ref||result.ref);add('resource',selector.resourceId);add('point',target.point?`${target.point.x},${target.point.y}`:(result.x&&result.y?`${result.x},${result.y}`:null));
  return chips.length?`<div class="selector-chips">${chips.join('')}</div>`:'';
}
function openLightbox(src,label){lightboxImage.src=src;lightboxImage.alt=label;lightboxCaption.textContent=label;lightbox.hidden=false;document.body.classList.add('modal-open');}
function closeLightbox(){lightbox.hidden=true;lightboxImage.removeAttribute('src');document.body.classList.remove('modal-open');}
function attachScreenshotPreviews(){timeline.querySelectorAll('.shot-link').forEach((button)=>{button.addEventListener('click',()=>openLightbox(button.dataset.shotSrc,button.dataset.shotLabel));button.querySelector('img')?.addEventListener('error',()=>{button.outerHTML=`<div class="shot-error">Screenshot artifact could not be loaded: ${escapeHtml(button.querySelector('img')?.dataset.ref||'unknown')}</div>`;});});}
function attachCopyChips(){timeline.querySelectorAll('.copy-chip').forEach((button)=>button.addEventListener('click',async()=>{try{await navigator.clipboard.writeText(button.dataset.copy||'');button.textContent='copied';}catch(error){button.textContent='copy failed';}}));}
async function loadManifest(event){
  if(!event.refs||!event.refs.manifest){return null;}
  if(state.manifests.has(event.id)){return state.manifests.get(event.id);}
  try{const response=await fetch(artifactUrl(event,'manifest'));if(!response.ok){throw new Error(`HTTP ${response.status}`);}const manifest=await response.json();state.manifests.set(event.id,manifest);return manifest;
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
function hydrateBodyPreviews(){
  timeline.querySelectorAll('.body-preview').forEach(async (el)=>{
    const event=state.events.find((item)=>item.id===el.dataset.eventId);
    if(!event){return;}
    try{
      const response=await fetch(artifactUrl(event,el.dataset.ref));
      if(!response.ok){throw new Error(`HTTP ${response.status}`);}
      const text=new TextDecoder().decode(await response.arrayBuffer());
      el.textContent=text.length>4096?`${text.slice(0,4096)}\n... preview truncated ...`:text;
    }catch(error){
      el.textContent=`Preview unavailable: ${error}`;
    }
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
  stream.addEventListener('network.request',handleMessage);
  stream.addEventListener('network.response',handleMessage);
  stream.addEventListener('network.error',handleMessage);
  stream.addEventListener('runtime.advisory',handleMessage);
  stream.onerror=()=>{statusEl.textContent='Live event stream disconnected; retrying...';};
}
sessionPicker.addEventListener('change',async()=>{state.selectedSession=sessionPicker.value;if(state.stream){state.stream.close();state.stream=null;}await loadHistory();connectStream();});
networkFilters.addEventListener('click',(event)=>{const button=event.target.closest('button[data-filter]');if(!button){return;}state.networkFilter=button.dataset.filter||'all';networkFilters.querySelectorAll('button').forEach((item)=>item.classList.toggle('active',item===button));renderTimeline();});
networkStatusFilters.addEventListener('click',(event)=>{const button=event.target.closest('button[data-status]');if(!button){return;}state.networkStatusClass=button.dataset.status||'all';networkStatusFilters.querySelectorAll('button').forEach((item)=>item.classList.toggle('active',item===button));renderTimeline();});
networkSearch.addEventListener('input',()=>{state.networkSearch=networkSearch.value.trim();renderTimeline();});
viewToggle.addEventListener('click',(event)=>{const button=event.target.closest('button[data-view]');if(!button){return;}state.view=button.dataset.view||'timeline';viewToggle.querySelectorAll('button').forEach((item)=>item.classList.toggle('active',item===button));renderTimeline();});
document.getElementById('lightbox-close').addEventListener('click',closeLightbox);
lightbox.addEventListener('click',(event)=>{if(event.target===lightbox){closeLightbox();}});
document.addEventListener('keydown',(event)=>{if(event.key==='Escape'&&!lightbox.hidden){closeLightbox();}});
loadSessions().then(loadHistory).then(connectStream).catch((error)=>{statusEl.textContent=`Load failed: ${error}`;});
</script>
</body>
</html>
"""#

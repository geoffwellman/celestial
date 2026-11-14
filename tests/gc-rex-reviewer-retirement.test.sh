# shellcheck shell=bash
# Exercise the real retirement policy and GC integration. Only external Rex,
# GitHub and inbox boundaries are fixtures; native history, /proc generations,
# descendants, receipts, verdicts and registry updates are real private files.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/registry.sh"
source "$CEL_ROOT/lib/gc.sh"
source "$CEL_ROOT/lib/reviewer-retirement.sh"
source "$CEL_ROOT/lib/solo.sh"
RR_SOURCE_ROOT="$CEL_ROOT"
RR_NODE="$(node -p process.execPath)"

_rr_fixture() {
  umask 077
  RR_T="$(mktemp -d)"
  RR_PID=""
  trap '_rr_cleanup' EXIT
  export HOME="$RR_T/home" CEL_REGISTRY="$RR_T/registry.yaml"
  export CEL_REX_STATE="$RR_T/rex" CEL_REVIEWERS_STATE="$RR_T/reviewers.json"
  export CEL_GC_REVIEWER_STOP_STATE="$RR_T/stop.json" CEL_GC_RETIRE_STATE="$RR_T/retire.json" RR_T
  RR_STATUS=idle
  export CEL_ROOT="$RR_T/root"
  RR_WS="$RR_T/workspace" RR_CO="$RR_T/workspace/.cel/reviewers/widget/71"
  RR_ALIAS=widget-pr-71-review RR_PANE=rex/widget-review/terminal
  RR_HEAD=1111111111111111111111111111111111111111
  export RR_NATIVE="$RR_T/pi/sessions/widget/native.jsonl"
  RR_RECEIPT="$CEL_REX_STATE/$RR_ALIAS.json"
  mkdir -p "$HOME" "$CEL_REX_STATE" "$RR_CO/artifacts" "$RR_WS/repos/widget" "$RR_T/bin" "$CEL_ROOT/bin" "$(dirname "$RR_NATIVE")"
  local protocol_paths
  protocol_paths="$("$RR_NODE" --input-type=module - "$RR_SOURCE_ROOT/tools/reviewers/retirement-protocol.mjs" "$RR_RECEIPT" <<'NODE'
import {pathToFileURL} from 'node:url';
const [module,receipt]=process.argv.slice(2);
const {reviewerRetirementPaths}=await import(pathToFileURL(module));
console.log(JSON.stringify(reviewerRetirementPaths(receipt)));
NODE
  )" || return
  RR_PROTOCOL_DIRECTORY="$(printf '%s' "$protocol_paths" | jq -er .directory)" || return
  RR_CAPABILITY="$(printf '%s' "$protocol_paths" | jq -er .capability)" || return
  mkdir -m 700 "$RR_PROTOCOL_DIRECTORY"
  ln -s "$RR_SOURCE_ROOT/lib" "$CEL_ROOT/lib"
  ln -s "$RR_SOURCE_ROOT/tools" "$CEL_ROOT/tools"
  mkdir -p "$RR_WS/.cel/reviews/pr-71"
  printf 'Reviewer fixture role\n' > "$RR_WS/.cel/reviews/pr-71/role-reviewer.md"
  export PI_CODING_AGENT_DIR="$RR_T/pi"
  chmod 700 "$CEL_REX_STATE"
  # The repo's declared url names its forge (forge_repo): GitHub by default,
  # Forgejo when the test sets RR_FORGE=forgejo.
  if [ "${RR_FORGE:-github}" = forgejo ]; then
    printf 'name: bundle\nrepos:\n  - name: widget\n    url: git@forgejo.example:acme/widget.git\n    forge: forgejo\n    host: http://forgejo.example\n' > "$RR_WS/workspace.yaml"
  else
    printf 'name: bundle\nrepos:\n  - name: widget\n    url: git@github.com:acme/widget.git\n' > "$RR_WS/workspace.yaml"
  fi
  printf 'review evidence\n' > "$RR_CO/artifacts/result.txt"
  registry_add bundle "$RR_WS" ""
  cat > "$RR_T/runtime.mjs" <<'NODE'
import fs from 'node:fs';
import {spawn,spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
const root=process.env.RR_T, receipt=process.env.CEL_REX_RECORD;
const {reviewerRetirementPaths}=await import(pathToFileURL(process.env.CEL_ROOT+'/tools/reviewers/retirement-protocol.mjs'));
const protocol=reviewerRetirementPaths(receipt);
process.title = 'pi';
fs.writeFileSync(root+'/ready', String(process.pid));
let child, producer, interrupted=false;
const keepalive=setInterval(()=>{},1000);
if (process.env.RR_JOB === '1') {
  child=spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{stdio:'ignore'});
  fs.writeFileSync(root+'/job.pid',String(child.pid));
}
process.on('SIGTERM',()=>{ interrupted=true; producer?.dispose(); clearInterval(keepalive); if(child) child.kill(); });
while(!fs.existsSync(root+'/receipt-ready')&&!interrupted) await new Promise(resolve=>setTimeout(resolve,10));
if(!interrupted) {
const state=()=>JSON.parse(fs.readFileSync(root+'/boundary.json','utf8'));
const exiting=()=>{
  try{return JSON.parse(fs.readFileSync(protocol.request,'utf8')).phase==='exit';}
  catch{return false;}
};
const event=type=>fs.appendFileSync(root+'/producer-events.jsonl',JSON.stringify({type})+'\n');
const ctx={
  mode:'tui',hasUI:true,cwd:process.cwd(),
  isIdle:()=>!state().sdkBusy,
  hasPendingMessages:()=>Boolean(state().sdkPending),
  sessionManager:{
    getSessionFile:()=>process.env.RR_NATIVE,
    getLeafId:()=>exiting()&&state().exitLeaf?state().exitLeaf:(state().liveLeaf||JSON.parse(fs.readFileSync(process.env.RR_NATIVE,'utf8').trim().split('\n').at(-1)).id),
  },
  ui:{getEditorText:()=>state().editorDraft||''},
  shutdown:()=>{
    event('sdk-shutdown');
    if(state().shutdownThrows) throw new Error('fixture SDK shutdown refused');
    if(state().processSurvives) return;
    producer?.dispose(); clearInterval(keepalive);
  },
};
if(process.env.RR_UNSUPPORTED_SDK==='1') delete ctx.shutdown;
const {startReviewerRetirement}=await import(pathToFileURL(process.env.CEL_ROOT+'/tools/hooks/reviewer-retirement.mjs'));
producer=startReviewerRetirement({
  getContext:()=>ctx,
  getNativeTurnActive:()=>Boolean(state().nativeTurnActive)||(exiting()&&Boolean(state().exitTurnActive)),
  getInboxDebt:()=>({owed:Boolean(state().inboxOwed)||(exiting()&&Boolean(state().exitDebt)),pending:Boolean(state().inboxPending),waking:Boolean(state().inboxWaking)}),
  countUnread:()=>{
    const result=spawnSync('bash',[process.env.CEL_ROOT+'/bin/cel','inbox','count','--for',process.env.CEL_AGENT_NAME,'--all-workspaces','--workspace','bundle'],{encoding:'utf8'});
    if(result.error||result.status!==0||!/^\d+\s*$/.test(result.stdout)) throw new Error('fixture unread count unavailable');
    return Number(result.stdout.trim());
  },
  prepareExit:()=>event('inbox-stopped'),
  restoreAfterFailedExit:()=>event('inbox-restored'),
});
fs.writeFileSync(root+'/producer-started',producer?'supported':'unsupported');
}
NODE
  cat > "$RR_T/bin/boundary" <<'NODE'
#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
const root = process.env.RR_T;
let args = process.argv.slice(2);
const cmd = path.basename(process.argv[1]);
const state = JSON.parse(fs.readFileSync(root + '/boundary.json'));
fs.appendFileSync(root + '/calls.jsonl', JSON.stringify({cmd,args}) + '\n');
if (cmd === 'rex') args = args.filter(arg => arg !== '--autostart=false');
const emit = x => console.log(JSON.stringify(x));
const save = () => fs.writeFileSync(root + '/boundary.json', JSON.stringify(state));
if (cmd === 'gh') {
  if (state.ghFailure) process.exit(1);
  if (state.ghMalformed) { console.log('{}'); process.exit(0); }
  emit({state:state.prState,headRefOid:state.head,headRefName:'review-widget',number:71,url:'https://github.com/acme/widget/pull/71'});
} else if (cmd === 'cel' && args[0] === 'forge') {
  // `cel forge pr view <repo>#<n> --json --workspace <name>`: lib/forge.sh's
  // normalised answer, as Forgejo's pull request reads in Celestial's words.
  if (args[1] !== 'pr' || args[2] !== 'view') process.exit(90);
  if (state.forgeFailure) process.exit(1);
  emit({number:state.forgeNumber||71,state:state.prState.toLowerCase(),head_sha:state.head,head_ref:'review-widget',base_ref:'main',author:'acme',draft:false,mergeable:'unknown',merged_at:null,url:state.forgeUrl||'http://forgejo.example/acme/widget/pulls/71',labels:[]});
} else if (cmd === 'cel') {
  if (args[0] !== 'inbox' || args[1] !== 'count') process.exit(91);
  if (state.mailFailure) process.exit(1);
  console.log(state.mail);
} else if (cmd === 'rex') {
  // windowScope: the reviewer is a window (reviewer-window) in its product
  // agent's session, beside the product's own window; only window-scoped
  // calls may touch it, and killing the session is never allowed.
  const flag = name => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
  if (state.windowScope && args[0] === 'block' && flag('-w') !== 'reviewer-window') process.exit(97);
  if (state.windowScope && args[0] === 'window' && args[1] === 'inspect') {
    if (state.inspectFailure || state.windowAbsent || args[2] !== 'reviewer-window' || flag('-s') !== 'widget-review') process.exit(3);
    const blocks = [{block_id:'terminal',type:'terminal'}];
    if (state.extraBlock) blocks.push({block_id:'user-terminal',type:'terminal'});
    emit({session_id:'widget-review',window_id:'reviewer-window',label:'widget-pr-71-review',focused_block_id:'terminal',layers:[{layer_id:'layer',kind:'tiled',blocks}]});
    process.exit(0);
  }
  if (state.windowScope && args[0] === 'window' && args[1] === 'ls') {
    emit({session_id:'widget-review',label:'widget-orch',windows:[{window_id:'product-window'},...(state.windowAbsent?[]:[{window_id:'reviewer-window'}])]});
    process.exit(0);
  }
  if (state.windowScope && args[0] === 'window' && args[1] === 'close') {
    if (flag('-s') !== 'widget-review' || args.at(-1) !== 'reviewer-window') process.exit(96);
    const pid=Number(fs.readFileSync(root+'/ready','utf8'));
    try {
      const stat=fs.readFileSync(`/proc/${pid}/stat`,'utf8');
      if (!/^\d+ \(.*\) Z /.test(stat)) { state.nativeLiveAtKill=true; save(); process.exit(94); }
    } catch {}
    if (state.closeFailure) process.exit(1);
    state.windowAbsent=true; save();
    process.exit(0);
  }
  if (state.windowScope && args.includes('kill')) { state.sessionKilled=true; save(); process.exit(95); }
  if (args[0] === 'session' && args[1] === 'inspect') {
    if (state.inspectFailure) process.exit(1);
    state.observations=(state.observations||0)+1;
    save();
    if(state.unrelatedRoundChurn) {
      const file=root+'/workspace/.cel/solo-reviews.json';
      const rounds=JSON.parse(fs.readFileSync(file,'utf8'));
      rounds['widget#99']={verdict:'changes',by:'widget-pr-99-review',head:'9999999999999999999999999999999999999999',at:'2026-01-01T00:01:00Z',note:'Other reviewer update '+state.observations};
      fs.writeFileSync(file,JSON.stringify(rounds));
    }
    const blocks = [{block_id:'terminal',type:'terminal'}];
    if (state.extraBlock) blocks.push({block_id:'user-terminal',type:'terminal'});
    const windows=[{window_id:'window',layers:[{blocks}]}];
    if (state.extraWindow) windows.push({window_id:'user-window',layers:[{blocks:[{block_id:'user-block'}]}]});
    emit({revision:state.revisionChurn?state.observations:1,session_id:'widget-review',label:'widget-pr-71-review',active_window_id:'window',windows,clients:state.revisionChurn?[{client_id:'fixture-'+state.observations}]:[]});
  } else if (args[0] === 'block' && args[1] === 'call' && args[2] === 'process') {
    const pid = state.foreignPid || Number(fs.readFileSync(root + '/ready','utf8'));
    let alive=false;
    try { alive=!/^\d+ \(.*\) Z /.test(fs.readFileSync(`/proc/${pid}/stat`,'utf8')); } catch {}
    if(alive) emit({child:{pid,name:'pi',cwd:state.cwd},foreground:{pid,name:'pi',cwd:state.cwd},ancestors:[],last_exit:null,home:process.env.HOME});
    else {
      const stopped={home:process.env.HOME};
      if(!state.unknownLastExit) stopped.last_exit={exit_code:state.failedLastExit?1:0};
      if(state.stoppedNulls) { stopped.child=null; stopped.foreground=null; }
      if(state.replacementAfterExit) { stopped.child={pid:1,name:'replacement',cwd:state.cwd}; stopped.foreground=stopped.child; }
      emit(stopped);
    }
  } else if (args[0] === 'block' && args[1] === 'call' && args[2] === 'format') {
    emit({content:state.capture,eof:!state.incompleteCapture,total:Buffer.byteLength(state.capture)});
    if (state.changeHead) { state.head='2222222222222222222222222222222222222222'; save(); }
    if (state.changeIdentity) {
      const file=process.env.CEL_REX_STATE + '/widget-pr-71-review.json';
      const receipt=JSON.parse(fs.readFileSync(file)); receipt.pid_start='0';
      fs.writeFileSync(file,JSON.stringify(receipt),{mode:0o600});
    }
    if (state.changeNative) fs.appendFileSync(process.env.RR_NATIVE,JSON.stringify({type:'message',id:'late-user',parentId:'final',timestamp:'2026-01-01T00:03:00Z',message:{role:'user',content:[{type:'text',text:'New review work'}],timestamp:1767225780000}})+'\n');
  } else if (args.includes('kill')) {
    const pid=Number(fs.readFileSync(root+'/ready','utf8'));
    try {
      const stat=fs.readFileSync(`/proc/${pid}/stat`,'utf8');
      if (!/^\d+ \(.*\) Z /.test(stat)) { state.nativeLiveAtKill=true; save(); process.exit(94); }
    } catch {}
    if (state.closeFailure) process.exit(1);
    if (state.rebindRegistry) {
      const file=process.env.CEL_REVIEWERS_STATE;
      const rows=JSON.parse(fs.readFileSync(file));
      for (const row of rows) if (row.repo==='widget' && String(row.pr)==='71') row.pane='rex/replacement/terminal';
      fs.writeFileSync(file,JSON.stringify(rows));
    }
    state.absent=true; save();
  } else if (args[0] === 'ls') {
    if (state.listFailure) process.exit(1);
    emit({sessions:state.absent ? [] : [{session_id:'widget-review',label:'widget-pr-71-review'}]});
  } else process.exit(92);
} else process.exit(93);
NODE
  chmod 700 "$RR_T/bin/boundary"
  # An extensionless executable must be parsed as ESM on all supported Node versions.
  printf '{"type":"module"}\n' > "$RR_T/bin/package.json"
  ln -s boundary "$RR_T/bin/rex"; ln -s boundary "$RR_T/bin/gh"; ln -s boundary "$RR_T/bin/cel"
  export PATH="$RR_T/bin:${RR_NODE%/*}:$PATH" CEL_REX_BIN="$RR_T/bin/rex" GH="$RR_T/bin/gh"
  # The capture is Pi 1.5's idle screen: an empty composer, then the footer -
  # the checkout and its branch, the stats line (tools/reviewers/fixtures).
  jq -n --arg head "$RR_HEAD" --arg cwd "$RR_CO" \
    '{head:$head,cwd:$cwd,prState:"MERGED",mail:0,capture:("Review complete; verdict recorded.\n────────────────────\n\n────────────────────\n"+$cwd+" (review-widget)\n↑12k ↓3.4k R1.2M W40k CH98.5% 23.4%/200k (auto)  (fixture-gate) fixture-model • medium\n")}' > "$RR_T/boundary.json"
  : > "$RR_T/calls.jsonl"
  _rr_native completed
  jq -n --arg head "$RR_HEAD" --arg by "$RR_ALIAS" \
    '{"widget#71":{verdict:"approved",by:$by,head:$head,at:"2026-01-01T00:01:00Z",note:"Fixture review"}}' > "$RR_WS/.cel/solo-reviews.json"
  _rr_start || { printf 'retirement fixture native protocol startup failed\n' >&2; exit 1; }
  reviewers_record "$RR_WS" widget 71 "$RR_PANE" "$RR_ALIAS"
  reviewers_write "$(reviewers_rows | jq --arg c "$RR_CO" --arg r "$RR_WS/repos/widget" 'map(.backend="rex" | .checkout=$c | .repodir=$r)')"
  RR_VERDICT_BEFORE="$(sha256sum "$RR_WS/.cel/solo-reviews.json")"
  RR_NATIVE_BEFORE="$(sha256sum "$RR_NATIVE")"
  # A Rex candidate must never fall through either destructive Herdr sink.
  herdr() { printf 'herdr %s\n' "$*" >> "$RR_T/forbidden"; return 1; }
  reviewer_checkout_release() { printf 'release %s\n' "$*" >> "$RR_T/forbidden"; return 1; }
}

_rr_start() {
  (cd "$RR_CO" && exec env CEL_AGENT_NAME="$RR_ALIAS" CEL_ROLE=reviewer CEL_REX_RECORD="$RR_RECEIPT" CEL_SESSION_BACKEND=rex \
    CEL_WORKSPACE_DIR="$RR_WS" CEL_WORKSPACE="$RR_WS" CEL_REPO=widget CEL_PR=71 \
    CEL_ROLE_FILE="$RR_WS/.cel/reviews/pr-71/role-reviewer.md" CEL_ROOT="$CEL_ROOT" PI_CODING_AGENT_DIR="$PI_CODING_AGENT_DIR" \
    "$RR_NODE" "$RR_T/runtime.mjs") &
  RR_PID=$!
  RR_PID_START="$(_rex_pid_start "$RR_PID")"
  printf '#!/usr/bin/env bash\nexec %q %q "$@"\n' "$RR_NODE" "$RR_T/bin/cel" > "$CEL_ROOT/bin/cel"
  ws_name() { printf bundle; }
  local i
  for ((i=0;i<100;i++)); do [ -s "$RR_T/ready" ] && break; sleep .02; done
  [ -s "$RR_T/ready" ] || return 1
  if [ "${RR_JOB:-0}" = 1 ]; then
    for ((i=0;i<100;i++)); do [ -s "$RR_T/job.pid" ] && break; sleep .02; done
    [ -s "$RR_T/job.pid" ] || return 1
  fi
  jq -n --arg name "$RR_ALIAS" --arg cwd "$RR_CO" --arg workspace "$RR_WS" \
    --arg pane "$RR_PANE" --argjson pid "$RR_PID" --arg start "$RR_PID_START" --arg native "$RR_NATIVE" \
    '{name:$name,agent:"pi",cwd:$cwd,role:"reviewer",workspace:$workspace,repo:"widget",pr:"71",pane_id:$pane,backend:"rex",rex_session:"widget-review",rex_block:"terminal",pid:$pid,pid_start:$start,agent_status:"idle",agent_session:{value:$native}}
     | if env.RR_WINDOW == "1" then .rex_scope="window" | .rex_window="reviewer-window" | .rex_host="widget-orch" else . end' > "$RR_RECEIPT"
  chmod 600 "$RR_RECEIPT"
  : > "$RR_T/receipt-ready"
  for ((i=0;i<200;i++)); do [ -s "$RR_T/producer-started" ] && break; sleep .02; done
  [ -s "$RR_T/producer-started" ] || return 1
  if [ "${RR_UNSUPPORTED_SDK:-0}" != 1 ]; then [ -f "$RR_CAPABILITY" ] || return 1; fi
}

_rr_native() { # actual Pi session entry graph, not copied provider API blobs
  "$RR_NODE" - "$RR_NATIVE" "$RR_CO" "$1" <<'NODE'
const fs=require('node:fs');
const [file,cwd,mode]=process.argv.slice(2);
const rows=[{type:'session',version:3,id:'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',timestamp:'2026-01-01T00:00:00Z',cwd}];
const msg=(id,parentId,role,content,stopReason,timestamp)=>({type:'message',id,parentId,timestamp,message:{role,content,...(stopReason?{stopReason}:{}),timestamp:Date.parse(timestamp),api:'anthropic-messages',provider:'fixture',model:'fixture'}});
rows.push(msg('request',null,'user',[{type:'text',text:'Review widget pull request 71'}],null,'2026-01-01T00:00:01Z'));
rows.push(msg('tool','request','assistant',[{type:'toolCall',id:'review-tool',name:'read',arguments:{path:'widget.txt'}}],'toolUse','2026-01-01T00:00:02Z'));
if(mode!=='pendingtools') rows.push({...msg('result','tool','toolResult',[{type:'text',text:'widget source'}],null,'2026-01-01T00:00:03Z'),message:{role:'toolResult',toolCallId:'review-tool',toolName:'read',content:[{type:'text',text:'widget source'}],isError:false,timestamp:1767225603000}});
if(mode!=='active') rows.push(msg('final',mode==='pendingtools'?'tool':'result','assistant',[{type:'text',text:'Review complete; verdict recorded.'}],'stop','2026-01-01T00:02:00Z'));
if(mode==='lateuser') rows.push(msg('late-user','final','user',[{type:'text',text:'Please review the new patch'}],null,'2026-01-01T00:03:00Z'));
if(mode==='background') rows.push({type:'custom',id:'job',parentId:'final',timestamp:'2026-01-01T00:03:00Z',customType:'background-task',data:{id:'build',status:'running',pid:123}});
fs.writeFileSync(file,rows.map(x=>JSON.stringify(x)).join('\n')+'\n',{mode:0o600});
NODE
}

_rr_set() {
  local value; value="$(jq "$1" "$RR_T/boundary.json")" || return
  printf '%s\n' "$value" > "$RR_T/boundary.json"
}
_rr_receipt_set() {
  local value; value="$(jq "$1" "$RR_RECEIPT")" || return
  printf '%s\n' "$value" > "$RR_RECEIPT"
}
_rr_agents() {
  jq -n --arg p "$RR_PANE" --arg n "$RR_ALIAS" --arg c "$RR_CO" --arg s "${RR_STATUS:-idle}" \
    '{result:{agents:[{pane_id:$p,name:$n,cwd:$c,agent_status:$s,backend:"rex"}]}}'
}
_rr_gc() {
  _gc_reviewers "${1:-0}" "${2:-$(_rr_agents)}" > "$RR_T/gc.out" 2>&1
  cat "$RR_T/gc.out" >&2
}
_rr_preserved() {
  [ -f "$RR_CO/artifacts/result.txt" ] || return 1
  assert_eq "$(cat "$RR_CO/artifacts/result.txt")" 'review evidence' || return
  assert_eq "$(sha256sum "$RR_WS/.cel/solo-reviews.json")" "$RR_VERDICT_BEFORE" || return
  [ ! -e "$RR_T/forbidden" ]
}
_rr_kept() {
  kill -0 "$RR_PID" || return 1
  [ -f "$RR_RECEIPT" ] || return 1
  assert_eq "$(reviewers_find "$RR_WS" widget 71 | jq -r .pane)" "$RR_PANE" || return
  assert_eq "$reviewers_closed" 0 || return
  [ "$(jq -s '[.[] | select(.cmd=="rex" and (.args|index("kill")))] | length' "$RR_T/calls.jsonl")" = 0 ] || return 1
  _rr_preserved
}
_rr_exited() {
  local i
  for ((i=0;i<100;i++)); do
    if ! kill -0 "$RR_PID" 2>/dev/null; then wait "$RR_PID" 2>/dev/null || true; return 0; fi
    sleep .02
  done
  printf 'fixture reviewer survived retirement\n' >&2
  return 1
}
_rr_cleanup() {
  if [ -n "${RR_PID:-}" ] && [ "$(_rex_pid_start "$RR_PID" 2>/dev/null)" = "${RR_PID_START:-missing}" ]; then
    kill "$RR_PID" 2>/dev/null || true
    wait "$RR_PID" 2>/dev/null || true
  fi
  RR_PID=""
  rm -rf "$RR_T"
}

# Only an APPROVED round of the current head ends a reviewer's job: once its
# PR is merged or closed, that reviewer retires with its evidence kept.
test_gc_rex_completed_exact_head_approved_rounds_retire_and_preserve_evidence() {
  local state
  for state in MERGED CLOSED; do
    _rr_fixture
    _rr_set ".prState=\"$state\""
    # one of the two also proves a stop record carrying nulls still retires
    if [ "$state" = CLOSED ]; then _rr_set '.stoppedNulls=true'; fi
    local rounds; rounds="$(jq '."widget#71".verdict="approved"' "$RR_WS/.cel/solo-reviews.json")"
    printf '%s\n' "$rounds" > "$RR_WS/.cel/solo-reviews.json"
    RR_VERDICT_BEFORE="$(sha256sum "$RR_WS/.cel/solo-reviews.json")"
    _rr_gc
    _rr_exited || return
    [ ! -e "$RR_RECEIPT" ] || return 1
    assert_eq "$(reviewers_rows | jq length)" 0 || return
    assert_eq "$reviewers_closed" 1 || return
    assert_eq "$(sha256sum "$RR_NATIVE")" "$RR_NATIVE_BEFORE" || return
    _rr_preserved || return
    jq -se 'map(.type) as $events | ($events|index("inbox-stopped"))!=null and ($events|index("sdk-shutdown"))!=null and ($events|index("inbox-stopped"))<($events|index("sdk-shutdown"))' "$RR_T/producer-events.jsonl" >/dev/null || return
    assert_eq "$(jq -r '.nativeLiveAtKill // false' "$RR_T/boundary.json")" false || return
    # Mailbox queries must bind the exact alias and receipt's workspace.
    jq -se --arg a "$RR_ALIAS" 'any(.[]; .cmd=="cel" and (.args|index($a))!=null and (.args|index("--all-workspaces"))!=null and (.args|index("bundle"))!=null)' "$RR_T/calls.jsonl" >/dev/null || return
    # A GitHub repo's PR is read from GitHub, by the declared url's slug.
    jq -se 'any(.[]; .cmd=="gh" and (.args|index("acme/widget"))!=null) and all(.[]; .cmd!="cel" or .args[0]!="forge")' "$RR_T/calls.jsonl" >/dev/null || return
    jq -se '
      [to_entries[] | select(.value.cmd=="rex" and (.value.args|index("kill"))!=null)] as $close |
      ($close|length)==1 and
      ($close[0].value.args|index("--autostart=false"))!=null and
      ($close[0].value.args|index("widget-review"))!=null and
      any(to_entries[]; .key>$close[0].key and .value.cmd=="rex" and (.value.args|index("ls"))!=null)
    ' "$RR_T/calls.jsonl" >/dev/null || return
    _rr_cleanup
  done
}

# A reviewer opened as a WINDOW in its product agent's session retires by
# closing that window only: the same native handshake and evidence, every
# Rex call scoped to its window, and the session - the product agent's - is
# never killed. Its completion proof says a window went, not the session.
test_gc_rex_window_scoped_reviewer_retires_only_its_window() {
  export RR_WINDOW=1
  _rr_fixture
  _rr_set '.windowScope=true'
  _rr_gc
  _rr_exited || return
  [ ! -e "$RR_RECEIPT" ] || return 1
  assert_eq "$(reviewers_rows | jq length)" 0 || return
  _rr_preserved || return
  assert_eq "$(jq -r '.sessionKilled // false' "$RR_T/boundary.json")" false || return
  assert_eq "$(jq -r '.windowAbsent // false' "$RR_T/boundary.json")" true || return
  assert_eq "$(jq -r '.nativeLiveAtKill // false' "$RR_T/boundary.json")" false || return
  # calls.jsonl logs argv as given, --autostart=false first
  jq -se '
    def a: .args - ["--autostart=false"];
    [to_entries[] | select(.value.cmd=="rex" and (.value|a)[0:2]==["window","close"])] as $close |
    ($close|length)==1 and ($close[0].value|a)==["window","close","-s","widget-review","reviewer-window"] and
    ([.[] | select(.cmd=="rex" and (a|index("kill"))!=null)] | length)==0 and
    ([.[] | select(.cmd=="rex" and (a)[0]=="session")] | length)==0 and
    ([.[] | select(.cmd=="rex" and (a)[0]=="block")] | all(a | index("-w") != null)) and
    any(to_entries[]; .key>$close[0].key and .value.cmd=="rex" and (.value|a)[0:2]==["window","ls"])
  ' "$RR_T/calls.jsonl" >/dev/null || return
  jq -e '.container=="window" and .containerAbsent==true and .sessionAbsent==false' \
    "$CEL_REX_STATE"/retirements/*.retired.json >/dev/null || return
  unset RR_WINDOW
  _rr_cleanup
}

# A terminal the owner added to the reviewer's window makes it not only the
# reviewer's: protected, nothing closed. A receipt claiming a window without
# naming it is no identity at all.
test_gc_rex_window_scoped_reviewer_with_an_added_terminal_is_protected() {
  export RR_WINDOW=1
  _rr_fixture
  _rr_set '.windowScope=true | .extraBlock=true'
  _rr_gc
  _rr_kept || return
  assert_eq "$(jq -s '[.[] | select(.cmd=="rex" and (.args - ["--autostart=false"])[0:2]==["window","close"])] | length' "$RR_T/calls.jsonl")" 0 || return
  # it was the window proof that refused, not an unreachable fixture
  assert_eq "$(jq -s '[.[] | select(.cmd=="rex" and (.args - ["--autostart=false"])[0:2]==["window","inspect"])] | length > 0' "$RR_T/calls.jsonl")" true || return
  _rr_cleanup
  _rr_fixture
  _rr_set '.windowScope=true'
  _rr_receipt_set 'del(.rex_window)'
  _rr_gc
  kill -0 "$RR_PID" && [ -f "$RR_RECEIPT" ] || return 1
  assert_eq "$(jq -s '[.[] | select(.cmd=="rex" and ((.args - ["--autostart=false"])[0]=="window" or (.args|index("kill"))!=null))] | length' "$RR_T/calls.jsonl")" 0 || return
  unset RR_WINDOW
  _rr_cleanup
}

# A reviewer whose round asked for CHANGES stays for the re-review, even once
# the PR is merged or closed: gc touches no terminal, registry or receipt.
test_gc_rex_completed_exact_head_changes_round_keeps_the_reviewer() {
  local state
  for state in MERGED CLOSED; do
    _rr_fixture
    _rr_set ".prState=\"$state\""
    local rounds; rounds="$(jq '."widget#71".verdict="changes"' "$RR_WS/.cel/solo-reviews.json")"
    printf '%s\n' "$rounds" > "$RR_WS/.cel/solo-reviews.json"
    RR_VERDICT_BEFORE="$(sha256sum "$RR_WS/.cel/solo-reviews.json")"
    _rr_gc; _rr_kept || return
    _rr_cleanup
  done
}

# An open PR can still take a push or a re-review request, so even a reviewer
# with a completed, exact-head round on it keeps running - approved or changes.
# It is refused before any terminal, native handshake or inbox is touched.
test_gc_rex_open_pr_keeps_a_completed_reviewer_untouched() {
  local verdict
  for verdict in approved changes; do
    _rr_fixture
    _rr_set '.prState="OPEN"'
    local rounds; rounds="$(jq --arg v "$verdict" '."widget#71".verdict=$v' "$RR_WS/.cel/solo-reviews.json")"
    printf '%s\n' "$rounds" > "$RR_WS/.cel/solo-reviews.json"
    RR_VERDICT_BEFORE="$(sha256sum "$RR_WS/.cel/solo-reviews.json")"
    _rr_gc; _rr_kept || return
    ! grep -q 'retirement incomplete' "$RR_T/gc.out" || return 1
    assert_eq "$(jq -s '[.[] | select(.cmd=="rex" or .cmd=="cel")] | length' "$RR_T/calls.jsonl")" 0 || return
    [ ! -e "$RR_PROTOCOL_DIRECTORY/request.json" ] || return 1
    [ ! -e "$RR_T/producer-events.jsonl" ] || return 1
    _rr_cleanup
  done
}

# `cel sessions retire-reviewer` and `cel solo land` share one targeted path.
test_targeted_rex_reviewer_retirement_dry_run_then_retires() {
  _rr_fixture
  cel_agent_list() { _rr_agents; }
  local out rc=0 reviewers_closed=0
  out="$(reviewer_retire_target "$RR_WS" widget 71 1)" || rc=$?
  assert_eq "$rc" 0 || return
  assert_eq "$(printf '%s' "$out" | jq -r .status)" eligible || return
  _rr_kept || return
  rc=0; out="$(reviewer_retire_target "$RR_WS" widget 71 0)" || rc=$?
  assert_eq "$rc" 0 || return
  assert_eq "$(printf '%s' "$out" | jq -r '[.status, .pane] | join(" ")')" "retired $RR_PANE" || return
  _rr_exited || return
  [ ! -e "$RR_RECEIPT" ] || return 1
  assert_eq "$(reviewers_rows | jq length)" 0 || return
  assert_eq "$(sha256sum "$RR_NATIVE")" "$RR_NATIVE_BEFORE" || return
  _rr_preserved
}

test_targeted_rex_reviewer_retirement_refuses_open_absent_and_herdr_targets() {
  _rr_fixture
  cel_agent_list() { _rr_agents; }
  local out rc=0
  _rr_set '.prState="OPEN"'
  out="$(reviewer_retire_target "$RR_WS" widget 71 0)" || rc=$?
  assert_eq "$rc" 3 || return
  assert_eq "$(printf '%s' "$out" | jq -r '[.status, .reason] | join(" ")')" 'protected pull_request_open' || return
  rc=0; out="$(reviewer_retire_target "$RR_WS" widget 72 0)" || rc=$?
  assert_eq "$rc" 4 || return
  reviewers_write "$(reviewers_rows | jq 'map(.pane="window:pane" | .backend="herdr")')"
  cel_agent_list() { printf '%s' '{"result":{"agents":[{"pane_id":"window:pane","name":"widget-pr-71-review","agent_status":"idle","cwd":"/fixture","backend":"herdr"}]}}'; }
  rc=0; out="$(reviewer_retire_target "$RR_WS" widget 71 0)" || rc=$?
  assert_eq "$rc" 4 || return
  assert_eq "$(printf '%s' "$out" | jq -r .reason)" herdr_reviewer_keeps_gc_path || return
  cel_agent_list() { return 1; }
  rc=0; out="$(reviewer_retire_target "$RR_WS" widget 71 0)" || rc=$?
  assert_eq "$rc" 2 || return
  kill -0 "$RR_PID" && [ -f "$RR_RECEIPT" ] || return 1
  assert_eq "$(jq -s '[.[]|select(.cmd=="rex" and (.args|index("kill"))!=null)]|length' "$RR_T/calls.jsonl")" 0 || return
  _rr_preserved
}

# After its merge, `cel solo land` retires the PR's reviewer through the same
# proof; a reviewer that must be kept is reported, and the land still succeeds.
test_solo_land_retirement_uses_the_shared_proof_and_never_fails_the_land() {
  _rr_fixture
  cel_agent_list() { _rr_agents; }
  local out rc=0 reviewers_closed=0
  _rr_set '.mail=1'
  out="$(_solo_land_retire_reviewer "$RR_WS" widget 71 2>&1)" || rc=$?
  assert_eq "$rc" 0 || return
  assert_contains "$out" 'kept the reviewer for widget#71: pending_reviewer_mail' || return
  _rr_kept || return
  _rr_set '.mail=0'
  rc=0; out="$(_solo_land_retire_reviewer "$RR_WS" widget 71 2>&1)" || rc=$?
  assert_eq "$rc" 0 || return
  assert_contains "$out" "retired the Rex reviewer for widget#71 (pane $RR_PANE)" || return
  _rr_exited || return
  [ ! -e "$RR_RECEIPT" ] || return 1
  assert_eq "$(reviewers_rows | jq length)" 0 || return
  assert_eq "$(sha256sum "$RR_NATIVE")" "$RR_NATIVE_BEFORE" || return
  _rr_preserved
}

# A REFUSAL THAT DOES NOT CLEAR IS SAID, ONCE. Every tick retries a reviewer
# whose retirement came back unknown and counts the attempt; at the Nth
# attempt its product agent hears about it - once - naming the reviewer and
# the reason. A retirement that then goes through clears the count.
_rr_unknown_footer() { _rr_set '.capture="Review complete.\n────────────────────\n\n────────────────────\n/elsewhere (main)\n1.0%/200k (auto)  fixture-model\n"'; }
_rr_key() { printf '%s' "$RR_PANE $RR_ALIAS widget#71"; }
_rr_attempts() { jq -r --arg k "$(_rr_key)" '.[$k].attempts // 0' "$CEL_GC_RETIRE_STATE" 2>/dev/null || printf 0; }
test_gc_rex_unknown_retirement_is_counted_and_reported_once_to_its_product() {
  _rr_fixture
  export CEL_GC_RETIRE_ALERT_ATTEMPTS=3
  cmd_inbox() { printf '%s\n' "$*" >> "$RR_T/mail"; }
  _rr_unknown_footer
  local tick
  for tick in 1 2; do
    _rr_gc; _rr_kept || return
    assert_contains "$(cat "$RR_T/gc.out")" 'retirement incomplete for widget#71: unknown_pi_footer' || return
    assert_eq "$(_rr_attempts)" "$tick" || return
    [ ! -s "$RR_T/mail" ] || return 1
  done
  _rr_gc; _rr_kept || return
  assert_eq "$(_rr_attempts)" 3 || return
  assert_eq "$(grep -c . "$RR_T/mail")" 1 || return
  local mail; mail="$(cat "$RR_T/mail")"
  assert_contains "$mail" "send widget-orch " || return
  assert_contains "$mail" "$RR_ALIAS" || return
  assert_contains "$mail" 'widget#71' || return
  assert_contains "$mail" 'unknown_pi_footer' || return
  assert_contains "$mail" '--workspace bundle' || return
  assert_contains "$mail" "--fp gc-reviewer-retire-$RR_ALIAS" || return
  _rr_gc; _rr_kept || return
  assert_eq "$(_rr_attempts)" 4 || return
  assert_eq "$(grep -c . "$RR_T/mail")" 1 || return
  # the cause fixed, the next tick retires it and the count goes with it
  jq --arg c "$RR_CO" '.capture=("Review complete.\n────────────────────\n\n────────────────────\n"+$c+" (review-widget)\n23.4%/200k (auto)  fixture-model\n")' "$RR_T/boundary.json" > "$RR_T/boundary.next" && mv "$RR_T/boundary.next" "$RR_T/boundary.json"
  _rr_gc
  _rr_exited || return
  assert_eq "$(jq -r --arg k "$(_rr_key)" 'has($k)' "$CEL_GC_RETIRE_STATE")" false || return
  unset CEL_GC_RETIRE_ALERT_ATTEMPTS
  _rr_cleanup
}

# A day after the first failed attempt is enough, however few ticks ran; a
# report that did not go out was not made, and the next tick sends it.
test_gc_rex_unknown_retirement_is_reported_after_a_day_and_a_failed_send_retries() {
  _rr_fixture
  _rr_unknown_footer
  jq -n --arg k "$(_rr_key)" --arg p "$RR_PANE" --arg a "$RR_ALIAS" --argjson t "$(( $(date +%s) - 90000 ))" \
    '{($k):{pane:$p, agent:$a, repo:"widget", pr:"71", since:$t, attempts:1, reason:"unknown_pi_footer", reported:false}}' > "$CEL_GC_RETIRE_STATE"
  cmd_inbox() { printf '%s\n' "$*" >> "$RR_T/mail"; return 1; }
  _rr_gc; _rr_kept || return
  assert_eq "$(grep -c . "$RR_T/mail")" 1 || return
  assert_eq "$(jq -r --arg k "$(_rr_key)" '.[$k].reported' "$CEL_GC_RETIRE_STATE")" false || return
  cmd_inbox() { printf '%s\n' "$*" >> "$RR_T/mail"; }
  _rr_gc; _rr_kept || return
  assert_eq "$(grep -c . "$RR_T/mail")" 2 || return
  assert_eq "$(jq -r --arg k "$(_rr_key)" '.[$k].reported' "$CEL_GC_RETIRE_STATE")" true || return
  _rr_gc; _rr_kept || return
  assert_eq "$(grep -c . "$RR_T/mail")" 2 || return
  _rr_cleanup
}

# A protected reviewer is waiting on something real (mail owed, a turn under
# way) that gc retires it after: that is no failed attempt, and it ends a run
# of them. A dry run counts nothing.
test_gc_rex_protected_or_dry_retirement_is_not_a_failed_attempt() {
  _rr_fixture
  cmd_inbox() { printf '%s\n' "$*" >> "$RR_T/mail"; }
  local footer; footer="$(jq -c .capture "$RR_T/boundary.json")"
  _rr_unknown_footer
  _rr_gc 1; _rr_kept || return
  assert_eq "$(_rr_attempts)" 0 || return
  _rr_gc; assert_eq "$(_rr_attempts)" 1 || return
  # its own footer back, but mail owed: protected
  _rr_set ".capture=$footer | .mail=1"
  _rr_gc; _rr_kept || return
  assert_eq "$(_rr_attempts)" 0 || return
  [ ! -s "$RR_T/mail" ] || return 1
  _rr_cleanup
}

# `cel solo land`'s own attempt is the first of the count gc carries on, and
# its warning says what gc will do - retry every tick, and tell the product.
test_solo_land_unknown_retirement_starts_the_count_gc_continues() {
  _rr_fixture
  cel_agent_list() { _rr_agents; }
  cmd_inbox() { printf '%s\n' "$*" >> "$RR_T/mail"; }
  _rr_unknown_footer
  local out rc=0
  out="$(_solo_land_retire_reviewer "$RR_WS" widget 71 2>&1)" || rc=$?
  assert_eq "$rc" 0 || return
  assert_contains "$out" 'reviewer retirement for widget#71 is incomplete: unknown_pi_footer - `cel gc` retries it every tick and tells widget-orch if it keeps failing' || return
  assert_eq "$(_rr_attempts)" 1 || return
  _rr_gc; _rr_kept || return
  assert_eq "$(_rr_attempts)" 2 || return
  _rr_cleanup
}

# An unknown answer before the retirement ran - here the roster cannot be
# read, so neither pane nor alias is known - is counted by the same note, so
# land's "tells widget-orch if it keeps failing" holds; the retirement that
# later goes through ends that count too.
test_solo_land_early_unknown_retirement_is_counted_and_reported() {
  _rr_fixture
  export CEL_GC_RETIRE_ALERT_ATTEMPTS=2
  cmd_inbox() { printf '%s\n' "$*" >> "$RR_T/mail"; }
  cel_agent_list() { return 1; }
  local out rc=0 k="- - widget#71"
  out="$(_solo_land_retire_reviewer "$RR_WS" widget 71 2>&1)" || rc=$?
  assert_eq "$rc" 0 || return
  assert_contains "$out" 'native_inventory_unreadable - `cel gc` retries it every tick and tells widget-orch if it keeps failing' || return
  assert_eq "$(jq -r --arg k "$k" '.[$k].attempts' "$CEL_GC_RETIRE_STATE")" 1 || return
  [ ! -s "$RR_T/mail" ] || return 1
  _solo_land_retire_reviewer "$RR_WS" widget 71 >/dev/null 2>&1
  assert_eq "$(jq -r --arg k "$k" '.[$k].attempts' "$CEL_GC_RETIRE_STATE")" 2 || return
  assert_eq "$(grep -c . "$RR_T/mail")" 1 || return
  assert_contains "$(cat "$RR_T/mail")" 'send widget-orch ' || return
  assert_contains "$(cat "$RR_T/mail")" 'native_inventory_unreadable' || return
  cel_agent_list() { _rr_agents; }
  out="$(_solo_land_retire_reviewer "$RR_WS" widget 71 2>&1)" || return
  assert_contains "$out" "retired the Rex reviewer for widget#71" || return
  assert_eq "$(jq -c . "$CEL_GC_RETIRE_STATE")" '{}' || return
  unset CEL_GC_RETIRE_ALERT_ATTEMPTS
  _rr_cleanup
}

# A count belongs to one reviewer: pane, alias and PR. A reviewer that went
# some other way (on neither registry nor roster) loses its entry at the next
# gc pass, and a pane id that now carries another reviewer does not inherit
# the old one's count or its `reported`.
test_gc_retire_counts_are_pruned_and_reset_with_the_reviewer() {
  _rr_fixture
  cmd_inbox() { printf '%s\n' "$*" >> "$RR_T/mail"; }
  jq -n --arg p "$RR_PANE" '{
      "rex/gone/terminal widget-pr-9-review widget#9": {pane:"rex/gone/terminal", agent:"widget-pr-9-review", repo:"widget", pr:"9", since:1, attempts:9, reason:"x", reported:true},
      "- - widget#9": {pane:"-", agent:"", repo:"widget", pr:"9", since:1, attempts:2, reason:"x", reported:false},
      ($p + " widget-pr-70-review widget#70"): {pane:$p, agent:"widget-pr-70-review", repo:"widget", pr:"70", since:1, attempts:9, reason:"x", reported:true},
      ($p + " widget#71"): {agent:"widget-pr-71-review", since:1, attempts:9, reason:"x", reported:true}
    }' > "$CEL_GC_RETIRE_STATE"
  _rr_unknown_footer
  _rr_gc; _rr_kept || return
  assert_eq "$(jq -c 'keys' "$CEL_GC_RETIRE_STATE")" "$(jq -nc --arg k "$(_rr_key)" '[$k]')" || return
  assert_eq "$(_rr_attempts)" 1 || return
  assert_eq "$(jq -r --arg k "$(_rr_key)" '.[$k].reported' "$CEL_GC_RETIRE_STATE")" false || return
  [ ! -s "$RR_T/mail" ] || return 1
  # The same pane id, relaunched as another reviewer: a fresh count.
  _gc_retire_note "$RR_WS" widget 71 "$RR_PANE" widget-pr-71-qa unknown unknown_pi_footer
  assert_eq "$(jq -c 'keys' "$CEL_GC_RETIRE_STATE")" "$(jq -nc --arg k "$RR_PANE widget-pr-71-qa widget#71" '[$k]')" || return
  assert_eq "$(jq -r --arg k "$RR_PANE widget-pr-71-qa widget#71" '.[$k].attempts' "$CEL_GC_RETIRE_STATE")" 1 || return
  _rr_cleanup
}

# An empty roster is no proof that a reviewer is gone (Rex restarting, a
# roster read mid-relaunch): the pass keeps every count, so a 24h clock is
# not reset. A roster that does list agents prunes as before.
test_gc_retire_prune_skips_an_empty_roster() {
  _rr_fixture
  local reviewers_closed=0
  reviewers_write '[]'
  jq -n '{"rex/gone/terminal widget-pr-9-review widget#9": {pane:"rex/gone/terminal", agent:"widget-pr-9-review", repo:"widget", pr:"9", since:1, attempts:3, reason:"x", reported:false}}' > "$CEL_GC_RETIRE_STATE"
  _gc_reviewers 0 '{"result":{"agents":[]}}' >/dev/null 2>&1
  assert_eq "$(jq 'keys | length' "$CEL_GC_RETIRE_STATE")" 1 || return
  _gc_reviewers 0 '{"result":{"agents":[{"pane_id":"w:1","name":"widget-orch","agent_status":"idle","cwd":"/nowhere"}]}}' >/dev/null 2>&1
  assert_eq "$(jq 'keys | length' "$CEL_GC_RETIRE_STATE")" 0 || return
  _rr_cleanup
}

# gc and land update the same file; concurrent notes lose nothing: every
# reviewer's entry is there, and one reviewer noted N times counts N.
test_gc_retire_notes_from_concurrent_runs_lose_no_update() {
  _rr_fixture
  cmd_inbox() { :; }
  printf '{}\n' > "$CEL_GC_RETIRE_STATE"
  local i pids=()
  for i in $(seq 1 16); do
    _gc_retire_note "" widget "$i" "rex/r$i/terminal" "widget-pr-$i-review" unknown fixture & pids+=($!)
    _gc_retire_note "" widget 99 rex/r99/terminal widget-pr-99-review unknown fixture & pids+=($!)
  done
  wait "${pids[@]}"
  assert_eq "$(jq 'keys | length' "$CEL_GC_RETIRE_STATE")" 17 || return
  assert_eq "$(jq -r '.["rex/r99/terminal widget-pr-99-review widget#99"].attempts' "$CEL_GC_RETIRE_STATE")" 16 || return
  # No temp left beside it.
  assert_eq "$(find "$(dirname "$CEL_GC_RETIRE_STATE")" -maxdepth 1 -name '.retire.json.*' | wc -l)" 0 || return
  _rr_cleanup
}

test_gc_rex_active_pending_tools_and_later_user_work_keep_registry() {
  local mode
  for mode in active pendingtools lateuser background; do
    _rr_fixture; _rr_native "$mode"
    _rr_gc; _rr_kept || return
    _rr_cleanup
  done
}

test_gc_rex_pending_mail_and_boundary_unknowns_keep_registry() {
  local condition
  for condition in '.mail=1' '.mailFailure=true' '.ghFailure=true' '.ghMalformed=true' '.inspectFailure=true' '.incompleteCapture=true'; do
    _rr_fixture; _rr_set "$condition"
    _rr_gc; _rr_kept || return
    _rr_cleanup
  done
}

test_gc_rex_changed_head_identity_native_and_user_terminal_are_protected() {
  local condition
  for condition in '.head="2222222222222222222222222222222222222222"' '.foreignPid=1' '.extraBlock=true' '.extraWindow=true' '.capture="Unsent user draft"' '.changeHead=true' '.changeIdentity=true' '.changeNative=true'; do
    _rr_fixture; _rr_set "$condition"
    _rr_gc; _rr_kept || return
    _rr_cleanup
  done
}

test_gc_rex_malformed_native_missing_round_and_pid_reuse_keep_registry() {
  local condition
  for condition in malformed nativeabsent missinground wrongreviewer reusedpid working unsupported unsafemode symlink; do
    _rr_fixture
    case "$condition" in
      malformed) printf '{"type":' >> "$RR_NATIVE" ;;
      nativeabsent) rm "$RR_NATIVE" ;;
      missinground) printf '{}\n' > "$RR_WS/.cel/solo-reviews.json"; RR_VERDICT_BEFORE="$(sha256sum "$RR_WS/.cel/solo-reviews.json")" ;;
      wrongreviewer)
        local rounds; rounds="$(jq '."widget#71".by="widget-other-review"' "$RR_WS/.cel/solo-reviews.json")"
        printf '%s\n' "$rounds" > "$RR_WS/.cel/solo-reviews.json"
        RR_VERDICT_BEFORE="$(sha256sum "$RR_WS/.cel/solo-reviews.json")" ;;
      reusedpid) _rr_receipt_set '.pid_start="0"' ;;
      working) _rr_receipt_set '.agent_status="working"'; RR_STATUS=working ;;
      unsupported) _rr_receipt_set '.agent="unknown-runtime"' ;;
      unsafemode) chmod 666 "$RR_RECEIPT" ;;
      symlink) mv "$RR_RECEIPT" "$RR_T/retained-receipt.json"; ln -s "$RR_T/retained-receipt.json" "$RR_RECEIPT" ;;
    esac
    _rr_gc; _rr_kept || return
    _rr_cleanup
  done
}

test_gc_rex_real_descendant_job_vetoes_close() {
  export RR_JOB=1
  _rr_fixture
  _rr_gc; _rr_kept
}

test_gc_rex_unsettled_durable_background_tasks_keep_registry() {
  local status
  for status in running completed failed killed; do
    _rr_fixture
    local tasks="$RR_CO/.pi/tasks/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee-$RR_PID"
    mkdir -p "$tasks"
    jq -n --arg status "$status" --arg cwd "$RR_CO" --arg output "$tasks/job.output" \
      '{id:"job",command:"true",status:$status,outputPath:$output,cwd:$cwd,startTime:1767225600000,endTime:1767225670000,notified:false,notifyOnCompletion:true,triggerOnCompletion:false}' > "$tasks/job.json"
    _rr_gc; _rr_kept || return
    _rr_cleanup
  done
}

test_gc_rex_failed_close_and_surviving_process_never_drop_registry() {
  local condition
  for condition in '.closeFailure=true' '.processSurvives=true' '.listFailure=true'; do
    _rr_fixture; _rr_set "$condition"
    _rr_gc
    [ -f "$RR_RECEIPT" ] || return 1
    assert_eq "$(reviewers_find "$RR_WS" widget 71 | jq -r .pane)" "$RR_PANE" || return
    assert_eq "$reviewers_closed" 0 || return
    _rr_preserved || return
    if [ "$condition" = '.processSurvives=true' ]; then
      kill -0 "$RR_PID" || return 1
      assert_eq "$(jq -s '[.[]|select(.cmd=="rex" and (.args|index("kill"))!=null)]|length' "$RR_T/calls.jsonl")" 0 || return
    else
      _rr_exited || return
    fi
    _rr_cleanup
  done
}

test_gc_rex_dry_run_keeps_runtime_receipt_registry_and_checkout() {
  _rr_fixture
  _rr_gc 1
  _rr_kept
}

# A repo on Forgejo (declared forge: forgejo) has its reviewer retired by the
# same proofs, its PR read from its own forge (`cel forge pr view`, as the
# workspace) - never from GitHub, where a mirror numbers other PRs the same.
test_gc_rex_forgejo_repo_reviewer_retires_from_its_forge() {
  local state
  export RR_FORGE=forgejo
  for state in MERGED CLOSED; do
    _rr_fixture
    _rr_set ".prState=\"$state\""
    _rr_gc
    _rr_exited || return
    [ ! -e "$RR_RECEIPT" ] || return 1
    assert_eq "$(reviewers_rows | jq length)" 0 || return
    assert_eq "$reviewers_closed" 1 || return
    assert_eq "$(sha256sum "$RR_NATIVE")" "$RR_NATIVE_BEFORE" || return
    _rr_preserved || return
    assert_eq "$(jq -s '[.[] | select(.cmd=="gh")] | length' "$RR_T/calls.jsonl")" 0 || return
    jq -se 'any(.[]; .cmd=="cel" and .args==["forge","pr","view","widget#71","--json","--workspace","bundle"])' "$RR_T/calls.jsonl" >/dev/null || return
    # the proof packet keeps the forge's answer in the round's own words
    jq -se --arg h "$RR_HEAD" --arg s "$state" 'any(.[]; .stage=="prepared" and .remote==({state:$s,headRefOid:$h,headRefName:"review-widget"}))' \
      "$CEL_REX_STATE"/retirements/*.json >/dev/null || return
    _rr_cleanup
  done
  unset RR_FORGE
}

# Fail-closed as on GitHub: an open PR, an unreadable forge, or an answer for
# another repository or PR keeps the reviewer, before any inbox is asked.
test_gc_rex_forgejo_open_or_unproven_pr_keeps_the_reviewer() {
  local condition reason
  export RR_FORGE=forgejo
  for condition in '.prState="OPEN"|' '.forgeFailure=true|forge_unavailable' \
    '.forgeUrl="http://forgejo.example/other/widget/pulls/71"|unknown_remote_pr' '.forgeNumber=72|unknown_remote_pr'; do
    reason="${condition#*|}"
    _rr_fixture; _rr_set "${condition%%|*}"
    _rr_gc; _rr_kept || return
    if [ -n "$reason" ]; then assert_contains "$(cat "$RR_T/gc.out")" "retirement incomplete for widget#71: $reason" || return
    else ! grep -q 'retirement incomplete' "$RR_T/gc.out" || return 1; fi
    assert_eq "$(jq -s '[.[] | select(.cmd=="gh" or (.cmd=="cel" and .args[0]!="forge"))] | length' "$RR_T/calls.jsonl")" 0 || return
    _rr_cleanup
  done
  unset RR_FORGE
}

# A repo whose forge cannot be resolved has no slug, and a slug or forge that
# is not exactly owner/name on github or forgejo is refused before anything
# is asked of a forge, Rex or the inbox.
test_gc_rex_unresolved_or_malformed_forge_slug_is_refused() {
  _rr_fixture
  printf 'name: bundle\nrepos:\n  - name: widget\n    url: git@forgejo-alias:acme/widget.git\n    forge: forgejo\n' > "$RR_WS/workspace.yaml"
  _rr_gc; _rr_kept || return
  assert_contains "$(cat "$RR_T/gc.out")" "retirement incomplete for widget#71: invalid_workspace_arguments" || return
  local args out rc
  for args in 'acme/widget/x|forgejo' 'forgejo.example/acme/widget|forgejo' '|forgejo' 'acme widget|forgejo' 'acme/widget|' 'acme/widget|gitlab'; do
    rc=0; out="$("$RR_NODE" "$CEL_ROOT/tools/reviewers/retire.mjs" widget 71 "$RR_PANE" "$RR_ALIAS" 1 "$RR_RECEIPT" bundle "${args%%|*}" '' '' "$RR_WS/repos/widget" "$GH" "$PATH" "${args#*|}")" || rc=$?
    assert_eq "$rc $(printf '%s' "$out" | jq -r '[.status, .reason] | join(" ")')" "2 unknown invalid_workspace_arguments" || { echo "$args: $out"; return 1; }
  done
  assert_eq "$(jq -s '[.[] | select(.cmd=="gh" or .cmd=="cel" or .cmd=="rex")] | length' "$RR_T/calls.jsonl")" 0 || return
  _rr_preserved
}

# A pane off the roster whose PID generation exited, with no retirement proof
# of ours, is a stale row: only the row goes. Receipt, checkout, verdict and
# native log stay, and nothing is closed.
test_gc_gone_rex_row_is_dropped_but_its_evidence_is_kept() {
  _rr_fixture
  kill "$RR_PID"; wait "$RR_PID" 2>/dev/null || true
  _rr_gc 1 '{"result":{"agents":[]}}'
  assert_eq "$(reviewers_find "$RR_WS" widget 71 | jq -r .pane)" "$RR_PANE" || return
  _rr_gc 0 '{"result":{"agents":[]}}'
  assert_eq "$(reviewers_rows | jq length)" 0 || return
  [ -f "$RR_RECEIPT" ] || return 1
  assert_eq "$(sha256sum "$RR_NATIVE")" "$RR_NATIVE_BEFORE" || return
  assert_eq "$(jq -s '[.[] | select(.cmd=="rex" or .cmd=="gh")] | length' "$RR_T/calls.jsonl")" 0 || return
  _rr_preserved
}

# Absent from one roster read is not gone: a live generation keeps its row.
test_gc_rex_row_with_a_live_generation_is_kept_when_its_pane_is_unlisted() {
  _rr_fixture
  _rr_set '.prState="OPEN"'
  _rr_gc 0 '{"result":{"agents":[]}}'
  assert_eq "$(reviewers_find "$RR_WS" widget 71 | jq -r .pane)" "$RR_PANE" || return
  kill -0 "$RR_PID" && [ -f "$RR_RECEIPT" ] || return 1
  _rr_preserved
}

test_gc_rex_retirement_does_not_drop_a_concurrently_rebound_registry_row() {
  _rr_fixture
  _rr_set '.rebindRegistry=true'
  _rr_gc
  _rr_exited || return
  assert_eq "$(reviewers_find "$RR_WS" widget 71 | jq -r .pane)" rex/replacement/terminal || return
  _rr_preserved
}

# THE RACE BEHIND THAT TEST'S CI FLAKE. The native side publishes each
# response by rename, over the previous one (the exit answer replaces the
# inspect answer). A poll that opens the old file and re-checks the name after
# the rename must read again, not refuse the whole retirement with
# evidence_changed_during_read. A separate process replaces stale responses
# back to back while the handshake polls, then publishes the real answer.
test_rex_retirement_handshake_reads_through_a_response_replaced_mid_read() {
  local T; T="$(mktemp -d)"; chmod 700 "$T"
  local rc=0 out
  # A script file, not stdin: retire.mjs runs as a CLI when argv[1] is "-".
  cat > "$T/handshake.mjs" <<'NODE'
import fs from 'node:fs'; import path from 'node:path'; import {spawn} from 'node:child_process'; import {pathToFileURL} from 'node:url';
const [root, dir, node] = process.argv.slice(2);
const {nativeHandshake} = await import(pathToFileURL(path.join(root, 'tools/reviewers/retire.mjs')));
const receipt = path.join(dir, 'reviewer.json'), protocol = `${receipt}.retirement`;
fs.mkdirSync(protocol, {mode: 0o700});
const identity = {name: 'widget-pr-71-review', pid: 4242, pid_start: '7', agent_session: {value: '/native.jsonl'}};
const churner = spawn(node, ['--input-type=module', '-e', `
import fs from 'node:fs';
const [protocol, identity] = [process.argv[1], JSON.parse(process.argv[2])];
const response = protocol + '/response.json';
let n = 0;
const publish = value => { const t = response + '.' + (n++) + '.tmp'; fs.writeFileSync(t, JSON.stringify(value) + '\\n', {mode: 0o600}); fs.renameSync(t, response); };
const stale = {version: 1, type: 'cel-reviewer-retirement-response', phase: 'inspect', nonce: 'stale', pad: 'x'.repeat(60000)};
const until = Date.now() + 2500;
while (Date.now() < until) publish(stale);
const request = JSON.parse(fs.readFileSync(protocol + '/request.json', 'utf8'));
publish({version: 1, type: 'cel-reviewer-retirement-response', phase: request.phase, nonce: request.nonce,
  name: identity.name, pid: identity.pid, pid_start: identity.pid_start, native_session: identity.agent_session.value,
  observed_at: Date.now(), status: 'ready', reason: '', live_leaf: 'leaf', is_idle: true, sdk_pending: false,
  native_turn_active: false, inbox_owed: false, inbox_pending: false, inbox_waking: false, composer_empty: true, exit_committed: false});
`, protocol, JSON.stringify(identity)], {stdio: 'inherit'});
const exited = new Promise(resolve => churner.on('exit', resolve));
try {
  const {response} = await nativeHandshake(receipt, identity, 'inspect', 'the-nonce');
  console.log(`answered ${response.nonce}`);
} catch (error) { console.log(`refused ${error.message}`); }
await exited;
NODE
  out="$("$RR_NODE" "$T/handshake.mjs" "$RR_SOURCE_ROOT" "$T" "$RR_NODE" 2>&1)" || rc=$?
  rm -rf "$T"
  [ "$rc" = 0 ] || { echo "$out"; return 1; }
  assert_eq "$out" 'answered the-nonce'
}

test_gc_herdr_reviewer_closed_pr_behavior_is_unchanged() {
  _rr_fixture
  reviewers_write "$(reviewers_rows | jq 'map(.pane="window:pane" | .backend="herdr")')"
  _rr_set '.prState="MERGED"'
  herdr() { [ "$1 $2 $3" = 'pane close window:pane' ] || return 1; printf close > "$RR_T/herdr-close"; }
  reviewer_checkout_release() { printf '%s#%s' "$1" "$2" > "$RR_T/herdr-release"; }
  _rr_gc 0 '{"result":{"agents":[{"pane_id":"window:pane","name":"widget-pr-71-review","agent_status":"idle","cwd":"/fixture","backend":"herdr"}]}}'
  assert_eq "$(cat "$RR_T/herdr-close")" close || return
  assert_eq "$(cat "$RR_T/herdr-release")" widget#71 || return
  assert_eq "$(reviewers_rows | jq length)" 0 || return
  kill -0 "$RR_PID"
}

test_gc_rex_completed_retirement_replay_clears_only_stale_registry() {
  _rr_fixture
  _rr_gc
  _rr_exited || return
  [ ! -f "$RR_RECEIPT" ] || return 1
  reviewers_record "$RR_WS" widget 71 "$RR_PANE" "$RR_ALIAS"
  reviewers_write "$(reviewers_rows | jq 'map(.backend="rex")')"
  _rr_gc 0 '{"result":{"agents":[]}}'
  assert_eq "$(reviewers_rows | jq length)" 0 || return
  assert_eq "$(jq -s '[.[]|select(.cmd=="rex" and (.args|index("kill"))!=null)]|length' "$RR_T/calls.jsonl")" 1 || return
  _rr_preserved
}

test_gc_rex_retirement_replay_rejects_unknown_session_and_changed_evidence() {
  local condition
  for condition in listfailure nativeprefix proofidentity; do
    _rr_fixture
    _rr_gc
    _rr_exited || return
    [ ! -f "$RR_RECEIPT" ] || return 1
    reviewers_record "$RR_WS" widget 71 "$RR_PANE" "$RR_ALIAS"
    reviewers_write "$(reviewers_rows | jq 'map(.backend="rex")')"
    case "$condition" in
      listfailure) _rr_set '.listFailure=true' ;;
      nativeprefix) printf 'corrupted prefix\n' > "$RR_NATIVE" ;;
      proofidentity)
        local completed prepared value
        for completed in "$CEL_REX_STATE"/retirements/*.retired.json; do
          [ -f "$completed" ] || return 1
          prepared="$(jq -er .prepared "$completed")" || return
          value="$(jq '.identity.name="widget-other-review"' "$prepared")" || return
          printf '%s\n' "$value" > "$prepared"
        done ;;
    esac
    _rr_gc 0 '{"result":{"agents":[]}}'
    assert_eq "$(reviewers_find "$RR_WS" widget 71 | jq -r .pane)" "$RR_PANE" || return
    assert_eq "$(jq -s '[.[]|select(.cmd=="rex" and (.args|index("kill"))!=null)]|length' "$RR_T/calls.jsonl")" 1 || return
    _rr_preserved || return
    _rr_cleanup
  done
}

test_gc_rex_native_in_memory_work_vetoes_retirement_with_empty_mailbox() {
  local condition
  for condition in '.nativeTurnActive=true' '.exitTurnActive=true' '.sdkPending=true' '.sdkBusy=true' '.editorDraft="Unsent in-memory draft"' '.inboxOwed=true' '.inboxPending=true' '.inboxWaking=true' '.liveLeaf="tool"' '.liveLeaf="unpersisted-leaf"' '.exitLeaf="request"' '.exitDebt=true'; do
    _rr_fixture
    _rr_set "$condition | .mail=0"
    _rr_gc; _rr_kept || return
    _rr_cleanup
  done
}

test_gc_rex_legacy_runtime_without_native_capability_is_protected() {
  _rr_fixture
  rm "$RR_CAPABILITY"
  _rr_gc
  _rr_kept
}

test_gc_rex_prepared_only_verification_debt_recovers_without_second_close() {
  _rr_fixture
  _rr_set '.listFailure=true'
  _rr_gc
  _rr_exited || return
  [ -f "$RR_RECEIPT" ] || return 1
  assert_eq "$(reviewers_find "$RR_WS" widget 71 | jq -r .pane)" "$RR_PANE" || return
  local completed
  for completed in "$CEL_REX_STATE"/retirements/*.retired.json; do [ ! -e "$completed" ] || return 1; done
  _rr_set '.listFailure=false'
  _rr_gc 0 '{"result":{"agents":[]}}'
  [ ! -f "$RR_RECEIPT" ] || return 1
  assert_eq "$(reviewers_rows | jq length)" 0 || return
  assert_eq "$(jq -s '[.[]|select(.cmd=="rex" and (.args|index("kill"))!=null)]|length' "$RR_T/calls.jsonl")" 1 || return
  _rr_preserved
}

test_gc_rex_unsupported_native_sdk_never_publishes_retirement_capability() {
  export RR_UNSUPPORTED_SDK=1
  _rr_fixture
  assert_eq "$(cat "$RR_T/producer-started")" unsupported || return
  [ ! -f "$RR_CAPABILITY" ] || return 1
  _rr_gc
  _rr_kept
}

test_gc_rex_native_shutdown_failure_preserves_runtime_and_restores_inbox() {
  _rr_fixture
  _rr_set '.shutdownThrows=true'
  _rr_gc
  _rr_kept || return
  jq -se 'any(.[]; .type=="inbox-stopped") and any(.[]; .type=="sdk-shutdown") and any(.[]; .type=="inbox-restored")' "$RR_T/producer-events.jsonl" >/dev/null
}

test_gc_rex_unknown_exit_or_replacement_terminal_keeps_retirement_debt() {
  local condition
  for condition in '.unknownLastExit=true' '.failedLastExit=true' '.replacementAfterExit=true'; do
    _rr_fixture
    _rr_set "$condition"
    _rr_gc
    _rr_exited || return
    [ -f "$RR_RECEIPT" ] || return 1
    assert_eq "$(reviewers_find "$RR_WS" widget 71 | jq -r .pane)" "$RR_PANE" || return
    assert_eq "$reviewers_closed" 0 || return
    assert_eq "$(jq -s '[.[]|select(.cmd=="rex" and (.args|index("kill"))!=null)]|length' "$RR_T/calls.jsonl")" 0 || return
    _rr_preserved || return
    _rr_cleanup
  done
}

test_gc_rex_session_metadata_and_unrelated_review_churn_do_not_veto_retirement() {
  _rr_fixture
  _rr_set '.revisionChurn=true | .unrelatedRoundChurn=true'
  local own_round
  own_round="$(jq -c '."widget#71"' "$RR_WS/.cel/solo-reviews.json")"
  _rr_gc
  _rr_exited || return
  [ ! -f "$RR_RECEIPT" ] || return 1
  assert_eq "$(reviewers_rows | jq length)" 0 || return
  assert_eq "$(jq -c '."widget#71"' "$RR_WS/.cel/solo-reviews.json")" "$own_round" || return
  jq -e 'has("widget#99")' "$RR_WS/.cel/solo-reviews.json" >/dev/null || return
  # Only the unrelated reviewer intentionally changes the aggregate ledger.
  RR_VERDICT_BEFORE="$(sha256sum "$RR_WS/.cel/solo-reviews.json")"
  assert_eq "$(sha256sum "$RR_NATIVE")" "$RR_NATIVE_BEFORE" || return
  _rr_preserved
}

test_gc_rex_accepted_native_exit_recovers_missing_controller_sidecar() {
  _rr_fixture
  _rr_set '.listFailure=true'
  _rr_gc
  _rr_exited || return
  local exit_proof
  for exit_proof in "$CEL_REX_STATE"/retirements/*.exit.json; do
    [ -f "$exit_proof" ] || return 1
    rm "$exit_proof"
  done
  _rr_set '.listFailure=false'
  _rr_gc 1 '{"result":{"agents":[]}}'
  [ -f "$RR_RECEIPT" ] && [ ! -e "$exit_proof" ] || return 1
  assert_eq "$(reviewers_find "$RR_WS" widget 71 | jq -r .pane)" "$RR_PANE" || return
  _rr_gc 0 '{"result":{"agents":[]}}'
  [ ! -f "$RR_RECEIPT" ] && [ -f "$exit_proof" ] || return 1
  assert_eq "$(reviewers_rows | jq length)" 0 || return
  assert_eq "$(jq -s '[.[]|select(.cmd=="rex" and (.args|index("kill"))!=null)]|length' "$RR_T/calls.jsonl")" 1 || return
  _rr_preserved
}

test_gc_rex_prepared_debt_without_valid_native_exit_proof_cannot_settle() {
  local condition
  for condition in missing uncommitted expired; do
    _rr_fixture
    _rr_set '.listFailure=true'
    _rr_gc
    _rr_exited || return
    [ -f "$RR_RECEIPT" ] || return 1
    local exit_proof value found=0
    for exit_proof in "$CEL_REX_STATE"/retirements/*.exit.json; do
      [ -f "$exit_proof" ] || continue
      found=$((found+1))
      case "$condition" in
        missing) rm "$exit_proof" "$RR_PROTOCOL_DIRECTORY/response.json" ;;
        uncommitted)
          value="$(jq '.response.exit_committed=false' "$exit_proof")" || return
          printf '%s\n' "$value" > "$exit_proof" ;;
        expired)
          value="$(jq '.response.observed_at=0' "$exit_proof")" || return
          printf '%s\n' "$value" > "$exit_proof" ;;
      esac
    done
    [ "$found" -gt 0 ] || return 1
    _rr_set '.listFailure=false'
    _rr_gc 0 '{"result":{"agents":[]}}'
    [ -f "$RR_RECEIPT" ] || return 1
    assert_eq "$(reviewers_find "$RR_WS" widget 71 | jq -r .pane)" "$RR_PANE" || return
    assert_eq "$reviewers_closed" 0 || return
    assert_eq "$(jq -s '[.[]|select(.cmd=="rex" and (.args|index("kill"))!=null)]|length' "$RR_T/calls.jsonl")" 1 || return
    _rr_preserved || return
    _rr_cleanup
  done
}

test_gc_rex_failed_empty_session_close_retries_without_native_shutdown_again() {
  _rr_fixture
  _rr_set '.closeFailure=true'
  _rr_gc
  _rr_exited || return
  [ -f "$RR_RECEIPT" ] || return 1
  assert_eq "$(reviewers_find "$RR_WS" widget 71 | jq -r .pane)" "$RR_PANE" || return
  assert_eq "$reviewers_closed" 0 || return
  assert_eq "$(jq -s '[.[]|select(.type=="sdk-shutdown")]|length' "$RR_T/producer-events.jsonl")" 1 || return
  assert_eq "$(jq -s '[.[]|select(.cmd=="rex" and (.args|index("kill"))!=null)]|length' "$RR_T/calls.jsonl")" 1 || return
  _rr_set '.closeFailure=false'
  _rr_gc 1 '{"result":{"agents":[]}}'
  [ -f "$RR_RECEIPT" ] || return 1
  assert_eq "$(reviewers_find "$RR_WS" widget 71 | jq -r .pane)" "$RR_PANE" || return
  assert_eq "$(jq -s '[.[]|select(.type=="sdk-shutdown")]|length' "$RR_T/producer-events.jsonl")" 1 || return
  assert_eq "$(jq -s '[.[]|select(.cmd=="rex" and (.args|index("kill"))!=null)]|length' "$RR_T/calls.jsonl")" 1 || return
  _rr_gc 0 '{"result":{"agents":[]}}'
  [ ! -f "$RR_RECEIPT" ] || return 1
  assert_eq "$(reviewers_rows | jq length)" 0 || return
  assert_eq "$(jq -s '[.[]|select(.type=="sdk-shutdown")]|length' "$RR_T/producer-events.jsonl")" 1 || return
  assert_eq "$(jq -s '[.[]|select(.cmd=="rex" and (.args|index("kill"))!=null)]|length' "$RR_T/calls.jsonl")" 2 || return
  assert_eq "$(jq -r '.nativeLiveAtKill // false' "$RR_T/boundary.json")" false || return
  _rr_preserved
}

test_gc_rex_failed_close_retry_protects_changed_or_unknown_terminal() {
  local condition
  for condition in '.extraBlock=true' '.extraWindow=true' '.replacementAfterExit=true' '.unknownLastExit=true' '.failedLastExit=true'; do
    _rr_fixture
    _rr_set '.closeFailure=true'
    _rr_gc
    _rr_exited || return
    [ -f "$RR_RECEIPT" ] || return 1
    _rr_set ".closeFailure=false | $condition"
    _rr_gc 0 '{"result":{"agents":[]}}'
    [ -f "$RR_RECEIPT" ] || return 1
    assert_eq "$(reviewers_find "$RR_WS" widget 71 | jq -r .pane)" "$RR_PANE" || return
    assert_eq "$reviewers_closed" 0 || return
    assert_eq "$(jq -s '[.[]|select(.type=="sdk-shutdown")]|length' "$RR_T/producer-events.jsonl")" 1 || return
    assert_eq "$(jq -s '[.[]|select(.cmd=="rex" and (.args|index("kill"))!=null)]|length' "$RR_T/calls.jsonl")" 1 || return
    _rr_preserved || return
    _rr_cleanup
  done
}

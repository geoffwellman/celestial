# shellcheck shell=bash
# Exercise the real retirement policy and GC integration. Only external Rex,
# GitHub and inbox boundaries are fixtures; native history, /proc generations,
# descendants, receipts, verdicts and registry updates are real private files.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/registry.sh"
source "$CEL_ROOT/lib/gc.sh"
source "$CEL_ROOT/lib/reviewer-retirement.sh"
RR_SOURCE_ROOT="$CEL_ROOT"
RR_NODE="$(node -p process.execPath)"

_rr_fixture() {
  umask 077
  RR_T="$(mktemp -d)"
  RR_PID=""
  trap '_rr_cleanup' EXIT
  export HOME="$RR_T/home" CEL_REGISTRY="$RR_T/registry.yaml"
  export CEL_REX_STATE="$RR_T/rex" CEL_REVIEWERS_STATE="$RR_T/reviewers.json"
  export CEL_GC_REVIEWER_STOP_STATE="$RR_T/stop.json" RR_T
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
  printf 'name: bundle\n' > "$RR_WS/workspace.yaml"
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
    getLeafId:()=>exiting()&&state().exitLeaf?state().exitLeaf:(state().liveLeaf||'final'),
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
} else if (cmd === 'cel') {
  if (args[0] !== 'inbox' || args[1] !== 'count') process.exit(91);
  if (state.mailFailure) process.exit(1);
  console.log(state.mail);
} else if (cmd === 'rex') {
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
  jq -n --arg head "$RR_HEAD" --arg cwd "$RR_CO" \
    '{head:$head,cwd:$cwd,prState:"OPEN",mail:0,capture:("Review complete; verdict recorded.\n────────────────────\n\n────────────────────\n"+$cwd+"\nusage counters (fixture) fixture-model\n")}' > "$RR_T/boundary.json"
  : > "$RR_T/calls.jsonl"
  _rr_native completed
  jq -n --arg head "$RR_HEAD" --arg by "$RR_ALIAS" \
    '{"widget#71":{verdict:"approved",by:$by,head:$head,at:"2026-01-01T00:01:00Z",note:"Fixture review"}}' > "$RR_WS/.cel/solo-reviews.json"
  _rr_start || { printf 'retirement fixture native protocol startup failed\n' >&2; exit 1; }
  reviewers_record widget 71 "$RR_PANE" "$RR_ALIAS"
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
  ws_repo_github_slug() { printf acme/widget; }
  local i
  for ((i=0;i<100;i++)); do [ -s "$RR_T/ready" ] && break; sleep .02; done
  [ -s "$RR_T/ready" ] || return 1
  if [ "${RR_JOB:-0}" = 1 ]; then
    for ((i=0;i<100;i++)); do [ -s "$RR_T/job.pid" ] && break; sleep .02; done
    [ -s "$RR_T/job.pid" ] || return 1
  fi
  jq -n --arg name "$RR_ALIAS" --arg cwd "$RR_CO" --arg workspace "$RR_WS" \
    --arg pane "$RR_PANE" --argjson pid "$RR_PID" --arg start "$RR_PID_START" --arg native "$RR_NATIVE" \
    '{name:$name,agent:"pi",cwd:$cwd,role:"reviewer",workspace:$workspace,repo:"widget",pr:"71",pane_id:$pane,backend:"rex",rex_session:"widget-review",rex_block:"terminal",pid:$pid,pid_start:$start,agent_status:"idle",agent_session:{value:$native}}' > "$RR_RECEIPT"
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
  assert_eq "$(reviewers_find widget 71 | jq -r .pane)" "$RR_PANE" || return
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

test_gc_rex_completed_exact_head_rounds_retire_and_preserve_evidence() {
  local verdict state
  for verdict in approved changes; do
    for state in OPEN MERGED; do
      _rr_fixture
      _rr_set ".prState=\"$state\""
      if [ "$verdict" = changes ]; then _rr_set '.stoppedNulls=true'; fi
      local rounds; rounds="$(jq --arg v "$verdict" '."widget#71".verdict=$v' "$RR_WS/.cel/solo-reviews.json")"
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
      jq -se '
        [to_entries[] | select(.value.cmd=="rex" and (.value.args|index("kill"))!=null)] as $close |
        ($close|length)==1 and
        ($close[0].value.args|index("--autostart=false"))!=null and
        ($close[0].value.args|index("widget-review"))!=null and
        any(to_entries[]; .key>$close[0].key and .value.cmd=="rex" and (.value.args|index("ls"))!=null)
      ' "$RR_T/calls.jsonl" >/dev/null || return
      _rr_cleanup
    done
  done
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
    assert_eq "$(reviewers_find widget 71 | jq -r .pane)" "$RR_PANE" || return
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

test_gc_gone_rex_metadata_retains_checkout_and_evidence() {
  _rr_fixture
  kill "$RR_PID"; wait "$RR_PID" 2>/dev/null || true
  _rr_gc 0 '{"result":{"agents":[]}}'
  _rr_preserved || return
  # A gone roster is not physical-retirement proof or permission to release.
  assert_eq "$(reviewers_find widget 71 | jq -r .pane)" "$RR_PANE" || return
  [ -f "$RR_RECEIPT" ]
}

test_gc_rex_retirement_does_not_drop_a_concurrently_rebound_registry_row() {
  _rr_fixture
  _rr_set '.rebindRegistry=true'
  _rr_gc
  _rr_exited || return
  assert_eq "$(reviewers_find widget 71 | jq -r .pane)" rex/replacement/terminal || return
  _rr_preserved
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
  reviewers_record widget 71 "$RR_PANE" "$RR_ALIAS"
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
    reviewers_record widget 71 "$RR_PANE" "$RR_ALIAS"
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
    assert_eq "$(reviewers_find widget 71 | jq -r .pane)" "$RR_PANE" || return
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
  assert_eq "$(reviewers_find widget 71 | jq -r .pane)" "$RR_PANE" || return
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
    assert_eq "$(reviewers_find widget 71 | jq -r .pane)" "$RR_PANE" || return
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
        missing) rm "$exit_proof" ;;
        uncommitted)
          value="$(jq '.exit_committed=false' "$exit_proof")" || return
          printf '%s\n' "$value" > "$exit_proof" ;;
        expired)
          value="$(jq '.observed_at=0' "$exit_proof")" || return
          printf '%s\n' "$value" > "$exit_proof" ;;
      esac
    done
    [ "$found" -gt 0 ] || return 1
    _rr_set '.listFailure=false'
    _rr_gc 0 '{"result":{"agents":[]}}'
    [ -f "$RR_RECEIPT" ] || return 1
    assert_eq "$(reviewers_find widget 71 | jq -r .pane)" "$RR_PANE" || return
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
  assert_eq "$(reviewers_find widget 71 | jq -r .pane)" "$RR_PANE" || return
  assert_eq "$reviewers_closed" 0 || return
  assert_eq "$(jq -s '[.[]|select(.type=="sdk-shutdown")]|length' "$RR_T/producer-events.jsonl")" 1 || return
  assert_eq "$(jq -s '[.[]|select(.cmd=="rex" and (.args|index("kill"))!=null)]|length' "$RR_T/calls.jsonl")" 1 || return
  _rr_set '.closeFailure=false'
  _rr_gc 1 '{"result":{"agents":[]}}'
  [ -f "$RR_RECEIPT" ] || return 1
  assert_eq "$(reviewers_find widget 71 | jq -r .pane)" "$RR_PANE" || return
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
    assert_eq "$(reviewers_find widget 71 | jq -r .pane)" "$RR_PANE" || return
    assert_eq "$reviewers_closed" 0 || return
    assert_eq "$(jq -s '[.[]|select(.type=="sdk-shutdown")]|length' "$RR_T/producer-events.jsonl")" 1 || return
    assert_eq "$(jq -s '[.[]|select(.cmd=="rex" and (.args|index("kill"))!=null)]|length' "$RR_T/calls.jsonl")" 1 || return
    _rr_preserved || return
    _rr_cleanup
  done
}

// VS-01 WP01 live stress against the disposable Supabase spike project.
// Uses the same local-only environment as live_smoke.mjs. Prints no token, key or password.
// Optional: MYRIAL_SPIKE_EMAIL_B / MYRIAL_SPIKE_PASSWORD_B (second test account, cross-account check)
// and --with-expiry (waits for the 90 s lease to expire, then checks takeover; adds about 100 s).
// Exit codes: 0 PASS, 1 FAIL, 2 BLOCKED (missing environment).
import {randomUUID} from 'node:crypto';

const required=['MYRIAL_SPIKE_SUPABASE_URL','MYRIAL_SPIKE_SUPABASE_PUBLISHABLE_KEY','MYRIAL_SPIKE_EMAIL','MYRIAL_SPIKE_PASSWORD','MYRIAL_SPIKE_SESSION_ID'];
const missing=required.filter(name=>!process.env[name]);
if(missing.length){
  console.error(`LIVE_STRESS_BLOCKED missing environment: ${missing.join(', ')}`);
  process.exit(2);
}

const url=process.env.MYRIAL_SPIKE_SUPABASE_URL.replace(/\/$/,'');
const key=process.env.MYRIAL_SPIKE_SUPABASE_PUBLISHABLE_KEY;
const sessionA=process.env.MYRIAL_SPIKE_SESSION_ID;
const withExpiry=process.argv.includes('--with-expiry');
const results={};
const record=(name,pass,detail)=>{results[name]={result:pass?'PASS':'FAIL',...detail};};
const json=async response=>{
  const text=await response.text();
  let body=null;
  try{body=text?JSON.parse(text):null;}catch{body={unparsed:true};}
  return {status:response.status,body};
};
const signIn=async(email,password)=>{
  const auth=await json(await fetch(`${url}/auth/v1/token?grant_type=password`,{
    method:'POST',headers:{apikey:key,'content-type':'application/json'},body:JSON.stringify({email,password}),
  }));
  if(auth.status!==200)throw new Error(`Auth failed with HTTP ${auth.status}`);
  return {token:auth.body.access_token,userId:auth.body.user.id};
};
const client=token=>body=>fetch(`${url}/functions/v1/command`,{
  method:'POST',headers:{apikey:key,authorization:`Bearer ${token}`,'content-type':'application/json'},
  body:JSON.stringify(body),
}).then(json);
const timed=async fn=>{const start=performance.now();const value=await fn();return {value,ms:performance.now()-start};};
const percentile=(values,p)=>{const sorted=[...values].sort((a,b)=>a-b);return Math.round(sorted[Math.min(sorted.length-1,Math.floor(sorted.length*p))]);};
const command=(sessionId,idempotencyKey,overrides={})=>({action:'apply_test_command',sessionId,idempotencyKey,moneyDelta:1,itemId:'spike_item',quantityDelta:1,...overrides});
const state=async invoke=>{const read=await invoke({action:'get_state'});if(read.status!==200)throw new Error(`get_state HTTP ${read.status}`);return read.body.state;};
const run=`stress-${Date.now()}`;

try{
  const a=await signIn(process.env.MYRIAL_SPIKE_EMAIL,process.env.MYRIAL_SPIKE_PASSWORD);
  const invokeA=client(a.token);
  const started=await invokeA({action:'start_session',sessionId:sessionA});
  if(started.status!==200)throw new Error(`start_session for the fixed session returned HTTP ${started.status} ${started.body?.errorCode??''}; if a takeover ran recently, wait for the 90 s lease to expire`);

  // 1. Parallel duplicate delivery: one key sent 20 times at once mutates exactly once.
  {
    const before=await state(invokeA);
    const replies=await Promise.all(Array.from({length:20},()=>invokeA(command(sessionA,`${run}-dup`))));
    const after=await state(invokeA);
    const ok=replies.filter(r=>r.status===200);
    const fresh=ok.filter(r=>r.body.replayed===false).length;
    const revisions=new Set(ok.map(r=>r.body.state.revision));
    record('parallel_duplicate_x20',ok.length===20&&fresh===1&&revisions.size===1&&after.revision===before.revision+1&&after.money===before.money+1,
      {ok:ok.length,fresh,distinctRevisions:revisions.size,revisionDelta:after.revision-before.revision,moneyDelta:after.money-before.money});
  }

  // 2. Parallel unique commands: 20 different keys at once all apply, with no lost update.
  {
    const before=await state(invokeA);
    const replies=await Promise.all(Array.from({length:20},(_,i)=>invokeA(command(sessionA,`${run}-par-${i}`))));
    const after=await state(invokeA);
    const ok=replies.filter(r=>r.status===200&&r.body.replayed===false).length;
    const revisions=new Set(replies.filter(r=>r.status===200).map(r=>r.body.state.revision));
    record('parallel_unique_x20',ok===20&&revisions.size===20&&after.revision===before.revision+20&&after.money===before.money+20,
      {ok,distinctRevisions:revisions.size,revisionDelta:after.revision-before.revision,moneyDelta:after.money-before.money});
  }

  // 3. Rapid sequential burst with latency and error capture.
  {
    const latencies=[];let errors=0;
    for(let i=0;i<30;i++){
      const {value,ms}=await timed(()=>invokeA(command(sessionA,`${run}-seq-${i}`)));
      latencies.push(ms);if(value.status!==200||value.body.replayed!==false)errors++;
    }
    record('sequential_burst_x30',errors===0,{errors,p50Ms:percentile(latencies,0.5),p95Ms:percentile(latencies,0.95),maxMs:percentile(latencies,1)});
  }

  // 4. Lost-response retry after the burst still returns the stored receipt.
  {
    const first=await invokeA(command(sessionA,`${run}-retry`));
    const retry=await invokeA(command(sessionA,`${run}-retry`));
    record('lost_response_retry',first.status===200&&retry.status===200&&retry.body.replayed===true&&retry.body.state.revision===first.body.state.revision,
      {firstRevision:first.body?.state?.revision,retryReplayed:retry.body?.replayed});
  }

  // 5. Rejected command is atomic.
  {
    const before=await state(invokeA);
    const rejected=await invokeA(command(sessionA,`${run}-invalid`,{moneyDelta:-5000}));
    const after=await state(invokeA);
    record('rejected_command_atomic',rejected.status!==200&&rejected.body?.errorCode==='ERR_MONEY_DELTA'&&after.revision===before.revision&&after.money===before.money,
      {errorCode:rejected.body?.errorCode,revisionDelta:after.revision-before.revision});
  }

  // 6. Session takeover while the lease is live is refused; the holder keeps authority.
  const sessionB=randomUUID();
  {
    const takeover=await invokeA({action:'start_session',sessionId:sessionB});
    const holder=await invokeA(command(sessionA,`${run}-holder`));
    const intruder=await invokeA(command(sessionB,`${run}-intruder`));
    record('session_takeover_refused',takeover.body?.errorCode==='ERR_SESSION_ACTIVE'&&holder.status===200&&intruder.body?.errorCode==='ERR_SESSION_STALE',
      {takeover:takeover.body?.errorCode??takeover.status,holder:holder.status,intruder:intruder.body?.errorCode??intruder.status});
  }

  // 7. Cross-account isolation (needs a second disposable account).
  if(process.env.MYRIAL_SPIKE_EMAIL_B&&process.env.MYRIAL_SPIKE_PASSWORD_B){
    const b=await signIn(process.env.MYRIAL_SPIKE_EMAIL_B,process.env.MYRIAL_SPIKE_PASSWORD_B);
    const foreign=await json(await fetch(`${url}/rest/v1/spike_player_progress?user_id=eq.${a.userId}&select=user_id`,{
      headers:{apikey:key,authorization:`Bearer ${b.token}`},
    }));
    const foreignCommand=await client(b.token)(command(sessionA,`${run}-foreign`));
    record('cross_account_isolation',b.userId!==a.userId&&Array.isArray(foreign.body)&&foreign.body.length===0&&foreignCommand.status!==200,
      {foreignRowsVisible:Array.isArray(foreign.body)?foreign.body.length:'error',foreignCommand:foreignCommand.body?.errorCode??foreignCommand.status});
  }else results.cross_account_isolation={result:'NOT RUN',reason:'MYRIAL_SPIKE_EMAIL_B / MYRIAL_SPIKE_PASSWORD_B not set'};

  // 8. Lease expiry: after 90 s without renewal the new session takes over and the old one is stale.
  if(withExpiry){
    await new Promise(resolve=>setTimeout(resolve,95_000));
    const takeover=await invokeA({action:'start_session',sessionId:sessionB});
    const stale=await invokeA(command(sessionA,`${run}-stale`));
    const fresh=await invokeA(command(sessionB,`${run}-new-holder`));
    record('lease_expiry_takeover',takeover.status===200&&stale.body?.errorCode==='ERR_SESSION_STALE'&&fresh.status===200,
      {takeover:takeover.status,oldSession:stale.body?.errorCode??stale.status,newSession:fresh.status,note:'the fixed session is now stale for up to 90 s'});
  }else results.lease_expiry_takeover={result:'NOT RUN',reason:'run with --with-expiry'};
}catch(error){
  results.run_error={result:'FAIL',message:String(error.message)};
}

const failed=Object.values(results).some(r=>r.result==='FAIL');
console.log(JSON.stringify({run,overall:failed?'FAIL':'PASS',results},null,2));
process.exitCode=failed?1:0;

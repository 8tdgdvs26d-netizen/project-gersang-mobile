const required=['MYRIAL_SPIKE_SUPABASE_URL','MYRIAL_SPIKE_SUPABASE_PUBLISHABLE_KEY','MYRIAL_SPIKE_EMAIL','MYRIAL_SPIKE_PASSWORD','MYRIAL_SPIKE_SESSION_ID'];
const missing=required.filter(name=>!process.env[name]);
if(missing.length){
  console.error(`LIVE_SPIKE_BLOCKED missing environment: ${missing.join(', ')}`);
  process.exitCode=2;
}else{
  const url=process.env.MYRIAL_SPIKE_SUPABASE_URL.replace(/\/$/,'');
  const key=process.env.MYRIAL_SPIKE_SUPABASE_PUBLISHABLE_KEY;
  const sessionId=process.env.MYRIAL_SPIKE_SESSION_ID;
  const json=async(response)=>{
    const text=await response.text();
    return {status:response.status,body:text?JSON.parse(text):null};
  };
  const auth=await json(await fetch(`${url}/auth/v1/token?grant_type=password`,{
    method:'POST',headers:{apikey:key,'content-type':'application/json'},
    body:JSON.stringify({email:process.env.MYRIAL_SPIKE_EMAIL,password:process.env.MYRIAL_SPIKE_PASSWORD}),
  }));
  if(auth.status!==200)throw new Error(`Auth failed: ${JSON.stringify(auth)}`);
  const token=auth.body.access_token;
  const invoke=body=>fetch(`${url}/functions/v1/command`,{
    method:'POST',headers:{apikey:key,authorization:`Bearer ${token}`,'content-type':'application/json'},
    body:JSON.stringify(body),
  }).then(json);
  const started=await invoke({action:'start_session',sessionId});
  if(started.status!==200)throw new Error(`Start session failed: ${JSON.stringify(started)}`);
  const keyOnce=`live-${Date.now()}`;
  const command={action:'apply_test_command',sessionId,idempotencyKey:keyOnce,moneyDelta:-10,itemId:'spike_item',quantityDelta:1};
  const first=await invoke(command),retry=await invoke(command);
  if(first.status!==200||retry.status!==200||retry.body.replayed!==true||first.body.state.revision!==retry.body.state.revision){
    throw new Error(`Idempotency failed: ${JSON.stringify({first,retry})}`);
  }
  const beforeDirect=await invoke({action:'get_state'});
  if(beforeDirect.status!==200)throw new Error(`State read before direct-write check failed: ${JSON.stringify(beforeDirect)}`);
  const direct=await json(await fetch(`${url}/rest/v1/spike_player_progress?user_id=eq.${auth.body.user.id}`,{
    method:'PATCH',headers:{apikey:key,authorization:`Bearer ${token}`,'content-type':'application/json','prefer':'return=representation'},
    body:JSON.stringify({money:999999}),
  }));
  const afterDirect=await invoke({action:'get_state'});
  if(afterDirect.status!==200)throw new Error(`State read after direct-write check failed: ${JSON.stringify(afterDirect)}`);
  const stateChanged=beforeDirect.body.state.money!==afterDirect.body.state.money||beforeDirect.body.state.revision!==afterDirect.body.state.revision;
  const rowsReturned=Array.isArray(direct.body)&&direct.body.length>0;
  if(stateChanged||rowsReturned)throw new Error(`Direct client progress write changed or exposed state: ${JSON.stringify({direct,beforeDirect,afterDirect})}`);
  console.log(JSON.stringify({auth:'PASS',session:'PASS',idempotency:'PASS',directWriteDenied:'PASS',revision:first.body.state.revision}));
}

import {createClient} from 'https://esm.sh/@supabase/supabase-js@2';

const cors={
  'access-control-allow-origin':'*',
  'access-control-allow-headers':'authorization, apikey, content-type',
};
const reply=(status:number,body:unknown)=>new Response(JSON.stringify(body),{
  status,headers:{...cors,'content-type':'application/json'},
});
const knownDatabaseErrors=[
  'ERR_LEASE_RANGE','ERR_SESSION_ACTIVE','ERR_SESSION_STALE','ERR_IDEMPOTENCY_KEY',
  'ERR_ITEM','ERR_MONEY_DELTA','ERR_QUANTITY_DELTA','ERR_INSUFFICIENT_MONEY',
  'ERR_INSUFFICIENT_ITEM','ERR_PROGRESS_MISSING',
];
const safeDatabaseError=(message:string)=>
  knownDatabaseErrors.find(code=>message.includes(code))??'ERR_BACKEND';

Deno.serve(async request=>{
  if(request.method==='OPTIONS')return new Response('ok',{headers:cors});
  if(request.method!=='POST')return reply(405,{ok:false,errorCode:'ERR_METHOD'});
  const url=Deno.env.get('SUPABASE_URL');
  const anonKey=Deno.env.get('SUPABASE_ANON_KEY');
  const serviceKey=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const authorization=request.headers.get('authorization');
  if(!url||!anonKey||!serviceKey)return reply(500,{ok:false,errorCode:'ERR_SERVER_CONFIG'});
  if(!authorization)return reply(401,{ok:false,errorCode:'ERR_AUTH_REQUIRED'});

  const caller=createClient(url,anonKey,{global:{headers:{Authorization:authorization}}});
  const {data:{user},error:userError}=await caller.auth.getUser();
  if(userError||!user)return reply(401,{ok:false,errorCode:'ERR_AUTH_INVALID'});

  let body:Record<string,unknown>;
  try{body=await request.json();}catch{return reply(400,{ok:false,errorCode:'ERR_JSON'});}
  const service=createClient(url,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});

  if(body.action==='get_state'){
    const {data,error}=await service.from('spike_player_progress')
      .select('revision,money,inventory,updated_at').eq('user_id',user.id).maybeSingle();
    if(error)return reply(400,{ok:false,errorCode:'ERR_STATE_READ'});
    return reply(200,{ok:true,state:data});
  }

  if(body.action==='start_session'){
    const {data,error}=await service.rpc('spike_start_session',{
      p_user_id:user.id,p_session_id:body.sessionId,p_lease_seconds:90,
    });
    if(error)return reply(409,{ok:false,errorCode:safeDatabaseError(error.message)});
    return reply(200,data);
  }

  if(body.action==='apply_test_command'){
    const {data,error}=await service.rpc('spike_apply_command',{
      p_user_id:user.id,
      p_session_id:body.sessionId,
      p_idempotency_key:body.idempotencyKey,
      p_money_delta:body.moneyDelta,
      p_item_id:body.itemId,
      p_quantity_delta:body.quantityDelta,
    });
    if(error)return reply(400,{ok:false,errorCode:safeDatabaseError(error.message)});
    return reply(200,data);
  }
  return reply(400,{ok:false,errorCode:'ERR_ACTION'});
});

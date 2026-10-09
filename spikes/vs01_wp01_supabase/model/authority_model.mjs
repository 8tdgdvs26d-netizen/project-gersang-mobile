const clone=value=>structuredClone(value);

const failure=errorCode=>({ok:false,errorCode});

export class AuthorityModel{
  constructor({leaseMs=90_000}={}){
    this.leaseMs=leaseMs;
    this.progress=new Map();
    this.sessions=new Map();
    this.receipts=new Map();
    this.audit=[];
  }

  ensureUser(userId){
    if(typeof userId!=='string'||userId.length===0)return failure('ERR_AUTH_REQUIRED');
    if(!this.progress.has(userId))this.progress.set(userId,{revision:0,money:1000,inventory:{}});
    return {ok:true};
  }

  startSession(userId,sessionId,nowMs){
    if(!this.ensureUser(userId).ok)return failure('ERR_AUTH_REQUIRED');
    if(typeof sessionId!=='string'||sessionId.length===0)return failure('ERR_SESSION_ID');
    if(!Number.isSafeInteger(nowMs)||nowMs<0)return failure('ERR_TIME');
    const current=this.sessions.get(userId);
    if(current&&current.sessionId!==sessionId&&current.leaseExpiresAt>nowMs)return failure('ERR_SESSION_ACTIVE');
    const session={sessionId,leaseExpiresAt:nowMs+this.leaseMs};
    this.sessions.set(userId,session);
    return {ok:true,...clone(session)};
  }

  readState(requesterId,targetUserId=requesterId){
    if(requesterId!==targetUserId)return failure('ERR_FORBIDDEN');
    if(!this.ensureUser(requesterId).ok)return failure('ERR_AUTH_REQUIRED');
    return {ok:true,state:clone(this.progress.get(requesterId))};
  }

  applyCommand(userId,{sessionId,idempotencyKey,moneyDelta,itemId,quantityDelta},nowMs){
    if(!this.ensureUser(userId).ok)return failure('ERR_AUTH_REQUIRED');
    const session=this.sessions.get(userId);
    if(!session||session.sessionId!==sessionId||session.leaseExpiresAt<=nowMs)return failure('ERR_SESSION_STALE');
    if(typeof idempotencyKey!=='string'||idempotencyKey.length<1||idempotencyKey.length>128)return failure('ERR_IDEMPOTENCY_KEY');
    const receiptKey=`${userId}:${idempotencyKey}`;
    if(this.receipts.has(receiptKey))return {...clone(this.receipts.get(receiptKey)),replayed:true};
    if(!Number.isSafeInteger(moneyDelta)||Math.abs(moneyDelta)>100)return failure('ERR_MONEY_DELTA');
    if(itemId!=='spike_item')return failure('ERR_ITEM');
    if(!Number.isSafeInteger(quantityDelta)||quantityDelta===0||Math.abs(quantityDelta)>10)return failure('ERR_QUANTITY_DELTA');

    const before=this.progress.get(userId);
    const oldQuantity=before.inventory[itemId]??0;
    const nextMoney=before.money+moneyDelta;
    const nextQuantity=oldQuantity+quantityDelta;
    if(nextMoney<0)return failure('ERR_INSUFFICIENT_MONEY');
    if(nextQuantity<0)return failure('ERR_INSUFFICIENT_ITEM');

    const next=clone(before);
    next.revision++;
    next.money=nextMoney;
    next.inventory[itemId]=nextQuantity;
    const response={ok:true,replayed:false,state:clone(next)};
    this.progress.set(userId,next);
    this.receipts.set(receiptKey,clone(response));
    this.audit.push({userId,idempotencyKey,sessionId,revision:next.revision,moneyDelta,itemId,quantityDelta});
    return response;
  }
}

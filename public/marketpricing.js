// Phase 3 P3-02 — pure market execution pricing. Prototype parameter, not permanent balance.
export const MARKET_BATCH_SIZE=10;

export function marketExecutionQuote({referencePrice,spread,side,quantity,budget=Number.POSITIVE_INFINITY,batchSize=MARKET_BATCH_SIZE}){
  if(side!=='BUY'&&side!=='SELL')throw new Error('ERR_INVALID_MARKET_SIDE');
  if(!Number.isInteger(quantity)||quantity<0)throw new Error('ERR_INVALID_QUANTITY');
  if(!Number.isInteger(batchSize)||batchSize<=0)throw new Error('ERR_INVALID_BATCH_SIZE');
  let remaining=quantity,fillQuantity=0,total=0,ref=referencePrice;
  const batches=[];
  while(remaining>0){
    const planned=Math.min(batchSize,remaining);
    const unitPrice=side==='BUY'?ref+spread:Math.max(1,ref-spread);
    const affordable=side==='BUY'?Math.min(planned,Math.max(0,Math.floor((budget-total)/unitPrice))):planned;
    if(affordable<=0)break;
    total+=affordable*unitPrice;fillQuantity+=affordable;remaining-=affordable;
    batches.push({quantity:affordable,unitPrice,referencePrice:ref});
    ref=Math.max(1,ref+(side==='BUY'?1:-1));
    if(affordable<planned)break;
  }
  return {fillQuantity,total,averageUnitPrice:fillQuantity?total/fillQuantity:0,finalReferencePrice:ref,batches};
}

/* Детализированные ресурсы для строительства и перевозок. */
(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.StrategyResources=api;
})(typeof globalThis==='object'?globalThis:this,function(){
  'use strict';
  const cell=320,atlas='assets/resources/construction-resources.webp';
  const variants={
    boards:[0,1],stone:[2,3],logs:[4,5],
    grain:[6,7],flour:[8,9]
  };
  function sprite(resource,count=1){
    const pair=variants[resource];if(!pair||count<=0)return null;
    const index=pair[count>1?1:0];
    return {x:(index%5)*cell,y:Math.floor(index/5)*cell,w:cell,h:cell};
  }
  function visibleMaterials(site){
    const {goods={},required={}}=site;
    const fraction=Math.min(1,Math.max(0,(site.progress||0)/Math.max(1,site.duration||1)));
    const remaining=fraction<=.2?1:Math.max(0,(1-fraction)/.8);
    return ['boards','stone'].filter(r=>(required[r]||0)>0).map(resource=>{
      const delivered=Math.min(required[resource],Math.max(0,goods[resource]||0));
      const visible=Math.min(4,Math.ceil(delivered*remaining));
      return {resource,delivered,required:required[resource],visible};
    });
  }
  return Object.freeze({cell,atlas,variants,sprite,visibleMaterials});
});
